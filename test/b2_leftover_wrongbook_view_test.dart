// B2 leftover → 十九批 A1（D-219）：视图切换（大卡片 / 紧凑列表）已
// 去掉，只剩板子一种行设计；但 AppSettings.wrongbookView 与 load()
// 的“首次才取设置默认值”守门（R4）仍在——本文件改写为状态层测试：
// setViewMode 后再 load() 不弹回设置默认值；全新 notifier 重新读
// 设置默认值。旧的 widget 层切换断言（点「大卡片」「紧凑列表」）
// 随切换入口一起删除（入口已不存在）。
// 用独立 FakeRepo（不碰真实数据库），只覆盖本文件用到的 repository 调用。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/wrongbook_notifier.dart';

Question _q(
  String id,
  String title, {
  List<String> errorTypes = const [],
  DateTime? createdAt,
  bool isFavorite = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: 'math',
      folderIds: const ['f1'],
      errorTypes: errorTypes,
      sliceKind: 'limit',
      sliceText: '题：求极限',
      createdAt: createdAt ?? DateTime.now().subtract(const Duration(days: 2)),
      isOrganized: true,
      isFavorite: isFavorite,
    );

class FakeViewRepo extends QuestionRepository {
  FakeViewRepo({this.settingsValue = const AppSettings()})
      : questions = [
          _q('q1', '函数极限',
              errorTypes: const ['概念不清'],
              createdAt: DateTime.now().subtract(const Duration(days: 2)),
              isFavorite: true),
          _q('q2', '导数综合',
              errorTypes: const ['方法不会'],
              createdAt: DateTime.now().subtract(const Duration(days: 10))),
          _q('q3', '定积分',
              errorTypes: const ['计算错误'],
              createdAt: DateTime.now().subtract(const Duration(days: 5))),
        ],
        super(AppDatabase.instance);

  AppSettings settingsValue;
  List<Question> questions;

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
  Future<List<Subject>> subjects() async =>
      [Subject.math, Subject.english, Subject.politics];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

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

  // 2026-11-25 口径迁移 §2.1/§4：load() 封面到期数走这里（同款 D-225：
  // 不覆写会走真实库、页面卡 loading、pumpAndSettle 超时）。
  @override
  Future<Map<String, int>> fsrsDueCountsBySubject({
    required ReviewScheduler scheduler,
    DateTime? now,
  }) async => const {};

  // FSRS 全量迁移包 4：load() 读下次到期表（同款 D-225：不覆写
  // 会走真实库）。
  @override
  Future<Map<String, DateTime>> fsrsNextDueByQuestion({
    required ReviewScheduler scheduler,
  }) async => const {};

  @override
  Future<List<CauseRecord>> causeRecords() async => [];

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> save(Question question, {SaveToken? token}) async {
    final i = questions.indexWhere((x) => x.id == question.id);
    if (i >= 0) questions[i] = question;
  }

  @override
  Future<void> toggleFavorite(Question q) async {
    await save(q.copyWith(isFavorite: !q.isFavorite));
  }
}

Future<(FakeViewRepo, WrongbookNotifier, ProviderContainer)> _setUp({
  AppSettings settings = const AppSettings(),
}) async {
  final repo = FakeViewRepo(settingsValue: settings);
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  final notifier = container.read(wrongbookProvider.notifier);
  await notifier.load();
  return (repo, notifier, container);
}

void main() {
  group('B2 leftover：viewMode 跨 load() 保留（状态层）', () {
    test('首次 load 取设置默认值：默认 large；设置 compact 则 compact', () async {
      final (_, _, c1) = await _setUp();
      addTearDown(c1.dispose);
      expect(c1.read(wrongbookProvider).viewMode, 'large');

      final (_, _, c2) = await _setUp(
        settings: const AppSettings(wrongbookView: 'compact'),
      );
      addTearDown(c2.dispose);
      expect(c2.read(wrongbookProvider).viewMode, 'compact');
    });

    test('setViewMode 后再 load，不弹回设置默认值（双向）', () async {
      final (_, notifier, c) = await _setUp();
      addTearDown(c.dispose);
      expect(c.read(wrongbookProvider).viewMode, 'large');
      // 模拟“从详情返回 / 点星 / 批量操作后刷新”：load() 再跑一次。
      notifier.setViewMode('compact');
      await notifier.load();
      expect(c.read(wrongbookProvider).viewMode, 'compact');
      notifier.setViewMode('large');
      await notifier.load();
      expect(c.read(wrongbookProvider).viewMode, 'large');
    });

    test('全新 notifier 重新读设置默认值', () async {
      final (_, _, c1) = await _setUp(
        settings: const AppSettings(wrongbookView: 'compact'),
      );
      addTearDown(c1.dispose);
      expect(c1.read(wrongbookProvider).viewMode, 'compact');
      final (_, _, c2) = await _setUp();
      addTearDown(c2.dispose);
      expect(c2.read(wrongbookProvider).viewMode, 'large');
    });
  });
}
