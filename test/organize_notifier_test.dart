// ARCH-PLAN-A 第 3 阶段：OrganizeNotifier 单测（不启动 widget）。
// 注入方式与 review_notifier_test.dart 一致：ProviderContainer.test +
// repositoryProvider.overrideWithValue。autoDispose 下单测要像页面
// ref.watch 那样持一个监听保活（D-36：只 read 不监听时 build 里的
// microtask 首查还没写回就被销毁），见 `_container`。
// 首查直接调 `await notifier.refresh()`（与 review 单测调 `load()`
// 同款），不等 build 里的 microtask。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';

Question _oq(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> folderIds = const [],
  String? examId,
  List<String> errorTypes = const [],
  List<String> customErrorTypes = const [],
  List<String> tags = const [],
  String? answer,
  DateTime? createdAt,
  bool isOrganized = false,
  bool isArchived = false,
  bool reviewJoined = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      folderIds: folderIds,
      examId: examId,
      errorTypes: errorTypes,
      customErrorTypes: customErrorTypes,
      tags: tags,
      answer: answer,
      createdAt: createdAt ?? DateTime(2026, 11, 8),
      isOrganized: isOrganized,
      isArchived: isArchived,
      reviewJoined: reviewJoined,
      sliceKind: 'material',
      sliceText: '题：$title',
    );

class FakeOrganizeNotifierRepo extends QuestionRepository {
  FakeOrganizeNotifierRepo({
    required List<Question> questions,
    required List<Folder> folderList,
    List<Exam> examList = const [],
    List<KnowledgePoint> kpList = const [],
    List<String> tagList = const [],
    List<Subject>? subjectsValue,
  })  : questions = List.of(questions),
        folderList = List.of(folderList),
        examList = List.of(examList),
        kpList = List.of(kpList),
        tagList = List.of(tagList),
        subjectsValue = subjectsValue ?? Subject.all,
        super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;
  List<Exam> examList;
  List<KnowledgePoint> kpList;
  List<String> tagList;
  List<Subject> subjectsValue;

  final List<Question> saved = [];
  final List<String> deletedIds = [];
  final List<Folder> savedFolders = [];
  final Set<String> failSaveIds = {};
  int syncCauseRecordsCalls = 0;
  String? lastRecentKind;

  int organizedTodayValue = 0;
  List<Question> dueTodayValue = const [];

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async =>
      subjectId == null
          ? List.of(folderList)
          : folderList.where((f) => f.subjectId == subjectId).toList();

  @override
  Future<List<Exam>> exams() async => List.of(examList);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kpList);

  @override
  Future<List<String>> tags() async => List.of(tagList);

  @override
  Future<void> save(Question question) async {
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
  Future<void> delete(Question question) async {
    deletedIds.add(question.id);
    questions.removeWhere((x) => x.id == question.id);
  }

  @override
  Future<void> saveFolder(Folder folder) async {
    savedFolders.add(folder);
    folderList.add(folder);
  }

  @override
  Future<bool> folderNameExistsInSubject(
    String subjectId,
    String name, {
    String? excludeId,
  }) async =>
      folderList.any(
        (f) =>
            f.subjectId == subjectId &&
            f.name == name &&
            f.id != excludeId,
      );

  @override
  Future<void> addExam(Exam exam) async {
    examList.add(exam);
  }

  @override
  Future<void> addTag(String name) async {
    if (!tagList.contains(name)) tagList.add(name);
  }

  @override
  Future<void> syncCauseRecords(Question question) async {
    syncCauseRecordsCalls++;
  }

  @override
  Future<void> saveRecentTask({
    required String kind,
    required String subjectId,
    required String title,
  }) async {
    lastRecentKind = kind;
  }

  @override
  Future<int> organizedTodayCount({DateTime? now}) async =>
      organizedTodayValue;

  @override
  Future<List<Question>> dueToday({bool includeArchived = false}) async =>
      List.of(dueTodayValue);
}

