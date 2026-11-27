// 十四批 D1 Linux 模拟用户核验：M3 到期复习会话与软件内答题。
//
// 走真实界面 + 真实代码路径：ReviewPage（Riverpod reviewProvider）+
// 真实 QuestionRepository + 真实 Drift 内存库（AppDatabase.openForTest，
// 绝不动 ~/.local/share/quiz-master2/quiz-master2.db 本体）。
// 种子数据直接造题 + 错因（cause_records）+ 复习加入状态；到期状态靠
// 真实 FSRS 卡片控制（建卡 + 几天前答对一次，Good 首间隔恰好 2 天，
// 实测：3 天前→昨天到期，2 天前→今天到期，1 天前→明天到期）。
// 不调 OCR，不改 lib/。
//
// 覆盖清单：#13 #14 #15 #16 #17 #18 #19 #20 #21（改写）#24。
// #22（治愈进度与 24h 锚点）与 #25（「不确定」verdict）已删除：
// 旧治愈/自查/verdict 流程已随 FSRS 全量迁移退役，新流程无对应
// 界面与行为；#21 改写为新流程等价断言（一题多错因只记一次作答，
// 错因记录冻结不动）。
// FakeAsync 铁律（见 test/b9_3_review_badge_test.dart 文件头，B Stage 1
// 探针 11/12/13）：testWidgets 体跑在 FakeAsync 区里；setUp 在区外
// 打开的库，测试体内 await 仓库方法会挂住。因此库必须在测试体内打开，
// 播种也在测试体内做；界面收敛用有界手动 pump（pump 一帧 + runAsync
// 真实延时 100ms + 再 pump），不用 pumpAndSettle（加载中的
// CircularProgressIndicator 会让它永不静止）。
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/review/review_page.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

Question mkQ(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> errorTypes = const ['概念不清'],
  String? questionType,
  List<String>? optionLabels,
  bool optionLabelsConfirmed = false,
  String? correctOption,
  String? answer,
  String? explanation,
  String? notes,
  bool reviewJoined = true,
  bool isOrganized = true,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  errorTypes: errorTypes,
  createdAt: DateTime(2026, 11, 8),
  isOrganized: isOrganized,
  reviewJoined: reviewJoined,
  questionType: questionType,
  optionLabels: optionLabels,
  optionLabelsConfirmed: optionLabelsConfirmed,
  correctOption: correctOption,
  answer: answer,
  explanation: explanation,
  notes: notes,
);

