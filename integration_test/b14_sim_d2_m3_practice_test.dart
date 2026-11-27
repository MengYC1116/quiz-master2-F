// 十四批 Linux 模拟用户核验 · 模块 D2（M3 跳过与断点续接、专项练习、回归抽查）。
//
// 清单：~/workspace/batch14-work/WIN11-CHECKLIST-B14.md #23 / #26 / #27 / #32。
// 细则：PLAN-14-REV4.3.md M3（M3-2 / M3-9 / M3-10 / M3-15，用户流程 §3/§11/§12）。
//
// 走真实 widget + 真实 Drift 库（临时文件库，绝不动真实库），不用 FakeRepo。
// 种子：临时库直接造题 + 错因 + 复习加入状态（AppDatabase.upsertQuestionInto +
// repo.setReviewJoined，与 test/b14_m5_fix3_session_restore_test.dart 同款）。
// 绝不做真实 GLM-OCR 调用；OCR 只验入口存在与页面可达。
// “关闭应用”用“销毁当前 widget 树后用同一临时库重新 pump 一个新 app 实例”模拟。
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/batch_import.dart';
import 'package:quiz_master2/modules/collect/batch_import_card.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/modules/home/home_page.dart';
import 'package:quiz_master2/modules/report/report_page.dart';
import 'package:quiz_master2/modules/review/review_page.dart';
import 'package:quiz_master2/modules/wrongbook/wrongbook_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

const _tmpRoot = '/home/hatch/workspace/batch14-work/sim-tmp-d2';

Question _mkQ(
  String id,
  String title, {
  String subjectId = 'math',
  String cause = '概念不清',
  String? answer,
  String? explanation,
  String? questionType,
  List<String>? optionLabels,
  bool optionLabelsConfirmed = false,
  String? correctOption,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  errorTypes: [cause],
  answer: answer,
  explanation: explanation,
  createdAt: DateTime(2026, 11, 8),
  isOrganized: true,
  reviewJoined: true,
  questionType: questionType,
  optionLabels: optionLabels,
  optionLabelsConfirmed: optionLabelsConfirmed,
  correctOption: correctOption,
);

/// 每测一个全新的临时文件库。openForTest(path:) 只建表不播种演示数据，
/// 且生产开库时的 _seed（学科/文件夹/标签等）不跑——这里补种学科
/// （openAtImpl 同款值），否则 subjects() 为空、选题页/错题本/报告
/// 都没有学科。
/// 目录操作一律同步：testWidgets 体内 `await Directory.exists()/create()`
/// 会永久挂起（探针 b14_sim_d2_probe3 确认；同步版 2 秒跑通）。
Future<(QuizDatabase, QuestionRepository)> _openFreshDb(
  String name,
) async {
  final dir = Directory('$_tmpRoot/$name');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final db = await AppDatabase.openForTest(path: '${dir.path}/test.db');
  AppDatabase.useDatabaseForTest(db);
  final repo = QuestionRepository(AppDatabase.instance);
  for (final s in Subject.all) {
    await db.into(db.subjects).insert(
          SubjectsCompanion.insert(
            id: s.id,
            name: s.name,
            color: s.color.toARGB32(),
            coverStyle: const drift.Value('plain'),
            coverColor: drift.Value(switch (s.id) {
              'math' => 'blue',
              'english' => 'green',
              _ => 'red',
            }),
          ),
        );
  }
  addTearDown(() async {
    try {
      await db.close();
    } catch (_) {}
    await AppDatabase.resetForTest();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return (db, repo);
}

/// 确定性调度器（fuzzing 关）+ SQLite store，绑指定库（test/p5 同款）。
FsrsReviewScheduler _testScheduler(QuizDatabase db) =>
    FsrsReviewScheduler(
      config: const SchedulerConfig(enableFuzzing: false),
      store: SqliteCardStore.forDatabase(db),
    );

/// 种子一题并加入复习。错题本按“已整理”口径计数（subjectCounts 要求
/// reviewJoined && isOrganized），故种子题默认进一个同科文件夹并标记
/// 已整理（探针 8：未整理种子在书架上是 0 道题、进书为空）；复习队列
/// 不依赖是否整理，#23/#26/#27 不受影响。
Future<void> _seedJoined(
  QuizDatabase db,
  QuestionRepository repo,
  Question q,
) async {
  final folderId = 'f-${q.subjectId}';
  await repo.saveFolder(
    Folder(id: folderId, name: '默认文件夹', subjectId: q.subjectId),
  );
  final organized = q.copyWith(folderIds: [folderId], isOrganized: true);
  await AppDatabase.upsertQuestionInto(db, organized);
  // FSRS 全量迁移包2：只翻标志，不播种错因记录（专项练习读 q.allCauses）。
  final ok = await repo.setReviewJoinedFlag(organized, true);
  assert(ok, 'setReviewJoinedFlag 失败：${q.id}');
  // sim 清理批：legacy 回落已删，池空即无到期；要建出到期会话，
  // 须先给每道题建一张 FSRS 卡（p2 同款办法）。只建卡、不预答——
  // 建卡后即进今日新题释放，当天可练。
  await _testScheduler(db).initializeQuestion(q.id);
}

Future<void> _pumpReview(
  WidgetTester tester,
  QuestionRepository repo,
) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      darkTheme: AppTheme.dark(scale: 1.0),
      home: Scaffold(
        body: ReviewPage(
          key: UniqueKey(),
          repo: repo,
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoWrongbook: () {},
        ),
      ),
    ),
  );
  await _settle(tester, maxPumps: 100, minPumps: 8);
}


