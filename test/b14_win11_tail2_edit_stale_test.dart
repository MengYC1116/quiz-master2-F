// Win11 反馈尾巴 2：详情页编辑态竞态——保存时底稿过期要弹提示让用户选。
// 底稿（editBase）是进编辑时记的旧快照；表单开着时底下内容变了
// （自动重算改了题型、取消识别清了 OCR），保存仍按旧底稿写回会把新
// 内容顶掉。修法（Meng 2026-11-20 13:50 定：弹提示让我选）：保存前
// 重读库里行比 contentVersion，过期不直接保存、弹确认框；用户选
// “保留我的编辑”才按旧底稿强制保存，选“用新内容”则丢弃表单编辑、
// 重新加载新内容。题型归属：保留时按表单原有的走，用新内容时按新行走。
// 整理页无同类问题：OrganizeNotifier.saveCurrent 已有代次守门 +
// SaveToken，过期保存直接失败并刷新，不会静默覆盖（见本文件末尾注释）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';

Question _tq(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> folderIds = const [],
  String? answer,
  String? explanation,
  String? ocrRaw,
  String? ocrStem,
  String ocrSplitStatus = OcrSplitStatus.unsegmented,
  String? questionType,
  String questionTypeSource = 'unclassified',
  int contentVersion = 0,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  folderIds: folderIds,
  examId: null,
  knowledgePointIds: const [],
  errorTypes: const [],
  customErrorTypes: const [],
  tags: const [],
  answer: answer,
  explanation: explanation,
  notes: null,
  createdAt: DateTime(2026, 11, 8),
  isOrganized: true,
  isArchived: false,
  isFavorite: false,
  reviewJoined: false,
  sliceKind: 'limit',
  sliceText: '题：$title',
  ocrRaw: ocrRaw,
  ocrStem: ocrStem,
  ocrSplitStatus: ocrSplitStatus,
  ocrManualEdited: false,
  contentVersion: contentVersion,
  questionType: questionType,
  questionTypeSource: questionTypeSource,
);

/// 详情 notifier 单测用的假 repo（只覆盖 load / enterEdit / saveEdit
/// 走到的口径；save 按真实令牌语义校验版本，不符抛 SaveTokenMismatch）。
class _Tail2Repo extends QuestionRepository {
  _Tail2Repo({required List<Question> questions})
    : questions = List.of(questions),
      super(AppDatabase.instance);

  List<Question> questions;
  final List<Question> saved = [];
  SaveToken? lastToken;

  /// 置真时 save 一律抛 SaveTokenMismatch（模拟“预检通过后、落库前
  /// 底下又变了一次”，验证 saveEdit 的令牌兜底分支）。
  bool saveShouldThrowTokenMismatch = false;

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async => [];

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
  ];

  @override
  Future<List<Exam>> exams() async => [];

  @override
  Future<List<String>> tags() async => [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => [];

  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async => [];

  @override
  Future<bool> hasOcrApiKey() async => false;

  @override
  Future<void> recordQuestionViewed(String questionId) async {}

  @override
  Future<void> save(Question question, {SaveToken? token}) async {
    lastToken = token;
    if (saveShouldThrowTokenMismatch) {
      throw SaveTokenMismatch(
        question.id,
        token?.expectedContentVersion ?? -1,
        questions
            .where((x) => x.id == question.id)
            .firstOrNull
            ?.contentVersion,
      );
    }
    if (token != null) {
      final stored = questions
          .where((x) => x.id == question.id)
          .firstOrNull;
      if (stored == null ||
          stored.contentVersion != token.expectedContentVersion) {
        throw SaveTokenMismatch(
          token.questionId,
          token.expectedContentVersion,
          stored?.contentVersion,
        );
      }
    }
    saved.add(question);
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
  }

  /// 详情页自愈（_healSliceIfNeeded）读同页框：无框，不碰真实库（见 D-88）。
  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      const [];
}

