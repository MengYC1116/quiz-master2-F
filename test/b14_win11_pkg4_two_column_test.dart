// Win11 反馈包 4：双栏切分与自动分类。
// TDD：先写失败测试，再写实现。
// 1. 切分器：空行分隔的双栏选项（图九 f(x)=sin x+3x 形态）跨段组装；
//    跨段须两侧标记均为显式格式（裸字母不得借空行拼成选项）；
//    HTML 两列表格的第二列标记也参与序列。
// 2. 分类器：图九文本定型为单项选择。
// 3. reclassifiedQuestion（纯函数）：manual / 无原文 / 结果一致时
//    不写库；否则返回新题（题型 + 来源 + 版本+1，manual 标签不动）。
// 4. 两 Notifier 的 reclassifyCurrent：自动（版本守门）+ 强制
//    （“重新分类”按钮）；入口自动重算；OCR 完成刷新时表单题型同步。
// 5. 整理页 / 详情页题型区：切分诊断小字 + “重新分类”按钮。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/detail/question_detail_page.dart';
import 'package:quiz_master2/modules/ocr/question_classifier.dart';
import 'package:quiz_master2/modules/organize/organize_page.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/services/stem_splitter.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/uikit.dart';

// ---------------------------------------------------------------------------
// 图九形态：双栏选项 A、B 同行，空行，C、D 同行
// ---------------------------------------------------------------------------

/// 图九原文形态（DOT 格式，空行分隔两行）。
const fxText =
    '已知函数 f(x)=sin x+3x，则该函数是\nA. 偶函数 B. 奇函数\n\nC. 非奇非偶函数 D. 既是奇函数又是偶函数';

/// 图九原文形态（题干含 $...$ 公式）。
const fxTextFormula =
    r'已知函数 $ f(x)=\sin x+3x $，则该函数是'
    '\nA. 偶函数 B. 奇函数\n\nC. 非奇非偶函数 D. 既是奇函数又是偶函数';

/// 图九原文形态（顿号格式，空行分隔两行）。
const fxTextDun =
    '已知函数 f(x)=sin x+3x，则该函数是\nA、偶函数 B、奇函数\n\nC、非奇非偶函数 D、既是奇函数又是偶函数';

/// 混合格式跨段：A、B 为 dot，C、D 为括号式。
const fxTextMixed =
    '已知函数 f(x)=sin x+3x，则该函数是\nA. 偶函数 B. 奇函数\n\n(C) 非奇非偶函数 (D) 既是奇函数又是偶函数';

/// HTML 两列表格形态。
const fxTextHtmlTable =
    '已知函数 f(x)=sin x+3x，则该函数是\n<table><tr><td>A. 偶函数</td><td>B. 奇函数</td></tr><tr><td>C. 非奇非偶函数</td><td>D. 既是奇函数又是偶函数</td></tr></table>';

/// HTML 单列表格形态（已支持，回归用）。
const fxTextHtmlTableSingleCol =
    '已知函数 f(x)=sin x+3x，则该函数是\n<table><tr><td>A. 偶函数</td></tr><tr><td>B. 奇函数</td></tr><tr><td>C. 非奇非偶函数</td></tr><tr><td>D. 既是奇函数又是偶函数</td></tr></table>';

/// 守门形态：题干里的裸字母 A、B + 空行 + 只有 C、D 的选项。
/// 裸字母是题干引用（“设 A 为集合”），不得借空行拼成选项。
const guardText = '设 A 为集合，B 为子集，求 A∩B 的元素个数。\n\nC. {1} D. {2}';

/// 无选项标记、无分类信号的文本（切分诊断显示用）。
const noSignalText = '请默写出《静夜思》全文。';

String _raw(String md) => GlmOcrRawData(mdResults: md).toJsonString();