/// 定量 pump，替代 pumpAndSettle：首页等页有周期性刷新（相对时间/问候语），
/// pumpAndSettle 会烧光 10 分钟假时钟后抛错；定量 pump 足够让 Drift
/// 加载 + 重建完成（探针 3/4：20~30 次 × 100ms 即够）。
/// 等到无待渲染帧即提前停（但至少跑 minPumps 次，避免 microtask 里的
/// load 还没起跑就误判为已静止），最多跑 maxPumps 次兜底。
Future<void> _settle(
  WidgetTester tester, {
  int maxPumps = 20,
  int minPumps = 3,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (i + 1 >= minPumps && !tester.binding.hasScheduledFrame) break;
  }
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      darkTheme: AppTheme.dark(scale: 1.0),
      home: Scaffold(body: page),
    ),
  );
  await _settle(tester, maxPumps: 100, minPumps: 8);
}

/// 销毁当前 widget 树（模拟关闭应用），再用同一临时库重新 pump 一个新实例。
Future<void> _restartApp(
  WidgetTester tester,
  QuestionRepository repo,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _settle(tester);
  await _pumpReview(tester, repo);
}

Future<void> _tapBtn(WidgetTester tester, String label, {int at = 0}) async {
  final finder = find.widgetWithText(QmButton, label);
  await tester.ensureVisible(finder.at(at));
  await _settle(tester);
  await tester.tap(finder.at(at));
  await _settle(tester);
}

Future<void> _tapText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder);
  await _settle(tester);
  await tester.tap(finder);
  await _settle(tester);
}

bool _currentIs(WidgetTester tester, String title) =>
    find.textContaining(title).evaluate().isNotEmpty;

/// 纸上作答的题在到期复习里走完三步：看题 → 作答（我已完成作答）
/// → 核对（确认核对，下一题）。无置信度、无错因自查、无 verdict。
Future<void> _completeDuePaper(WidgetTester tester) async {
  await _tapBtn(tester, '开始作答');
  await _tapBtn(tester, '我已完成作答');
  await _tapBtn(tester, '确认核对，下一题');
}

/// 专项练习里做完当前题（纸上或单选都行），点“下一题”。
Future<void> _completePracticeCurrent(WidgetTester tester) async {
  await _tapBtn(tester, '开始作答');
  if (find.widgetWithText(QmButton, 'B').evaluate().isNotEmpty) {
    await _tapBtn(tester, 'B');
    await _tapBtn(tester, '提交答案');
    expect(find.text('回答正确'), findsOneWidget);
  } else {
    await _tapBtn(tester, '我已完成作答');
  }
  // 专项练习没有逐错因自查环节：核对步直接“下一题”，没有“下一步：自查”。
  expect(find.widgetWithText(QmButton, '下一步：自查'), findsNothing,
      reason: '专项练习没有逐错因自查环节');
  await _tapBtn(tester, '下一题');
}