ProviderContainer _container(
  _Tail2Repo repo, {
  String questionId = 'q1',
  List<String> orderIds = const ['q1'],
}) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      detailInitialProvider.overrideWithValue(
        DetailInitial(questionId: questionId, orderIds: orderIds),
      ),
    ],
  );
  addTearDown(container.dispose);
  // autoDispose 保活（D-36）：像页面 ref.watch 那样持一个监听。
  container.listen(detailProvider, (_, __) {});
  return container;
}

DetailNotifier _notifier(ProviderContainer container) =>
    container.read(detailProvider.notifier);

Future<SaveEditOutcome> _save(
  DetailNotifier notifier, {
  String title = '函数极限',
  String answer = '',
  String explanation = '',
  String notes = '',
  bool force = false,
}) => notifier.saveEdit(
  title: title,
  answer: answer,
  explanation: explanation,
  notes: notes,
  force: force,
);

void main() {
  group('saveEdit 底稿过期检测（notifier）', () {
    test('未过期：保存成功，带令牌写库', () async {
      final repo = _Tail2Repo(
        questions: [_tq('q1', '函数极限', answer: '1')],
      );
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      final outcome = await _save(notifier, title: '函数极限（改）');
      expect(outcome, SaveEditOutcome.saved);
      expect(repo.saved.last.title, '函数极限（改）');
      // 非强制保存带版本令牌（期望版本 = 进编辑时看到的版本）。
      expect(repo.lastToken, isNotNull);
      expect(repo.lastToken!.expectedContentVersion, 0);
    });

    test('重算触发过期：保存返回 stale，不写库、不清新内容', () async {
      final repo = _Tail2Repo(
        questions: [_tq('q1', '函数极限', answer: '1')],
      );
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      // 模拟自动重算已完成：行题型变了、版本 +1。
      final reclassified = repo.questions.single.copyWith(
        questionType: 'choice_single',
        questionTypeSource: 'auto',
        contentVersion: 1,
      );
      await repo.save(reclassified);
      final savedBefore = repo.saved.length;
      final outcome = await _save(notifier, title: '函数极限（改）');
      expect(outcome, SaveEditOutcome.stale);
      expect(repo.saved.length, savedBefore);
      // 库里仍是重算后的新行，没被旧底稿顶掉。
      final row = await repo.questionById('q1');
      expect(row?.questionType, 'choice_single');
      expect(row?.title, '函数极限');
    });

    test('取消触发过期：保存返回 stale，已清的 OCR 不复活', () async {
      final repo = _Tail2Repo(
        questions: [
          _tq(
            'q1',
            '函数极限',
            ocrRaw: 'raw',
            ocrStem: '旧题干',
            ocrSplitStatus: OcrSplitStatus.autoSegmented,
          ),
        ],
      );
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      // 模拟取消识别已完成：OCR 字段清掉、版本 +1。
      final cancelled = repo.questions.single.copyWith(
        clearOcrRaw: true,
        clearOcrStem: true,
        ocrSplitStatus: OcrSplitStatus.unsegmented,
        contentVersion: 1,
      );
      await repo.save(cancelled);
      final outcome = await _save(notifier, title: '函数极限（改）');
      expect(outcome, SaveEditOutcome.stale);
      final row = await repo.questionById('q1');
      expect(row?.ocrStem, isNull);
      expect(row?.ocrRaw, isNull);
    });

    test('过期后强制保存：按旧底稿写回，是用户明确的选择', () async {
      final repo = _Tail2Repo(
        questions: [
          _tq(
            'q1',
            '函数极限',
            ocrRaw: 'raw',
            ocrStem: '旧题干',
            ocrSplitStatus: OcrSplitStatus.autoSegmented,
          ),
        ],
      );
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      final cancelled = repo.questions.single.copyWith(
        clearOcrRaw: true,
        clearOcrStem: true,
        ocrSplitStatus: OcrSplitStatus.unsegmented,
        contentVersion: 1,
      );
      await repo.save(cancelled);
      expect(await _save(notifier, title: '函数极限（改）'), SaveEditOutcome.stale);
      // 强制保存不带令牌（明确覆盖），旧题干按用户选择写回。
      final outcome = await _save(
        notifier,
        title: '函数极限（改）',
        force: true,
      );
      expect(outcome, SaveEditOutcome.saved);
      expect(repo.lastToken, isNull);
      final row = await repo.questionById('q1');
      expect(row?.title, '函数极限（改）');
      expect(row?.ocrStem, '旧题干');
    });

    test('过期后强制保存：表单改过题型时归属按表单走（manual）', () async {
      final repo = _Tail2Repo(
        questions: [_tq('q1', '函数极限')],
      );
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      notifier.setEditQuestionType('choice_single');
      final reclassified = repo.questions.single.copyWith(
        questionType: 'choice_single',
        questionTypeSource: 'auto',
        contentVersion: 1,
      );
      await repo.save(reclassified);
      expect(await _save(notifier), SaveEditOutcome.stale);
      expect(
        await _save(notifier, force: true),
        SaveEditOutcome.saved,
      );
      final row = await repo.questionById('q1');
      expect(row?.questionType, 'choice_single');
      expect(row?.questionTypeSource, 'manual');
    });

    test('题已删：保存返回 noQuestion，不写库', () async {
      final repo = _Tail2Repo(
        questions: [_tq('q1', '函数极限')],
      );
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      repo.questions.removeWhere((q) => q.id == 'q1');
      final outcome = await _save(notifier);
      expect(outcome, SaveEditOutcome.noQuestion);
      expect(repo.saved, isEmpty);
    });

    test('无 editBase：保存返回 noBase，不写库', () async {
      final repo = _Tail2Repo(
        questions: [_tq('q1', '函数极限')],
      );
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      final outcome = await _save(notifier);
      expect(outcome, SaveEditOutcome.noBase);
      expect(repo.saved, isEmpty);
    });

    test('令牌第二道防线：预检通过后版本又变了，保存仍被令牌拦下', () async {
      final repo = _Tail2Repo(
        questions: [_tq('q1', '函数极限')],
      );
      final container = _container(repo);
      final notifier = _notifier(container);
      await notifier.load();
      notifier.enterEdit();
      // 预检读到的仍是旧行（版本 0，一致）；落库时令牌校验发现
      // 底下已变 → saveEdit 应把 SaveTokenMismatch 转成 stale，
      // 而不是抛错或写库。
      repo.saveShouldThrowTokenMismatch = true;
      final outcome = await _save(notifier, title: '函数极限（改）');
      expect(outcome, SaveEditOutcome.stale);
      expect(repo.saved, isEmpty);
      final row = await repo.questionById('q1');
      expect(row?.title, '函数极限');
    });
  });

  group('详情页保存过期提示（widget）', () {
    testWidgets('未过期：保存不弹框，直接落库退出编辑', (tester) async {
      final repo = _PageRepo(
        questions: [
          _tq(
            'q1',
            '函数极限',
            folderIds: const ['f1'],
            answer: '1',
            explanation: 'lim(x→0) sin3x/x = 3。',
          ),
        ],
      );
      await _pumpDetail(tester, repo: repo);
      await _tapText(tester, '编辑');
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      await _tapText(tester, '保存', first: true);
      expect(find.text('内容已更新'), findsNothing);
      // 十九批 C：旧拼串标题「学科 · 题型｜题名」已随 D1 板子去掉，
      // 保存后标题行只显示题名本身。
      expect(find.text('函数极限改'), findsOneWidget);
      expect(repo.saved.last.title, '函数极限改');
      expect(find.text('编辑'), findsOneWidget);
    });

    testWidgets('重算触发过期：选保留我的编辑，旧底稿按选择写回', (tester) async {
      final repo = _PageRepo(
        questions: [
          _tq('q1', '函数极限', folderIds: const ['f1'], answer: '1'),
        ],
      );
      await _pumpDetail(tester, repo: repo);
      await _tapText(tester, '编辑');
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      // 模拟自动重算已完成：题型定了、版本 +1（页面不刷新也无妨，
      // 保存时重读库里行即能发现过期）。
      repo.questions[0] = repo.questions[0].copyWith(
        questionType: 'choice_single',
        questionTypeSource: 'auto',
        contentVersion: 1,
      );
      await _tapText(tester, '保存', first: true);
      expect(find.text('内容已更新'), findsOneWidget);
      expect(find.text('保留我的编辑'), findsOneWidget);
      expect(find.text('用新内容'), findsOneWidget);
      await _tapText(tester, '保留我的编辑');
      // 十九批 C：旧拼串标题「学科 · 题型｜题名」已随 D1 板子去掉。
      expect(find.text('函数极限改'), findsOneWidget);
      // 旧底稿写回：标题是表单改的，题型是旧底稿的（未定型）。
      expect(repo.saved.last.title, '函数极限改');
      expect(repo.saved.last.questionType, isNull);
      expect(find.text('编辑'), findsOneWidget);
    });

    testWidgets('重算触发过期：选用新内容，丢弃编辑、重进保存不再弹框', (tester) async {
      final repo = _PageRepo(
        questions: [
          _tq('q1', '函数极限', folderIds: const ['f1'], answer: '1'),
        ],
      );
      await _pumpDetail(tester, repo: repo);
      await _tapText(tester, '编辑');
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      repo.questions[0] = repo.questions[0].copyWith(
        questionType: 'choice_single',
        questionTypeSource: 'auto',
        contentVersion: 1,
      );
      await _tapText(tester, '保存', first: true);
      expect(find.text('内容已更新'), findsOneWidget);
      await _tapText(tester, '用新内容');
      // 退出编辑、什么都没保存，页面仍显示旧标题（重算没改标题）。
      // 十九批 C：旧拼串标题「学科 · 题型｜题名」已随 D1 板子去掉。
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('函数极限'), findsOneWidget);
      expect(repo.saved, isEmpty);
      // 再进编辑：底稿已是新行（版本 1），直接保存不再弹框。
      await _tapText(tester, '编辑');
      await _tapText(tester, '保存', first: true);
      expect(find.text('内容已更新'), findsNothing);
      expect(find.text('编辑'), findsOneWidget);
    });

    testWidgets('取消触发过期：选保留我的编辑，旧 OCR 按选择写回', (tester) async {
      final repo = _PageRepo(
        questions: [
          _tq(
            'q1',
            '函数极限',
            folderIds: const ['f1'],
            answer: '1',
            ocrRaw: 'raw',
            ocrStem: '旧题干',
            ocrSplitStatus: OcrSplitStatus.autoSegmented,
          ),
        ],
      );
      await _pumpDetail(tester, repo: repo);
      await _tapText(tester, '编辑');
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      // 模拟取消识别已完成：OCR 字段清掉、版本 +1。
      repo.questions[0] = repo.questions[0].copyWith(
        clearOcrRaw: true,
        clearOcrStem: true,
        ocrSplitStatus: OcrSplitStatus.unsegmented,
        contentVersion: 1,
      );
      await _tapText(tester, '保存', first: true);
      expect(find.text('内容已更新'), findsOneWidget);
      await _tapText(tester, '保留我的编辑');
      expect(repo.saved.last.title, '函数极限改');
      // 用户明确选了保留：旧题干按选择写回（不是静默复活）。
      expect(repo.saved.last.ocrStem, '旧题干');
      expect(find.text('编辑'), findsOneWidget);
    });

    testWidgets('取消触发过期：选用新内容，不保存、已清的 OCR 不复活', (tester) async {
      final repo = _PageRepo(
        questions: [
          _tq(
            'q1',
            '函数极限',
            folderIds: const ['f1'],
            answer: '1',
            ocrRaw: 'raw',
            ocrStem: '旧题干',
            ocrSplitStatus: OcrSplitStatus.autoSegmented,
          ),
        ],
      );
      await _pumpDetail(tester, repo: repo);
      await _tapText(tester, '编辑');
      await tester.enterText(find.byType(TextField).first, '函数极限改');
      repo.questions[0] = repo.questions[0].copyWith(
        clearOcrRaw: true,
        clearOcrStem: true,
        ocrSplitStatus: OcrSplitStatus.unsegmented,
        contentVersion: 1,
      );
      await _tapText(tester, '保存', first: true);
      expect(find.text('内容已更新'), findsOneWidget);
      await _tapText(tester, '用新内容');
      expect(find.text('编辑'), findsOneWidget);
      expect(repo.saved, isEmpty);
      final row = await repo.questionById('q1');
      expect(row?.ocrStem, isNull);
      expect(row?.ocrRaw, isNull);
    });
  });
}

