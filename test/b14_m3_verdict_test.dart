// 十四批 M3：attempts 生命周期、P1-A 标签改动、会话持久化、
// 恢复清会话、专项练习重新加入复习、hasSessionVerdict 读路径。
// verdict 提交事务（治愈规则 (d)+⑥、幂等、中性事件）已随 FSRS
// 全量迁移（包1）退役删除。走真实内存库（AppDatabase.openForTest），
// 不调真实接口。
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';

Question _q(
  String id, {
  List<String> errorTypes = const ['计算错误'],
  String? questionType,
  List<String>? optionLabels,
  bool optionLabelsConfirmed = false,
  String? correctOption,
  String? answer,
  String? explanation,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: 'math',
  errorTypes: errorTypes,
  createdAt: DateTime(2026, 11, 10),
  isOrganized: true,
  reviewJoined: true,
  questionType: questionType,
  optionLabels: optionLabels,
  optionLabelsConfirmed: optionLabelsConfirmed,
  correctOption: correctOption,
  answer: answer,
  explanation: explanation,
);

void main() {
  late QuizDatabase db;
  late QuestionRepository repo;

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
  });

  tearDown(() async {
    await db.close();
  });

  /// 建题 + 直接插一条错因记录，返回库内错因记录。
  /// FSRS 全量迁移包2：播种（setReviewJoined）已删，测试自己插行。
  Future<CauseRecord> seedCause(
    String qid,
    String cause, {
    List<String> errorTypes = const ['计算错误'],
  }) async {
    final q = _q(qid, errorTypes: errorTypes);
    await AppDatabase.upsertQuestionInto(db, q);
    await db
        .into(db.causeRecords)
        .insert(
          CauseRecordsCompanion.insert(
            questionId: qid,
            cause: cause,
            subjectId: 'math',
            joinedAt: DateTime(2026, 11, 10).millisecondsSinceEpoch,
          ),
        );
    final records = await repo.causeRecordsFor(qid);
    return records.firstWhere((r) => r.cause == cause);
  }

  group('attempts 生命周期', () {
    test('只跳过、从未作答的题不建 attempt；作答后同一条记录更新、不新建', () async {
      await seedCause('q1', '计算错误');
      final none = await repo.loadAttempt(
        sessionId: 'sess-a',
        questionId: 'q1',
      );
      expect(none, isNull);
      final attempt = AttemptData(
        id: 'att-1',
        questionId: 'q1',
        sessionId: 'sess-a',
        mode: '到期复习',
        selected: ['B'],
        correct: 1,
        confidence: '确定',
        answerVersion: 1,
        contentVersion: 2,
        status: '已提交',
        causeIds: ['计算错误'],
        submissionId: 'att-sub-1',
        createdAt: DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
      );
      final id = await repo.recordAttempt(attempt);
      expect(id, 'att-1');
      // 跳过后重遇：同一条记录更新（保留原选择与客观结果，不重新提交）。
      final updated = attempt.copyWith(status: '跳过');
      final id2 = await repo.recordAttempt(updated);
      expect(id2, 'att-1');
      final rows = await db
          .customSelect(
            'SELECT * FROM attempts WHERE session_id = ? AND question_id = ?',
            variables: [
              Variable.withString('sess-a'),
              Variable.withString('q1'),
            ],
          )
          .get();
      expect(rows.length, 1);
      expect(rows.single.data['submission_id'], 'att-sub-1');
      expect(rows.single.data['status'], '跳过');
      expect(rows.single.data['correct'], 1);
      expect(rows.single.data['content_version'], 2);
      // 同一会话同一题再建一条 attempt（不同 submission_id）仍是同一行。
      final again = AttemptData(
        id: 'att-2',
        questionId: 'q1',
        sessionId: 'sess-a',
        mode: '到期复习',
        selected: ['A'],
        correct: 0,
        confidence: '猜的',
        answerVersion: 1,
        contentVersion: 2,
        status: '已提交',
        causeIds: ['计算错误'],
        submissionId: 'att-sub-2',
        createdAt: DateTime(2026, 11, 16, 10).millisecondsSinceEpoch,
      );
      final id3 = await repo.recordAttempt(again);
      expect(id3, 'att-1');
      final rows2 = await db.customSelect('SELECT * FROM attempts').get();
      expect(rows2.length, 1);
    });
  });

  group('P1-A：改标签后旧答案重新核对', () {
    Future<Question> readQuestion(String id) async {
      final rows = await (db.select(
        db.questions,
      )..where((t) => t.id.equals(id))).get();
      return rows.map((r) {
        return Question(
          id: r.id,
          title: r.title,
          subjectId: r.subjectId,
          createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
          answer: r.answer,
          explanation: r.explanation,
          questionType: r.questionType,
          correctOption: r.correctOption,
          optionLabels: r.optionLabels,
          optionLabelsConfirmed: r.optionLabelsConfirmed == 1,
          answerVersion: r.answerVersion,
          answerPendingRecheck: r.answerPendingRecheck == 1,
        );
      }).single;
    }

    test('多选改标签不重新确认 → 答案与解析置 NULL、待核对、answer_version+1', () async {
      final q = _q(
        'q1',
        questionType: 'choice_multi',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        answer: 'A、C',
        explanation: '解析文本',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      expect(saved.answerVersion, 1);
      expect(saved.answerPendingRecheck, isFalse);
      // 改标签（增 E），不带重确认信号。
      await repo.save(saved.copyWith(optionLabels: ['A', 'B', 'C', 'D', 'E']));
      saved = await readQuestion('q1');
      expect(saved.answer, isNull);
      expect(saved.explanation, isNull);
      expect(saved.answerPendingRecheck, isTrue);
      expect(saved.answerVersion, 2);
      expect(saved.optionLabelsConfirmed, isFalse);
      expect(saved.hasValidStandardAnswer, isFalse);
    });

    test('多选改标签并重新确认 → 新答案和新标签原子保存，answer_version 只 +1', () async {
      final q = _q(
        'q1',
        questionType: 'choice_multi',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        answer: 'A、C',
        explanation: '解析文本',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      await repo.save(
        saved.copyWith(
          optionLabels: ['A', 'B', 'C', 'D', 'E'],
          answer: 'A、C、E',
          explanation: '新解析',
          answerReconfirmed: true,
        ),
      );
      saved = await readQuestion('q1');
      expect(saved.answer, 'A、C、E');
      expect(saved.explanation, '新解析');
      expect(saved.answerPendingRecheck, isFalse);
      expect(saved.answerVersion, 2);
    });

    test('单选只改标签顺序、未重选 → correct_option 置 NULL、待核对、不判分', () async {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      await repo.save(saved.copyWith(optionLabels: ['B', 'A', 'C', 'D']));
      saved = await readQuestion('q1');
      expect(saved.correctOption, isNull);
      expect(saved.answerPendingRecheck, isTrue);
      expect(saved.answerVersion, 2);
      expect(objectiveGradingAvailable(saved), isFalse);
    });

    test('单选只改标签顺序、重选同一标签 → 立即恢复判分（WP-A #1 REV5：不再另点确认选项）', () async {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      // 同一次保存重选正确标签：correct_option 保留、待核对清除。
      // REV5 起判分不再读 option_labels_confirmed 列：确认列仍被数据层
      // 清零（保留列），但判分立即恢复，不再等另一次“确认选项”保存。
      await repo.save(
        saved.copyWith(
          optionLabels: ['B', 'A', 'C', 'D'],
          correctOption: 'B',
          answerReconfirmed: true,
        ),
      );
      saved = await readQuestion('q1');
      expect(saved.correctOption, 'B');
      expect(saved.answerPendingRecheck, isFalse);
      expect(saved.optionLabelsConfirmed, isFalse);
      expect(objectiveGradingAvailable(saved), isTrue);
      expect(gradeObjective(saved, 'B'), 1);
    });

    test('单选集合变化致正确答案失效 → correct_option 置 NULL', () async {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      await repo.save(saved.copyWith(optionLabels: ['A', 'C', 'D']));
      saved = await readQuestion('q1');
      expect(saved.correctOption, isNull);
      expect(saved.answerPendingRecheck, isTrue);
    });

    test('改标签后确认清零；确认保存带信号时保留确认状态', () async {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        optionLabels: ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
      );
      await AppDatabase.upsertQuestionInto(db, q);
      var saved = await readQuestion('q1');
      await repo.save(saved.copyWith(optionLabels: ['A', 'B', 'C', 'D', 'E']));
      saved = await readQuestion('q1');
      expect(saved.optionLabelsConfirmed, isFalse);
      // 确认保存：标签 + 确认一起落盘。
      await repo.save(
        saved.copyWith(
          optionLabels: ['A', 'B', 'C', 'D', 'E'],
          optionLabelsConfirmed: true,
          optionLabelsJustConfirmed: true,
          correctOption: 'B',
          answerReconfirmed: true,
        ),
      );
      saved = await readQuestion('q1');
      expect(saved.optionLabelsConfirmed, isTrue);
      expect(saved.correctOption, 'B');
    });
  });

  group('会话持久化 review_state', () {
    test('保存/读取完整快照：session_id、模式、跳过次数、每题状态', () async {
      final perQuestion = {
        'q1': <String, Object?>{
          'question_submission_id': 'qs-1',
          'answer_version_at_start': 1,
          'content_version_at_start': 2,
          'stage': 'checking',
          'attempt_id': 'att-1',
          'submitted_causes': ['计算错误'],
        },
      };
      await repo.saveReviewState(
        queue: const [
          ReviewQueueItem(questionId: 'q1', cause: '计算错误'),
          ReviewQueueItem(questionId: 'q2', cause: '概念不清'),
        ],
        position: 1,
        sessionId: 'sess-1',
        mode: '到期复习',
        skips: {'q1': 1},
        perQuestionState: perQuestion,
      );
      final loaded = await repo.reviewState();
      expect(loaded, isNotNull);
      expect(loaded!.sessionId, 'sess-1');
      expect(loaded.mode, '到期复习');
      expect(loaded.position, 1);
      expect(loaded.queue.length, 2);
      expect(loaded.skips, {'q1': 1});
      expect(loaded.perQuestionState['q1']!['question_submission_id'], 'qs-1');
      expect(loaded.perQuestionState['q1']!['answer_version_at_start'], 1);
      await repo.clearReviewState();
      expect(await repo.reviewState(), isNull);
    });

    test('恢复备份时目标库原有暂停会话被清除', () async {
      await repo.saveReviewState(
        queue: const [ReviewQueueItem(questionId: 'q1', cause: '计算错误')],
        position: 0,
        sessionId: 'sess-old',
        mode: '到期复习',
      );
      expect(await repo.reviewState(), isNotNull);
      // 导出当前库（含一道题），再恢复进同一库：恢复事务清空 review_state。
      final q = _q('q1');
      await AppDatabase.upsertQuestionInto(db, q);
      final dataDir = await Directory.systemTemp.createTemp('m3-restore');
      addTearDown(() => dataDir.delete(recursive: true));
      final bytes = await AppDatabase.exportBackupZipFrom(
        db,
        dataDir: dataDir.path,
      );
      final warnings = await AppDatabase.importBackupZipInto(
        db,
        bytes,
        dataDir: dataDir.path,
      );
      expect(warnings, isEmpty);
      expect(await repo.reviewState(), isNull);
      // 恢复后不创建任何活动会话：再读一次仍为空。
      expect(await repo.reviewState(), isNull);
    });
  });

  // 已删（FSRS 全量迁移包2）：'专项练习重新加入复习'组——'已治愈错因回到
  // 解决中，进度与锚点清空；本次练习记录不受影响'。旧重入语义是把已治愈
  // 错因记录打回解决中并清空进度/锚点；新语义是按题重入 FSRS 池（建卡，
  // 已在池不重置），cause_records 状态列冻结、不再改动。替代：
  // 新文件 test/fsrs_pkg2_migration_test.dart 的“重新加入”组
  //（不在池建卡、已在池不重复建卡不重置状态）。

  group('M3-10 断点恢复重建：hasSessionVerdict', () {
    test('已提交任何 verdict 的错因在该会话查到；他会话 / 未提交查不到', () async {
      final record = await seedCause('q1', '计算错误');
      final stable = causeStableId(record);
      expect(
        await repo.hasSessionVerdict(
          causeStableId: stable,
          sessionId: 'sess-a',
        ),
        isFalse,
      );
      // 旧 verdict 写入层已退役：直接写一条 review_history 行，
      // 模拟“该错因在本会话已提交过 verdict”。
      await db
          .into(db.reviewHistory)
          .insert(
            ReviewHistoryCompanion.insert(
              questionId: 'q1',
              result: 'unsolved',
              reviewedAt: DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
              causeId: Value(stable),
              sessionId: const Value('sess-a'),
              verdict: const Value('未解决'),
            ),
          );
      // “未解决”也是已提交过的 verdict，恢复重建要认它。
      expect(
        await repo.hasSessionVerdict(
          causeStableId: stable,
          sessionId: 'sess-a',
        ),
        isTrue,
      );
      expect(
        await repo.hasSessionVerdict(
          causeStableId: stable,
          sessionId: 'sess-b',
        ),
        isFalse,
      );
      expect(
        await repo.hasSessionVerdict(
          causeStableId: 'q1|不存在的错因',
          sessionId: 'sess-a',
        ),
        isFalse,
      );
    });
  });
}