/// 选下拉菜单项（按显示文字点菜单里的 Text）。
/// 注意：不要点 DropdownMenuItem widget 本身——探针 6 证实它的中心点
/// (381,303) 在 hit test 里会落到下层页面、选不中且菜单不关；而点它
/// 里面的 Text（同一行偏左的位置）能正常选中、菜单关闭。
/// [displayText] 是菜单项显示的文字（学科传名字如“政治”，不是 id）。
Future<void> _pickMenuItem<T>(
  WidgetTester tester,
  Finder dropdown,
  String displayText,
) async {
  await tester.ensureVisible(dropdown);
  await _settle(tester);
  await tester.tap(dropdown);
  await _settle(tester);
  final item = find.text(displayText).last;
  await tester.ensureVisible(item);
  await _settle(tester);
  await tester.tap(item);
  await _settle(tester);
}

// FSRS 全量迁移包 7：CauseRecord 已无状态列；快照改取仍存活的
// 冻结历史载体字段（补救条数 + 加入时间），用途不变（断言练习
// 不改写错因记录）。
Future<Map<String, String>> _causeSnapshot(QuestionRepository repo) async {
  final out = <String, String>{};
  for (final r in await repo.causeRecords()) {
    out['${r.questionId}|${r.cause}'] =
        '${r.remedyHistory.length}|${r.joinedAt.toIso8601String()}';
  }
  return out;
}

/// FSRS 卡片快照：只取调度进度字段（整张卡状态 + 是否已开始正式
/// 复习），不含首次呈现账本字段。专项练习不调 FSRS：练完前后
/// 快照必须一字不变。
Future<Map<String, String>> _fsrsCardSnapshot(
  FsrsReviewScheduler scheduler,
) async {
  final out = <String, String>{};
  for (final c in await scheduler.loadAllCards()) {
    out[c.questionId] =
        '${c.card}|firstReviewedAt=${c.firstReviewedAt?.toIso8601String()}';
  }
  return out;
}

Future<Map<String, int>> _historyCounts(
  QuestionRepository repo,
  List<String> qids,
) async {
  final out = <String, int>{};
  for (final id in qids) {
    out[id] = (await repo.reviewHistory(id)).length;
  }
  return out;
}

