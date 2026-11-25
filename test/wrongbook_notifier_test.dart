// ARCH-PLAN-A 第 2 阶段（B 路）：WrongbookNotifier 单测（不启动 widget）。
// 拿 notifier 的方式与 Stage 1 一致：`ProviderContainer.test` +
// `repositoryProvider.overrideWithValue(repo)` 注入（见
// docs/ui-replication/A-READING-GUIDE.md）；初始落点经
// `wrongbookInitialProvider.overrideWithValue` 注入；
// FakeRepo 只覆盖 Notifier 实际调的方法，不碰真实库。
// 覆盖首读（设置默认值只取一次）、初始落点、列表过滤与排序、
// 筛选/分页、文件夹移动禁则、批量操作汇总。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/wrongbook_notifier.dart';

Question _wbq(
  String id, {
  String subjectId = 'math',
  List<String> folderIds = const [],
  List<String> errorTypes = const ['概念不清'],
  DateTime? createdAt,
  bool isOrganized = true,
  bool isArchived = false,
  bool isFavorite = false,
  bool reviewJoined = false,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: subjectId,
  folderIds: folderIds,
  errorTypes: errorTypes,
  createdAt: createdAt ?? DateTime(2026, 11, 10),
  isOrganized: isOrganized,
  isArchived: isArchived,
  isFavorite: isFavorite,
  reviewJoined: reviewJoined,
  sliceKind: 'material',
  sliceText: '题',
);

CauseRecord _rec(
  String qid,
  String cause, {
  CauseStatus status = CauseStatus.pending,
  DateTime? recheckDate,
}) => CauseRecord(
  questionId: qid,
  cause: cause,
  subjectId: 'math',
  status: status,
  recheckDate: recheckDate,
  joinedAt: DateTime(2026, 11, 10),
);

class FakeWrongbookNotifierRepo extends QuestionRepository {
  FakeWrongbookNotifierRepo({this.throwOnLoad = false})
    : super(AppDatabase.instance);

  bool throwOnLoad;
  List<Subject> subjectsValue = [
    Subject.math.copyWith(coverColor: 'green'),
    Subject.english,
    Subject.politics,
  ];
  List<Question> questions = [
    _wbq('q1', folderIds: ['f1']),
    _wbq('q2', folderIds: ['f1'], createdAt: DateTime(2026, 11, 9)),
    _wbq(
      'q3',
      folderIds: ['f2'],
      createdAt: DateTime(2026, 11, 8),
      isFavorite: true,
    ),
    _wbq('q4', subjectId: 'english', folderIds: ['f3']),
    _wbq('q5', folderIds: ['f1'], isArchived: true),
    _wbq('q6', folderIds: ['f1'], isOrganized: false),
  ];
  List<Folder> folderList = [
    const Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 0),
    const Folder(id: 'f2', name: '平时作业', subjectId: 'math', sortOrder: 10),
    const Folder(id: 'f3', name: '试卷', subjectId: 'english', sortOrder: 0),
    const Folder(
      id: 'f1a',
      name: '期中',
      subjectId: 'math',
      parentId: 'f1',
      sortOrder: 0,
    ),
  ];
  List<Exam> examList = [];
  List<KnowledgePoint> kpList = [];
  List<String> tagList = ['易错'];
  List<CauseRecord> records = [
    _rec('q1', '概念不清'),
    _rec('q2', '概念不清', status: CauseStatus.solved),
    _rec('q3', '计算错误'),
  ];
  Map<String, (int, int, int)> counts = {
    'math': (2, 0, 0),
    'english': (1, 0, 0),
    'politics': (0, 0, 0),
  };
  AppSettings settingsValue = const AppSettings(
    wrongbookView: 'compact',
    pageSize: 20,
    wrongbookSort: 'old',
  );
  final List<Folder> savedFolders = [];
  final List<String> deletedFolderIds = [];

  /// 十九批 A3：内存版已存查找（不碰真实库）。
  final List<SavedSearch> savedSearchList = [];

  @override
  Future<List<SavedSearch>> savedSearches() async =>
      List.of(savedSearchList);

  @override
  Future<void> saveSavedSearch(SavedSearch search) async {
    savedSearchList.removeWhere((s) => s.id == search.id);
    savedSearchList.add(search);
  }

  @override
  Future<void> deleteSavedSearch(String id) async {
    savedSearchList.removeWhere((s) => s.id == id);
  }

  @override
  Future<bool> folderNameExistsInSubject(
    String subjectId,
    String name, {
    String? excludeId,
  }) async => folderList.any(
    (f) => f.subjectId == subjectId && f.name == name && f.id != excludeId,
  );

  @override
  Future<List<Subject>> subjects() async {
    if (throwOnLoad) throw StateError('boom');
    return List.of(subjectsValue);
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<Folder>> folders({String? subjectId}) async => subjectId == null
      ? List.of(folderList)
      : folderList.where((f) => f.subjectId == subjectId).toList();

  @override
  Future<List<Exam>> exams() async => List.of(examList);

  @override
  Future<List<String>> tags() async => List.of(tagList);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kpList);

  @override
  Future<Map<String, (int, int, int)>> subjectCounts({
    bool includeArchived = false,
  }) async => counts;

  @override
  Future<List<CauseRecord>> causeRecords() async => List.of(records);

  // P3 入口 1：池内标记（Fake 不碰真实数据库，默认空集）。
  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => const {};

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> save(Question question, {SaveToken? token}) async {
    final i = questions.indexWhere((e) => e.id == question.id);
    if (i >= 0) {
      questions[i] = question;
    } else {
      questions.add(question);
    }
  }

  @override
  Future<void> delete(Question question) async {
    questions.removeWhere((e) => e.id == question.id);
  }

  /// FR-37：整批删除（Fake 版按“整批”语义：先记下要删的 id，一次
  /// 从列表里去掉；`failBatchDelete` 为真时整批抛错、一道都不删，
  /// 与数据层“中途失败整批回滚”同口径）。
  bool failBatchDelete = false;
  final List<String> batchDeletedIds = [];

  @override
  Future<void> deleteQuestions(List<Question> questionsToDelete) async {
    if (failBatchDelete) throw StateError('模拟批量删题失败');
    batchDeletedIds.addAll(questionsToDelete.map((q) => q.id));
    final ids = questionsToDelete.map((q) => q.id).toSet();
    questions.removeWhere((e) => ids.contains(e.id));
  }

  @override
  Future<void> saveFolder(Folder folder) async {
    final i = folderList.indexWhere((e) => e.id == folder.id);
    if (i >= 0) {
      folderList[i] = folder;
    } else {
      folderList.add(folder);
    }
    savedFolders.add(folder);
  }

  @override
  Future<int> deleteFolder(Folder folder) async {
    folderList.removeWhere((e) => e.id == folder.id || e.parentId == folder.id);
    deletedFolderIds.add(folder.id);
    return 0;
  }

  @override
  Future<void> toggleFavorite(Question q) async {
    final i = questions.indexWhere((e) => e.id == q.id);
    if (i >= 0) {
      questions[i] = q.copyWith(isFavorite: !q.isFavorite);
    }
  }

  @override
  Future<void> archive(Question q, {bool archived = true}) async {
    final i = questions.indexWhere((e) => e.id == q.id);
    if (i >= 0) questions[i] = q.copyWith(isArchived: archived);
  }

  @override
  Future<void> addTag(String name) async {
    tagList.add(name);
  }

  @override
  Future<bool> setReviewJoined(Question q, bool joined) async {
    if (q.allCauses.isEmpty) return false;
    final i = questions.indexWhere((e) => e.id == q.id);
    if (i >= 0) questions[i] = q.copyWith(reviewJoined: joined);
    return true;
  }
}

