// ARCH-PLAN-A 第 2 阶段 A 路：ReportNotifier 单测（不启动 widget）。
// 注入方式与 settings_controller_test.dart 一致：ProviderContainer.test
// + repositoryProvider.overrideWithValue(FakeRepo)。
// 夹具口径与 report_page_test.dart 的默认库一致（日期一律相对今天取）。
// FSRS 口径迁移（Meng 2026-11-25 定）：三个核心数、两组 Top 5、分布
// 全部按 attempts / 题目集合新定义重写断言；weakStats 不变，只做回归。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_engine.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/report_provider.dart';
import 'package:quiz_master2/state/repository_provider.dart';

DateTime get _today {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

int get _nowMs => _today.millisecondsSinceEpoch;

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

AttemptData _att(
  String qid,
  String mode,
  int? correct,
  int createdAtMs, {
  List<String> causeIds = const [],
  String sessionId = 'sess-1',
}) =>
    AttemptData(
      id: 'att-$qid-$createdAtMs-$correct-$sessionId',
      questionId: qid,
      sessionId: sessionId,
      mode: mode,
      correct: correct,
      answerVersion: 1,
      contentVersion: 0,
      status: '已提交',
      causeIds: causeIds,
      submissionId: 'sub-$qid-$createdAtMs-$correct-$sessionId',
      createdAt: createdAtMs,
    );

class FakeReportRepo extends QuestionRepository {
  FakeReportRepo({
    required this.questions,
    required this.records,
    required this.kps,
    this.attemptsValue = const [],
    this.throwOnLoad = false,
    List<Subject>? subjects,
  })  : subjectsValue = subjects ?? Subject.all,
        super(AppDatabase.instance);

  List<Question> questions;
  List<CauseRecord> records;
  List<KnowledgePoint> kps;
  List<AttemptData> attemptsValue;
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
  Future<List<AttemptData>> loadAllAttempts() async =>
      List.of(attemptsValue);

  @override
  Future<Set<String>> fsrsPoolQuestionIds() async => const {};

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kps);

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;
}