void main() {
  group('#23 跳过与断点续接', () {
    testWidgets('跳过一次移队尾、第二次留到下次：不写记录、不改进度', (
      tester,
    ) async {
      final (db, repo) = await _openFreshDb('d2-23-skip-twice');
      const titles = ['跳过题一', '跳过题二', '跳过题三'];
      const ids = ['s1', 's2', 's3'];
      for (var i = 0; i < 3; i++) {
        await _seedJoined(
          db,
          repo,
          _mkQ(
            ids[i],
            titles[i],
            answer: '答案 $i',
            explanation: '解析 $i。',
          ),
        );
      }
      await _pumpReview(tester, repo);
      await _tapBtn(tester, '开始复习');
      expect(find.textContaining('第 1 / 3 道题'), findsOneWidget);

      // 记下首题，点一次跳过：首题移到队尾，当前题换了，仍在会话里。
      final firstTitle = titles.firstWhere((t) => _currentIs(tester, t));
      await _tapBtn(tester, '跳过');
      expect(find.text('本轮复习总结'), findsNothing);
      expect(_currentIs(tester, firstTitle), isFalse,
          reason: '第一次跳过后首题应移到队尾，不再是当前题');

      // 做完其余两题，首题在队尾重遇。
      await _completeDuePaper(tester);
      await _completeDuePaper(tester);
      expect(_currentIs(tester, firstTitle), isTrue,
          reason: '队尾重遇的应是第一次跳过的首题');
      expect(find.textContaining('第 3 / 3 道题'), findsOneWidget);

      // 第二次跳过：直接留到下次，进小结。
      await _tapBtn(tester, '跳过');
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(find.textContaining('留待下次 1 道'), findsOneWidget);

      // DB 断言：被跳过的题没有任何正式作答记录、不改进度。
      expect(await _historyCounts(repo, [ids[0]]), {'s1': 0},
          reason: '跳过不写正式作答记录');
      // 新流程不再播种错因记录（包 2）：跳过不产生任何错因记录。
      expect(
        (await repo.causeRecords())
            .where((r) => r.questionId == ids[0]),
        isEmpty,
        reason: '跳过不写记录：不产生错因记录',
      );
    });

    testWidgets('跳过已提交答案的题：队尾重遇保留原选择与客观结果，不可重新提交', (
      tester,
    ) async {
      final (db, repo) = await _openFreshDb('d2-23-skip-submitted');
      await _seedJoined(
        db,
        repo,
        _mkQ(
          'c1',
          '单选跳过题',
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          optionLabelsConfirmed: true,
          correctOption: 'B',
          answer: 'B',
          explanation: '选 B。',
        ),
      );
      await _seedJoined(
        db,
        repo,
        _mkQ('p1', '纸上跳过题', answer: '纸上答案', explanation: '纸上解析。'),
      );
      await _pumpReview(tester, repo);
      await _tapBtn(tester, '开始复习');
      final sessionId = (await repo.reviewState())!.sessionId!;

      // 先把单选题做到“已提交答案”那一步：点选 B + 提交。
      if (_currentIs(tester, '纸上跳过题')) {
        await _completeDuePaper(tester);
      }
      expect(_currentIs(tester, '单选跳过题'), isTrue);
      await _tapBtn(tester, '开始作答');
      await _tapBtn(tester, 'B');
      await _tapBtn(tester, '提交答案');
      expect(find.text('回答正确'), findsOneWidget);

      // 在核对步点跳过 → 队尾；做完纸上题后重遇。
      await _tapBtn(tester, '跳过');
      expect(_currentIs(tester, '纸上跳过题'), isTrue);
      await _completeDuePaper(tester);
      expect(_currentIs(tester, '单选跳过题'), isTrue,
          reason: '队尾重遇已提交答案的单选题');

      // 恢复到的应是核对步：原选择与客观结果都在，不允许重新提交。
      expect(find.text('回答正确'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '提交答案'), findsNothing,
          reason: '已提交的题不允许重新提交');
      expect(find.text('③ 核对'), findsOneWidget);

      // 同一会话同一题只有一条 attempt——attempt 只在核对提交时写库
      // （客观提交只改内存状态），所以断言移到核对提交完成之后。
      // 收尾：核对提交后直接进小结，确认流程能正常结束。
      await _tapBtn(tester, '确认核对，下一题');
      expect(find.text('本轮复习总结'), findsOneWidget);
      final attempts = await repo.loadAttemptsForSession(sessionId);
      final choiceAttempts = attempts
          .where((a) => a.questionId == 'c1')
          .toList();
      expect(choiceAttempts, hasLength(1));
      expect(choiceAttempts.single.selected, ['B']);
      expect(choiceAttempts.single.correct, 1);
    });

    testWidgets('暂停 → 关闭应用重进：继续上次会话从断点恢复；放弃后重新生成', (
      tester,
    ) async {
      final (db, repo) = await _openFreshDb('d2-23-pause-resume');
      for (var i = 0; i < 3; i++) {
        await _seedJoined(
          db,
          repo,
          _mkQ(
            'r$i',
            '断点题$i',
            answer: '答案 $i',
            explanation: '解析 $i。',
          ),
        );
      }
      await _pumpReview(tester, repo);
      await _tapBtn(tester, '开始复习');
      // 做完第 1 题，停在第 2 题。
      await _completeDuePaper(tester);
      expect(find.textContaining('第 2 / 3 道题'), findsOneWidget);
      await _tapBtn(tester, '暂停');

      // 模拟关闭应用：销毁 widget 树，用同一临时库重新 pump 新实例。
      await _restartApp(tester, repo);
      expect(find.textContaining('继续上次会话'), findsNWidgets(2),
          reason: '恢复条文案 + 按钮各一处');
      expect(find.text('放弃上次会话'), findsOneWidget);
      expect(find.textContaining('第 2 / 3 道题'), findsOneWidget,
          reason: '恢复条应标出断点位置');

      // 点“继续”：从断点（第 2 题）恢复，队列顺序不变。
      await _tapBtn(tester, '继续上次会话');
      expect(find.textContaining('第 2 / 3 道题'), findsOneWidget);
      expect(find.text('① 看题'), findsOneWidget);

      // 再暂停、重进，点“放弃上次会话”：按当前到期状态重新生成队列，从第 1 题起。
      await _tapBtn(tester, '暂停');
      await _restartApp(tester, repo);
      await _tapBtn(tester, '放弃上次会话');
      expect(find.textContaining('第 1 / 3 道题'), findsOneWidget);
    });

    testWidgets('另一模式：暂停会话时开专项练习先二选一', (tester) async {
      final (db, repo) = await _openFreshDb('d2-23-mode-switch');
      for (var i = 0; i < 2; i++) {
        await _seedJoined(
          db,
          repo,
          _mkQ(
            'm$i',
            '模式题$i',
            answer: '答案 $i',
            explanation: '解析 $i。',
          ),
        );
      }
      await _pumpReview(tester, repo);
      await _tapBtn(tester, '开始复习');
      await _tapBtn(tester, '暂停');

      // 开专项练习：先弹二选一，不直接进选题页。
      await _tapBtn(tester, '专项练习');
      expect(find.textContaining('有一个暂停的学习会话'), findsOneWidget);
      // 选“继续上次会话”：回到中断的到期复习。
      final dialogContinue = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('继续上次会话'),
      );
      await tester.tap(dialogContinue);
      await _settle(tester);
      expect(find.textContaining('第 1 / 2 道题'), findsOneWidget);

      // 再暂停、再开专项练习，选“放弃上次会话”：旧断点清掉，进选题页。
      // 恢复条上也有同名按钮，只点弹窗里的那一个。
      await _tapBtn(tester, '暂停');
      await _tapBtn(tester, '专项练习');
      final dialogAbandon = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('放弃上次会话'),
      );
      await tester.tap(dialogAbandon);
      await _settle(tester);
      expect(find.widgetWithText(QmButton, '开始练习'), findsOneWidget);
      expect(await repo.reviewState(), isNull,
          reason: '放弃后旧暂停会话应已清除');
    });
  });

  group('#26 专项练习全程', () {
    testWidgets('选题默认 + 练完全程：专项不改变 FSRS 进度、DB 卡片不变', (
      tester,
    ) async {
      final (db, repo) = await _openFreshDb('d2-26-practice-full');
      await _seedJoined(
        db,
        repo,
        _mkQ('pp1', '练习纸上题一', answer: '答案一', explanation: '解析一。'),
      );
      await _seedJoined(
        db,
        repo,
        _mkQ(
          'pp2',
          '练习纸上题二',
          subjectId: 'english',
          answer: '答案二',
          explanation: '解析二。',
        ),
      );
      await _seedJoined(
        db,
        repo,
        _mkQ(
          'pc1',
          '练习单选题',
          subjectId: 'politics',
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          optionLabelsConfirmed: true,
          correctOption: 'B',
          answer: 'B',
          explanation: '选 B。',
        ),
      );
      final causesBefore = await _causeSnapshot(repo);
      final historyBefore = await _historyCounts(
        repo,
        const ['pp1', 'pp2', 'pc1'],
      );
      // 专项练习不调 FSRS：练前记下三张卡的调度进度，练后逐字比对。
      final scheduler = _testScheduler(db);
      final cardsBefore = await _fsrsCardSnapshot(scheduler);

      await _pumpReview(tester, repo);
      await _tapBtn(tester, '专项练习');
      // 选题页默认：全部 / 10 道 / 随机。“只练，不排期”那句说明小字
      // 已随文案走查批删除（final-report §2 模块 07），不再断言文案，
      // “不改变 FSRS 进度”改由下面的 DB 快照断言。
      expect(find.text('专项练习'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '10 道'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '随机'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '加入时间'), findsOneWidget);
      await _tapBtn(tester, '开始练习');
      final sessionId = (await repo.reviewState())!.sessionId!;
      expect(find.textContaining('第 1 / 3 道题'), findsOneWidget);
      expect(find.textContaining('本轮共 3 个错因'), findsOneWidget);

      // 随机顺序：按当前题做完 3 道（核对后直接“下一题”，无自查环节）。
      for (var i = 0; i < 3; i++) {
        await _completePracticeCurrent(tester);
      }
      expect(find.text('本轮专项练习小结'), findsOneWidget);
      // 小结收题块的短提示：专项练习的错不记成正式复习记录。
      expect(find.text('加入后从下一次正式复习开始记录。'), findsOneWidget);

      // DB 断言：FSRS 卡片一点没变，cause_records 一点没变，
      // review_history 一行没加；attempts 记了 3 条（每题一条），
      // 练习记录本身在。
      expect(await _fsrsCardSnapshot(scheduler), cardsBefore,
          reason: '专项练习不调 FSRS：卡片进度必须一点没变');
      expect(await _causeSnapshot(repo), causesBefore,
          reason: '专项练习不改变 FSRS 进度：cause_records 必须一点没变');
      expect(await _historyCounts(repo, const ['pp1', 'pp2', 'pc1']),
          historyBefore,
          reason: '专项练习不写正式作答记录：review_history 必须一行没加');
      final attempts = await repo.loadAttemptsForSession(sessionId);
      expect(attempts.map((a) => a.questionId).toSet(),
          {'pp1', 'pp2', 'pc1'});
      expect(
        attempts.where((a) => a.mode == ReviewMode.practice),
        hasLength(3),
      );
    });

    testWidgets('所选范围无题：专项练习空状态，不进空白会话，改范围回选题页', (
      tester,
    ) async {
      final (db, repo) = await _openFreshDb('d2-26-practice-empty');
      await _seedJoined(
        db,
        repo,
        _mkQ('e1', '数学概念题', answer: '答案', explanation: '解析。'),
      );
      await _seedJoined(
        db,
        repo,
        _mkQ(
          'e2',
          '政治概念题',
          subjectId: 'politics',
          answer: '答案',
          explanation: '解析。',
        ),
      );
      // 再加一道数学“计算错误”题：错因下拉的选项来自库里已有的全部错因
      // （allCauses），没有这道题菜单里根本没有“计算错误”可选；
      // 政治 + 计算错误 才是空范围（政治题全是概念不清）。
      await _seedJoined(
        db,
        repo,
        _mkQ(
          'e3',
          '数学计算题',
          cause: '计算错误',
          answer: '答案',
          explanation: '解析。',
        ),
      );
      await _pumpReview(tester, repo);
      await _tapBtn(tester, '专项练习');
      // 政治 + 计算错误：库里没有这样的题。
      await _pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).first,
        '政治',
      );
      await _pickMenuItem<String>(
        tester,
        find.byType(DropdownButton<String>).last,
        '计算错误',
      );
      await _tapBtn(tester, '开始练习');
      // 空范围不进会话：选题页内出空态盒（伙伴 + 换个范围试试 + 改范围）。
      expect(find.text('该范围内没有可练的题'), findsOneWidget);
      expect(find.text('换个范围试试。'), findsOneWidget);
      expect(find.textContaining('第 1 /'), findsNothing,
          reason: '空范围不进入空白会话');
      await _tapBtn(tester, '改范围');
      expect(find.text('该范围内没有可练的题'), findsNothing);
      expect(find.widgetWithText(QmButton, '开始练习'), findsOneWidget,
          reason: '返回后仍在选题页');
    });
  });

  // FSRS 全量迁移包 7：已删 #27 组（1 个测试：'已治愈错因重新加入
  // 复习：回到解决中，只影响后续会话'）——它覆盖的行为已随包 1/包 2
  // 删除：经 cureChecks=1 + 真实 verdict 路径治愈错因，再经
  // unsolvedReset 回到解决中；新语义是按题重入池、记录冻结不动，
  // 由单元测试覆盖（review_notifier_test 与 review_page_test 的
  // '专项练习重新加入复习：按题入池，记录冻结不动'）。
  group('#32 回归抽查', () {
    // 注意：种子必须在 test 体内开库+写（seed32），不能放 group setUp——
    // 探针 10/11/12 证实：setUp 里开库后，testWidgets 体内第一次 repo
    // 调用（甚至只是 await AppDatabase.instance.db 后的 tearDown）
    // 会永久挂起（FakeAsync 区与 setUp 真实区之间的 Future 衔接问题，
    // 与 lib 无关）；体内开库的写法（#23/#26/#27 同款）全部跑通。
    // 每个测试用独立目录（不共用 'd2-32-regression'），避免上一个
    // 测试的库文件/单例状态泄漏到下一个。
    Future<(QuizDatabase, QuestionRepository)> seed32(String name) async {
      final opened = await _openFreshDb(name);
      final db = opened.$1;
      final repo = opened.$2;
      await _seedJoined(
        db,
        repo,
        _mkQ('g1', '回归数学题', answer: '答案', explanation: '解析。'),
      );
      await _seedJoined(
        db,
        repo,
        _mkQ(
          'g2',
          '回归英语题',
          subjectId: 'english',
          cause: '计算错误',
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          optionLabelsConfirmed: true,
          correctOption: 'B',
          answer: 'B',
          explanation: '选 B。',
        ),
      );
      await _seedJoined(
        db,
        repo,
        _mkQ('g3', '回归政治题', subjectId: 'politics', answer: '答案',
            explanation: '解析。'),
      );
      // 首页历史：记两次查看（g1 今天、g2 昨天同一时刻）。
      final now = DateTime.now();
      await repo.recordQuestionViewed('g1');
      await AppDatabase.recordQuestionViewedInto(
        db,
        'g2',
        viewedAtMillis: now
            .subtract(const Duration(days: 1))
            .millisecondsSinceEpoch,
      );
      return (db, repo);
    }

    testWidgets('首页：学科行 + 最近查看（含最后查看时间）都能打开', (
      tester,
    ) async {
      final (_, repo) = await seed32('d2-32-home');
      await _pumpPage(
        tester,
        HomePage(
          repo: repo,
          settings: const AppSettings(),
          onGoCollect: () {},
          onGoOrganize: () {},
          onGoWrongbook: (_) {},
          onGoReview: () {},
          onOpenDetail: (_, __, {String? searchContext}) {},
        ),
      );
      expect(find.text('最近查看'), findsOneWidget);
      expect(find.text('回归数学题'), findsOneWidget);
      expect(find.text('回归英语题'), findsOneWidget);
      expect(find.textContaining('数学 · 今天'), findsOneWidget);
      expect(find.textContaining('英语 · 昨天'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('错题本：书架目录能打开，进书看到题', (tester) async {
      final (_, repo) = await seed32('d2-32-wrongbook');
      await _pumpPage(
        tester,
        WrongbookPage(
          repo: repo,
          onOpenHome: () {},
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: ({String? subjectId}) {},
        ),
      );
      // 书架目录：点数学书进目录页（文件夹），再点文件夹进题目列表。
      // 直接 tap（探针 13 证实可行）；_tapText 的 ensureVisible
      // 在目录页会把文件夹行滚出可点位置，点不中。
      expect(find.text('数学'), findsOneWidget);
      await tester.tap(find.text('数学'));
      await _settle(tester);
      expect(find.text('默认文件夹'), findsOneWidget);
      await tester.tap(find.text('默认文件夹'));
      await _settle(tester);
      // 板子行直接渲染完整题干（行标题即题名），视图切换已去掉，
      // 不用再切“紧凑列表”就能按题名断言。行标题是独立 RichText，
      // textContaining 默认不匹配，须传 findRichText: true。
      expect(
        find.textContaining('回归数学题', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      // 回到书架走真实导航（列表 ← 目录 → 返回书架）：不能重 pump
      // 一个新的 WrongbookPage——无 key 时 Flutter 会复用旧 State，
      // 仍停在数学列表里，书架出不来。
      await _tapBtn(tester, '← 目录');
      await _tapBtn(tester, '返回书架');
      await tester.tap(find.text('英语'));
      await _settle(tester);
      expect(find.text('默认文件夹'), findsOneWidget);
      await tester.tap(find.text('默认文件夹'));
      await _settle(tester);
      expect(
        find.textContaining('回归英语题', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('D-49 详情页能打开：题干 + OCR 纠错/重新识别入口都在', (
      tester,
    ) async {
      final (_, repo) = await seed32('d2-32-detail');
      await _pumpPage(
        tester,
        QuestionDetailPage(
          repo: repo,
          questionId: 'g1',
          orderIds: const ['g1', 'g2', 'g3'],
        ),
      );
      expect(find.textContaining('回归数学题'), findsOneWidget);
      // 十三批 OCR 入口只验存在与页面可达，不做真实 GLM-OCR 调用。
      expect(find.text('编辑题干'), findsOneWidget,
          reason: '纠错入口（编辑题干）应在详情页题干区');
      expect(find.text('重新识别'), findsOneWidget,
          reason: 'OCR 重新识别入口应在详情页题干区');
      expect(tester.takeException(), isNull);
    });

    testWidgets('D-50 报告点薄弱点进题目列表，再经「在错题本中查看」直达已筛选的错题本列表', (tester) async {
      final (db, repo) = await seed32('d2-32-report');
      // 包 6：报告空态守门改看正式作答——seed32 只有题、零正式作答，
      // 新守门下会进空态。补一笔正式作答种子（g1 答错一次，Again），
      // 再进数据视图（b8_1 同款做法，走真实 submitReviewCheck）。
      final g1q = (await repo.all()).firstWhere((q) => q.id == 'g1');
      final now = DateTime.now();
      await repo.submitReviewCheck(
        attempt: AttemptData(
          id: 'att-d2-32-report',
          questionId: 'g1',
          sessionId: 'sess-d2-32-report',
          mode: ReviewMode.due,
          selected: const ['B'],
          correct: 0,
          confidence: null,
          answerVersion: g1q.answerVersion,
          contentVersion: g1q.contentVersion,
          status: '已提交',
          causeIds: const ['概念不清'],
          submissionId: 'attsub-d2-32-report',
          createdAt: now.millisecondsSinceEpoch,
        ),
        result: ReviewResult.again,
        reviewedAt: now,
        eventId: 'attsub-d2-32-report',
        scheduler: _testScheduler(db),
      );
      String? gotSubject;
      String? gotCause;
      await _pumpPage(
        tester,
        ReportPage(
          repo: repo,
          onGoReview: () {},
          onOpenWrongbookFiltered: ({subjectId, cause, knowledgePointId}) {
            gotSubject = subjectId;
            gotCause = cause;
          },
        ),
      );
      expect(find.textContaining('有没有效果'), findsOneWidget);
      expect(find.textContaining('最常错的 5 个原因'), findsOneWidget);
      expect(find.textContaining('接下来练什么'), findsOneWidget);
      // 默认范围“本周”按题的 createdAt 过滤——种子题的 createdAt
      //（2026-11-08）不在测试假时钟的本周内，弱点行是空的；切到“全部”
      // 再验弱点行（范围切换本身也是报告行为）。
      await _tapText(tester, '全部');
      // 薄弱点 Top：数学 · 概念不清（g1 正式答错一次）应有一行，点它。
      // 行标题是 Text.rich（“数学 · 概念不清”）；“接下来练什么”那句
      // “先解决数学的概念不清。”也是 RichText 且在树里排在前面
      // （探针 14），按包含匹配会点到它且不触发回调——按行标题全文
      // 精确匹配，只取弱点行。
      final firstCause = find
          .byWidgetPredicate(
            (w) =>
                w is RichText && w.text.toPlainText() == '数学 · 概念不清',
          )
          .first;
      await tester.ensureVisible(firstCause);
      await _settle(tester);
      await tester.tap(firstCause);
      await _settle(tester);
      // 点弱点行先进薄弱点题目列表页（P3 入口 3），再点次入口
      // “在错题本中查看”才走旧深链路回调。
      expect(find.textContaining('回归数学题'), findsOneWidget);
      await _tapBtn(tester, '在错题本中查看');
      expect(gotSubject, 'math');
      expect(gotCause, '概念不清');
      expect(tester.takeException(), isNull);
    });

    testWidgets('复习页能打开：到期 / 今日新题 + 开始复习 / 专项练习', (
      tester,
    ) async {
      final (_, repo) = await seed32('d2-32-review');
      await _pumpReview(tester, repo);
      // seed32 已给 3 道题建卡：到期 0 道、今日新题 3 道。
      // “今日新题 3 道”在页顶与 FSRS 清单盒各出现一处。
      expect(
        find.textContaining('今日新题 3 道'),
        findsNWidgets(2),
      );
      expect(find.widgetWithText(QmButton, '开始复习'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '专项练习'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('十二批重试入口：批量导入失败卡片有单行重试与重试失败项', (
      tester,
    ) async {
      final batch = BatchImportState(
        subjectId: 'math',
        files: [
          BatchImportFile(path: '/tmp/a.png', name: 'a.png'),
          BatchImportFile(path: '/tmp/b.png', name: 'b.png'),
        ],
      );
      batch.markDone(0);
      batch.markFailed(1, '导入失败');
      String? retriedPath;
      var retriedAll = false;
      await _pumpPage(
        tester,
        BatchImportCard(
          batch: batch,
          onRetryFailed: () => retriedAll = true,
          onRetryPath: (p) => retriedPath = p,
          onDismiss: () {},
        ),
      );
      expect(find.textContaining('重试失败项'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '重试'), findsOneWidget);
      await _tapBtn(tester, '重试失败项（1 个）');
      expect(retriedAll, isTrue);
      await _tapBtn(tester, '重试');
      expect(retriedPath, '/tmp/b.png');
    });
  });
}
