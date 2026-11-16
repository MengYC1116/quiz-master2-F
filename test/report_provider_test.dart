// ARCH-PLAN-A 第 2 阶段 A 路：ReportNotifier 单测（不启动 widget）。
// 注入方式与 settings_controller_test.dart 一致：ProviderContainer.test
// + repositoryProvider.overrideWithValue(FakeRepo)。
// 夹具口径与 report_page_test.dart 的默认库一致（日期一律相对今天取）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/report_provider.dart';
import 'package:quiz_master2/state/repository_provider.dart';

DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

Question _tq(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> errorTypes = const [],
  List<String> knowledgePointIds = const [],
  DateTime? createdAt,
  bool isOrganized = true,
  bool isArchived = false,
}) =>
    Question(
      id: id,
      title: title,
      subjectId: subjectId,
      errorTypes: errorTypes,
      knowledgePointIds: knowledgePointIds,
      createdAt: createdAt ?? _today,
      isOrganized: isOrganized,
      isArchived: isArchived,
      reviewJoined: true,
      sliceKind: 'material',
      sliceText: '题：$title',
    );

CauseRecord _trec(
  String questionId,
  String cause, {
  String subjectId = 'math',
  CauseStatus status = CauseStatus.pending,
  int solvedCount = 0,
  DateTime? lastCheck,
  DateTime? joinedAt,
}) =>
    CauseRecord(
      questionId: questionId,
      cause: cause,
      subjectId: subjectId,
      status: status,
      solvedCount: solvedCount,
      lastCheck: lastCheck,
      joinedAt: joinedAt ?? _today,
    );

KnowledgePoint _tkp(String id, String subjectId, String chapter, String name) =>
    KnowledgePoint(id: id, subjectId: subjectId, chapter: chapter, name: name);

class FakeReportRepo extends QuestionRepository {
  FakeReportRepo({
    required this.questions,
    required this.records,
    required this.kps,
    this.history = const {},
    this.throwOnLoad = false,
    List<Subject>? subjects,
  })  : subjectsValue = subjects ?? Subject.all,
        super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  List<KnowledgePoint> kps;
  Map<String, List<({String result, DateTime reviewedAt})>> history;
  bool throwOnLoad;
  List<Subject> subjectsValue;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsValue);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async {
    if (throwOnLoad) throw StateError('db down');
    return List.of(questions);
  }

  @override
  Future<List<CauseRecord>> causeRecords() async {
    if (throwOnLoad) throw StateError('db down');
    return List.of(records);
  }

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kps);

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<List<({String result, DateTime reviewedAt})>> reviewHistory(
          String questionId) async =>
      List.of(history[questionId] ?? const []);
}

