// 十四批 D1 Linux 模拟用户核验：M3 到期复习会话与软件内答题。
//
// 走真实界面 + 真实代码路径：ReviewPage（Riverpod reviewProvider）+
// 真实 QuestionRepository + 真实 Drift 内存库（AppDatabase.openForTest，
// 绝不动 ~/.local/share/quiz-master2/quiz-master2.db 本体）。
// 种子数据直接造题 + 错因（cause_records）+ 复习加入状态；到期状态靠
// recheck_date / 状态字段控制；24 小时规则用“锚点写成 25 小时前 / 1 小时前”
// 的种子数据覆盖，不真等 24 小时。不调 OCR，不改 lib/。
//
// 覆盖清单：#13 #14 #15 #16 #17 #18 #19 #20 #21 #22 #24 #25。
// #22(d) 同会话第二次“已解决”：UI 在提交后锁定 verdict（同一会话内
// 无法再次提交同一错因），因此该条另用真实 repo + 真实库在同文件末尾
// 以补充测试覆盖（见 group '22-d 补充'）。
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
import 'package:quiz_master2/data/review_engine.dart';
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

  /// 造题 + 加入复习（setReviewJoined 按 errorTypes 建错因记录）。
  Future<void> seedQ(Question q) async {
    await ensureDb();
    await AppDatabase.upsertQuestionInto(db, q);
    if (q.reviewJoined) await repo.setReviewJoined(q, true);
  }

  /// 直接改库内错因记录的状态 / 计数 / 复查日 / 24h 锚点 / 加入时间。
  Future<void> setCause(
    String qid,
    String cause, {
    CauseStatus status = CauseStatus.pending,
    int solvedCount = 0,
    DateTime? recheckDate,
    int? anchorMs,
    String? anchorSession,
    DateTime? joinedAt,
  }) async {
    final statusStr = switch (status) {
      CauseStatus.pending => 'pending',
      CauseStatus.inProgress => 'inProgress',
      CauseStatus.solved => 'solved',
    };
    await db.customUpdate(
      'UPDATE cause_records SET status = ?, solved_count = ?, '
      'recheck_date = ?, last_counted_success_at = ?, '
      'last_counted_session_id = ?, joined_at = ? '
      'WHERE question_id = ? AND cause = ?',
      variables: [
        Variable.withString(statusStr),
        Variable.withInt(solvedCount),
        recheckDate == null
            ? const Variable<int>(null)
            : Variable.withInt(recheckDate.millisecondsSinceEpoch),
        anchorMs == null
            ? const Variable<int>(null)
            : Variable.withInt(anchorMs),
        anchorSession == null
            ? const Variable<String>(null)
            : Variable.withString(anchorSession),
        joinedAt == null
            ? Variable.withInt(DateTime(2026, 11, 10).millisecondsSinceEpoch)
            : Variable.withInt(joinedAt.millisecondsSinceEpoch),
        Variable.withString(qid),
        Variable.withString(cause),
      ],
    );
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

  Future<List<Map<String, Object?>>> attemptRows(String qid) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM attempts WHERE question_id = ?',
          variables: [Variable.withString(qid)],
        )
        .get();
    return rows.map((r) => r.data).toList();
  }

  Future<List<Map<String, Object?>>> historyRows(String causeStable) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM review_history WHERE cause_id = ? ORDER BY id',
          variables: [Variable.withString(causeStable)],
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

  Future<void> tapQm(
    WidgetTester tester,
    String label, {
    int at = 0,
  }) async {
    final finder = find.widgetWithText(QmButton, label);
    await tester.ensureVisible(finder.at(at));
    await settle(tester);
    await tester.tap(finder.at(at));
    await settle(tester);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.ensureVisible(finder);
    await settle(tester);
    await tester.tap(finder);
    await settle(tester);
  }

  /// 纸上作答走完“看题 → 作答 → 核对”（有答案时做核对确认）。
  Future<void> paperToCheck(
    WidgetTester tester, {
    String? confirm,
  }) async {
    await tapQm(tester, '开始作答');
    await tapQm(tester, '我已完成作答');
    if (confirm != null) await tapQm(tester, confirm);
  }

  /// 单选/判断走完“看题 → 作答（点选 + 置信度 + 提交）→ 核对”。
  Future<void> objectiveToCheck(
    WidgetTester tester, {
    required String option,
    String confidence = '确定',
  }) async {
    await tapQm(tester, '开始作答');
    await tapQm(tester, option);
    await tapQm(tester, confidence);
    await tapQm(tester, '提交答案');
  }

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  group('#13 复习页分组与入口', () {
    testWidgets('页顶计数去重 + 五组顺序 + 一题一行 + 筛选保留', (tester) async {
      await seedQ(mkQ('q-over', '逾期复查题', errorTypes: ['概念不清']));
      await setCause(
        'q-over',
        '概念不清',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: today().subtract(const Duration(days: 1)),
      );
      await seedQ(mkQ('q-due', '今日到期题', errorTypes: ['计算错误']));
      await setCause(
        'q-due',
        '计算错误',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: today(),
      );
      await seedQ(
        mkQ(
          'q-uns',
          '未解决题',
          errorTypes: ['概念不清'],
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
          optionLabelsConfirmed: true,
          correctOption: 'B',
        ),
      );
      await seedQ(mkQ('q-mas', '已掌握题', errorTypes: ['概念不清']));
      await setCause(
        'q-mas',
        '概念不清',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: today().add(const Duration(days: 7)),
      );
      await seedQ(
        mkQ('q-nj', '未加入题', errorTypes: ['概念不清'], reviewJoined: false),
      );

      await pumpReview(tester);
      // 页顶：到期 3 道题（逾期+今日+未解决，去重后题数）/ 3 个错因。
      expect(find.textContaining('今日待复习'), findsOneWidget);
      expect(find.textContaining('3 道题 / 3 个错因'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '开始复习'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '专项练习'), findsOneWidget);
      // 五组顺序：已逾期复查 → 今日到期复查 → 未解决错因 → 已掌握未到期。
      expect(find.text('已逾期复查'), findsOneWidget);
      expect(find.text('今日到期复查'), findsOneWidget);
      expect(find.text('未解决错因'), findsOneWidget);
      expect(find.text('已掌握未到期'), findsOneWidget);
      // 一题一行：题名各出现一次；行副标题带题型 chip 文案、错因名与状态。
      expect(find.text('逾期复查题'), findsOneWidget);
      expect(find.text('今日到期题'), findsOneWidget);
      expect(find.text('未解决题'), findsOneWidget);
      expect(find.text('已掌握题'), findsOneWidget);
      expect(find.textContaining('单项选择 · 概念不清 · 1 项未解决'), findsOneWidget);
      expect(find.textContaining('1 项待复查'), findsNWidgets(2));
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
    testWidgets('今天没有到期复习：伙伴 + 等待未来复查的错因数', (tester) async {
      await seedQ(mkQ('q-mas', '已掌握题', errorTypes: ['概念不清']));
      await setCause(
        'q-mas',
        '概念不清',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: today().add(const Duration(days: 7)),
      );
      await pumpReview(tester);
      expect(find.textContaining('今天没有到期复习'), findsOneWidget);
      expect(
        find.textContaining('正在等待未来复查的错因有 1 个'),
        findsOneWidget,
      );
      expect(find.widgetWithText(QmButton, '去专项练习'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '查看已掌握题目'), findsOneWidget);
      // 空状态下“开始复习”不可点（队列为空，不进空白会话）。
      final start = find
          .widgetWithText(QmButton, '开始复习')
          .evaluate()
          .first
          .widget as QmButton;
      expect(start.onPressed, isNull);
    });

    testWidgets('有暂停会话时优先显示继续/放弃重开，空状态文案退后', (tester) async {
      await seedQ(
        mkQ(
          'q1',
          '函数极限',
          errorTypes: ['概念不清'],
          answer: '3',
          explanation: 'lim sin3x/x = 3。',
        ),
      );
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      await tapQm(tester, '暂停');
      // 恢复条优先于列表/空状态出现。
      expect(find.textContaining('继续上次会话'), findsNWidgets(2));
      expect(find.widgetWithText(QmButton, '放弃重开'), findsOneWidget);
      expect(find.textContaining('今天没有到期复习'), findsNothing);
      // 点“继续上次会话”回到中断的题。
      await tapQm(tester, '继续上次会话');
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      expect(find.text('① 看题'), findsOneWidget);
    });
  });

  group('#15 列表分页按题行计', () {
    testWidgets('一题多错因只占一行：11 道题共 11 条，分两页', (tester) async {
      await seedQ(
        mkQ(
          'q-p00',
          '分页题 00',
          errorTypes: ['概念不清', '计算错误', '方法不会'],
        ),
      );
      for (var i = 1; i <= 10; i++) {
        await seedQ(
          mkQ('q-p${i.toString().padLeft(2, '0')}', '分页题 ${i.toString().padLeft(2, '0')}'),
        );
      }
      await pumpReview(tester);
      // 11 道题 = 11 行（不是 13 条错因），默认每页 10 条 → 2 页。
      expect(find.text('共 11 条 · 第 1 / 2 页'), findsOneWidget);
      // 三错因的题在第 1 页只出现一次。
      expect(find.text('分页题 00'), findsOneWidget);
      expect(
        find.textContaining('概念不清、计算错误、方法不会 · 3 项未解决'),
        findsOneWidget,
      );
      await tapQm(tester, '下一页');
      expect(find.text('共 11 条 · 第 2 / 2 页'), findsOneWidget);
      expect(find.text('分页题 10'), findsOneWidget);
      expect(find.text('分页题 00'), findsNothing);
    });
  });

  group('#16 到期复习全程', () {
    testWidgets('开场题数/错因数 + 全屏题干 + 非本轮错因折叠 + 对策默认收起', (tester) async {
      await seedQ(
        mkQ(
          'q-m',
          '多错因题',
          errorTypes: ['概念不清', '方法不会'],
          answer: '3',
          explanation: '解析文本。',
        ),
      );
      await setCause(
        'q-m',
        '方法不会',
        status: CauseStatus.solved,
        solvedCount: 2,
        recheckDate: today().add(const Duration(days: 7)),
      );
      final records = await repo.causeRecordsFor('q-m');
      final pending = records.firstWhere((r) => r.cause == '概念不清');
      await repo.saveRemedy(pending, '先把公式抄三遍');
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      // 开场：本轮共 1 道题、1 个错因（只计本轮错因）。
      expect(find.textContaining('第 1 / 1 道题'), findsOneWidget);
      expect(find.textContaining('本轮共 1 道题、1 个错因'), findsOneWidget);
      // 看题步：本轮错因 + 非本轮错因折叠，标未到期与下次复查日期。
      expect(find.text('本轮 1 项错因'), findsOneWidget);
      expect(
        find.textContaining('方法不会：未到期，下次复查'),
        findsOneWidget,
      );
      // 自查步：上次对策默认收起，可展开查看。
      await paperToCheck(tester, confirm: '已对照，关键答案/步骤符合');
      await tapQm(tester, '下一步：自查');
      expect(find.text('④ 错因自查'), findsOneWidget);
      expect(find.textContaining('上次对策（先自己回忆，可展开查看）'), findsOneWidget);
      expect(find.textContaining('先把公式抄三遍'), findsNothing);
      await tapQm(tester, '展开查看');
      expect(find.textContaining('先把公式抄三遍'), findsOneWidget);
    });
  });

  group('#17 选择题作答判分', () {
    testWidgets('标签已确认：点选 → 置信度 → 提交 → 锁定，显示对错 + 答案 + 解析', (tester) async {
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
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await tapQm(tester, '开始作答');
      // 选项按钮按 option_labels 渲染；未选置信度时提交不可点。
      expect(find.widgetWithText(QmButton, 'A'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'B'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'C'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'D'), findsOneWidget);
      expect(find.text('这次作答有多大把握？'), findsOneWidget);
      await tapQm(tester, 'B');
      final submitDisabled = find
          .widgetWithText(QmButton, '提交答案')
          .evaluate()
          .first
          .widget as QmButton;
      expect(submitDisabled.onPressed, isNull);
      await tapQm(tester, '确定');
      await tapQm(tester, '提交答案');
      // 提交后锁定：核对步不再显示选项按钮，显示对错 + 答案 + 解析。
      expect(find.text('回答正确'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'A'), findsNothing);
      expect(find.widgetWithText(QmButton, 'B'), findsNothing);
      expect(find.textContaining('选 B 的理由'), findsOneWidget);
      // attempt 写库：selected=B、correct=1、confidence=确定。
      final attempts = await attemptRows('q1');
      expect(attempts.length, 1);
      expect(attempts.single['selected'], '["B"]');
      expect(attempts.single['correct'], 1);
      expect(attempts.single['confidence'], '确定');
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
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await tapQm(tester, '开始作答');
      expect(
        find.text('未配置有效答案，不显示选项按钮。请在纸上作答，或先补全答案。'),
        findsOneWidget,
      );
      expect(find.widgetWithText(QmButton, 'A'), findsNothing);
      expect(find.widgetWithText(QmButton, 'B'), findsNothing);
      expect(find.widgetWithText(QmButton, 'C'), findsNothing);
      expect(find.widgetWithText(QmButton, 'D'), findsNothing);
      expect(find.text('这次作答有多大把握？'), findsNothing);
      expect(find.widgetWithText(QmButton, '补全答案'), findsOneWidget);
      await tapQm(tester, '我已完成作答');
      // 核对步：无可判分，不显示对错；标准答案待补充、解析照常显示；
      // 单选无正确答案即无有效标准答案，不出核对确认四选一。
      expect(find.text('回答正确'), findsNothing);
      expect(find.text('回答错误'), findsNothing);
      expect(find.textContaining('标准答案：待补充'), findsOneWidget);
      expect(find.textContaining('解析文本'), findsOneWidget);
      expect(find.textContaining('暂无标准答案/解析'), findsOneWidget);
      await tapQm(tester, '下一步：自查');
      await tapQm(tester, '未解决', at: 0);
      await tapQm(tester, '看总结');
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
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await tapQm(tester, '开始作答');
      expect(
        find.text('选项标签尚未确认，不显示选项按钮。请在纸上作答，或先补全标签。'),
        findsNothing,
      );
      expect(find.widgetWithText(QmButton, '补全标签'), findsNothing);
      expect(find.widgetWithText(QmButton, 'A'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'B'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'C'), findsOneWidget);
      expect(find.widgetWithText(QmButton, 'D'), findsOneWidget);
      await tapQm(tester, 'B');
      await tapQm(tester, '确定');
      await tapQm(tester, '提交答案');
      expect(find.text('回答正确'), findsOneWidget);
      final attempts = await attemptRows('q1');
      expect(attempts.length, 1);
      expect(attempts.single['selected'], '["B"]');
      expect(attempts.single['correct'], 1);
      expect(attempts.single['confidence'], '确定');
    });

    testWidgets('标签未确认时点“我已完成作答”走纸上作答：selected/correct/置信度皆空', (tester) async {
      await seedQ(
        mkQ(
          'q1',
          '标签未确认单选题',
          errorTypes: ['概念不清'],
          questionType: 'choice_single',
          optionLabels: const ['A', 'B', 'C', 'D'],
        ),
      );
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await tapQm(tester, '开始作答');
      await tapQm(tester, '我已完成作答');
      // 无答案：显示暂无标准答案/解析，仍可继续进自查。
      expect(find.textContaining('暂无标准答案/解析'), findsOneWidget);
      expect(find.text('这次作答有多大把握？'), findsNothing);
      await tapQm(tester, '下一步：自查');
      await tapQm(tester, '未解决', at: 0);
      await tapQm(tester, '看总结');
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
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await tapQm(tester, '开始作答');
      // 标签全空也不影响：只显示固定“正确/错误”两个按钮。
      expect(find.widgetWithText(QmButton, '正确'), findsOneWidget);
      expect(find.widgetWithText(QmButton, '错误'), findsOneWidget);
      await tapQm(tester, '错误');
      await tapQm(tester, '确定');
      await tapQm(tester, '提交答案');
      expect(find.text('回答错误'), findsOneWidget);
      expect(find.textContaining('该命题成立'), findsOneWidget);
      final attempts = await attemptRows('q1');
      expect(attempts.length, 1);
      expect(attempts.single['selected'], '["错误"]');
      expect(attempts.single['correct'], 0);
      expect(attempts.single['confidence'], '确定');
    });
  });

  group('#20 填空/解答纸上作答与核对确认', () {
    testWidgets('有答案：核对确认四选一；选“有错误”则任何错因都不能记已核验已解决；无答案仍可继续', (tester) async {
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
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      // 第一题：显示标准答案与解析，随后出现核对确认四选一。
      await tapQm(tester, '开始作答');
      await tapQm(tester, '我已完成作答');
      expect(find.textContaining('42'), findsWidgets);
      expect(find.textContaining('代入得 42'), findsOneWidget);
      for (final c in [
        '已对照，关键答案/步骤符合',
        '已对照，有错误或明显遗漏',
        '无法判断',
        '尚未核对',
      ]) {
        expect(find.widgetWithText(QmButton, c), findsOneWidget);
      }
      await tapQm(tester, '已对照，有错误或明显遗漏');
      await tapQm(tester, '下一步：自查');
      await tapQm(tester, '已解决');
      await tapQm(tester, '下一题');
      // 第二题：无答案显示“暂无标准答案/解析”，仍可继续。
      await tapQm(tester, '开始作答');
      await tapQm(tester, '我已完成作答');
      expect(find.textContaining('暂无标准答案/解析'), findsOneWidget);
      await tapQm(tester, '下一步：自查');
      await tapQm(tester, '未解决');
      await tapQm(tester, '看总结');
      // 第一题选“有错误”：自评已解决只记未核验，不推进治愈。
      expect(find.textContaining('未核验自评 1 个'), findsOneWidget);
      expect(find.textContaining('今天解决了 0 个错因'), findsOneWidget);
      final r1 = await causeRow('q1', '计算错误');
      expect(r1['solved_count'], 0);
    });
  });

  group('#21 错因自查与证据关联', () {
    testWidgets('一题双错因：关联=是才计入，关联=否不推进——答对绝不自动复制到全部错因', (tester) async {
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
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await objectiveToCheck(tester, option: 'B', confidence: '确定');
      expect(find.text('回答正确'), findsOneWidget);
      await tapQm(tester, '下一步：自查');
      // 证据关联判断逐错因出现（两个错因各一组）。
      expect(
        find.text('本次作答是否直接检验了这个错因？'),
        findsNWidgets(2),
      );
      expect(find.text('不选则该错因按未核验处理。'), findsNWidgets(2));
      // 错因 1：关联=是 + 已解决；错因 2：关联=否 + 已解决。
      await tapQm(tester, '是', at: 0);
      await tapQm(tester, '已解决', at: 0);
      await tapQm(tester, '否', at: 1);
      await tapQm(tester, '已解决', at: 1);
      await tapQm(tester, '看总结');
      expect(find.textContaining('未核验自评 1 个'), findsOneWidget);
      expect(find.textContaining('今天解决了 0 个错因'), findsOneWidget);
      final r1 = await causeRow('q1', '概念不清');
      final r2 = await causeRow('q1', '计算错误');
      expect(r1['solved_count'], 1); // 关联=是：客观判分作核验依据，计入。
      expect(r2['solved_count'], 0); // 关联=否：按未核验处理，不计入。
      final h1 = await historyRows(causeStableId(
        (await repo.causeRecordsFor('q1')).firstWhere((r) => r.cause == '概念不清'),
      ));
      expect(h1.single['verification_source'], '客观判分');
      expect(h1.single['attempt_id'], isNotNull);
      final h2 = await historyRows(causeStableId(
        (await repo.causeRecordsFor('q1')).firstWhere((r) => r.cause == '计算错误'),
      ));
      expect(h2.single['verification_source'], '未核验');
    });

    testWidgets('无软件答案：勾选外部核对才计入，不勾选记未核验自我判断', (tester) async {
      await seedQ(
        mkQ('q1', '无答案计算题', errorTypes: ['方法不会'], questionType: 'calculation'),
      );
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await paperToCheck(tester);
      await tapQm(tester, '下一步：自查');
      // 选“已解决”出现外部核对复选框，默认不勾选。
      expect(
        find.text('我已对照课本/讲义等可靠外部资料核对'),
        findsNothing,
      );
      await tapQm(tester, '已解决');
      expect(
        find.text('我已对照课本/讲义等可靠外部资料核对'),
        findsOneWidget,
      );
      expect(find.text('不勾选即按未核验处理，不推进治愈。'), findsOneWidget);
      await tapText(tester, '我已对照课本/讲义等可靠外部资料核对');
      await tapQm(tester, '看总结');
      final r = await causeRow('q1', '方法不会');
      expect(r['solved_count'], 1);
      final h = await historyRows(causeStableId(
        (await repo.causeRecordsFor('q1')).single,
      ));
      expect(h.single['verification_source'], '外部资料核对');
      expect(h.single['verification_status'], '已核验');
    });
  });

  group('#22 治愈进度与 24 小时', () {
    testWidgets('锚点 25 小时前：第二次有效成功计入并治愈；显示下次可计入治愈的最早时间', (tester) async {
      final anchor = DateTime.now().subtract(const Duration(hours: 25));
      await seedQ(
        mkQ(
          'q1',
          '待治愈题',
          errorTypes: ['概念不清'],
          answer: '3',
          explanation: 'lim sin3x/x = 3。',
        ),
      );
      await setCause(
        'q1',
        '概念不清',
        status: CauseStatus.inProgress,
        solvedCount: 1,
        anchorMs: anchor.millisecondsSinceEpoch,
        anchorSession: 'sess-old',
      );
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await paperToCheck(tester, confirm: '已对照，关键答案/步骤符合');
      await tapQm(tester, '下一步：自查');
      // 治愈进度处显示下次可计入治愈的最早时间（锚点 + 24h）。
      expect(find.textContaining('下次可计入治愈的最早时间'), findsOneWidget);
      expect(find.textContaining('「已解决」1 / 2 次'), findsOneWidget);
      await tapQm(tester, '已解决');
      await tapQm(tester, '看总结');
      expect(find.textContaining('今天解决了 1 个错因'), findsOneWidget);
      final r = await causeRow('q1', '概念不清');
      expect(r['solved_count'], 2);
      expect(r['status'], 'solved');
      expect(r['recheck_date'], isNotNull);
    });

    testWidgets('锚点 1 小时前：第二次有效成功不计入（未满 24 小时），不治愈', (tester) async {
      final anchor = DateTime.now().subtract(const Duration(hours: 1));
      await seedQ(
        mkQ(
          'q1',
          '未满 24 小时题',
          errorTypes: ['概念不清'],
          answer: '3',
          explanation: 'lim sin3x/x = 3。',
        ),
      );
      await setCause(
        'q1',
        '概念不清',
        status: CauseStatus.inProgress,
        solvedCount: 1,
        anchorMs: anchor.millisecondsSinceEpoch,
        anchorSession: 'sess-old',
      );
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await paperToCheck(tester, confirm: '已对照，关键答案/步骤符合');
      await tapQm(tester, '下一步：自查');
      expect(find.textContaining('下次可计入治愈的最早时间'), findsOneWidget);
      await tapQm(tester, '已解决');
      await tapQm(tester, '看总结');
      expect(find.textContaining('今天解决了 0 个错因'), findsOneWidget);
      final r = await causeRow('q1', '概念不清');
      expect(r['solved_count'], 1); // 未计入。
      expect(r['status'], 'inProgress');
      // 未计入不刷新锚点。
      expect(r['last_counted_success_at'], anchor.millisecondsSinceEpoch);
    });
  });

  group('#24 小结页', () {
    testWidgets('完成题数/错因数/新治愈/复查/未核验/未判分/跳过与留待/客观汇总/下次复查', (tester) async {
      // q1：单选答对（有答案，客观汇总计答对 1）。
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
      // q2：填空无答案（未判分/无标准答案计 1；自评已解决不勾选外部核对 → 未核验 1）。
      await seedQ(
        mkQ('q2', '无答案填空题', errorTypes: ['计算错误'], questionType: 'fill_blank'),
      );
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      // q1：答对 + 确定 + 证据关联是 + 已解决（第 1 次有效成功，不治愈）。
      await objectiveToCheck(tester, option: 'B', confidence: '确定');
      await tapQm(tester, '下一步：自查');
      await tapQm(tester, '是');
      await tapQm(tester, '已解决');
      await tapQm(tester, '下一题');
      // q2：纸上作答，无答案，选已解决但不勾选外部核对。
      await paperToCheck(tester);
      await tapQm(tester, '下一步：自查');
      await tapQm(tester, '已解决');
      await tapQm(tester, '看总结');
      expect(find.text('本轮复习总结'), findsOneWidget);
      expect(find.textContaining('完成 2 道题'), findsOneWidget);
      expect(find.textContaining('处理 2 个错因'), findsOneWidget);
      expect(find.textContaining('新治愈 0 个错因'), findsOneWidget);
      expect(
        find.textContaining('复查通过 0 个 · 打回 0 个 · 未核验自评 1 个 · 未判分/无标准答案 1 道'),
        findsOneWidget,
      );
      expect(find.textContaining('跳过 0 道 · 留待下次 0 道'), findsOneWidget);
      expect(
        find.textContaining('本次客观作答答对 1 道 / 答错 0 道（仅有答案的题）'),
        findsOneWidget,
      );
      expect(find.textContaining('今天解决了 0 个错因'), findsOneWidget);
    });
  });

  group('#25 “不确定”是中性事件', () {
    testWidgets('选“不确定”：写一条复习事件，不改治疗次数、状态和复查时间，仍是到期状态', (tester) async {
      await seedQ(
        mkQ('q1', '不确定题', errorTypes: ['概念不清'], questionType: 'calculation'),
      );
      await pumpReview(tester);
      await tapQm(tester, '开始复习');
      await paperToCheck(tester);
      await tapQm(tester, '下一步：自查');
      await tapQm(tester, '不确定');
      // 选“不确定”后出现中性事件说明。
      expect(
        find.text('选「不确定」记为一次中性复习事件，不推进治愈、不改治疗状态，下次还要重新练这道题。'),
        findsOneWidget,
      );
      await tapQm(tester, '看总结');
      expect(find.textContaining('今天解决了 0 个错因'), findsOneWidget);
      // 库内：治疗次数、状态、复查时间均未变。
      final r = await causeRow('q1', '概念不清');
      expect(r['solved_count'], 0);
      expect(r['status'], 'pending');
      expect(r['recheck_date'], isNull);
      expect(r['last_counted_success_at'], isNull);
      // review_history 有一条中性事件（verdict=不确定，未核验）。
      final h = await historyRows(causeStableId(
        (await repo.causeRecordsFor('q1')).single,
      ));
      expect(h.length, 1);
      expect(h.single['verdict'], '不确定');
      expect(h.single['verification_status'], '未核验');
      expect(h.single['verification_source'], '未核验');
      expect(h.single['result'], 'unsure');
      // 回到列表：该错因仍是到期状态（仍在待复习池里）。
      await tapQm(tester, '回复习列表');
      expect(find.textContaining('1 道题 / 1 个错因'), findsOneWidget);
      expect(find.text('不确定题'), findsOneWidget);
    });
  });

  group('#22(d) 补充：同会话第二次“已解决”不计入（真实 repo + 真实库）', () {
    test('会话 A 计入 → 同会话 B 第二次真实操作即使超 24h 也不计入', () async {
      await ensureDb();
      final q = mkQ('q1', '重复提交题', errorTypes: ['计算错误']);
      await AppDatabase.upsertQuestionInto(db, q);
      await repo.setReviewJoined(q, true);
      final record = (await repo.causeRecordsFor('q1')).single;
      final t0 = DateTime(2026, 11, 16, 9);
      Future<VerdictSubmitResult> submit({
        required CauseRecord rec,
        required String sessionId,
        required String submissionId,
        required DateTime now,
      }) => repo.submitCauseVerdict(
        questionId: rec.questionId,
        record: rec,
        verdict: '已解决',
        verificationStatus: '已核验',
        verificationSource: '外部资料核对',
        sessionId: sessionId,
        submissionId: submissionId,
        now: now,
      );
      // 会话 A 第一次成功计入（solvedCount 0→1）。
      final a = await submit(
        rec: record,
        sessionId: 'sess-a',
        submissionId: 'sub-a1',
        now: t0,
      );
      expect(a.counted, isTrue);
      expect(a.record.solvedCount, 1);
      // 会话 B 第一次成功未满 24h 不计入。
      final b1 = await submit(
        rec: a.record,
        sessionId: 'sess-b',
        submissionId: 'sub-b1',
        now: t0.add(const Duration(hours: 11)),
      );
      expect(b1.counted, isFalse);
      // 会话 B 第二次真实操作：即使距 A 已 30h 也不计入（(d) 同会话重复检查）。
      final b2 = await submit(
        rec: b1.record,
        sessionId: 'sess-b',
        submissionId: 'sub-b2',
        now: t0.add(const Duration(hours: 30)),
      );
      expect(b2.counted, isFalse);
      expect(b2.record.solvedCount, 1);
      expect(b2.record.lastCountedSuccessAt, t0.millisecondsSinceEpoch);
      // UI 侧无法触发第二次提交：同一会话内 verdict 提交后即锁定，
      // 上述 (d) 规则由本补充测试在真实提交事务上验证。
    });
  });
}