Question _q(
  String id,
  String title, {
  String subjectId = 'math',
  String? questionType,
  String questionTypeSource = 'unclassified',
  String questionBackgroundTags = '',
  String questionBackgroundTagsSource = 'unclassified',
  String? ocrRaw,
  int contentVersion = 3,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  questionType: questionType,
  questionTypeSource: questionTypeSource,
  questionBackgroundTags: questionBackgroundTags,
  questionBackgroundTagsSource: questionBackgroundTagsSource,
  ocrRaw: ocrRaw,
  contentVersion: contentVersion,
  createdAt: DateTime(2026, 11, 8),
  sliceKind: 'limit',
  sliceText: '题：$title',
);

/// f(x) 选项段（材料题用例复用）。
const fXTextTail = 'A. 偶函数 B. 奇函数\n\nC. 非奇非偶函数 D. 既是奇函数又是偶函数';

// ---------------------------------------------------------------------------
// Notifier 测试夹具（内存假库，不碰真实数据库）
// ---------------------------------------------------------------------------

class _P4OrgRepo extends QuestionRepository {
  _P4OrgRepo({required this.questions, this.folderList = const []})
    : super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;
  final List<Question> saved = [];
  final Set<String> failSaveIds = {};

  @override
  Future<List<Subject>> subjects() async => List.of(Subject.all);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => subjectId == null
      ? List.of(folderList)
      : folderList.where((f) => f.subjectId == subjectId).toList();

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<void> save(Question question, {SaveToken? token}) async {
    if (failSaveIds.contains(question.id)) {
      throw StateError('模拟写库失败');
    }
    saved.add(question);
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
  }

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((x) => x.id == id).firstOrNull;

  @override
  Future<void> syncCauseRecords(Question question) async {}

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {}

  @override
  Future<int> organizedTodayCount({DateTime? now}) async => 0;

  @override
  Future<List<Question>> dueToday({bool includeArchived = false}) async =>
      const [];

  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async => const [];

  @override
  Future<bool> hasOcrApiKey() async => false;
}

class _P4DetailRepo extends QuestionRepository {
  _P4DetailRepo({required this.questions}) : super(AppDatabase.instance);

  List<Question> questions;
  final List<Question> saved = [];
  final Set<String> failSaveIds = {};

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((x) => x.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async =>
      const [];

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<Subject>> subjects() async => List.of(Subject.all);

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<void> recordQuestionViewed(String questionId) async {}

  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async => const [];

  @override
  Future<bool> hasOcrApiKey() async => false;

  @override
  Future<void> save(Question question, {SaveToken? token}) async {
    if (failSaveIds.contains(question.id)) {
      throw StateError('模拟写库失败');
    }
    saved.add(question);
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
  }

  @override
  Future<void> syncCauseRecords(Question question) async {}

  /// 详情页自愈（_healSliceIfNeeded）读同页框：无框，不碰真实库（见 D-88）。
  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      const [];
}

ProviderContainer _orgContainer(_P4OrgRepo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  container.listen(organizeProvider, (_, __) {});
  return container;
}

ProviderContainer _detailContainer(_P4DetailRepo repo, {String questionId = 'q1'}) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      detailInitialProvider.overrideWithValue(
        DetailInitial(
          questionId: questionId,
          orderIds: repo.questions.map((q) => q.id).toList(),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(detailProvider, (_, __) {});
  return container;
}

/// 让 unawaited 的后台任务（入口自动重算）跑完。
Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

void main() {
  group('切分器：空行分隔的双栏选项（图九形态）', () {
    test('图九 dot 格式：A、B 一行，空行，C、D 一行 → 自动切分', () {
      final r = splitStem(fxText);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '已知函数 f(x)=sin x+3x，则该函数是');
      expect(r.cutIndex, isNotNull);
      expect(fxText.substring(r.cutIndex!), startsWith('A.'));
      expect(r.optionLabels, ['A', 'B', 'C', 'D']);
      expect(r.reason, isNotEmpty);
    });

    test(r'图九公式版：题干含 $...$ 公式，空行分隔 → 自动切分', () {
      final r = splitStem(fxTextFormula);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(
        r.stemText,
        r'已知函数 $ f(x)=\sin x+3x $，则该函数是',
      );
      expect(r.optionLabels, ['A', 'B', 'C', 'D']);
    });

    test('图九顿号格式：空行分隔 → 自动切分', () {
      final r = splitStem(fxTextDun);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '已知函数 f(x)=sin x+3x，则该函数是');
      expect(r.optionLabels, ['A', 'B', 'C', 'D']);
    });

    test('混合格式跨段：A、B 为 dot，C、D 为括号式 → 自动切分', () {
      final r = splitStem(fxTextMixed);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.optionLabels, ['A', 'B', 'C', 'D']);
    });

    test('A 单独一行，空行，B、C、D 在下一段 → 自动切分', () {
      const input =
          '已知函数 f(x)=sin x+3x，则该函数是\nA. 偶函数\n\nB. 奇函数\nC. 非奇非偶函数\nD. 既是奇函数又是偶函数';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.optionLabels, ['A', 'B', 'C', 'D']);
    });

    test('两项跨段：A、B 各占一段且均为行首强标记 → 自动切分', () {
      const input = '下列正确的是\nA. 第一项\n\nB. 第二项';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '下列正确的是');
      expect(r.optionLabels, ['A', 'B']);
    });

    test('守门：题干裸字母 A、B + 空行 + 只有 C、D → 不切分', () {
      final r = splitStem(guardText);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.cutIndex, isNull);
      expect(r.stemText, guardText);
      expect(r.reason, contains('裸字母'));
    });

    test('守门：A、B 句子相隔数段（中间有实质文字）→ 仍不切分', () {
      const input = '第一段。\n\nA. student who studies hard will succeed.\n\n'
          '第二段很长很长，讲了很多别的内容。\n\n'
          'B. teacher who works hard will be respected.';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.notSplit);
      expect(r.stemText, input);
    });
  });

  group('切分器：表格 / div 容器边界', () {
    test('HTML 两列表格：A、B 同行，C、D 同行 → 自动切分', () {
      final r = splitStem(fxTextHtmlTable);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.stemText, '已知函数 f(x)=sin x+3x，则该函数是');
      expect(r.optionLabels, ['A', 'B', 'C', 'D']);
    });

    test('HTML 单列表格：四行各一选项 → 自动切分（回归）', () {
      final r = splitStem(fxTextHtmlTableSingleCol);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.optionLabels, ['A', 'B', 'C', 'D']);
    });

    test('HTML 两列表格：首列单字母格 + 内容列（| A | 内容 | 形）→ 切分', () {
      const input =
          '下列正确的是\n<table><tr><td>A</td><td>第一项</td></tr><tr><td>B</td><td>第二项</td></tr></table>';
      final r = splitStem(input);
      expect(r.status, StemSplitStatus.autoSplit);
      expect(r.optionLabels, ['A', 'B']);
    });
  });

  group('分类器：图九文本', () {
    test('图九 dot 双栏文本 → 单项选择', () {
      final c = classifyQuestionText(fxText);
      expect(c.questionType, 'choice_single');
      expect(c.questionTypeSource, 'auto');
    });

    test('图九顿号双栏文本 → 单项选择', () {
      final c = classifyQuestionText(fxTextDun);
      expect(c.questionType, 'choice_single');
    });

    test('图九 HTML 两列表格文本 → 单项选择', () {
      final c = classifyQuestionText(fxTextHtmlTable);
      expect(c.questionType, 'choice_single');
    });
  });

  group('reclassifiedQuestion（纯函数）', () {
    test('图九题：待确认 + 未分类来源 → 返回新题（单选 + auto + 版本+1）', () {
      final q = _q('q1', '图九题', ocrRaw: _raw(fxText));
      final updated = reclassifiedQuestion(q);
      expect(updated, isNotNull);
      expect(updated!.questionType, 'choice_single');
      expect(updated.questionTypeSource, 'auto');
      expect(updated.contentVersion, q.contentVersion + 1);
      expect(updated.id, q.id);
    });

    test('manual 来源 → null（永不覆盖人工指定）', () {
      final q = _q(
        'q1',
        '图九题',
        questionType: 'fill_blank',
        questionTypeSource: 'manual',
        ocrRaw: _raw(fxText),
      );
      expect(reclassifiedQuestion(q), isNull);
    });

    test('无 OCR 原文 → null', () {
      final q = _q('q1', '无原文题');
      expect(reclassifiedQuestion(q), isNull);
    });

    test('重算结果与库里一致 → null（不写库，防循环）', () {
      final q = _q(
        'q1',
        '图九题',
        questionType: 'choice_single',
        questionTypeSource: 'auto',
        ocrRaw: _raw(fxText),
      );
      expect(reclassifiedQuestion(q), isNull);
    });

    test('重算结果与库里不一致 → 返回新题（题型变化 + 版本+1）', () {
      final q = _q(
        'q1',
        '图九题',
        questionType: 'fill_blank',
        questionTypeSource: 'auto',
        ocrRaw: _raw(fxText),
      );
      final updated = reclassifiedQuestion(q);
      expect(updated, isNotNull);
      expect(updated!.questionType, 'choice_single');
      expect(updated.questionTypeSource, 'auto');
      expect(updated.contentVersion, q.contentVersion + 1);
    });

    test('背景标签 manual 时只改题型、不动标签', () {
      final q = _q(
        'q1',
        '材料题',
        questionType: 'fill_blank',
        questionTypeSource: 'auto',
        questionBackgroundTags: '案例',
        questionBackgroundTagsSource: 'manual',
        ocrRaw: _raw('阅读下列材料，回答问题。\n\n$fXTextTail'),
      );
      final updated = reclassifiedQuestion(q);
      expect(updated, isNotNull);
      expect(updated!.questionType, 'choice_single');
      expect(updated.questionBackgroundTags, '案例');
      expect(updated.questionBackgroundTagsSource, 'manual');
    });
  });

  group('OrganizeNotifier.reclassifyCurrent', () {
    test('自动重算：图九待确认题 → updated，行与表单同步', () async {
      final repo = _P4OrgRepo(
        questions: [_q('q1', '图九题', ocrRaw: _raw(fxText))],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      await _settle();
      // 入口自动重算已把图九题定型（refresh 后 unawaited 任务跑完）。
      expect(container.read(organizeProvider).questionType, 'choice_single');
      expect(
        repo.questions.first.questionType,
        'choice_single',
      );
      expect(repo.saved.any((x) => x.id == 'q1'), isTrue);
    });

    test('自动重算：同一输入版本只算一次（第二次 already_attempted）', () async {
      // 用无信号文本：入口自动重算算过一次得 unchanged（仍待确认），
      // 键已记；再调自动重算应被守门拦住，且全程不写库。
      final repo = _P4OrgRepo(
        questions: [_q('q1', '默写题', ocrRaw: _raw(noSignalText))],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      await _settle();
      expect(container.read(organizeProvider).questionType, isNull);
      expect(await notifier.reclassifyCurrent(), 'already_attempted');
      expect(repo.saved, isEmpty);
    });

    test('自动重算：题型已定 → already_typed，不写库', () async {
      final repo = _P4OrgRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'fill_blank',
            questionTypeSource: 'auto',
            ocrRaw: _raw(fxText),
          ),
        ],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(await notifier.reclassifyCurrent(), 'already_typed');
      expect(repo.saved, isEmpty);
    });

    test('自动重算：manual 题型 → manual，不写库', () async {
      final repo = _P4OrgRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'fill_blank',
            questionTypeSource: 'manual',
            ocrRaw: _raw(fxText),
          ),
        ],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(await notifier.reclassifyCurrent(), 'manual');
      expect(repo.saved, isEmpty);
    });

    test('自动重算：无 OCR 原文 → no_raw，不写库', () async {
      final repo = _P4OrgRepo(
        questions: [_q('q1', '无原文题')],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(await notifier.reclassifyCurrent(), 'no_raw');
      expect(repo.saved, isEmpty);
    });

    test('自动重算：已定型且重算结果一致 → already_typed，不写库', () async {
      final repo = _P4OrgRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'choice_single',
            questionTypeSource: 'auto',
            ocrRaw: _raw(fxText),
          ),
        ],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      // 注意：入口自动重算对“已定型”的题不触发；直接调也应为 already_typed。
      expect(await notifier.reclassifyCurrent(), 'already_typed');
      expect(repo.saved, isEmpty);
    });

    test('强制重算（重新分类）：已定型但结果变了 → updated', () async {
      final repo = _P4OrgRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'fill_blank',
            questionTypeSource: 'auto',
            ocrRaw: _raw(fxText),
          ),
        ],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(await notifier.reclassifyCurrent(force: true), 'updated');
      expect(container.read(organizeProvider).questionType, 'choice_single');
      expect(repo.questions.first.questionType, 'choice_single');
      expect(repo.questions.first.contentVersion, 4);
    });

    test('强制重算：manual 题型 → manual，不写库', () async {
      final repo = _P4OrgRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'fill_blank',
            questionTypeSource: 'manual',
            ocrRaw: _raw(fxText),
          ),
        ],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(await notifier.reclassifyCurrent(force: true), 'manual');
      expect(repo.saved, isEmpty);
    });

    test('强制重算：写库失败 → save_failed', () async {
      final repo = _P4OrgRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'fill_blank',
            questionTypeSource: 'auto',
            ocrRaw: _raw(fxText),
          ),
        ],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      )..failSaveIds.add('q1');
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(await notifier.reclassifyCurrent(force: true), 'save_failed');
      expect(container.read(organizeProvider).questionType, 'fill_blank');
    });

    test('切题入口：goTo 到图九题 → 自动重算定型', () async {
      final repo = _P4OrgRepo(
        questions: [
          _q('q1', '无原文题'),
          _q('q2', '图九题', ocrRaw: _raw(fxText)),
        ],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      await notifier.goTo(1);
      await _settle();
      expect(container.read(organizeProvider).questionType, 'choice_single');
      expect(repo.questions[1].questionType, 'choice_single');
    });
  });

  group('OrganizeNotifier.refreshOcrForQuestion（任务 5：OCR 完成刷新）', () {
    test('当前题 OCR 完成：行换新 + 表单题型同步（用户没改过表单）', () async {
      // 刷新时本题还没有 OCR 原文（入口重算得 no_raw，表单待确认）；
      // 之后 OCR 完成写回：库里行已带原文且已定型。refreshOcrForQuestion
      // 应换行，并把表单题型从旧行的 null 同步到新行的单选。
      final repo = _P4OrgRepo(
        questions: [_q('q1', '图九题')],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      await _settle();
      expect(container.read(organizeProvider).questionType, isNull);
      // 模拟 OCR 写回：库里行已带原文且已定型（版本+1），内存仍是旧行。
      repo.questions[0] = _q(
        'q1',
        '图九题',
        questionType: 'choice_single',
        questionTypeSource: 'auto',
        ocrRaw: _raw(fxText),
        contentVersion: 4,
      );
      await notifier.refreshOcrForQuestion('q1');
      expect(container.read(organizeProvider).current?.questionType,
          'choice_single');
      expect(container.read(organizeProvider).questionType, 'choice_single');
    });

    test('当前题 OCR 完成：用户已改表单题型 → 行换新，表单不动', () async {
      final repo = _P4OrgRepo(
        questions: [_q('q1', '图九题', ocrRaw: _raw(fxText))],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      await _settle();
      repo.questions[0] = _q(
        'q1',
        '图九题',
        questionType: 'choice_single',
        questionTypeSource: 'auto',
        ocrRaw: _raw(fxText),
        contentVersion: 4,
      );
      // 用户在表单里已手动改成填空（未保存）：刷新不得悄悄改掉。
      notifier.setQuestionType('fill_blank');
      await notifier.refreshOcrForQuestion('q1');
      expect(container.read(organizeProvider).current?.questionType,
          'choice_single');
      expect(container.read(organizeProvider).questionType, 'fill_blank');
    });

    test('切走的题 OCR 完成：只换该题的队列行，不动当前题与表单', () async {
      final repo = _P4OrgRepo(
        questions: [
          _q('q1', '无原文题'),
          _q('q2', '图九题', ocrRaw: _raw(fxText)),
        ],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      await _settle();
      repo.questions[1] = _q(
        'q2',
        '图九题',
        questionType: 'choice_single',
        questionTypeSource: 'auto',
        ocrRaw: _raw(fxText),
        contentVersion: 4,
      );
      await notifier.refreshOcrForQuestion('q2');
      expect(container.read(organizeProvider).current?.id, 'q1');
      expect(container.read(organizeProvider).current?.questionType, isNull);
      expect(container.read(organizeProvider).questionType, isNull);
      expect(
        container.read(organizeProvider).queue[1].questionType,
        'choice_single',
      );
    });
  });

  group('DetailNotifier.reclassifyCurrent', () {
    test('入口自动重算：图九待确认题 → updated，视图行更新', () async {
      final repo = _P4DetailRepo(
        questions: [_q('q1', '图九题', ocrRaw: _raw(fxText))],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      await _settle();
      expect(container.read(detailProvider).question?.questionType,
          'choice_single');
      expect(repo.saved.any((x) => x.id == 'q1'), isTrue);
    });

    test('自动重算：同一输入版本只算一次（第二次 already_attempted）', () async {
      // 用无信号文本：入口自动重算算过一次得 unchanged（仍待确认），
      // 键已记；再调自动重算应被守门拦住，且全程不写库。
      final repo = _P4DetailRepo(
        questions: [_q('q1', '默写题', ocrRaw: _raw(noSignalText))],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      await _settle();
      expect(container.read(detailProvider).question?.questionType, isNull);
      expect(await notifier.reclassifyCurrent(), 'already_attempted');
      expect(repo.saved, isEmpty);
    });

    test('强制重算：已定型但结果变了 → updated', () async {
      final repo = _P4DetailRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'fill_blank',
            questionTypeSource: 'auto',
            ocrRaw: _raw(fxText),
          ),
        ],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect(await notifier.reclassifyCurrent(force: true), 'updated');
      expect(container.read(detailProvider).question?.questionType,
          'choice_single');
    });

    test('强制重算：manual 题型 → manual，不写库', () async {
      final repo = _P4DetailRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'fill_blank',
            questionTypeSource: 'manual',
            ocrRaw: _raw(fxText),
          ),
        ],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      expect(await notifier.reclassifyCurrent(force: true), 'manual');
      expect(repo.saved, isEmpty);
    });
  });

  group('整理页题型区：切分诊断 + 重新分类', () {
    testWidgets('题型待确认且无法自动定型：显示切分诊断小字 + 重新分类按钮',
        (tester) async {
      final repo = _P4OrgRepo(
        questions: [_q('q1', '默写题', ocrRaw: _raw(noSignalText))],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      await _pumpOrganize(tester, repo);
      // 待确认 chip + 切分诊断（splitStem 的 reason；注意题干区另有
      // 一处既有的“切分：未切分”状态文案，故按完整诊断文本断言）。
      expect(find.widgetWithText(QmChip, '待确认'), findsOneWidget);
      expect(
        find.text('切分：未发现选项标记，整段保留为题干'),
        findsOneWidget,
      );
      expect(find.text('重新分类'), findsOneWidget);
    });

    testWidgets('重新分类：仍无法自动定型 → 提示请人工指定', (tester) async {
      final repo = _P4OrgRepo(
        questions: [_q('q1', '默写题', ocrRaw: _raw(noSignalText))],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      await _pumpOrganize(tester, repo);
      await tester.tap(find.text('重新分类'));
      await tester.pumpAndSettle();
      expect(find.text('仍无法自动分类，请人工指定'), findsOneWidget);
      expect(find.widgetWithText(QmChip, '待确认'), findsOneWidget);
    });

    testWidgets('重新分类：已定型填空 + 图九原文 → 改为单项选择', (tester) async {
      final repo = _P4OrgRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'fill_blank',
            questionTypeSource: 'auto',
            ocrRaw: _raw(fxText),
          ),
        ],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      await _pumpOrganize(tester, repo);
      // 自动重算不对“已定型”的题动手；按钮点后才重算。
      expect(find.widgetWithText(QmChip, '填空题'), findsOneWidget);
      expect(find.text('重新分类'), findsOneWidget);
      await tester.tap(find.text('重新分类'));
      await tester.pumpAndSettle();
      expect(find.text('已重新分类为单项选择'), findsOneWidget);
      expect(find.widgetWithText(QmChip, '单项选择'), findsOneWidget);
      expect(repo.questions.first.questionType, 'choice_single');
    });

    testWidgets('manual 题型：不显示重新分类按钮', (tester) async {
      final repo = _P4OrgRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'fill_blank',
            questionTypeSource: 'manual',
            ocrRaw: _raw(fxText),
          ),
        ],
        folderList: const [Folder(id: 'f1', name: '试卷', subjectId: 'math')],
      );
      await _pumpOrganize(tester, repo);
      expect(find.widgetWithText(QmChip, '填空题'), findsOneWidget);
      expect(find.text('重新分类'), findsNothing);
    });
  });

  group('详情页题型区：切分诊断 + 重新分类', () {
    testWidgets('查看态：题型待确认 → 显示切分诊断 + 重新分类按钮',
        (tester) async {
      final repo = _P4DetailRepo(
        questions: [_q('q1', '默写题', ocrRaw: _raw(noSignalText))],
      );
      await _pumpDetail(tester, repo);
      // 十九批 C：题目信息 panel 默认展开（D1），不用再点标题展开；
      // 旧布局默认折叠，点标题会把它合上、chip 反而找不到了。
      // 待确认 chip + 切分诊断（同整理页：按完整诊断文本断言，
      // 避开题干区既有的“切分：未切分”状态文案）。
      expect(find.widgetWithText(QmChip, '待确认'), findsOneWidget);
      expect(
        find.text('切分：未发现选项标记，整段保留为题干'),
        findsOneWidget,
      );
      expect(find.text('重新分类'), findsOneWidget);
    });

    testWidgets('查看态：重新分类 → 图九题改为单项选择', (tester) async {
      final repo = _P4DetailRepo(
        questions: [
          _q(
            'q1',
            '图九题',
            questionType: 'fill_blank',
            questionTypeSource: 'auto',
            ocrRaw: _raw(fxText),
          ),
        ],
      );
      await _pumpDetail(tester, repo);
      // 十九批 C：题目信息 panel 默认展开（D1），不用再点标题展开。
      expect(find.widgetWithText(QmChip, '填空题'), findsOneWidget);
      await tester.tap(find.text('重新分类'));
      await tester.pumpAndSettle();
      expect(find.text('已重新分类为单项选择'), findsOneWidget);
      expect(find.widgetWithText(QmChip, '单项选择'), findsOneWidget);
      expect(repo.questions.first.questionType, 'choice_single');
    });
  });
}

// ---------------------------------------------------------------------------
// Widget 测试夹具
// ---------------------------------------------------------------------------

Future<void> _pumpOrganize(WidgetTester tester, _P4OrgRepo repo) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: OrganizePage(
          repo: repo,
          onOpenDetail: (_, __, {String? searchContext}) async {},
          onGoReview: () {},
          onGoCollect: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpDetail(WidgetTester tester, _P4DetailRepo repo) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: QuestionDetailPage(
          repo: repo,
          questionId: 'q1',
          orderIds: const ['q1'],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