/// 与 report_page_test.dart 的默认库同一份数据：本周 8 道题
///（q-old 是 40 天前的题，只在“全部”里出现）。
FakeReportRepo _defaultRepo({bool withHistory = true}) {
  final today = _today;
  final questions = [
    _tq('q1', '函数极限', errorTypes: ['概念不清'],
        knowledgePointIds: ['kp-limit']),
    _tq('q2', '导数应用', errorTypes: ['方法不会'],
        knowledgePointIds: ['kp-derivative']),
    _tq('q3', '定积分', errorTypes: ['计算错误'],
        knowledgePointIds: ['kp-integral']),
    _tq('q4', '学术词汇', subjectId: 'english', errorTypes: ['概念不清'],
        knowledgePointIds: ['kp-vocab']),
    _tq('q5', '长篇阅读', subjectId: 'english', errorTypes: ['审题失误'],
        knowledgePointIds: ['kp-reading']),
    _tq('q6', '史纲时间轴', subjectId: 'politics', errorTypes: ['审题失误'],
        knowledgePointIds: ['kp-history']),
    _tq('q7', '马原', subjectId: 'politics', errorTypes: ['概念不清'],
        knowledgePointIds: ['kp-marx']),
    _tq('q8', '材料分析', subjectId: 'politics', errorTypes: ['方法不会'],
        knowledgePointIds: ['kp-marx']),
    _tq('q-old', '旧题', errorTypes: ['概念不清'],
        knowledgePointIds: ['kp-limit'],
        createdAt: today.subtract(const Duration(days: 40))),
  ];
  final records = [
    _trec('q1', '概念不清'),
    _trec('q2', '方法不会'),
    _trec('q3', '计算错误',
        status: CauseStatus.inProgress, solvedCount: 1, lastCheck: today),
    _trec('q4', '概念不清',
        subjectId: 'english',
        status: CauseStatus.solved,
        solvedCount: 2,
        lastCheck: today),
    _trec('q-old', '概念不清', joinedAt: today.subtract(const Duration(days: 40))),
  ];
  final kps = [
    _tkp('kp-limit', 'math', '函数与极限', '函数极限'),
    _tkp('kp-derivative', 'math', '导数与微分', '导数应用'),
    _tkp('kp-integral', 'math', '定积分', '定积分应用'),
    _tkp('kp-vocab', 'english', '词汇', '学术词汇'),
    _tkp('kp-reading', 'english', '阅读', '长篇阅读'),
    _tkp('kp-history', 'politics', '史纲', '时间轴'),
    _tkp('kp-marx', 'politics', '马原', '矛盾观'),
  ];
  final history = withHistory
      ? {
          'q4': [
            (result: 'solved', reviewedAt: today),
            (result: 'solved', reviewedAt: today),
            (result: 'unsolved', reviewedAt: today),
          ],
        }
      : <String, List<({String result, DateTime reviewedAt})>>{};
  return FakeReportRepo(
    questions: questions,
    records: records,
    kps: kps,
    history: history,
  );
}

ProviderContainer _container(FakeReportRepo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  return container;
}