FakeOrganizeNotifierRepo _threeRepo() => FakeOrganizeNotifierRepo(
      questions: [
        _oq('q1', '函数极限', createdAt: DateTime(2026, 11, 8)),
        _oq(
          'q2',
          '导数综合',
          folderIds: const ['f1'],
          examId: 'e1',
          createdAt: DateTime(2026, 11, 5),
        ),
        _oq(
          'q3',
          '阅读主旨',
          subjectId: 'english',
          createdAt: DateTime(2026, 11, 3),
        ),
      ],
      folderList: const [
        Folder(id: 'f1', name: '试卷', subjectId: 'math'),
        Folder(id: 'f2', name: '平时作业', subjectId: 'math'),
        Folder(id: 'f3', name: '试卷', subjectId: 'english'),
      ],
      examList: [
        Exam(
          id: 'e1',
          name: '高等数学期末试卷',
          date: DateTime(2026, 11, 10),
        ),
      ],
      kpList: const [
        KnowledgePoint(
          id: 'k1',
          subjectId: 'math',
          chapter: '第一章 函数与极限',
          name: '函数极限',
        ),
        KnowledgePoint(
          id: 'k2',
          subjectId: 'math',
          chapter: '第一章 函数与极限',
          name: '导数概念',
        ),
        KnowledgePoint(
          id: 'k3',
          subjectId: 'english',
          chapter: '阅读理解',
          name: '主旨大意',
        ),
      ],
      tagList: const ['易错', '常考'],
    );

ProviderContainer _container(FakeOrganizeNotifierRepo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  // autoDispose 保活（D-36）：像页面 ref.watch 那样持一个监听，
  // 否则 build 里的 microtask 首查还没写回就被销毁。
  container.listen(organizeProvider, (_, __) {});
  return container;
}