void main() {
  late QuizDatabase db;
  late QuestionRepository repo;
  var dbOpened = false;

  /// 在测试体内打开真实内存库 + 预设三科（与新库首次启动一致）。
  Future<void> ensureDb() async {
    if (dbOpened) return;
    dbOpened = true;
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
    for (final s in Subject.all) {
      await repo.saveSubject(s);
    }
    addTearDown(() async {
      await AppDatabase.resetForTest();
      dbOpened = false;
    });
  }

  /// 造题 + 加入复习（只翻标志）+ 直接插错因记录。
  /// FSRS 全量迁移包2：翻标志不再播种；causeRow 仍直接
  /// 读 cause_records 行，测试自己插行。
  Future<void> seedQ(Question q) async {
    await ensureDb();
    await AppDatabase.upsertQuestionInto(db, q);
    if (q.reviewJoined) {
      await repo.setReviewJoinedFlag(q, true);
      for (final cause in q.allCauses) {
        await db
            .into(db.causeRecords)
            .insert(
              CauseRecordsCompanion.insert(
                questionId: q.id,
                cause: cause,
                subjectId: q.subjectId,
                joinedAt: DateTime(2026, 11, 10).millisecondsSinceEpoch,
              ),
            );
      }
    }
  }

  Future<Map<String, Object?>> causeRow(String qid, String cause) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM cause_records WHERE question_id = ? AND cause = ?',
          variables: [Variable.withString(qid), Variable.withString(cause)],
        )
        .get();
    return rows.single.data;
  }

  /// FSRS 到期卡播种（新流程唯一的到期建队来源）：建卡 + daysAgo 天前
  /// 答对一次。Good 首间隔恰好 2 天（sim 探针实测）：daysAgo=3 → 昨天
  /// 到期（已逾期），=2 → 今天到期，=1 → 明天到期（未到期）。
  Future<void> seedDueCard(String questionId, {int daysAgo = 3}) async {
    await ensureDb();
    final scheduler = FsrsReviewScheduler(
      config: const SchedulerConfig(enableFuzzing: false),
      store: SqliteCardStore.forDatabase(db),
    );
    await scheduler.initializeQuestion(questionId);
    await scheduler.recordAnswer(
      questionId,
      ReviewResult.good,
      DateTime.now().subtract(Duration(days: daysAgo)),
      'evt-d1-$questionId',
    );
  }

  /// FSRS 新卡播种（未开始正式复习）：只建卡、不答题，进今日新题释放。
  Future<void> seedNewCard(String questionId) async {
    await ensureDb();
    final scheduler = FsrsReviewScheduler(
      config: const SchedulerConfig(enableFuzzing: false),
      store: SqliteCardStore.forDatabase(db),
    );
    await scheduler.initializeQuestion(questionId);
  }

  Future<List<Map<String, Object?>>> attemptRows(String qid) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM attempts WHERE question_id = ?',
          variables: [Variable.withString(qid)],
        )
        .get();
    return rows.map((r) => r.data).toList();
  }

  /// 有界手动 pump（B8-1 / B9-3 同款）：每轮先 pump 一帧看条件，再切回
  /// 真实异步等一轮、再 pump 渲染，直到条件成立或超限失败。
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    required String reason,
    int maxRounds = 60,
  }) async {
    for (var i = 0; i < maxRounds; i++) {
      await tester.pump();
      if (condition()) return;
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      if (condition()) return;
    }
    fail('界面未稳定：$reason');
  }

  /// 点按后的收敛：若干轮 pump + 真实延时，让 Drift 同步调用与
  /// Notifier 的重读完成，再补一帧渲染。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 100)),
      );
    }
    await tester.pump();
  }

  Future<void> pumpReview(
    WidgetTester tester, {
    Future<void> Function(Question q, List<String> ids)? onOpenDetail,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.light,
        home: Scaffold(
          body: ReviewPage(
            key: UniqueKey(),
            repo: repo,
            onOpenDetail: onOpenDetail ?? (_, _) async {},
            onGoWrongbook: () {},
          ),
        ),
      ),
    );
    await pumpUntil(
      tester,
      () => find.text('复习').evaluate().isNotEmpty,
      reason: '复习页标题未出现（load 未完成）',
    );
  }

  Future<void> tapQm(WidgetTester tester, String label, {int at = 0}) async {
    final finder = find.widgetWithText(QmButton, label);
    await tester.ensureVisible(finder.at(at));
    await settle(tester);
    await tester.tap(finder.at(at));
    await settle(tester);
  }

  /// 纸上作答走完“看题 → 作答 → 核对”：点“我已完成作答”即进核对步
  /// （无旧四选一核对确认、无自查步；核对步点“确认核对，下一题”提交）。
  Future<void> paperToCheck(WidgetTester tester) async {
    await tapQm(tester, '开始作答');
    await tapQm(tester, '我已完成作答');
  }

  /// 单选/判断走完“看题 → 作答（点选 + 提交）→ 核对”（无置信度步）。
  Future<void> objectiveToCheck(
    WidgetTester tester, {
    required String option,
  }) async {
    await tapQm(tester, '开始作答');
    await tapQm(tester, option);
    await tapQm(tester, '提交答案');
  }

  group('#13 复习页分组与入口', () {
    testWidgets('FSRS 四组 + 页顶到期/今日新题 + 一题一行 + 筛选保留', (tester) async {
      await seedQ(mkQ('q-over', '逾期题', errorTypes: ['概念不清']));
      await seedDueCard('q-over', daysAgo: 3); // 昨天到期 → 已逾期
      await seedQ(mkQ('q-due', '今日到期题', errorTypes: ['计算错误']));
      await seedDueCard('q-due', daysAgo: 2); // 今天到期
      await seedQ(mkQ('q-future', '未到期题', errorTypes: ['概念不清']));
      await seedDueCard('q-future', daysAgo: 1); // 明天到期
      await seedQ(
        mkQ(
          'q-new1',
          '今日新题 A',
          errorTypes: ['概念不清'],
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          optionLabelsConfirmed: true,
          correctOption: 'B',
        ),
      );
      await seedNewCard('q-new1'); // 未开始 → 今日新题
      await seedQ(mkQ('q-new2', '今日新题 B', errorTypes: ['方法不会']));
      await seedNewCard('q-new2'); // 未开始 → 今日新题
      await seedQ(
        mkQ('q-nj', '未加入题', errorTypes: ['概念不清'], reviewJoined: false),
      );

      await pumpReview(tester);
      // 页顶：到期 2 道（逾期+今日到期）· 今日新题 2 道；FSRS 当日
      // 清单盒同口径（“到期 2 道”在页顶与清单盒各出现一次）。
      expect(find.textContaining('到期 2 道'), findsNWidgets(2));
      expect(
        find.textContaining('今日到期 2 道 · 今日新题 2 道 · 待开始 0 道'),
        findsOneWidget,
      );
      expect(find.widgetWithText(QmButton, '开始复习'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '专项练习'), findsOneWidget);
      // 四组：已逾期 → 今日到期 → 未到期 → 未开始；旧分组头不出。
      expect(find.text('已逾期'), findsOneWidget);
      expect(find.text('今日到期'), findsOneWidget);
      expect(find.text('未到期'), findsOneWidget);
      expect(find.text('未开始'), findsOneWidget);
      expect(find.text('未解决错因'), findsNothing);
      expect(find.text('已掌握未到期'), findsNothing);
      // 一题一行：题名各出现一次；行副标题带题型、错因名与 FSRS 状态。
      expect(find.text('逾期题'), findsOneWidget);
      expect(find.text('今日到期题'), findsOneWidget);
      expect(find.text('未到期题'), findsOneWidget);
      expect(find.text('今日新题 A'), findsOneWidget);
      expect(find.text('今日新题 B'), findsOneWidget);
      expect(find.textContaining('单项选择 · 概念不清 · 未开始'), findsOneWidget);
      expect(find.textContaining('待确认 · 概念不清 · 已逾期 1 天'), findsOneWidget);
      expect(find.textContaining('待确认 · 计算错误 · 今日到期'), findsOneWidget);
      expect(find.textContaining('未到期 · '), findsOneWidget);
      // 逾期行有「已到期」红标。
      expect(find.text('已到期'), findsOneWidget);
      // 未加入复习的题只在“还没加入复习”盒里。
      expect(find.textContaining('还没加入复习的题'), findsOneWidget);
      expect(find.textContaining('未加入题'), findsOneWidget);
      // 学科 / 题型 / 错因三维筛选保留。
      expect(find.text('学科'), findsOneWidget);
      expect(find.text('题型'), findsOneWidget);
      expect(find.text('错因'), findsOneWidget);
    });
  });

  group('#14 空状态', () {
    testWidgets('今天没有到期复习：伙伴 + 未到期/未开始题数 + 去专项练习', (tester) async {
      await seedQ(mkQ('q-future', '未到期题', errorTypes: ['概念不清']));
      await seedDueCard('q-future', daysAgo: 1); // 明天到期：池非空、无到期、无今日新题
      await pumpReview(tester);
      expect(find.textContaining('今天没有到期复习'), findsOneWidget);
      expect(find.textContaining('未到期的题有 1 道，未开始的题有 0 道。'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '去专项练习'), findsOneWidget);
      // 空状态下“开始复习”不可点（无到期、无今日新题，不进空白会话）。
      final start =
          find.widgetWithText(QmButton, '开始复习').evaluate().first.widget
              as QmButton;
      expect(start.onPressed, isNull);
    });

    testWidgets('有暂停会话时优先显示恢复条，空状态文案退后', (tester) async {
      await seedQ(
        mkQ(
          'q1',
          '函数极限',
          errorTypes: ['概念不清'],
          answer: '3',
          explanation: 'lim sin3x/x = 3。',
        ),
      );
      await seedDueCard('q1', daysAgo: 3);
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      await tapQm(tester, '暂停');
      // 恢复条优先于列表/空状态出现。
      expect(find.textContaining('继续上次会话'), findsNWidgets(2));
      expect(find.widgetWithText(QmButton, '放弃上次会话'), findsOneWidget);
      expect(find.textContaining('今天没有到期复习'), findsNothing);
      // 点“继续上次会话”回到中断的题。
      await tapQm(tester, '继续上次会话');
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      expect(find.text('① 看题'), findsOneWidget);
    });
  });

  group('#15 列表分页按题行计', () {
    testWidgets('一题多错因只占一行：11 道题共 11 行，分两页', (tester) async {
      await seedQ(mkQ('q-p00', '分页题 00', errorTypes: ['概念不清', '计算错误', '方法不会']));
      for (var i = 1; i <= 10; i++) {
        await seedQ(
          mkQ(
            'q-p${i.toString().padLeft(2, '0')}',
            '分页题 ${i.toString().padLeft(2, '0')}',
          ),
        );
      }
      await pumpReview(tester);
      // 11 道题 = 11 行（不是 13 条错因），默认每页 10 行 → 2 页。
      expect(find.text('共 11 道 · 第 1 / 2 页'), findsOneWidget);
      // 三错因的题在第 1 页只出现一次。
      expect(find.text('分页题 00'), findsOneWidget);
      expect(find.textContaining('概念不清、计算错误、方法不会 · 未开始'), findsOneWidget);
      await tapQm(tester, '下一页');
      expect(find.text('共 11 道 · 第 2 / 2 页'), findsOneWidget);
      expect(find.text('分页题 10'), findsOneWidget);
      expect(find.text('分页题 00'), findsNothing);
    });
  });

  group('#16 到期复习全程', () {
    testWidgets('三步全程：看题（本轮错因 + FSRS 状态）→ 作答 → 核对 → 小结', (tester) async {
      await seedQ(
        mkQ(
          'q-m',
          '多错因题',
          errorTypes: ['概念不清', '方法不会'],
          answer: '3',
          explanation: '解析文本。',
        ),
      );
      await seedDueCard('q-m', daysAgo: 3);
      final records = await repo.causeRecordsFor('q-m');
      final pending = records.firstWhere((r) => r.cause == '概念不清');
      await repo.saveRemedy(pending, '先把公式抄三遍');
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      // 会话头：本轮共 1 道题、2 个错因；看题步列出本轮全部错因。
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      expect(find.textContaining('本轮共 2 个错因'), findsOneWidget);
      expect(find.text('本轮 2 项错因'), findsOneWidget);
      expect(find.text('① 看题'), findsOneWidget);
      // 两错因行共用题级 FSRS 状态：卡已到期，两行都显示「已到期」。
      expect(find.text('已到期'), findsNWidgets(2));
      // 作答步：纸上作答；核对步：答案 + 解析，确认核对进下一题。
      await tapQm(tester, '开始作答');
      expect(find.text('② 作答'), findsOneWidget);
      expect(find.textContaining('请在纸上演算/作答'), findsOneWidget);
      await tapQm(tester, '我已完成作答');
      expect(find.text('③ 核对'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.textContaining('解析文本'), findsOneWidget);
      await tapQm(tester, '确认核对，下一题');
      // 小结：只报对错数、用时、薄弱点与下次时间（无治愈/自查数）。
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(
        find.textContaining('完成 1 道题 · 答对 0 道 · 答错 0 道 · 未判分 1 道'),
        findsOneWidget,
      );
      // 补救记录仍在库里（数据未删，只是会话不再展示“上次对策”；
      // saveRemedy 入库时带日期前缀）。
      final after = await repo.causeRecordsFor('q-m');
      expect(
        after.firstWhere((r) => r.cause == '概念不清').remedyHistory.first,
        contains('先把公式抄三遍'),
      );
    });
  });

  group('#17 选择题作答判分', () {
    testWidgets('标签已确认：点选 → 提交 → 锁定，显示对错 + 答案 + 解析', (tester) async {
      await seedQ(
        mkQ(
          'q1',
          '单选题',
          errorTypes: ['概念不清'],
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          optionLabelsConfirmed: true,
          correctOption: 'B',
          answer: 'B',
          explanation: '选 B 的理由。',
        ),
      );
      await seedDueCard('q1', daysAgo: 3);
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await tapQm(tester, '开始作答');
      // 选项按钮按 option_labels 渲染；无置信度步，未选时提交不可点。
      expect(find.widgetWithText(QmButton, 'A'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'B'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'C'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'D'), findsOneWidget);
      expect(find.text('这次作答有多大把握？'), findsNothing);
      final submitDisabled =
          find.widgetWithText(QmButton, '提交答案').evaluate().first.widget
              as QmButton;
      expect(submitDisabled.onPressed, isNull);
      await tapQm(tester, 'B');
      await tapQm(tester, '提交答案');
      // 提交后锁定：核对步不再显示选项按钮，显示对错 + 答案 + 解析。
      expect(find.text('回答正确'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'A'), findsNothing);
      expect(find.widgetWithText(QmButton, 'B'), findsNothing);
      expect(find.textContaining('选 B 的理由'), findsOneWidget);
      // 点“确认核对”才正式写库（提交答案只在内存里判分、进核对步）。
      await tapQm(tester, '确认核对，下一题');
      // attempt 写库：selected=B、correct=1、confidence 为空（无置信度）。
      final attempts = await attemptRows('q1');
      expect(attempts.length, 1);
      expect(attempts.single['selected'], '["B"]');
      expect(attempts.single['correct'], 1);
      expect(attempts.single['confidence'], isNull);
      expect(attempts.single['status'], '已提交');
    });

    testWidgets('标签已确认但未填正确答案：不显示选项按钮、走纸上作答，不判分', (tester) async {
      // REV5 R1-3：单选判分门禁只看答案配置是否有效（标签 ≥2 位且正确
      // 答案在标签内），不再读 optionLabelsConfirmed 列。标签已确认
      // 但未填正确答案 → 判分不可用，走纸上作答，不显示选项按钮。
      await seedQ(
        mkQ(
          'q1',
          '无答案单选题',
          errorTypes: ['概念不清'],
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          optionLabelsConfirmed: true,
          answer: '见解析',
          explanation: '解析文本。',
        ),
      );
      await seedDueCard('q1', daysAgo: 3);
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await tapQm(tester, '开始作答');
      expect(find.text('这道题暂无可用答案，不显示选项按钮。请在纸上作答，或先补全答案。'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'A'), findsNothing);
      expect(find.widgetWithText(QmButton, 'B'), findsNothing);
      expect(find.widgetWithText(QmButton, 'C'), findsNothing);
      expect(find.widgetWithText(QmButton, 'D'), findsNothing);
      expect(find.text('这次作答有多大把握？'), findsNothing);
      expect(find.widgetWithText(QmButton, '补全答案'), findsOneWidget);
      await tapQm(tester, '我已完成作答');
      // 核对步：无可判分，不显示对错；标准答案待补充、解析照常显示。
      expect(find.text('回答正确'), findsNothing);
      expect(find.text('回答错误'), findsNothing);
      expect(find.text('待补充'), findsOneWidget);
      expect(find.textContaining('解析文本'), findsOneWidget);
      await tapQm(tester, '确认核对，下一题');
      expect(find.text('本轮复习总结'), findsOneWidget);
      // 纸上作答不判分：attempt 只记“已完成作答”，选择/对错/置信度皆空。
      final attempts = await attemptRows('q1');
      expect(attempts.length, 1);
      expect(attempts.single['selected'], isNull);
      expect(attempts.single['correct'], isNull);
      expect(attempts.single['confidence'], isNull);
      expect(attempts.single['status'], '已完成作答');
    });
  });

  group('#18 标签未确认不再拦选项按钮', () {
    testWidgets('标签未确认不拦选项按钮：标签齐全即可点选判分', (tester) async {
      // REV5 R1-3：门禁不再读 optionLabelsConfirmed 列；标签齐全
      // （≥2 位）且正确答案有效即可点选判分，未确认标签不再拦路，
      // “选项标签尚未确认”提示与“补全标签”入口已随之取消。
      await seedQ(
        mkQ(
          'q1',
          '标签未确认单选题',
          errorTypes: ['概念不清'],
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          correctOption: 'B',
          answer: 'B',
          explanation: '选 B 的理由。',
        ),
      );
      await seedDueCard('q1', daysAgo: 3);
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await tapQm(tester, '开始作答');
      expect(find.text('选项标签尚未确认，不显示选项按钮。请在纸上作答，或先补全标签。'), findsNothing);
      expect(find.widgetWithText(QmButton, '补全标签'), findsNothing);
      expect(find.widgetWithText(QmButton, 'A'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'B'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'C'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'D'), findsOneWidget);
      await tapQm(tester, 'B');
      await tapQm(tester, '提交答案');
      expect(find.text('回答正确'), findsOneWidget);
      // 点“确认核对”才正式写库（提交答案只在内存里判分、进核对步）。
      await tapQm(tester, '确认核对，下一题');
      final attempts = await attemptRows('q1');
      expect(attempts.length, 1);
      expect(attempts.single['selected'], '["B"]');
      expect(attempts.single['correct'], 1);
      expect(attempts.single['confidence'], isNull);
    });

    testWidgets('标签未确认且无答案：点“我已完成作答”走纸上作答，不判分', (tester) async {
      await seedQ(
        mkQ(
          'q1',
          '标签未确认单选题',
          errorTypes: ['概念不清'],
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
        ),
      );
      await seedDueCard('q1', daysAgo: 3);
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await tapQm(tester, '开始作答');
      // 无有效答案 → 纸上作答提示，不显示选项按钮。
      expect(find.text('这道题暂无可用答案，不显示选项按钮。请在纸上作答，或先补全答案。'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'A'), findsNothing);
      await tapQm(tester, '我已完成作答');
      // 核对步：标准答案与解析均待补充，不显示对错。
      expect(find.text('待补充'), findsNWidgets(2));
      expect(find.text('回答正确'), findsNothing);
      expect(find.text('回答错误'), findsNothing);
      await tapQm(tester, '确认核对，下一题');
      expect(find.text('本轮复习总结'), findsOneWidget);
      final attempts = await attemptRows('q1');
      expect(attempts.length, 1);
      expect(attempts.single['selected'], isNull);
      expect(attempts.single['correct'], isNull);
      expect(attempts.single['confidence'], isNull);
      expect(attempts.single['status'], '已完成作答');
    });
  });

  group('#19 判断题作答', () {
    testWidgets('固定“正确/错误”按钮：不依赖选项标签，判分只看 correct_option', (tester) async {
      await seedQ(
        mkQ(
          'q1',
          '判断题',
          errorTypes: ['概念不清'],
          questionType: 'true_false',
          correctOption: '正确',
          answer: '正确',
          explanation: '该命题成立。',
        ),
      );
      await seedDueCard('q1', daysAgo: 3);
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await tapQm(tester, '开始作答');
      // 标签全空也不影响：只显示固定“正确/错误”两个按钮。
      expect(find.widgetWithText(QmButton, '正确'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '错误'), findsOneWidget);
      await tapQm(tester, '错误');
      await tapQm(tester, '提交答案');
      expect(find.text('回答错误'), findsOneWidget);
      expect(find.textContaining('该命题成立'), findsOneWidget);
      // 点“确认核对”才正式写库（提交答案只在内存里判分、进核对步）。
      await tapQm(tester, '确认核对，下一题');
      final attempts = await attemptRows('q1');
      expect(attempts.length, 1);
      expect(attempts.single['selected'], '["错误"]');
      expect(attempts.single['correct'], 0);
      expect(attempts.single['confidence'], isNull);
    });
  });

  group('#20 填空/解答纸上作答与核对确认', () {
    testWidgets('有答案：核对显示答案与解析，确认后进下一题；无答案仍可继续', (tester) async {
      await seedQ(
        mkQ(
          'q1',
          '填空题',
          errorTypes: ['计算错误'],
          questionType: 'fill_blank',
          answer: '42',
          explanation: '代入得 42。',
        ),
      );
      await seedQ(
        mkQ('q2', '无答案解答题', errorTypes: ['方法不会'], questionType: 'calculation'),
      );
      await seedDueCard('q1', daysAgo: 3);
      await seedDueCard('q2', daysAgo: 3);
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      // 第一题：核对步显示标准答案与解析，提示对照后确认进入下一题。
      await tapQm(tester, '开始作答');
      await tapQm(tester, '我已完成作答');
      expect(find.text('42'), findsOneWidget);
      expect(find.textContaining('代入得 42'), findsOneWidget);
      expect(find.textContaining('对照标准答案和解析核对一下'), findsOneWidget);
      await tapQm(tester, '确认核对，下一题');
      // 第二题：无答案，标准答案与解析均待补充，仍可继续。
      await tapQm(tester, '开始作答');
      await tapQm(tester, '我已完成作答');
      expect(find.text('待补充'), findsNWidgets(2));
      await tapQm(tester, '确认核对，下一题');
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(
        find.textContaining('完成 2 道题 · 答对 0 道 · 答错 0 道 · 未判分 2 道'),
        findsOneWidget,
      );
    });
  });

  group('#21 一题多错因只记一次作答', () {
    testWidgets('一题双错因：答对只写一条本题 attempt，错因记录冻结不动', (tester) async {
      // 新流程等价断言：旧“关联=是才计入 / 关联=否不推进”的按错因拆分
      // 已随自查流程删除；作答结果只属于题目本身，不按错因复制，
      // 也不写错因治愈计数。
      await seedQ(
        mkQ(
          'q1',
          '双错因单选题',
          errorTypes: ['概念不清', '计算错误'],
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          optionLabelsConfirmed: true,
          correctOption: 'B',
          answer: 'B',
          explanation: '选 B 的理由。',
        ),
      );
      await seedDueCard('q1', daysAgo: 3);
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      expect(find.textContaining('本轮共 2 个错因'), findsOneWidget);
      await objectiveToCheck(tester, option: 'B');
      expect(find.text('回答正确'), findsOneWidget);
      await tapQm(tester, '确认核对，下一题');
      expect(find.text('本轮复习总结'), findsOneWidget);
      // 按题记对错：只有一条 attempt，答对 1 次。
      final attempts = await attemptRows('q1');
      expect(attempts.length, 1);
      expect(attempts.single['correct'], 1);
      // 错因记录冻结：两个错因的计数与状态一字未动。
      final r1 = await causeRow('q1', '概念不清');
      final r2 = await causeRow('q1', '计算错误');
      expect(r1['solved_count'], 0);
      expect(r2['solved_count'], 0);
      expect(r1['status'], 'pending');
      expect(r2['status'], 'pending');
    });
  });

  group('#24 小结页', () {
    testWidgets('小结只报对错数、用时、薄弱点与下次时间', (tester) async {
      // q1：单选答对（客观汇总计答对 1）。
      await seedQ(
        mkQ(
          'q1',
          '单选题',
          errorTypes: ['概念不清'],
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          optionLabelsConfirmed: true,
          correctOption: 'B',
          answer: 'B',
          explanation: '选 B。',
        ),
      );
      // q2：填空无答案（未判分计 1）。
      await seedQ(
        mkQ('q2', '无答案填空题', errorTypes: ['计算错误'], questionType: 'fill_blank'),
      );
      await seedDueCard('q1', daysAgo: 3);
      await seedDueCard('q2', daysAgo: 3);
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      // q1：答对。
      await objectiveToCheck(tester, option: 'B');
      await tapQm(tester, '确认核对，下一题');
      // q2：纸上作答，无答案。
      await paperToCheck(tester);
      await tapQm(tester, '确认核对，下一题');
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(
        find.textContaining('完成 2 道题 · 答对 1 道 · 答错 0 道 · 未判分 1 道'),
        findsOneWidget,
      );
      expect(find.textContaining('用时 '), findsOneWidget);
      expect(find.textContaining('跳过 0 道 · 留待下次 0 道'), findsOneWidget);
      // 答对的题推进了 FSRS，下次时间取本轮最早的一道。
      expect(find.textContaining('下次复习最早 '), findsOneWidget);
      // 两题都无知识点：无按知识点汇总的薄弱点。
      expect(find.text('本次没有按知识点汇总的薄弱点。'), findsOneWidget);
    });
  });
}