// ---------- widget 测试用的页面假 repo 与 pump 脚手架 ----------
// 与 test/detail_page_test.dart 同款口径（FakeRepo + pumpAndSettle；
// 假 repo 不碰真实库，load() 的 OCR 状态刷新是 best-effort 不 await）。

class _PageRepo extends QuestionRepository {
  _PageRepo({required List<Question> questions})
    : questions = List.of(questions),
      super(AppDatabase.instance);

  List<Question> questions;
  final List<Question> saved = [];
  final List<String> deletedIds = [];

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async => [];

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [
    Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
  ];

  @override
  Future<List<Exam>> exams() async => [
    Exam(id: 'e1', name: '高等数学期末试卷', date: DateTime(2026, 11, 10)),
  ];

  @override
  Future<List<String>> tags() async => [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [
    KnowledgePoint(
      id: 'k1',
      subjectId: 'math',
      chapter: '第一章 函数与极限',
      name: '函数极限',
    ),
  ];

  @override
  Future<void> save(Question question, {SaveToken? token}) async {
    saved.add(question);
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
  }

  @override
  Future<void> recordQuestionViewed(String questionId) async {}

  @override
  Future<void> toggleFavorite(Question q) async {
    await save(q.copyWith(isFavorite: !q.isFavorite));
  }

  @override
  Future<void> archive(Question q, {bool archived = true}) async {
    await save(q.copyWith(isArchived: archived));
  }

  @override
  Future<void> delete(Question question) async {
    deletedIds.add(question.id);
    questions.removeWhere((x) => x.id == question.id);
  }

  @override
  // FSRS 全量迁移包2：无错因的题也可翻标志（旧空错因守门已删）。
  Future<bool> setReviewJoinedFlag(Question q, bool joined) async {
    await save(q.copyWith(reviewJoined: joined));
    return true;
  }

  @override
  Future<void> addTag(String name) async {}

  @override
  Future<void> saveFolder(Folder folder) async {}

  @override
  Future<bool> folderNameExistsInSubject(
    String subjectId,
    String name, {
    String? excludeId,
  }) async => false;

  @override
  Future<void> addKnowledgePoint(KnowledgePoint kp) async {}

  @override
  Future<void> addExam(Exam e) async {}

  /// 十三批 M5：OCR 状态是 best-effort 加载（不 await）；返回空任务行
  /// 与“无 key”，不碰真实库（见 D-88）。
  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;

  /// 详情页自愈（_healSliceIfNeeded）读同页框：无框，不碰真实库（见 D-88）。
  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      const [];
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  required _PageRepo repo,
  String questionId = 'q1',
  List<String> orderIds = const ['q1'],
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: QuestionDetailPage(
          key: UniqueKey(),
          repo: repo,
          questionId: questionId,
          orderIds: orderIds,
          sourceLabel: '错题本',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 点按前先滚到可见（详情页整页滚动，底部操作行常在 720 高视口外）。
Future<void> _tapText(
  WidgetTester tester,
  String text, {
  bool first = false,
}) async {
  final finder = first ? find.text(text).first : find.text(text);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

// 整理页无同类问题（OrganizeNotifier.saveCurrent）：保存前重读全表 +
// 代次守门（_gateOk）+ SaveToken（期望版本取自表单加载时的模型）；
// 过期保存抛 SaveTokenMismatch → 刷新队列与表单、返回 false，由用户
// 重新保存——旧表单值永远写不回库，不会静默覆盖新内容。因此本尾巴
// 只修详情页；整理页的令牌路径由既有测试覆盖（见 organize_notifier_test
// 的 stale/令牌用例），本次不另加整理页测试。
