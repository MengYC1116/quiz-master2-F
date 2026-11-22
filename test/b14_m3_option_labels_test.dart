// 十四批 M3：选项标签确认 UI 测试（整理页 / 详情页共用编辑器）。
//
// 覆盖：
// - parseOptionLabels 解析口径（分隔符、去空、去重保序、空串→null）。
// - OptionLabelsEditor（WP-A #1 REV5：无标签文本框、无「确认选项」按钮；
//   按位增删、「+」追加下一字母、点选正确答案即重确认、判断题固定两行、
//   多选改标签 P1-A 提示与复选框、待核对标记提示、非选择题型不渲染）。
//   旧版“确认选项保存置 confirmed”流程已随确认列停用而移除。
// - OrganizeNotifier：表单值→保存的信号透传（确认保存置 confirmed+
//   justConfirmed 信号、保存后信号清零、标签清空时确认态清零、
//   正确选项点选带 answerReconfirmed 信号）。
// - DetailNotifier：查看态 saveOptionBlock（确认保存 / 正确选项即时
//   保存保持确认态）、编辑态 saveEdit 从 base 带 answerPendingRecheck
//   （D-141：无关编辑不静默清标记）、enterEdit 初始化编辑值。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/option_labels_editor.dart';
import 'package:quiz_master2/state/detail_notifier.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/widgets/uikit.dart';