/// 与 report_page_test.dart 的默认库同一份数据：本周 8 道题
///（q-old 是 40 天前的题，只在“全部”里出现）。
///
/// 本周正式作答（attempts）：q1 答对 1 次 + 答错 1 次 + 未判分 1 次；
/// q2 正式答错 1 次 + 专项答对 1 次（专项不计核心数）；q3 正式答对 2 次；
/// q4/q5/q6 正式答错各 1 次；q7 正式答对 1 次；q8 正式答错 1 次
///（错因两个：方法不会、概念不清）；q-old 40 天前正式答错 1 次。
/// 本周：答对 4 次（q1 + q3×2 + q7），答错 6 道
///（q1/q2/q4/q5/q6/q8），已判分 10 次，答对率 40%。
FakeReportRepo _defaultRepo() {
  final today = _today;
  final now = _nowMs;
  final old = today.subtract(const Duration(days: 40)).millisecondsSinceEpoch;
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
  final attempts = [
    _att('q1', ReviewMode.due, 1, now, sessionId: 's1'),
    _att('q1', ReviewMode.due, 0, now, causeIds: ['概念不清'],
        sessionId: 's2'),
    _att('q1', ReviewMode.due, null, now, sessionId: 's3'),
    _att('q2', ReviewMode.due, 0, now, causeIds: ['方法不会']),
    _att('q2', ReviewMode.practice, 1, now),
    _att('q3', ReviewMode.due, 1, now, sessionId: 's1'),
    _att('q3', ReviewMode.due, 1, now, sessionId: 's2'),
    _att('q4', ReviewMode.due, 0, now, causeIds: ['概念不清']),
    _att('q5', ReviewMode.due, 0, now, causeIds: ['审题失误']),
    _att('q6', ReviewMode.due, 0, now, causeIds: ['审题失误']),
    _att('q7', ReviewMode.due, 1, now),
    _att('q8', ReviewMode.due, 0, now, causeIds: ['方法不会', '概念不清']),
    _att('q-old', ReviewMode.due, 0, old, causeIds: ['概念不清']),
  ];
  return FakeReportRepo(
    questions: questions,
    records: records,
    kps: kps,
    attemptsValue: attempts,
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
    test('load()：正式答对 4 次 · 正式答错 6 道 · 答对率 40%', () async {
      final container = _container(_defaultRepo());
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.loading, isFalse);
      expect(s.loadError, isFalse);
      // 答对按作答次数计：q1 1 次 + q3 2 次 + q7 1 次；专项答对不计，
      // 未判分不计。
      expect(s.formalCorrectCount, 4);
      // 答错按题去重：q1/q2/q4/q5/q6/q8 共 6 道。
      expect(s.formalWrongQuestionCount, 6);
      expect(s.gradedFormalCount, 10);
      expect(s.gradedFormalCorrectCount, 4);
      expect(s.passRate, 40);
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
      expect(container.read(reportProvider).formalCorrectCount, 4);
    });

    test('无已判分记录时答对率为 null', () async {
      final container = _container(
        FakeReportRepo(
          questions: [_tq('q1', '题', errorTypes: ['概念不清'])],
          records: [_trec('q1', '概念不清')],
          kps: [],
          attemptsValue: [_att('q1', ReviewMode.due, null, _nowMs)],
        ),
      );
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.passRate, isNull);
      expect(s.gradedFormalCount, 0);
      expect(s.formalCorrectCount, 0);
      expect(s.formalWrongQuestionCount, 0);
    });

    test('弱点：原因组 7 个、知识点组 7 个，矛盾观 2 道排第一', () async {
      final container = _container(_defaultRepo());
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.causeGroups.length, 7);
      expect(s.kpGroups.length, 7);
      expect(s.kpGroups.first.key, 'kp-marx');
      expect(s.kpGroups.first.count, 2);
      // D-259：已解决记录不再排除任何题——q4 的错因虽已解决，
      // 它正式答错过，英语的概念不清组与学术词汇组都在列。
      expect(
        s.causeGroups.where(
          (g) => g.subjectId == 'english' && g.key == '概念不清',
        ),
        hasLength(1),
      );
      expect(
        s.kpGroups.where((g) => g.key == 'kp-vocab'),
        hasLength(1),
      );
    });

    test('分布：范围内作答题数，本周数学 3 · 英语 2 · 政治 3', () async {
      final container = _container(_defaultRepo());
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.answeredBySubject, {'math': 3, 'english': 2, 'politics': 3});
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
        attemptsValue: [
          _att('q1', ReviewMode.due, 0, _nowMs, causeIds: ['概念不清']),
        ],
      );
      final container = _container(repo);
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.questionsInRange.length, 1);
      expect(s.causeGroups.single.count, 1);
      expect(s.kpGroups.single.count, 1);
      expect(s.answeredBySubject, {'math': 1});
    });

    test('setRange：切到“全部”旧题进来，数学分布变 4 道，不重读库', () async {
      final container = _container(_defaultRepo());
      final notifier = container.read(reportProvider.notifier);
      await notifier.load();
      var s = container.read(reportProvider);
      expect(s.range, 'week');
      expect(s.questionsInRange.length, 8);
      expect(s.records.length, 5);
      expect(s.formalWrongQuestionCount, 6);
      expect(s.passRate, 40);
      notifier.setRange('all');
      s = container.read(reportProvider);
      expect(s.range, 'all');
      expect(s.questionsInRange.length, 9);
      expect(
        s.questionsInRange.where((q) => q.subjectId == 'math').length,
        4,
      );
      // 旧题的正式答错进来：答错 7 道，已判分 11 次，答对率 36%。
      expect(s.formalWrongQuestionCount, 7);
      expect(s.gradedFormalCount, 11);
      expect(s.passRate, 36);
      expect(s.nextSentence, '先解决数学的概念不清。');
      // 切范围只重算派生值：读库数据本身没变。
      expect(s.records.length, 5);
      expect(s.rangeNote, '全部时间 · 数字按这个时间段算');
    });

    test('核心数按范围过滤（attempts.created_at）：本周与全部', () async {
      final today = _today;
      final now = _nowMs;
      final old = today.subtract(const Duration(days: 40)).millisecondsSinceEpoch;
      final questions = [
        _tq('qA', '题 A', errorTypes: ['概念不清']),
        _tq('qB', '题 B', errorTypes: ['方法不会']),
        _tq('qC', '题 C', errorTypes: ['计算错误']),
        _tq('qD', '题 D', errorTypes: ['审题失误']),
        _tq('qE', '题 E', errorTypes: ['概念不清']),
      ];
      final attempts = [
        _att('qA', ReviewMode.due, 0, now, causeIds: ['概念不清']),
        _att('qB', ReviewMode.due, 1, now),
        _att('qC', ReviewMode.due, 0, old, causeIds: ['计算错误']),
        _att('qD', ReviewMode.due, null, now),
        _att('qE', ReviewMode.due, 1, old),
      ];
      final container = _container(
        FakeReportRepo(
          questions: questions,
          records: const [],
          kps: const [],
          attemptsValue: attempts,
        ),
      );
      final notifier = container.read(reportProvider.notifier);
      await notifier.load();
      // 本周：答对 1 次（qB），答错 1 道（qA），已判分 2 次，答对率 50%。
      expect(container.read(reportProvider).formalCorrectCount, 1);
      expect(container.read(reportProvider).formalWrongQuestionCount, 1);
      expect(container.read(reportProvider).passRate, 50);
      notifier.setRange('all');
      // 全部：答对 2 次，答错 2 道，已判分 4 次，答对率仍 50%。
      expect(container.read(reportProvider).formalCorrectCount, 2);
      expect(container.read(reportProvider).formalWrongQuestionCount, 2);
      expect(container.read(reportProvider).passRate, 50);
    });

    test('同一题多次答错：答错题数只算 1 道，归因取最早一次的错因', () async {
      final now = _nowMs;
      final container = _container(
        FakeReportRepo(
          questions: [
            _tq('q1', '题', errorTypes: ['概念不清'],
                knowledgePointIds: ['kp-limit']),
          ],
          records: [_trec('q1', '概念不清')],
          kps: [_tkp('kp-limit', 'math', '函数与极限', '函数极限')],
          attemptsValue: [
            _att('q1', ReviewMode.due, 0, now, causeIds: ['方法不会'],
                sessionId: 's1'),
            _att('q1', ReviewMode.due, 0, now + 1000,
                causeIds: ['概念不清'], sessionId: 's2'),
          ],
        ),
      );
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.formalWrongQuestionCount, 1);
      expect(s.causeGroups.length, 1);
      expect(s.causeGroups.single.key, '方法不会');
    });

    test('weakStats 不变（回归）：只按新弱点组取样本', () async {
      final container = _container(_defaultRepo());
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      final group = s.causeGroups.singleWhere(
        (g) => g.subjectId == 'math' && g.key == '方法不会',
      );
      expect(group.questionIds, {'q2'});
      final stats = s.weakStats(group);
      // q2 本周：正式答错 1 次 + 专项答对 1 次。
      expect(stats.attemptCount, 2);
      expect(stats.wrongCount, 1);
      expect(stats.formalCount, 1);
      expect(stats.practiceCount, 1);
      expect(stats.errorRate, closeTo(0.5, 0.001));
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
      expect(s.formalCorrectCount, 4);
    });

    test('没有任何记录：nextSentence 为无正式答错那句', () async {
      final container = _container(
        FakeReportRepo(questions: [], records: [], kps: []),
      );
      await container.read(reportProvider.notifier).load();
      final s = container.read(reportProvider);
      expect(s.records, isEmpty);
      expect(s.causeGroups, isEmpty);
      expect(
        s.nextSentence,
        '这段时间正式复习还没有答错的题，先去复习页把到期的题做完。',
      );
    });
  });
}