/// 等 build 触发的首查跑完（只读 state、不调 load() 的用例用）。
Future<void> _waitLoaded(ProviderContainer container) async {
  for (var i = 0; i < 100 && container.read(reportProvider).loading; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('ReportNotifier', () {
    test('load()：已解决 1 · 待解决 4 · 复查通过率 67%', () async {
      final container = _container(_defaultRepo());
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.loading, isFalse);
      expect(s.loadError, isFalse);
      expect(s.solvedCount, 1);
      expect(s.pendingCount, 4);
      expect(s.judgedHistory.length, 3);
      expect(s.judgedPassed, 2);
      expect(s.passRate, 67);
      expect(s.nextSentence, '先解决数学的方法不会。');
    });

    test('build() 触发首查：只读 state 也能等到加载完成', () async {
      final container = _container(_defaultRepo());
      // autoDispose 的 Provider 无监听者时会被销毁：像页面 ref.watch 那样
      // 持一个监听保活，否则 build 里的 microtask 首查还没写回就被丢掉。
      container.listen(reportProvider, (_, __) {});
      container.read(reportProvider);
      await _waitLoaded(container);
      expect(container.read(reportProvider).loading, isFalse);
      expect(container.read(reportProvider).solvedCount, 1);
    });

    test('无复查记录时通过率为 null', () async {
      final container = _container(_defaultRepo(withHistory: false));
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.passRate, isNull);
      expect(s.judgedHistory, isEmpty);
    });

    test('弱点：原因组 7 个、知识点组 6 个，矛盾观 2 道排第一', () async {
      final container = _container(_defaultRepo());
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.causeGroups.length, 7);
      expect(s.kpGroups.length, 6);
      expect(s.kpGroups.first.key, 'kp-marx');
      expect(s.kpGroups.first.count, 2);
      // 英语的概念不清已解决，不进原因组。
      expect(
        s.causeGroups.where(
          (g) => g.subjectId == 'english' && g.key == '概念不清',
        ),
        isEmpty,
      );
    });

    test('分布只按学科、扣已掌握：本周数学 3 · 英语 1 · 政治 3', () async {
      final container = _container(_defaultRepo());
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      final qsIn = s.questionsInRange;
      expect(qsIn.where((q) => q.subjectId == 'math').length, 3);
      expect(qsIn.where((q) => q.subjectId == 'english').length, 1);
      expect(qsIn.where((q) => q.subjectId == 'politics').length, 3);
    });

    test('SR-P1-11：未整理题与已归档题不进弱点与分布', () async {
      final repo = FakeReportRepo(
        questions: [
          _tq('q1', '已整理题', errorTypes: ['概念不清'],
              knowledgePointIds: ['kp-limit']),
          _tq('q2', '未整理题', errorTypes: ['概念不清'],
              knowledgePointIds: ['kp-limit'], isOrganized: false),
          _tq('q3', '已归档题', errorTypes: ['概念不清'],
              knowledgePointIds: ['kp-limit'], isArchived: true),
        ],
        records: [_trec('q1', '概念不清')],
        kps: [_tkp('kp-limit', 'math', '函数与极限', '函数极限')],
      );
      final container = _container(repo);
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.questionsInRange.length, 1);
      expect(s.causeGroups.single.count, 1);
      expect(s.kpGroups.single.count, 1);
    });

    test('setRange：切到“全部”旧题进来，数学分布变 4 道，不重读库', () async {
      final container = _container(_defaultRepo());
      final notifier = container.read(reportProvider.notifier);
      await notifier.load();
      var s = container.read(reportProvider);
      expect(s.range, 'week');
      expect(s.questionsInRange.length, 7);
      expect(s.records.length, 5);
      notifier.setRange('all');
      s = container.read(reportProvider);
      expect(s.range, 'all');
      expect(s.questionsInRange.length, 8);
      expect(
        s.questionsInRange.where((q) => q.subjectId == 'math').length,
        4,
      );
      // 切范围只重算派生值：读库数据本身没变。
      expect(s.records.length, 5);
      expect(s.rangeNote, '全部时间 · 数字按这个时间段算');
    });

    test('待解决按范围过滤（S8 B1）：本周 2 · 全部 3，已解决恒为 1', () async {
      final today = _today;
      final questions = [
        _tq('qA', '题 A', errorTypes: ['概念不清']),
        _tq('qB', '题 B', errorTypes: ['方法不会']),
        _tq('qC', '题 C', errorTypes: ['计算错误']),
        _tq('qD', '题 D', errorTypes: ['审题失误']),
        _tq('qE', '题 E', errorTypes: ['概念不清']),
      ];
      final records = [
        _trec('qA', '概念不清', lastCheck: today),
        _trec('qC', '计算错误',
            lastCheck: today.subtract(const Duration(days: 40))),
        _trec('qD', '审题失误'),
        _trec('qE', '概念不清',
            status: CauseStatus.solved, solvedCount: 2, lastCheck: today),
      ];
      final container = _container(
        FakeReportRepo(questions: questions, records: records, kps: []),
      );
      final notifier = container.read(reportProvider.notifier);
      await notifier.load();
      expect(container.read(reportProvider).pendingCount, 2);
      expect(container.read(reportProvider).solvedCount, 1);
      notifier.setRange('all');
      expect(container.read(reportProvider).pendingCount, 3);
      expect(container.read(reportProvider).solvedCount, 1);
    });

    test('读库失败：loadError，旧内容留住；重读成功后恢复', () async {
      final repo = _defaultRepo()..throwOnLoad = true;
      final container = _container(repo);
      final notifier = container.read(reportProvider.notifier);
      await notifier.load();
      var s = container.read(reportProvider);
      expect(s.loading, isFalse);
      expect(s.loadError, isTrue);
      expect(s.records, isEmpty);
      repo.throwOnLoad = false;
      await notifier.load();
      s = container.read(reportProvider);
      expect(s.loadError, isFalse);
      expect(s.records.length, 5);
      expect(s.solvedCount, 1);
    });

    test('没有任何记录：nextSentence 为无待解决错因那句', () async {
      final container = _container(
        FakeReportRepo(questions: [], records: [], kps: []),
      );
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.records, isEmpty);
      expect(s.causeGroups, isEmpty);
      expect(s.nextSentence, '这段时间没有待解决的错因，先去复习页把到期的复查做完。');
    });
  });
}
