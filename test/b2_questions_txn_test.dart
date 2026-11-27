// ARCH-PLAN-B 第 2 阶段（W-questions）：两个跨表事务的验收测试。
//
// setReviewJoinedFlagInto（FSRS 全量迁移包2：只翻 review_joined 标志，
// 不再播种 cause_records；旧 setReviewJoinedIntoImpl 的“题行 + 播种同事务”
// 已删除）与 _deleteQuestionTxn（cause_records + review_history +
// collect_tasks + review_state + question_boxes + questions）各一个
// 成功路径测试与一个失败注入测试：删题用 SQLite 触发器（RAISE(ABORT)）
// 在事务中途注入失败，断言“要么全提交、要么全回滚”——数据库两表的改动
// 全部回滚；删题失败时切片文件也不删。翻标志另有一条触发器隔离测试：
// cause_records 触发器不再影响翻标志。
//
// 写法铁律（D-45）：建库在测试体内做（AppDatabase.openForTest，内部已
// SELECT 1 强制建连）；只用普通 test，不用 testWidgets，不用 runAsync
// 包多段调用。全部用内存库 + 各测试自己的临时目录，不碰真实演示库；
// 失败注入不删任何真实切片文件（删题成功路径删的也是临时目录里的文件）。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';

Question _question({
  required String id,
  List<String> errorTypes = const ['计算错误'],
  String? slicePath,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: 'math',
  errorTypes: errorTypes,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
  slicePath: slicePath,
);

Future<int> _causeCount(QuizDatabase db, String questionId) async {
  final rows = await (db.select(
    db.causeRecords,
  )..where((t) => t.questionId.equals(questionId))).get();
  return rows.length;
}

Future<int> _historyCount(QuizDatabase db, String questionId) async {
  final rows = await (db.select(
    db.reviewHistory,
  )..where((t) => t.questionId.equals(questionId))).get();
  return rows.length;
}

Future<DbQuestion?> _questionRow(QuizDatabase db, String id) =>
    (db.select(db.questions)..where((t) => t.id.equals(id))).getSingleOrNull();

/// 删题成功/失败测试共用的完整关联图：题 + 2 条错因记录 + 2 条自查历史 +
/// 1 个指向该题的收集任务 + 复习队列（含该题 1 项与他题 1 项）+
/// 该题的整题框 + 子框 + 他题的框 1 个 + 临时目录里的切片文件。
Future<void> _seedDeleteGraph(
  QuizDatabase db,
  Directory tmpDir, {
  required String id,
}) async {
  final q = _question(id: id, slicePath: 'slices/$id.png');
  await AppDatabase.upsertQuestionInto(db, q);
  expect(await AppDatabase.setReviewJoinedFlagInto(db, q, true), isTrue);
  // FSRS 全量迁移包2：播种已删；两条错因记录改为直接插行
  //（errorTypes 只有 1 个，先插 1 条，再补 1 条走另一错因）。
  await db
      .into(db.causeRecords)
      .insert(
        CauseRecordsCompanion.insert(
          questionId: id,
          cause: q.allCauses.single,
          subjectId: 'math',
          joinedAt: 1000,
        ),
      );
  await db
      .into(db.causeRecords)
      .insert(
        CauseRecordsCompanion.insert(
          questionId: id,
          cause: '概念不清',
          subjectId: 'math',
          joinedAt: 1000,
        ),
      );
  for (final result in ['solved', 'unsolved']) {
    await db
        .into(db.reviewHistory)
        .insert(
          ReviewHistoryCompanion.insert(
            questionId: id,
            result: result,
            reviewedAt: 1000,
          ),
        );
  }
  await db
      .into(db.collectTasks)
      .insert(
        CollectTasksCompanion.insert(
          id: 'task-$id',
          name: '任务 $id',
          fileName: 'f.png',
          subjectId: 'math',
          questionId: Value(id),
        ),
      );
  await db
      .into(db.reviewState)
      .insert(
        ReviewStateCompanion.insert(
          id: const Value(1),
          queue: Value([
            ReviewQueueItem(questionId: id, cause: '计算错误'),
            ReviewQueueItem(questionId: 'q-other', cause: '概念不清'),
          ]),
          position: const Value(0),
          updatedAt: 1000,
        ),
      );
  await db
      .into(db.questionBoxes)
      .insert(
        QuestionBoxesCompanion.insert(
          id: 'box-$id-1',
          questionId: Value(id),
          layer: 1,
          type: 'question',
          x: 0.1,
          y: 0.1,
          w: 0.5,
          h: 0.5,
          updatedAt: 1000,
        ),
      );
  await db
      .into(db.questionBoxes)
      .insert(
        QuestionBoxesCompanion.insert(
          id: 'box-$id-2',
          questionId: Value(id),
          parentBoxId: Value('box-$id-1'),
          layer: 2,
          type: 'stem',
          x: 0.1,
          y: 0.1,
          w: 0.2,
          h: 0.2,
          updatedAt: 1000,
        ),
      );
  await db
      .into(db.questionBoxes)
      .insert(
        QuestionBoxesCompanion.insert(
          id: 'box-other-1',
          questionId: const Value('q-other'),
          layer: 1,
          type: 'question',
          x: 0.1,
          y: 0.1,
          w: 0.5,
          h: 0.5,
          updatedAt: 1000,
        ),
      );
  final sliceFile = File(p.join(tmpDir.path, 'slices', '$id.png'));
  await sliceFile.parent.create(recursive: true);
  await sliceFile.writeAsString('fake-slice');
}

void main() {
  test('setReviewJoinedFlag 成功：已入库题标 joined，不播种错因记录', () async {
    final db = await AppDatabase.openForTest();
    addTearDown(db.close);
    final q = _question(id: 'q-join-ok');
    await AppDatabase.upsertQuestionInto(db, q);

    expect(await AppDatabase.setReviewJoinedFlagInto(db, q, true), isTrue);
    expect((await _questionRow(db, 'q-join-ok'))?.reviewJoined, 1);
    // FSRS 全量迁移包2：只翻标志，不播种。
    expect(await _causeCount(db, 'q-join-ok'), 0);

    // 取消加入：题行翻回。
    expect(await AppDatabase.setReviewJoinedFlagInto(db, q, false), isTrue);
    expect((await _questionRow(db, 'q-join-ok'))?.reviewJoined, 0);
    expect(await _causeCount(db, 'q-join-ok'), 0);
  });

  test('setReviewJoinedFlag 成功：题行不存在时整行 INSERT，不播种', () async {
    final db = await AppDatabase.openForTest();
    addTearDown(db.close);
    final q = _question(id: 'q-join-new', errorTypes: ['概念不清', '方法不会']);

    expect(await AppDatabase.setReviewJoinedFlagInto(db, q, true), isTrue);
    final row = await _questionRow(db, 'q-join-new');
    expect(row, isNotNull);
    expect(row!.reviewJoined, 1);
    expect(row.title, '题 q-join-new');
    expect(await _causeCount(db, 'q-join-new'), 0);
  });

  // 已删（FSRS 全量迁移包2）：'setReviewJoined 失败注入：播种中途抛错，
  // 题行改动全部回滚'——旧方法题行 + 播种同事务，触发器拦播种可验证
  // 回滚；新方法只做单列 UPDATE，无第二写可回滚，该行为已删除，无替代测试。
  test('setReviewJoinedFlag 失败注入：cause_records 触发器不再影响翻标志', () async {
    final db = await AppDatabase.openForTest();
    addTearDown(db.close);
    // 触发器只在播种写 cause_records 时炸；新方法不写该表，翻标志照常成功。
    await db.customStatement(
      "CREATE TRIGGER b2_fail_seed BEFORE INSERT ON cause_records "
      "WHEN NEW.cause = '__b2_fail__' "
      "BEGIN SELECT RAISE(ABORT, 'b2-injected-failure'); END;",
    );
    final q = _question(id: 'q-join-fail', errorTypes: ['__b2_fail__']);
    await AppDatabase.upsertQuestionInto(db, q);
    expect((await _questionRow(db, 'q-join-fail'))?.reviewJoined, 0);

    expect(await AppDatabase.setReviewJoinedFlagInto(db, q, true), isTrue);

    expect((await _questionRow(db, 'q-join-fail'))?.reviewJoined, 1);
    expect(await _causeCount(db, 'q-join-fail'), 0);
  });

  test('deleteQuestion 成功：六表联动 + 切片文件随后删除', () async {
    final tmpDir = await Directory.systemTemp.createTemp('b2-q-del-ok-');
    addTearDown(() async {
      await AppDatabase.resetForTest();
      await tmpDir.delete(recursive: true);
    });
    AppDatabase.testDataDirectory = tmpDir.path;
    final db = await AppDatabase.openForTest();
    addTearDown(db.close);
    const id = 'q-del-ok';
    await _seedDeleteGraph(db, tmpDir, id: id);
    expect(await _causeCount(db, id), 2);
    expect(await _historyCount(db, id), 2);
    final sliceFile = File(p.join(tmpDir.path, 'slices', '$id.png'));
    expect(await sliceFile.exists(), isTrue);

    await AppDatabase.deleteQuestionFrom(db, id);

    expect(await _questionRow(db, id), isNull);
    expect(await _causeCount(db, id), 0);
    expect(await _historyCount(db, id), 0);
    // 收集任务本身保留，指向置空。
    final task = await (db.select(
      db.collectTasks,
    )..where((t) => t.id.equals('task-$id'))).getSingleOrNull();
    expect(task, isNotNull);
    expect(task!.questionId, isNull);
    // 复习队列只去掉该题的项，他题的项保留。
    final state = await (db.select(
      db.reviewState,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    expect(state!.queue.map((e) => e.questionId).toList(), ['q-other']);
    // 该题的框（含子框）全删，他题的框保留。
    final boxes = await (db.select(db.questionBoxes)).get();
    expect(boxes.map((b) => b.id).toList(), ['box-other-1']);
    // 先删库行、后删文件：事务提交后切片文件已删。
    expect(await sliceFile.exists(), isFalse);
  });

  test('deleteQuestion 失败注入：历史删除中途抛错，全部回滚且切片保留', () async {
    final tmpDir = await Directory.systemTemp.createTemp('b2-q-del-fail-');
    addTearDown(() async {
      await AppDatabase.resetForTest();
      await tmpDir.delete(recursive: true);
    });
    AppDatabase.testDataDirectory = tmpDir.path;
    final db = await AppDatabase.openForTest();
    addTearDown(db.close);
    // 触发器在事务第二步（删 review_history）炸：第一步已删的
    // cause_records 必须随事务回滚回来。
    await db.customStatement(
      "CREATE TRIGGER b2_fail_del BEFORE DELETE ON review_history "
      "WHEN OLD.question_id = 'q-del-fail' "
      "BEGIN SELECT RAISE(ABORT, 'b2-injected-failure'); END;",
    );
    const id = 'q-del-fail';
    await _seedDeleteGraph(db, tmpDir, id: id);
    final sliceFile = File(p.join(tmpDir.path, 'slices', '$id.png'));
    expect(await sliceFile.exists(), isTrue);

    await expectLater(
      AppDatabase.deleteQuestionFrom(db, id),
      throwsA(isA<Exception>()),
    );

    // 要么全提交、要么全回滚：题、错因记录、自查历史、任务指向、
    // 队列、框全部原样；切片文件也没删（文件删除在事务提交后才做）。
    expect(await _questionRow(db, id), isNotNull);
    expect(await _causeCount(db, id), 2);
    expect(await _historyCount(db, id), 2);
    final task = await (db.select(
      db.collectTasks,
    )..where((t) => t.id.equals('task-$id'))).getSingleOrNull();
    expect(task!.questionId, id);
    final state = await (db.select(
      db.reviewState,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    expect(state!.queue.map((e) => e.questionId).toList(), [id, 'q-other']);
    final boxes = await (db.select(
      db.questionBoxes,
    )..where((t) => t.questionId.equals(id))).get();
    expect(boxes.map((b) => b.id).toList(), ['box-$id-1', 'box-$id-2']);
    expect(await sliceFile.exists(), isTrue);
  });
}