Future<(FakeWrongbookNotifierRepo, WrongbookNotifier, ProviderContainer)>
_setUp({WrongbookInitial initial = const WrongbookInitial()}) async {
  final repo = FakeWrongbookNotifierRepo();
  final container = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      wrongbookInitialProvider.overrideWithValue(initial),
    ],
  );
  final notifier = container.read(wrongbookProvider.notifier);
  await notifier.load();
  return (repo, notifier, container);
}

void main() {
  test('首读：设置默认值只取一次（视图/排序/每页条数）', () async {
    final (_, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    final s = container.read(wrongbookProvider);
    expect(s.loading, isFalse);
    expect(s.loadError, isFalse);
    expect(s.subjects.length, 3);
    expect(s.questions.length, 6);
    // 设置默认值只在首次 _load() 时取。
    expect(s.viewMode, 'compact');
    expect(s.pageSize, 20);
    expect(s.sort, 'old');
    // 之后重读不再覆盖页内改过的值。
    notifier.setViewMode('large');
    notifier.setPageSize(10);
    notifier.setSort('new');
    await notifier.load();
    final s2 = container.read(wrongbookProvider);
    expect(s2.viewMode, 'large');
    expect(s2.pageSize, 10);
    expect(s2.sort, 'new');
  });

  test('读库失败：loadError，不一直 loading', () async {
    final repo = FakeWrongbookNotifierRepo(throwOnLoad: true);
    final container = ProviderContainer.test(
      overrides: [repositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(wrongbookProvider.notifier);
    await notifier.load();
    final s = container.read(wrongbookProvider);
    expect(s.loading, isFalse);
    expect(s.loadError, isTrue);
    expect(s.hasLoaded, isFalse);
    await notifier.retryLoad();
    expect(container.read(wrongbookProvider).loadError, isTrue);
  });

  // 二十三批 D-250：落点改回 2026-11-16 条件三档——带筛选
  //（错因 / 知识点 / 文件夹任一）→ 列表；只带学科 → 目录；
  //都不带 → 书架。十九批 A5“全部进 L1 列表”已废。
  test('初始落点三档：只带学科进目录、只带错因进列表、都不带进书架',
      () async {
    final (_, _, c1) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(c1.dispose);
    expect(c1.read(wrongbookProvider).view, WrongbookView.directory);
    expect(c1.read(wrongbookProvider).subjectId, 'math');

    final (_, _, c2) = await _setUp(
      initial: const WrongbookInitial(filterCause: '概念不清'),
    );
    addTearDown(c2.dispose);
    expect(c2.read(wrongbookProvider).view, WrongbookView.list);
    expect(c2.read(wrongbookProvider).filterCauseName, '概念不清');

    final (_, _, c3) = await _setUp();
    addTearDown(c3.dispose);
    expect(c3.read(wrongbookProvider).view, WrongbookView.shelf);
    expect(c3.read(wrongbookProvider).subjectId, isNull);
  });

  // 十九批 A（D-223）：详情页右栏「打开列表 ›」带文件夹 + 学科进来，
  // 落到按该文件夹筛选的列表（学科只定范围）；f1 里是 q1/q2
  //（q5 已归档、q6 未整理不进列表），f2 的 q3 不在。
  test('初始落点：带文件夹筛选进该文件夹的列表', () async {
    final (_, _, c) = await _setUp(
      initial: const WrongbookInitial(
        subjectId: 'math',
        filterFolderId: 'f1',
      ),
    );
    addTearDown(c.dispose);
    final s = c.read(wrongbookProvider);
    expect(s.view, WrongbookView.list);
    expect(s.subjectId, 'math');
    expect(s.folderId, 'f1');
    final ids = s.filteredAll().map((q) => q.id).toSet();
    // f1 里 q1 在、q2 已掌握默认隐藏、q5 已归档、q6 未整理；
    // f2 的 q3 不在。
    expect(ids, contains('q1'));
    expect(ids, isNot(contains('q2')));
    expect(ids, isNot(contains('q3')));
  });

  test('列表过滤：已掌握默认隐藏，筛已解决才出现；归档/未整理不进列表', () async {
    final (_, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(container.dispose);
    // q2 错因全部已解决 → 已掌握，默认隐藏；q5 已归档、q6 未整理不进。
    notifier.openList(subjectId: 'math', folderId: null);
    var ids = container.read(wrongbookProvider).filteredAll().map((q) => q.id);
    expect(ids, containsAll(['q1', 'q3']));
    expect(ids, isNot(contains('q2')));
    expect(ids, isNot(contains('q5')));
    expect(ids, isNot(contains('q6')));
    notifier.setFilterCauseStatus('solved');
    ids = container.read(wrongbookProvider).filteredAll().map((q) => q.id);
    expect(ids, contains('q2'));
  });

  // 十九批 A3（D-218）：保存查找的增删应用（notifier 层）。
  test('保存查找：空名拦下；保存后进列表与仓库；删除后两边都清', () async {
    final (repo, notifier, c) = await _setUp();
    addTearDown(c.dispose);
    expect(await notifier.saveCurrentSearch('  '), '先给这次查找起个名字');
    expect(c.read(wrongbookProvider).savedSearches, isEmpty);
    notifier.applySearchConditions(const {'cause': '概念不清'});
    expect(await notifier.saveCurrentSearch('概念不清题'), isNull);
    final saved = c.read(wrongbookProvider).savedSearches;
    expect(saved.map((s) => s.name), ['概念不清题']);
    expect(saved.first.conditions['cause'], '概念不清');
    expect(repo.savedSearchList.map((s) => s.name), ['概念不清题']);
    await notifier.deleteSavedSearch(saved.first.id);
    expect(c.read(wrongbookProvider).savedSearches, isEmpty);
    expect(repo.savedSearchList, isEmpty);
  });

  test('保存查找：chip 点按应用条件；最近搜过只记非空、去重、上限 4', () async {
    final (_, notifier, c) = await _setUp();
    addTearDown(c.dispose);
    notifier.applySavedSearch(
      SavedSearch(
        id: 'ss1',
        name: '概念不清题',
        conditions: const {'cause': '概念不清'},
        createdAt: DateTime(2026, 11, 19),
      ),
    );
    var s = c.read(wrongbookProvider);
    expect(s.filterCauseName, '概念不清');
    expect(s.filteredAll().map((q) => q.id), contains('q1'));
    expect(s.recentSearches.map((r) => r.name), ['概念不清题']);
    // 空条件不记；同 label 同条件去重顶到最前；超过 4 条只留最新 4 条。
    notifier.recordRecentSearch('全部题目', const {});
    expect(c.read(wrongbookProvider).recentSearches.length, 1);
    for (var i = 0; i < 5; i++) {
      notifier.recordRecentSearch('搜$i', {
        'cause': '错因$i',
      });
    }
    s = c.read(wrongbookProvider);
    expect(s.recentSearches.length, 4);
    expect(s.recentSearches.first.name, '搜4');
    expect(s.recentSearches.map((r) => r.name), isNot(contains('概念不清题')));
  });

  test('文件夹范围：子树收题；目录计数只收已整理未归档未掌握', () async {
    final (_, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(container.dispose);
    notifier.openList(subjectId: 'math', folderId: 'f1');
    final ids = container
        .read(wrongbookProvider)
        .filteredAll()
        .map((q) => q.id);
    // f1 子树含 f1a；q1 在 f1，q2 在 f1 但已掌握默认隐藏。
    expect(ids, contains('q1'));
    expect(ids, isNot(contains('q3')));
    expect(container.read(wrongbookProvider).folderCount('f1'), 1);
    expect(container.read(wrongbookProvider).folderCount('f2'), 1);
  });

  test('筛选变化：回第 1 页，勾选只保留仍在结果里的题', () async {
    final (_, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(container.dispose);
    notifier.openList(subjectId: 'math', folderId: null);
    notifier.update((s) => s.copyWith(selected: {'q1', 'q3'}));
    notifier.toggleFilterFavorite();
    final s = container.read(wrongbookProvider);
    expect(s.page, 0);
    // 仅收藏 → 只剩 q3，q1 的勾选被清掉。
    expect(s.selected, {'q3'});
    expect(s.activeFilterCount(), 1);
  });

  test('重置：清搜索与筛选，排序固定回时间新→旧', () async {
    final (_, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(container.dispose);
    notifier.openList(subjectId: 'math', folderId: null);
    notifier.setSearch('试卷');
    notifier.setFilterCauseStatus('pending');
    notifier.resetFilters();
    final s = container.read(wrongbookProvider);
    expect(s.search, '');
    expect(s.filterCauseStatus, 'all');
    expect(s.sort, 'new');
    expect(s.activeFilterCount(), 0);
  });

  test('导航：目录/列表/书架切换清筛选，排序保留', () async {
    final (_, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    notifier.setSort('subj-asc');
    notifier.openDirectory('math');
    var s = container.read(wrongbookProvider);
    expect(s.view, WrongbookView.directory);
    expect(s.sort, 'subj-asc');
    notifier.openList(subjectId: 'math', folderId: 'f1');
    s = container.read(wrongbookProvider);
    expect(s.view, WrongbookView.list);
    expect(s.folderId, 'f1');
    notifier.openShelf();
    s = container.read(wrongbookProvider);
    expect(s.view, WrongbookView.shelf);
    expect(s.subjectId, isNull);
  });

  test('新增文件夹：空名/重名提示，成功入库', () async {
    final (repo, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(container.dispose);
    expect(await notifier.addFolder(name: ''), '先写文件夹名称');
    expect(await notifier.addFolder(name: '试卷'), '已经有了这个文件夹');
    expect(await notifier.addFolder(name: '错题集'), isNull);
    expect(repo.folderList.any((f) => f.name == '错题集'), isTrue);
    expect(container.read(wrongbookProvider).folders.length, 5);
  });

  test('移动禁则：不能移到自己下面；带子文件夹的一级不能再进别的文件夹', () async {
    final (repo, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(container.dispose);
    final s = container.read(wrongbookProvider);
    final f1 = s.folders.firstWhere((f) => f.id == 'f1');
    final f1a = s.folders.firstWhere((f) => f.id == 'f1a');
    expect(await notifier.moveOneFolder(f1a, 'f1a'), '不能移到自己下面');
    expect(await notifier.moveOneFolder(f1a, 'f1'), '已经在那里了');
    // f1 下面有子文件夹 f1a，不能再放进别的文件夹里。
    expect(await notifier.moveOneFolder(f1, 'f2'), contains('只留一层'));
    // 子文件夹只能有一层：f1a 移到 f2（顶层）可以。
    // moveOneFolder 本身不重读（与原来一致，重读在调用方），断言 FakeRepo。
    expect(await notifier.moveOneFolder(f1a, 'f2'), isNull);
    expect(repo.folderList.firstWhere((f) => f.id == 'f1a').parentId, 'f2');
  });

  test('批量加标签：勾选题加标签；新建标签含逗号拦下', () async {
    final (repo, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(container.dispose);
    notifier.openList(subjectId: 'math', folderId: null);
    notifier.update((s) => s.copyWith(selected: {'q1', 'q3'}));
    final bad = await notifier.batchAddTag(picked: {}, newName: 'a,b');
    expect(bad, '不能含逗号或竖线');
    final msg = await notifier.batchAddTag(picked: {'易错'});
    expect(msg, contains('已加标签 2 道'));
    expect(repo.questions.firstWhere((q) => q.id == 'q1').tags, ['易错']);
    expect(container.read(wrongbookProvider).selected, isEmpty);
  });

  test('批量加入复习：只加未解决错因，汇总含开始复习入口', () async {
    final (repo, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(container.dispose);
    notifier.openList(subjectId: 'math', folderId: null);
    notifier.update((s) => s.copyWith(selected: {'q1', 'q2', 'q3'}));
    // q1 待解决、q3 待解决可加入；q2 已解决跳过。
    final r = await notifier.batchJoinReviewSelected();
    expect(r.message, contains('已加入复习 2 道'));
    expect(r.message, contains('1 道已无未解决错因，跳过'));
    expect(r.showReviewAction, isTrue);
    expect(repo.questions.firstWhere((q) => q.id == 'q1').reviewJoined, isTrue);
    expect(
      repo.questions.firstWhere((q) => q.id == 'q2').reviewJoined,
      isFalse,
    );
  });

  test('批量全选切换 + 收藏/归档/删除汇总', () async {
    final (_, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(container.dispose);
    notifier.openList(subjectId: 'math', folderId: null);
    final all = container.read(wrongbookProvider).filteredAll();
    notifier.toggleSelectAll(all);
    expect(
      container.read(wrongbookProvider).selected,
      all.map((q) => q.id).toSet(),
    );
    notifier.toggleSelectAll(all);
    expect(container.read(wrongbookProvider).selected, isEmpty);
    notifier.update((s) => s.copyWith(selected: {'q1'}));
    expect(await notifier.batchFavorite(), contains('已收藏 1 道'));
    expect(
      container
          .read(wrongbookProvider)
          .questions
          .firstWhere((q) => q.id == 'q1')
          .isFavorite,
      isTrue,
    );
    notifier.update((s) => s.copyWith(selected: {'q1'}));
    expect(await notifier.batchArchive(), contains('已归档 1 道'));
    notifier.update((s) => s.copyWith(selected: {'q3'}));
    expect(await notifier.batchDeleteConfirmed(), contains('已删除 1 道'));
    expect(
      container.read(wrongbookProvider).questions.any((q) => q.id == 'q3'),
      isFalse,
    );
  });

  test('文件夹改名与删除：重名拦下，删除后重读', () async {
    final (_, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math'),
    );
    addTearDown(container.dispose);
    final s = container.read(wrongbookProvider);
    final f2 = s.folders.firstWhere((f) => f.id == 'f2');
    expect(await notifier.saveRename(f2, '试卷'), '已经有了这个文件夹');
    expect(await notifier.saveRename(f2, '周末作业'), isNull);
    expect(
      container
          .read(wrongbookProvider)
          .folders
          .firstWhere((f) => f.id == 'f2')
          .name,
      '周末作业',
    );
    await notifier.deleteFolderConfirmed(f2);
    expect(
      container.read(wrongbookProvider).folders.any((f) => f.id == 'f2'),
      isFalse,
    );
  });

  // ---------- D-50：报告深链路直达已筛选列表 ----------

  test('D-50 深链路：学科 + 错因直达已筛选列表', () async {
    final repo = FakeWrongbookNotifierRepo();
    repo.questions = [
      _wbq('m1', errorTypes: const ['概念不清']),
      _wbq('m2', errorTypes: const ['计算错误'], createdAt: DateTime(2026, 11, 9)),
      _wbq('m3', subjectId: 'english', errorTypes: const ['概念不清']),
    ];
    final container = ProviderContainer.test(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        wrongbookInitialProvider.overrideWithValue(
          const WrongbookInitial(subjectId: 'math', filterCause: '概念不清'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(wrongbookProvider.notifier);
    await notifier.load();
    final s = container.read(wrongbookProvider);
    expect(s.view, WrongbookView.list);
    expect(s.subjectId, 'math');
    expect(s.filterCauseName, '概念不清');
    // 只筛出数学的“概念不清”：m2 错因不对，m3 学科不对。
    expect(s.filteredAll().map((q) => q.id).toList(), ['m1']);
  });

  test('D-50 深链路：学科 + 知识点直达已筛选列表', () async {
    final repo = FakeWrongbookNotifierRepo();
    repo.questions = [
      _wbq('m1').copyWith(knowledgePointIds: const ['kp-math-limit']),
      _wbq(
        'm2',
        errorTypes: const ['计算错误'],
        createdAt: DateTime(2026, 11, 9),
      ).copyWith(knowledgePointIds: const ['kp-math-derivative']),
    ];
    final container = ProviderContainer.test(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        wrongbookInitialProvider.overrideWithValue(
          const WrongbookInitial(
            subjectId: 'math',
            filterKnowledgePointId: 'kp-math-limit',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(wrongbookProvider.notifier);
    await notifier.load();
    final s = container.read(wrongbookProvider);
    expect(s.view, WrongbookView.list);
    expect(s.subjectId, 'math');
    expect(s.filterKpIds, {'kp-math-limit'});
    expect(s.filteredAll().map((q) => q.id).toList(), ['m1']);
  });

  test('D-50 正常入口：目录进列表仍清筛选', () async {
    final (_, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math', filterCause: '概念不清'),
    );
    addTearDown(container.dispose);
    expect(container.read(wrongbookProvider).view, WrongbookView.list);
    expect(container.read(wrongbookProvider).filterCauseName, '概念不清');
    // 从目录进列表（SR-P2-44）：范围变化清筛选。
    notifier.openList(subjectId: 'math', folderId: 'f1');
    final s = container.read(wrongbookProvider);
    expect(s.view, WrongbookView.list);
    expect(s.filterCauseName, isNull);
    expect(s.filterKpIds, isEmpty);
  });

  test('D-50 重置行为不变', () async {
    final (_, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math', filterCause: '概念不清'),
    );
    addTearDown(container.dispose);
    notifier.setSearch('极限');
    notifier.setSort('old');
    notifier.resetFilters();
    final s = container.read(wrongbookProvider);
    expect(s.search, '');
    expect(s.filterCauseName, isNull);
    expect(s.sort, 'new');
  });

  test('D-50 挂载后 override 再变不影响当前页（initial 只在挂载时读一次）', () async {
    final (repo, notifier, container) = await _setUp(
      initial: const WrongbookInitial(subjectId: 'math', filterCause: '概念不清'),
    );
    addTearDown(container.dispose);
    final s1 = container.read(wrongbookProvider);
    expect(s1.loading, isFalse);
    expect(s1.view, WrongbookView.list);
    // 改一个会话字段，再让外壳重建（每次 build 都新建 initial 实例）。
    notifier.setSort('old');
    // 值相等的新实例：有 `==` 时 Riverpod 认为值没变（与
    // DetailInitial / ReviewInitial 同款）；即使没有 `==`，已挂载的
    // notifier 也不重建——initial 只在挂载时读一次。
    container.updateOverrides([
      repositoryProvider.overrideWithValue(repo),
      wrongbookInitialProvider.overrideWithValue(
        const WrongbookInitial(subjectId: 'math', filterCause: '概念不清'),
      ),
    ]);
    final s2 = container.read(wrongbookProvider);
    expect(s2.view, WrongbookView.list);
    expect(s2.sort, 'old');
    expect(s2.filterCauseName, '概念不清');
    // 值变了也不影响当前页：残留参数只在下一次全新挂载时才被读到，
    // 而 _go 会在普通导航时先清掉（见 lib/app.dart D-50）。
    container.updateOverrides([
      repositoryProvider.overrideWithValue(repo),
      wrongbookInitialProvider.overrideWithValue(const WrongbookInitial()),
    ]);
    final s3 = container.read(wrongbookProvider);
    expect(s3.view, WrongbookView.list);
    expect(s3.sort, 'old');
    expect(s3.filterCauseName, '概念不清');
  });

  test('FR-08：错题本学科首字母按拼音表算，化学 H；生物排在数学前', () {
    final st = WrongbookState(
      subjects: [
        Subject.math,
        Subject(id: 'chem', name: '化学', color: Subject.math.color, icon: '化'),
        Subject(id: 'bio', name: '生物', color: Subject.math.color, icon: '生'),
      ],
    );
    expect(st.subjectInitial('chem'), 'H');
    expect(st.subjectInitial('math'), 'S');
    expect(st.subjectPinyinKey('bio'), 'SW');
    expect(
      st.subjectKeyCompare(
        _wbq('qb', subjectId: 'bio'),
        _wbq('qm', subjectId: 'math'),
      ),
      lessThan(0),
    );
    expect(
      st.subjectKeyCompare(
        _wbq('qc', subjectId: 'chem'),
        _wbq('qm', subjectId: 'math'),
      ),
      lessThan(0),
    );
  });

  group('FR-37 错题本批量删除：整批一个事务', () {
    test('全部成功：一次调 deleteQuestions，报“已删除 2 道”，两道全删', () async {
      final (repo, notifier, container) = await _setUp(
        initial: const WrongbookInitial(subjectId: 'math'),
      );
      addTearDown(container.dispose);
      notifier.openList(subjectId: 'math', folderId: null);
      notifier.update((s) => s.copyWith(selected: {'q1', 'q3'}));
      final msg = await notifier.batchDeleteConfirmed();
      expect(msg, contains('已删除 2 道'));
      expect(repo.batchDeletedIds, ['q1', 'q3']);
      expect(
        container.read(wrongbookProvider).questions.any((q) => q.id == 'q1'),
        isFalse,
      );
      expect(
        container.read(wrongbookProvider).questions.any((q) => q.id == 'q3'),
        isFalse,
      );
      expect(container.read(wrongbookProvider).selected, isEmpty);
    });

    test('整批失败：一道都不删，报“2 道保存失败”，选中的题全在库里', () async {
      final (repo, notifier, container) = await _setUp(
        initial: const WrongbookInitial(subjectId: 'math'),
      );
      addTearDown(container.dispose);
      repo.failBatchDelete = true;
      notifier.openList(subjectId: 'math', folderId: null);
      notifier.update((s) => s.copyWith(selected: {'q1', 'q3'}));
      final msg = await notifier.batchDeleteConfirmed();
      expect(msg, contains('2 道保存失败'));
      expect(repo.batchDeletedIds, isEmpty);
      expect(repo.questions.any((q) => q.id == 'q1'), isTrue);
      expect(repo.questions.any((q) => q.id == 'q3'), isTrue);
    });

    test('选中含已不在列表的 id：missing 计 1，其余照常删', () async {
      final (repo, notifier, container) = await _setUp(
        initial: const WrongbookInitial(subjectId: 'math'),
      );
      addTearDown(container.dispose);
      notifier.openList(subjectId: 'math', folderId: null);
      notifier.update((s) => s.copyWith(selected: {'q1', 'qx'}));
      final msg = await notifier.batchDeleteConfirmed();
      expect(msg, contains('已删除 1 道'));
      expect(msg, contains('1 道已不在列表里，跳过'));
      expect(repo.batchDeletedIds, ['q1']);
    });
  });
}