void main() {
  group('OrganizeNotifier refresh / loadForm', () {
    test('refresh：待整理队列默认时间降序，元数据与表单按首题重建', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final s = container.read(organizeProvider);
      expect(s.loading, isFalse);
      expect(s.queue.map((q) => q.id), ['q1', 'q2', 'q3']);
      expect(s.current?.id, 'q1');
      expect(s.hasAnyQuestion, isTrue);
      expect(s.exams.map((e) => e.id), ['e1']);
      expect(s.kps.length, 3);
      expect(s.allTags, ['易错', '常考']);
      expect(s.subjects.length, 3);
      // 当前题是数学题：文件夹只读数学的。
      expect(s.folders.map((f) => f.id), ['f1', 'f2']);
      // 表单按 q1 重建：无文件夹、无试卷、无错因、无标签。
      expect(s.folderIds, isEmpty);
      expect(s.examId, isNull);
      expect(s.errorTypes, isEmpty);
      expect(s.tags, isEmpty);
      expect(s.formResetKey, greaterThanOrEqualTo(1));
      // 队列非空：今日小结不读。
      expect(s.organizedToday, 0);
      expect(s.toReviewCount, 0);
    });

    test('refresh：已整理与已归档排除在队列外，下标越界钳回末尾', () async {
      final repo = _threeRepo();
      repo.questions.addAll([
        _oq('q4', '已整理题', isOrganized: true),
        _oq('q5', '已归档题', isArchived: true),
      ]);
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(
        container.read(organizeProvider).queue.map((q) => q.id),
        ['q1', 'q2', 'q3'],
      );
      await notifier.goTo(2);
      expect(container.read(organizeProvider).current?.id, 'q3');
      // 模拟末尾题在别处被整理掉：重读后下标钳回末尾。
      repo.questions.removeWhere((q) => q.id == 'q3');
      await notifier.refresh();
      final s = container.read(organizeProvider);
      expect(s.index, 1);
      expect(s.current?.id, 'q2');
    });

    test('refresh：队列已空且库里有题时读今日小结；库里无题时不读', () async {
      final repo = _threeRepo();
      repo.questions = [
        _oq('q1', '已整理题', isOrganized: true),
      ];
      repo.organizedTodayValue = 3;
      repo.dueTodayValue = [
        _oq('q9', '待复习题', isOrganized: true, reviewJoined: true),
        _oq('q8', '待复习题二', isOrganized: true, reviewJoined: true),
      ];
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final s = container.read(organizeProvider);
      expect(s.queue, isEmpty);
      expect(s.hasAnyQuestion, isTrue);
      expect(s.organizedToday, 3);
      expect(s.toReviewCount, 2);

      final emptyRepo = _threeRepo();
      emptyRepo.questions = [];
      emptyRepo.organizedTodayValue = 5;
      emptyRepo.dueTodayValue = [
        _oq('q9', '待复习题', isOrganized: true, reviewJoined: true),
      ];
      final c2 = _container(emptyRepo);
      final n2 = c2.read(organizeProvider.notifier);
      await n2.refresh();
      final s2 = c2.read(organizeProvider);
      expect(s2.hasAnyQuestion, isFalse);
      expect(s2.organizedToday, 0);
      expect(s2.toReviewCount, 0);
    });

    test('refresh：subjectAsc 学科首字母升序，同科内时间降序', () async {
      final repo = _threeRepo();
      // 英语题最新：时间降序是 q3 在前；学科升序应把两道数学题排前面。
      repo.questions[2] = _oq(
        'q3',
        '阅读主旨',
        subjectId: 'english',
        createdAt: DateTime(2026, 11, 9),
      );
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(
        container.read(organizeProvider).queue.map((q) => q.id),
        ['q3', 'q1', 'q2'],
      );
      notifier.applyQueueSort('subjectAsc');
      final s = container.read(organizeProvider);
      expect(s.queue.map((q) => q.id), ['q1', 'q2', 'q3']);
      expect(s.index, 0);
      expect(s.current?.id, 'q1');
    });

    test('loadForm：SR-P2-27 与固定枚举同名的自定义错因合并进固定项', () async {
      final repo = _threeRepo();
      repo.questions = [
        _oq(
          'q1',
          '函数极限',
          errorTypes: const ['计算错误'],
          customErrorTypes: const ['概念不清', '自创原因'],
        ),
      ];
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final s = container.read(organizeProvider);
      expect(s.errorTypes.toSet(), {'计算错误', '概念不清'});
      expect(s.customTypes, ['自创原因']);
      expect(s.customTypesAll.toSet(), {'概念不清', '自创原因'});
    });

    test('loadForm：每次调用 formResetKey 加一', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final before = container.read(organizeProvider).formResetKey;
      notifier.loadForm();
      expect(
        container.read(organizeProvider).formResetKey,
        before + 1,
      );
    });
  });

  group('OrganizeNotifier 表单值改动', () {
    test('toggle / set / remove 各改动口只改自己那一项', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      notifier.toggleFolder('f1');
      notifier.toggleFolder('f2');
      notifier.toggleFolder('f1');
      expect(container.read(organizeProvider).folderIds, ['f2']);
      notifier.setExamId('e1');
      expect(container.read(organizeProvider).examId, 'e1');
      notifier.setExamId(null);
      expect(container.read(organizeProvider).examId, isNull);
      notifier.toggleKp('k1');
      notifier.toggleKp('k2');
      expect(container.read(organizeProvider).kpIds, ['k1', 'k2']);
      notifier.toggleErrorType('概念不清');
      notifier.toggleErrorType('计算错误');
      notifier.removeErrorType('概念不清');
      expect(container.read(organizeProvider).errorTypes, ['计算错误']);
      notifier.toggleCustomType('自创原因');
      notifier.removeCustomType('自创原因');
      expect(container.read(organizeProvider).customTypes, isEmpty);
      notifier.toggleTag('易错');
      notifier.toggleTag('常考');
      notifier.toggleTag('易错');
      expect(container.read(organizeProvider).tags, ['常考']);
    });

    test('addCustomType：固定名进固定项返回 true；新自定义进两处返回 false',
        () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      expect(notifier.addCustomType('概念不清'), isTrue);
      var s = container.read(organizeProvider);
      expect(s.errorTypes, ['概念不清']);
      expect(s.customTypes, isEmpty);
      expect(notifier.addCustomType('自创原因'), isFalse);
      s = container.read(organizeProvider);
      expect(s.customTypes, ['自创原因']);
      expect(s.customTypesAll, contains('自创原因'));
      // 重复添加不重复。
      expect(notifier.addCustomType('自创原因'), isFalse);
      expect(container.read(organizeProvider).customTypes, ['自创原因']);
    });
  });

  group('OrganizeNotifier 保存 / 切题 / 确认', () {
    test('saveCurrent：保存表单行 + 同步错因记录 + 写回队列（SR2-6）', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      notifier.toggleFolder('f1');
      notifier.setExamId('e1');
      notifier.toggleTag('易错');
      final ok = await notifier.saveCurrent(
        answer: ' 42 ',
        explanation: '',
        notes: '注意定义域',
      );
      expect(ok, isTrue);
      expect(repo.syncCauseRecordsCalls, 1);
      final saved = repo.saved.single;
      expect(saved.id, 'q1');
      expect(saved.folderIds, ['f1']);
      expect(saved.examId, 'e1');
      expect(saved.tags, ['易错']);
      expect(saved.answer, '42');
      expect(saved.explanation, isNull);
      expect(saved.notes, '注意定义域');
      // SR2-6：队列里的行已是保存后的新行。
      expect(container.read(organizeProvider).queue.first.folderIds, ['f1']);
      expect(container.read(organizeProvider).queue.first.answer, '42');
    });

    test('saveCurrent：写库失败返回 false，队列行保持旧值', () async {
      final repo = _threeRepo();
      repo.failSaveIds.add('q1');
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      notifier.toggleFolder('f1');
      final ok = await notifier.saveCurrent(
        answer: '',
        explanation: '',
        notes: '',
      );
      expect(ok, isFalse);
      expect(container.read(organizeProvider).queue.first.folderIds, isEmpty);
    });

    test('confirmCurrent：确认后进错题本、记最近任务、队列推进到下一道', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      notifier.toggleFolder('f1');
      await notifier.confirmCurrent(
        answer: '42',
        explanation: '解析',
        notes: '',
      );
      expect(repo.lastRecentKind, '整理');
      final saved = repo.saved.single;
      expect(saved.id, 'q1');
      expect(saved.isOrganized, isTrue);
      expect(saved.folderIds, ['f1']);
      final s = container.read(organizeProvider);
      expect(s.queue.map((q) => q.id), ['q2', 'q3']);
      expect(s.current?.id, 'q2');
      // 表单按新当前题 q2 重建。
      expect(s.folderIds, ['f1']);
      expect(s.examId, 'e1');
    });

    test('goTo：切题重读文件夹并重建表单；越界与原地不动直接返回', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      await notifier.goTo(2);
      var s = container.read(organizeProvider);
      expect(s.current?.id, 'q3');
      // q3 是英语题：文件夹只剩英语的 f3，表单按 q3 重建。
      expect(s.folders.map((f) => f.id), ['f3']);
      expect(s.folderIds, isEmpty);
      await notifier.goTo(99);
      await notifier.goTo(-1);
      await notifier.goTo(2);
      expect(container.read(organizeProvider).index, 2);
      await notifier.goTo(0);
      s = container.read(organizeProvider);
      expect(s.current?.id, 'q1');
      expect(s.folders.map((f) => f.id), ['f1', 'f2']);
    });

    test('jumpTo：跳到指定题；找不到时重读一遍', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      await notifier.jumpTo('q3');
      var s = container.read(organizeProvider);
      expect(s.index, 2);
      expect(s.current?.id, 'q3');
      await notifier.jumpTo('不存在');
      s = container.read(organizeProvider);
      expect(s.queue.map((q) => q.id), ['q1', 'q2', 'q3']);
      expect(s.current?.id, 'q3');
    });

    test('applyQueueSort：timeAsc 重排并回到第 1 道、表单重建', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final before = container.read(organizeProvider).formResetKey;
      notifier.applyQueueSort('timeAsc');
      final s = container.read(organizeProvider);
      expect(s.queue.map((q) => q.id), ['q3', 'q2', 'q1']);
      expect(s.index, 0);
      expect(s.current?.id, 'q3');
      expect(s.formResetKey, before + 1);
    });
  });

  group('OrganizeNotifier 内联新建', () {
    test('submitNewFolder：新建并选上；整科同名返回 null', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final folder = await notifier.submitNewFolder('错题精选', 'math');
      expect(folder, isNotNull);
      expect(folder!.name, '错题精选');
      expect(folder.subjectId, 'math');
      final s = container.read(organizeProvider);
      expect(s.folderIds, [folder.id]);
      expect(s.folders.map((f) => f.id), contains(folder.id));
      expect(await notifier.submitNewFolder('试卷', 'math'), isNull);
      // 跨科不同名不算重复（英语科没有「平时作业」）。
      expect(await notifier.submitNewFolder('平时作业', 'english'), isNotNull);
    });

    test('submitNewExam：追加进试卷表并归属到这道题', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      await notifier.submitNewExam(
        '高等数学期中试卷',
        DateTime(2026, 11, 12),
      );
      final s = container.read(organizeProvider);
      expect(s.exams.length, 2);
      expect(s.exams.last.name, '高等数学期中试卷');
      expect(s.examId, s.exams.last.id);
    });

    test('submitNewTag：追加进标签表并选上', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      await notifier.submitNewTag('期末重点');
      final s = container.read(organizeProvider);
      expect(s.tags, ['期末重点']);
      expect(s.allTags, contains('期末重点'));
    });
  });

  group('OrganizeNotifier 队列批量操作', () {
    test('batchConfirmQuestions：只确认已选文件夹的题，返回拦下数，不同步错因记录',
        () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final s = container.read(organizeProvider);
      final blocked = await notifier.batchConfirmQuestions(s.queue);
      expect(blocked, 2);
      expect(
        repo.saved.map((q) => q.id),
        ['q2'],
      );
      expect(repo.saved.single.isOrganized, isTrue);
      // 批量确认不同步错因记录（与单题确认不同，原代码同款）。
      expect(repo.syncCauseRecordsCalls, 0);
    });

    test('batchTagQuestions：打上标签并返回已保存 id；中途失败只返回已保存子集',
        () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final s = container.read(organizeProvider);
      final result = await notifier.batchTagQuestions(s.queue, '需重做');
      expect(result.total, 3);
      expect(result.savedIds, {'q1', 'q2', 'q3'});
      expect(
        repo.saved.map((q) => q.tags),
        [
          ['需重做'],
          ['需重做'],
          ['需重做'],
        ],
      );

      final repo2 = _threeRepo();
      repo2.failSaveIds.add('q2');
      final c2 = _container(repo2);
      final n2 = c2.read(organizeProvider.notifier);
      await n2.refresh();
      final s2 = c2.read(organizeProvider);
      final r2 = await n2.batchTagQuestions(s2.queue, '需重做');
      expect(r2.savedIds, {'q1'});
      expect(r2.total, 3);
    });

    test('batchAddFolders：本科已在文件夹里的计入已加入不重复写库；外科目跳过',
        () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final folder =
          repo.folderList.firstWhere((f) => f.id == 'f1');
      final s = container.read(organizeProvider);
      final result = await notifier.batchAddFolders(s.queue, folder);
      expect(result, (applied: 2, skipped: 1));
      // 只有 q1 真写了库（q2 已在 f1 里不重复写，q3 是英语题跳过）。
      expect(repo.saved.map((q) => q.id), ['q1']);
      expect(repo.saved.single.folderIds, ['f1']);
    });

    test('submitBatchFolder：新建返回文件夹；整科同名返回 null', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final folder =
          await notifier.submitBatchFolder('错题精选', 'math', 2);
      expect(folder, isNotNull);
      expect(folder!.subjectId, 'math');
      expect(
        await notifier.submitBatchFolder('试卷', 'math', 3),
        isNull,
      );
    });

    test('deleteQuestion / batchDeleteQuestions：逐题删除', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final s = container.read(organizeProvider);
      await notifier.deleteQuestion(s.queue.first);
      expect(repo.deletedIds, ['q1']);
      await notifier.batchDeleteQuestions(s.queue.sublist(1));
      expect(repo.deletedIds, ['q1', 'q2', 'q3']);
      expect(repo.questions, isEmpty);
    });
  });
}