Question _q(
  String id, {
  String subjectId = 'math',
  String? questionType,
  List<String>? optionLabels,
  bool optionLabelsConfirmed = false,
  String? correctOption,
  String? answer,
  String? explanation,
  bool answerPendingRecheck = false,
  bool isOrganized = false,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: subjectId,
  questionType: questionType,
  optionLabels: optionLabels,
  optionLabelsConfirmed: optionLabelsConfirmed,
  correctOption: correctOption,
  answer: answer,
  explanation: explanation,
  answerPendingRecheck: answerPendingRecheck,
  createdAt: DateTime(2026, 11, 8),
  isOrganized: isOrganized,
  sliceKind: 'material',
  sliceText: '题：$id',
);

// ---------------------------------------------------------------------------
// parseOptionLabels
// ---------------------------------------------------------------------------

void main() {
  group('parseOptionLabels', () {
    test('逗号分隔', () {
      expect(parseOptionLabels('A,B,C,D'), ['A', 'B', 'C', 'D']);
    });

    test('中文逗号/顿号/空格混用，去空去重保序', () {
      expect(
        parseOptionLabels('A，B、C D,,A, '),
        ['A', 'B', 'C', 'D'],
      );
    });

    test('空串与全分隔符返回 null', () {
      expect(parseOptionLabels(''), isNull);
      expect(parseOptionLabels(' , ， '), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // OptionLabelsEditor
  // -------------------------------------------------------------------------

  Future<void> pumpEditor(
    WidgetTester tester, {
    String questionId = 'q1',
    required String questionType,
    List<String>? optionLabels,
    List<String>? storedOptionLabels,
    bool optionLabelsConfirmed = false,
    String? correctOption,
    String? storedCorrectOption,
    bool answerPendingRecheck = false,
    bool hadOldAnswer = false,
    bool answerReconfirmed = false,
    bool correctOptionSavesImmediately = false,
    ValueChanged<List<String>?>? onLabelsChanged,
    ValueChanged<String?>? onCorrectOptionChanged,
    ValueChanged<bool>? onAnswerReconfirmedChanged,
    void Function({
      required List<String>? labels,
      required String? correctOption,
      required bool answerReconfirmed,
      required bool confirmLabels,
    })? onConfirm,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OptionLabelsEditor(
            key: ValueKey(questionId),
            questionId: questionId,
            questionType: questionType,
            optionLabels: optionLabels,
            storedOptionLabels: storedOptionLabels ?? optionLabels,
            optionLabelsConfirmed: optionLabelsConfirmed,
            correctOption: correctOption,
            storedCorrectOption: storedCorrectOption ?? correctOption,
            answerPendingRecheck: answerPendingRecheck,
            hadOldAnswer: hadOldAnswer,
            answerReconfirmed: answerReconfirmed,
            onLabelsChanged: onLabelsChanged ?? (_) {},
            onCorrectOptionChanged: onCorrectOptionChanged ?? (_) {},
            onAnswerReconfirmedChanged: onAnswerReconfirmedChanged ?? (_) {},
            onConfirm:
                onConfirm ??
                ({
                  required List<String>? labels,
                  required String? correctOption,
                  required bool answerReconfirmed,
                  required bool confirmLabels,
                }) {},
            correctOptionSavesImmediately: correctOptionSavesImmediately,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('OptionLabelsEditor', () {
    testWidgets('单选：纵向列出选项位，点正确选项带重确认信号', (tester) async {
      String? picked;
      var reconfirmed = false;
      await pumpEditor(
        tester,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        optionLabelsConfirmed: true,
        correctOption: 'B',
        onCorrectOptionChanged: (v) => picked = v,
        onAnswerReconfirmedChanged: (v) => reconfirmed = v,
      );
      // REV5：无标签文本框、无「确认选项」按钮；配置有效即显示可判分。
      expect(find.byType(TextField), findsNothing);
      expect(find.widgetWithText(QmButton, '确认选项'), findsNothing);
      expect(find.textContaining('已设正确答案，可客观判分'), findsOneWidget);
      for (final letter in ['A', 'B', 'C', 'D']) {
        expect(find.widgetWithText(QmChip, letter), findsOneWidget);
      }
      expect(find.widgetWithText(QmButton, '+ 添加选项'), findsOneWidget);
      // 点选 C：正确选项改动 + 重确认信号。
      await tester.tap(find.widgetWithText(QmChip, 'C'));
      await tester.pumpAndSettle();
      expect(picked, 'C');
      expect(reconfirmed, isTrue);
    });

    testWidgets('单选：未设正确答案时提示；标签为 null 时默认 A–D 四位', (tester) async {
      await pumpEditor(
        tester,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B'],
        optionLabelsConfirmed: false,
      );
      expect(find.textContaining('未设正确答案'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      final button = find
          .widgetWithText(QmButton, '+ 添加选项')
          .evaluate()
          .first
          .widget as QmButton;
      expect(button.onPressed, isNotNull);

      await pumpEditor(tester, questionId: 'q2', questionType: 'choice_single');
      for (final letter in ['A', 'B', 'C', 'D']) {
        expect(find.widgetWithText(QmChip, letter), findsOneWidget);
      }
      expect(find.textContaining('未设正确答案'), findsOneWidget);
    });

    testWidgets('删位：正确选项被删时清掉；删其他位不影响正确答案', (tester) async {
      List<String>? seen;
      String? correctSeen = 'B';
      await pumpEditor(
        tester,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
        onLabelsChanged: (v) => seen = v,
        onCorrectOptionChanged: (v) => correctSeen = v,
      );
      // 先删 D（非答案位）：标签少一位，正确答案保留。
      await tester.tap(find.byTooltip('删除选项 D'));
      await tester.pumpAndSettle();
      expect(seen, ['A', 'B', 'C']);
      expect(correctSeen, 'B');
      // 再删 B（答案位）：草稿清掉并回调 null。
      await tester.tap(find.byTooltip('删除选项 B'));
      await tester.pumpAndSettle();
      expect(seen, ['A', 'C']);
      expect(correctSeen, isNull);
      expect(find.textContaining('未设正确答案'), findsOneWidget);
    });

    testWidgets('判断题：固定标签，无标签编辑器与确认按钮；点选即时保存', (tester) async {
      Map<String, Object?>? saved;
      await pumpEditor(
        tester,
        questionType: 'true_false',
        optionLabelsConfirmed: false,
        correctOptionSavesImmediately: true,
        onConfirm: ({
          required List<String>? labels,
          required String? correctOption,
          required bool answerReconfirmed,
          required bool confirmLabels,
        }) {
          saved = {
            'correct': correctOption,
            'reconfirmed': answerReconfirmed,
            'confirm': confirmLabels,
          };
        },
      );
      expect(find.textContaining('判断题选项固定'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.widgetWithText(QmButton, '确认选项'), findsNothing);
      await tester.tap(find.widgetWithText(QmChip, '正确'));
      await tester.pumpAndSettle();
      expect(saved?['correct'], '正确');
      expect(saved?['reconfirmed'], isTrue);
      // 判断题即时保存保持原确认态（false），不强制确认标签。
      expect(saved?['confirm'], isFalse);
    });

    testWidgets('多选改标签 + 旧答案：P1-A 提示与重确认复选框', (tester) async {
      var reconfirmed = false;
      await pumpEditor(
        tester,
        questionType: 'choice_multi',
        optionLabels: const ['A', 'B', 'C', 'D', 'E'],
        storedOptionLabels: const ['A', 'B', 'C', 'D'],
        hadOldAnswer: true,
        onAnswerReconfirmedChanged: (v) => reconfirmed = v,
      );
      expect(find.textContaining('选项标签已改：旧答案与解析待重新核对'), findsOneWidget);
      expect(find.text('确认此答案和解析仍有效'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(reconfirmed, isTrue);
    });

    testWidgets('单选删位：删非答案位旧答案仍有效；删答案位提示重选', (tester) async {
      String? correctSeen = 'B';
      await pumpEditor(
        tester,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        storedOptionLabels: const ['A', 'B', 'C', 'D'],
        storedCorrectOption: 'B',
        correctOption: 'B',
        onCorrectOptionChanged: (v) => correctSeen = v,
      );
      // 删 D（非答案位）：正确答案保留，状态仍为可判分。
      await tester.tap(find.byTooltip('删除选项 D'));
      await tester.pumpAndSettle();
      expect(correctSeen, 'B');
      expect(find.textContaining('已设正确答案，可客观判分'), findsOneWidget);
      // 删 B（答案位）：正确答案清空，提示重选。
      await tester.tap(find.byTooltip('删除选项 B'));
      await tester.pumpAndSettle();
      expect(correctSeen, isNull);
      expect(find.textContaining('未设正确答案'), findsOneWidget);
    });

    testWidgets('标签未改但挂着待核对标记：显示待核对提示', (tester) async {
      await pumpEditor(
        tester,
        questionType: 'choice_single',
        optionLabels: const ['A', 'B', 'C', 'D'],
        answerPendingRecheck: true,
      );
      expect(find.textContaining('正确答案待重新核对'), findsOneWidget);
    });

    testWidgets('填空题：不渲染编辑器', (tester) async {
      await pumpEditor(tester, questionType: 'fill_blank');
      expect(find.text('选项标签'), findsNothing);
      expect(find.widgetWithText(QmButton, '确认选项'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // OrganizeNotifier
  // -------------------------------------------------------------------------

  group('OrganizeNotifier 选项标签', () {
    test('确认选项：置 confirmed + justConfirmed 信号；保存后信号清零', () async {
      final repo = _FakeOrgRepo(
        questions: [
          _q(
            'q1',
            questionType: 'choice_single',
            optionLabels: const ['A', 'B', 'C', 'D'],
            optionLabelsConfirmed: true,
            correctOption: 'B',
          ),
        ],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(container.read(organizeProvider).optionLabelsConfirmed, isTrue);
      // 改标签 + 重选正确选项 → 确认保存。
      notifier.setOptionLabels(const ['A', 'B', 'C', 'D', 'E']);
      notifier.setCorrectOption('B');
      final ok = await notifier.confirmOptionLabels(
        answer: '',
        explanation: '',
        notes: '',
      );
      expect(ok, isTrue);
      final saved = repo.saved.last;
      expect(saved.optionLabels, ['A', 'B', 'C', 'D', 'E']);
      expect(saved.optionLabelsConfirmed, isTrue);
      expect(saved.optionLabelsJustConfirmed, isTrue);
      // 点选正确选项带重确认信号。
      expect(saved.answerReconfirmed, isTrue);
      expect(saved.correctOption, 'B');
      // 保存成功后信号清零，不跨保存带。
      final st = container.read(organizeProvider);
      expect(st.answerReconfirmed, isFalse);
      expect(st.optionLabelsJustConfirmed, isFalse);
      expect(st.optionLabelsConfirmed, isTrue);
    });

    test('标签清空：确认态一并清零，保存时清掉库里标签', () async {
      final repo = _FakeOrgRepo(
        questions: [
          _q(
            'q1',
            questionType: 'choice_single',
            optionLabels: const ['A', 'B'],
            optionLabelsConfirmed: true,
            correctOption: 'A',
          ),
        ],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      notifier.setOptionLabels(null);
      expect(
        container.read(organizeProvider).optionLabelsConfirmed,
        isFalse,
      );
      await notifier.saveCurrent(answer: '', explanation: '', notes: '');
      final saved = repo.saved.last;
      expect(saved.optionLabels, isNull);
      expect(saved.optionLabelsConfirmed, isFalse);
    });

    test('多选改标签不确认：保存时 answerReconfirmed 为 false（数据层置 NULL）', () async {
      final repo = _FakeOrgRepo(
        questions: [
          _q(
            'q1',
            questionType: 'choice_multi',
            optionLabels: const ['A', 'B', 'C', 'D'],
            optionLabelsConfirmed: true,
            answer: 'B、C',
          ),
        ],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      notifier.setOptionLabels(const ['A', 'B', 'C', 'D', 'E']);
      await notifier.saveCurrent(answer: 'B、C', explanation: '', notes: '');
      final saved = repo.saved.last;
      expect(saved.answerReconfirmed, isFalse);
      expect(saved.optionLabelsJustConfirmed, isFalse);
    });

    test('题型从单选改成多选：保存时 correct_option 强制置 NULL', () async {
      final repo = _FakeOrgRepo(
        questions: [
          _q(
            'q1',
            questionType: 'choice_single',
            optionLabels: const ['A', 'B', 'C', 'D'],
            optionLabelsConfirmed: true,
            correctOption: 'B',
          ),
        ],
      );
      final container = _orgContainer(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      notifier.setQuestionType('choice_multi');
      await notifier.saveCurrent(answer: '', explanation: '', notes: '');
      expect(repo.saved.last.correctOption, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // DetailNotifier
  // -------------------------------------------------------------------------

  group('DetailNotifier 选项标签', () {
    test('查看态确认保存：标签 + confirmed + justConfirmed 信号', () async {
      final repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            questionType: 'choice_single',
            optionLabels: const ['A', 'B', 'C', 'D'],
            isOrganized: true,
          ),
        ],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      await notifier.saveOptionBlock(
        labels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
        confirmLabels: true,
        answerReconfirmed: false,
      );
      final saved = repo.saved.last;
      expect(saved.optionLabels, ['A', 'B', 'C', 'D']);
      expect(saved.optionLabelsConfirmed, isTrue);
      expect(saved.optionLabelsJustConfirmed, isTrue);
      expect(saved.correctOption, 'B');
      // 重读后当前题带上新值。
      expect(container.read(detailProvider).question?.correctOption, 'B');
    });

    test('查看态正确选项即时保存：保持原确认态，不强制确认标签', () async {
      final repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            questionType: 'choice_single',
            optionLabels: const ['A', 'B', 'C', 'D'],
            optionLabelsConfirmed: true,
            correctOption: 'A',
            isOrganized: true,
          ),
        ],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      await notifier.saveOptionBlock(
        labels: const ['A', 'B', 'C', 'D'],
        correctOption: 'B',
        confirmLabels: true,
        answerReconfirmed: true,
      );
      final saved = repo.saved.last;
      expect(saved.correctOption, 'B');
      expect(saved.optionLabelsConfirmed, isTrue);
      expect(saved.answerReconfirmed, isTrue);
    });

    test('D-141：编辑无关字段不静默清掉待核对标记', () async {
      final repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            questionType: 'choice_multi',
            optionLabels: const ['A', 'B', 'C', 'D'],
            optionLabelsConfirmed: false,
            answerPendingRecheck: true,
            isOrganized: true,
          ),
        ],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      notifier.enterEdit();
      await notifier.saveEdit(
        title: '题 q1',
        answer: '',
        explanation: '',
        notes: '改了备注',
      );
      final saved = repo.saved.last;
      expect(saved.answerPendingRecheck, isTrue);
      expect(saved.notes, '改了备注');
    });

    test('编辑态：enterEdit 初始化选项值；改标签 + 重确认随保存带信号', () async {
      final repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            questionType: 'choice_multi',
            optionLabels: const ['A', 'B', 'C', 'D'],
            optionLabelsConfirmed: true,
            answer: 'B、C',
            explanation: '解析',
            isOrganized: true,
          ),
        ],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      notifier.enterEdit();
      var st = container.read(detailProvider);
      expect(st.editOptionLabels, ['A', 'B', 'C', 'D']);
      expect(st.editOptionLabelsConfirmed, isTrue);
      notifier.setEditOptionLabels(const ['A', 'B', 'C', 'D', 'E']);
      notifier.confirmEditOptionLabels(
        labels: const ['A', 'B', 'C', 'D', 'E'],
        correctOption: null,
        answerReconfirmed: true,
      );
      st = container.read(detailProvider);
      expect(st.editOptionLabelsConfirmed, isTrue);
      expect(st.editOptionLabelsJustConfirmed, isTrue);
      await notifier.saveEdit(
        title: '题 q1',
        answer: 'B、C',
        explanation: '解析',
        notes: '',
      );
      final saved = repo.saved.last;
      expect(saved.optionLabels, ['A', 'B', 'C', 'D', 'E']);
      expect(saved.answerReconfirmed, isTrue);
      expect(saved.optionLabelsJustConfirmed, isTrue);
    });

    test('编辑态题型从单选改成多选：保存时 correct_option 强制置 NULL', () async {
      final repo = _FakeDetailRepo(
        questions: [
          _q(
            'q1',
            questionType: 'choice_single',
            optionLabels: const ['A', 'B', 'C', 'D'],
            optionLabelsConfirmed: true,
            correctOption: 'B',
            isOrganized: true,
          ),
        ],
      );
      final container = _detailContainer(repo);
      final notifier = container.read(detailProvider.notifier);
      await notifier.load();
      notifier.enterEdit();
      notifier.setEditQuestionType('choice_multi');
      await notifier.saveEdit(
        title: '题 q1',
        answer: '',
        explanation: '',
        notes: '',
      );
      expect(repo.saved.last.correctOption, isNull);
    });
  });
}

// ---------------------------------------------------------------------------
// 最小 fake（只覆盖本文件走到的 repo 方法；其余走基类——本文件不触发）
// ---------------------------------------------------------------------------

class _FakeOrgRepo extends QuestionRepository {
  _FakeOrgRepo({required this.questions}) : super(AppDatabase.instance);

  List<Question> questions;
  final List<Question> saved = [];
  int syncCauseRecordsCalls = 0;

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;

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
  Future<void> syncCauseRecords(Question q) async {
    syncCauseRecordsCalls++;
  }

  /// B11-10：OrganizeNotifier 只在队列已空且库里有题时读这两个数
  /// （今日小结行用）；返回 0 / 空，不碰真实库（见 D-88）。
  @override
  Future<int> organizedTodayCount({DateTime? now}) async => 0;

  @override
  Future<List<CauseRecord>> causeRecords() async => const [];
}

ProviderContainer _orgContainer(_FakeOrgRepo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  container.listen(organizeProvider, (_, __) {});
  return container;
}

class _FakeDetailRepo extends QuestionRepository {
  _FakeDetailRepo({required this.questions}) : super(AppDatabase.instance);

  List<Question> questions;
  final List<Question> saved = [];
  int syncCauseRecordsCalls = 0;

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<Question?> questionById(String id) async =>
      questions.where((q) => q.id == id).firstOrNull;

  @override
  Future<List<CauseRecord>> causeRecordsFor(String questionId) async =>
      const [];

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
    String questionId,
  ) async => const [];

  @override
  Future<List<Folder>> folders({String? subjectId}) async => const [];

  @override
  Future<List<Exam>> exams() async => const [];

  @override
  Future<List<String>> tags() async => const [];

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => const [];

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async =>
      const [];

  @override
  Future<bool> hasOcrApiKey() async => false;

  @override
  Future<void> recordQuestionViewed(String questionId) async {}

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
  Future<void> syncCauseRecords(Question q) async {
    syncCauseRecordsCalls++;
  }

  /// 详情页自愈（_healSliceIfNeeded）读同页框：无框，不碰真实库（见 D-88）。
  @override
  Future<List<QuestionBox>> boxesForPageImage(String pageImagePath) async =>
      const [];
}

ProviderContainer _detailContainer(_FakeDetailRepo repo) {
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      detailInitialProvider.overrideWithValue(
        const DetailInitial(questionId: 'q1', orderIds: ['q1']),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(detailProvider, (_, __) {});
  return container;
}
