// WP-B #3/#4/#5 竞态修复回归测试（定稿 REV5）。
//
// 覆盖：正文 §3.3 的 11 项 + 附录 R3-6 + S1-4（A→B→A，代次守门）
// + U1-4（A→B→A，版本令牌）+ U1 真实库令牌测试 + 连续合法保存。
// 全部时序用可控 Completer 的 fake repo 强制，不依赖真实时序。
//
// 命名说明：fake 的 save() 里“进入事务之后、真实 SQL 写入之前”
// 的卡点 = save() 入口处、令牌校验与写库之前的 await 门；
// 真实库里对应位置是 upsertQuestionIntoImpl 的事务内、写语句之前。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/data/review_scheduler.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/organize_notifier.dart';
import 'package:quiz_master2/state/repository_provider.dart';

Question _q(
  String id,
  String title, {
  String subjectId = 'math',
  List<String> folderIds = const [],
  String? questionType,
  String ocrStem = '题干',
  int contentVersion = 0,
  bool isOrganized = false,
  DateTime? createdAt,
}) => Question(
  id: id,
  title: title,
  subjectId: subjectId,
  folderIds: folderIds,
  questionType: questionType,
  ocrStem: ocrStem,
  contentVersion: contentVersion,
  createdAt: createdAt ?? DateTime(2026, 11, 8),
  isOrganized: isOrganized,
  sliceKind: 'material',
  sliceText: '题：$title',
);

/// WP-B 专用 fake repo：每个读/写方法都有一组一次性 Completer 门
///（按调用顺序消费），并记录令牌校验结果与真实写库次数。
class WpbRepo extends QuestionRepository {
  WpbRepo({
    required List<Question> questions,
    required List<Folder> folderList,
    List<Exam> examList = const [],
    List<KnowledgePoint> kpList = const [],
    List<String> tagList = const [],
  }) : questions = List.of(questions),
       folderList = List.of(folderList),
       examList = List.of(examList),
       kpList = List.of(kpList),
       tagList = List.of(tagList),
       super(AppDatabase.instance);

  List<Question> questions;
  List<Folder> folderList;
  List<Exam> examList;
  List<KnowledgePoint> kpList;
  List<String> tagList;

  /// 一次性门：每次调用按顺序消费一个（读完行之后再挂起，保证
  /// 门里卡住的任务已经读到了旧值；save 门在令牌校验与写库之前）。
  final List<Completer<void>> allGates = [];
  final List<Completer<void>> questionByIdGates = [];
  final List<Completer<void>> ocrJobsGates = [];
  final List<Completer<void>> foldersGates = [];

  /// save 门：只卡下一次 save 调用（进入“事务”之后、写之前）。
  Completer<void>? saveGate;
  final saveEntered = Completer<void>();

  /// 调用记录。
  int saveCalls = 0;
  int appliedWrites = 0;
  int rejectedWrites = 0;
  final List<Question> savedArgs = [];
  int syncCauseRecordsCalls = 0;
  String? lastRecentKind;
  int organizedTodayValue = 0;
  final Map<String, List<OcrJob>> ocrJobsById = {};

  Question? stored(String id) =>
      questions.where((x) => x.id == id).firstOrNull;

  Future<void> _pass(List<Completer<void>> gates) async {
    if (gates.isEmpty) return;
    await gates.removeAt(0).future;
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async {
    final result = List.of(questions);
    await _pass(allGates);
    return result;
  }

  @override
  Future<Question?> questionById(String id) async {
    final result = stored(id);
    await _pass(questionByIdGates);
    return result;
  }

  @override
  Future<List<OcrJob>> ocrJobsForQuestion(String questionId) async {
    await _pass(ocrJobsGates);
    return List.of(ocrJobsById[questionId] ?? const []);
  }

  @override
  Future<bool> hasOcrApiKey() async => false;

  @override
  Future<List<Folder>> folders({String? subjectId}) async {
    await _pass(foldersGates);
    return subjectId == null
        ? List.of(folderList)
        : folderList.where((f) => f.subjectId == subjectId).toList();
  }

  @override
  Future<List<Subject>> subjects() async => Subject.all;

  @override
  Future<List<Exam>> exams() async => List.of(examList);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kpList);

  @override
  Future<List<String>> tags() async => List.of(tagList);

  @override
  Future<void> save(Question q, {SaveToken? token}) async {
    saveCalls++;
    savedArgs.add(q);
    if (!saveEntered.isCompleted) saveEntered.complete();
    // 卡点：已进入 save（“事务”内），真实写库之前。
    final g = saveGate;
    saveGate = null;
    if (g != null) await g.future;
    if (token != null) {
      final cur = stored(token.questionId);
      if (cur == null ||
          cur.contentVersion != token.expectedContentVersion) {
        rejectedWrites++;
        throw SaveTokenMismatch(
          token.questionId,
          token.expectedContentVersion,
          cur?.contentVersion,
        );
      }
    }
    appliedWrites++;
    final i = questions.indexWhere((x) => x.id == q.id);
    final old = i >= 0 ? questions[i] : null;
    // 简化版版本权威（只算 contentVersion）：题干/题型/切分状态/图块
    // 任一变化且模型版本未抬高时 +1；归类字段（文件夹/标签等）不碰版本。
    int nextVersion;
    if (old == null) {
      nextVersion = q.contentVersion;
    } else {
      final visibleChanged =
          old.ocrStem != q.ocrStem ||
          old.questionType != q.questionType ||
          old.ocrSplitStatus != q.ocrSplitStatus ||
          old.ocrFigures != q.ocrFigures;
      if (visibleChanged && q.contentVersion <= old.contentVersion) {
        nextVersion = old.contentVersion + 1;
      } else {
        nextVersion = old.contentVersion > q.contentVersion
            ? old.contentVersion
            : q.contentVersion;
      }
    }
    final written = q.copyWith(contentVersion: nextVersion);
    if (i >= 0) {
      questions[i] = written;
    } else {
      questions.add(written);
    }
  }

  @override
  Future<void> delete(Question question) async {
    questions.removeWhere((x) => x.id == question.id);
  }

  @override
  Future<void> saveFolder(Folder folder) async {
    folderList.add(folder);
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
  Future<int> organizedTodayCount({DateTime? now}) async => organizedTodayValue;

  // 2026-11-26 面 C：旧 dueToday() 已删；本文件不测今日小结 N2，
  // FSRS 到期恒返回空，避免走到真实调度器 / 真实库。
  @override
  Future<List<String>> fsrsDueQuestionIds({
    required ReviewScheduler scheduler,
    DateTime? now,
  }) async => const [];
}

WpbRepo _threeRepo() => WpbRepo(
  questions: [
    _q('q1', '函数极限', createdAt: DateTime(2026, 11, 8)),
    _q(
      'q2',
      '导数综合',
      folderIds: const ['f1'],
      questionType: 'choice_multi',
      createdAt: DateTime(2026, 11, 5),
    ),
    _q(
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
  examList: [Exam(id: 'e1', name: '高等数学期末试卷', date: DateTime(2026, 11, 10))],
  kpList: const [
    KnowledgePoint(
      id: 'k1',
      subjectId: 'math',
      chapter: '第一章 函数与极限',
      name: '函数极限',
    ),
  ],
  tagList: const ['易错', '常考'],
);

ProviderContainer _container(WpbRepo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  container.listen(organizeProvider, (_, __) {});
  return container;
}

/// 先跑一次普通 refresh，把 build() 的 microtask 首查排空，
/// 再开始可控时序（否则首查会抢先消费门）。
Future<OrganizeNotifier> _ready(
  ProviderContainer container,
  WpbRepo repo,
) async {
  final notifier = container.read(organizeProvider.notifier);
  await notifier.refresh();
  // 与 build() 的 microtask 首查并发时，显式 refresh 可能因代次旧而
  // 中止（R3-6 行为），首查随后才写回——等 loading 落下再断言。
  for (var i = 0; i < 50 && container.read(organizeProvider).loading; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(container.read(organizeProvider).queue.map((q) => q.id), [
    'q1',
    'q2',
    'q3',
  ]);
  return notifier;
}

void main() {
  group('WP-B §3.3 单题刷新与全局刷新竞态', () {
    test('3.3-1 确认保存后自身事件延迟到达 → 队列不回退', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      // OCR 刷新先起跑：读到 q1 行后挂在 jobs 门上（快照已取旧队列）。
      final qGate = Completer<void>();
      final jobsGate = Completer<void>();
      repo.questionByIdGates.add(qGate);
      repo.ocrJobsGates.add(jobsGate);
      final ocrFuture = notifier.refreshOcrForQuestion('q1');
      qGate.complete();
      // 等 OCR 任务停在 jobs 门上（快照是确认前的旧队列）。
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // 此时确认 q1：保存 + 全局刷新（队列只剩 q2/q3，current q2）。
      notifier.toggleFolder('f1');
      await notifier.confirmCurrent(answer: '', explanation: '', notes: '');
      var s = container.read(organizeProvider);
      expect(s.queue.map((q) => q.id), ['q2', 'q3']);
      expect(s.current?.id, 'q2');
      // 延迟到达的自身事件（旧 OCR 刷新）现在才落地：不得把队列写回旧值。
      jobsGate.complete();
      await ocrFuture;
      s = container.read(organizeProvider);
      expect(s.queue.map((q) => q.id), ['q2', 'q3']);
      expect(s.current?.id, 'q2');
      expect(s.loadedQuestionId, 'q2');
    });

    test('3.3-2 全局刷新先完成、单题刷新后完成 → 旧单题刷新失效', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      final gate = Completer<void>();
      repo.questionByIdGates.add(gate);
      final ocrFuture = notifier.refreshOcrForQuestion('q1');
      // OCR 任务已读到旧行（题干 S0），挂在门上。
      await Future<void>.delayed(Duration.zero);
      // 库里 q1 被改成 S1，全局刷新先完成。
      repo.questions[0] = _q('q1', '函数极限', ocrStem: 'S1');
      await notifier.refresh();
      expect(
        container.read(organizeProvider).queue.first.ocrStem,
        'S1',
      );
      // 旧单题刷新现在才落地：不得把队列行写回 S0。
      gate.complete();
      await ocrFuture;
      expect(
        container.read(organizeProvider).queue.first.ocrStem,
        'S1',
      );
    });

    test('3.3-3 单题刷新先完成、全局刷新后完成 → 全局刷新结果正确', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      repo.questions[0] = _q('q1', '函数极限', ocrStem: 'S1');
      await notifier.refreshOcrForQuestion('q1');
      expect(
        container.read(organizeProvider).queue.first.ocrStem,
        'S1',
      );
      await notifier.refresh();
      final s = container.read(organizeProvider);
      expect(s.queue.first.ocrStem, 'S1');
      expect(s.current?.id, 'q1');
      expect(s.loadedQuestionId, 'q1');
    });

    test('3.3-4 同一题两次刷新逆序完成 → 旧结果不覆盖新结果', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      repo.questionByIdGates.addAll([gateA, gateB]);
      final futureA = notifier.refreshOcrForQuestion('q1');
      await Future<void>.delayed(Duration.zero);
      repo.questions[0] = _q('q1', '函数极限', ocrStem: 'S1');
      final futureB = notifier.refreshOcrForQuestion('q1');
      await Future<void>.delayed(Duration.zero);
      // B（新）先完成，写 S1；A（旧）后完成，不得覆盖回 S0。
      gateB.complete();
      await futureB;
      expect(
        container.read(organizeProvider).queue.first.ocrStem,
        'S1',
      );
      gateA.complete();
      await futureA;
      expect(
        container.read(organizeProvider).queue.first.ocrStem,
        'S1',
      );
    });

    test('3.3-5 两个不同题目同时刷新 → 各自更新，互不覆盖', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      // 库里两题都已更新。
      repo.questions[0] = _q('q1', '函数极限', ocrStem: 'S1');
      repo.questions[1] = _q(
        'q2',
        '导数综合',
        folderIds: const ['f1'],
        questionType: 'choice_multi',
        ocrStem: 'S2',
      );
      // q1 是当前题：它的刷新在 jobs 读上挂起（队列行已先写回），
      // 期间 q2 的刷新完整落地；旧代码会在 jobs 读完后用挂起前取的
      // 旧快照整体写回，把 q2 的 S2 覆盖回旧值。
      final jobsGate = Completer<void>();
      repo.ocrJobsGates.add(jobsGate);
      final f1 = notifier.refreshOcrForQuestion('q1');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await notifier.refreshOcrForQuestion('q2');
      final mid = container.read(organizeProvider);
      expect(mid.queue[1].ocrStem, 'S2');
      jobsGate.complete();
      await f1;
      final s = container.read(organizeProvider);
      expect(s.queue[0].ocrStem, 'S1');
      expect(s.queue[1].ocrStem, 'S2');
    });

    test('3.3-6 当前题目已离开队列 → 不得重新插入', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      // q1 在别处被确认整理：库里还在，但待整理队列里已无。
      repo.questions[0] = _q('q1', '函数极限', isOrganized: true);
      await notifier.refresh();
      expect(container.read(organizeProvider).queue.map((q) => q.id), [
        'q2',
        'q3',
      ]);
      await notifier.refreshOcrForQuestion('q1');
      expect(container.read(organizeProvider).queue.map((q) => q.id), [
        'q2',
        'q3',
      ]);
    });

    test('3.3-7 下一题是多选题 → 题型与表单 ID 一致', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      final qGate = Completer<void>();
      final jobsGate = Completer<void>();
      repo.questionByIdGates.add(qGate);
      repo.ocrJobsGates.add(jobsGate);
      final ocrFuture = notifier.refreshOcrForQuestion('q1');
      qGate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      notifier.toggleFolder('f1');
      await notifier.confirmCurrent(answer: '', explanation: '', notes: '');
      jobsGate.complete();
      await ocrFuture;
      final s = container.read(organizeProvider);
      expect(s.current?.id, 'q2');
      expect(s.loadedQuestionId, 'q2');
      expect(s.questionType, 'choice_multi');
    });

    test('3.3-8 下一题未选文件夹 → 文件夹值不被旧回调覆盖', () async {
      final repo = _threeRepo();
      // q2 本来就没有文件夹。
      repo.questions[1] = _q(
        'q2',
        '导数综合',
        questionType: 'choice_multi',
        createdAt: DateTime(2026, 11, 5),
      );
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      final qGate = Completer<void>();
      final jobsGate = Completer<void>();
      repo.questionByIdGates.add(qGate);
      repo.ocrJobsGates.add(jobsGate);
      final ocrFuture = notifier.refreshOcrForQuestion('q1');
      qGate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      notifier.toggleFolder('f1');
      await notifier.confirmCurrent(answer: '', explanation: '', notes: '');
      jobsGate.complete();
      await ocrFuture;
      final s = container.read(organizeProvider);
      expect(s.current?.id, 'q2');
      expect(s.folderIds, isEmpty);
    });

    test('3.3-9 刷新过程中连续确认两题 → 队列与 current 正确', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      notifier.toggleFolder('f1');
      await notifier.confirmCurrent(answer: '', explanation: '', notes: '');
      // q2 自带 f1 文件夹，直接确认。
      await notifier.confirmCurrent(answer: '', explanation: '', notes: '');
      final s = container.read(organizeProvider);
      expect(s.queue.map((q) => q.id), ['q3']);
      expect(s.current?.id, 'q3');
      expect(s.loadedQuestionId, 'q3');
      // 迟到的 q1 单题刷新不得把已确认的题插回来。
      await notifier.refreshOcrForQuestion('q1');
      expect(container.read(organizeProvider).queue.map((q) => q.id), ['q3']);
    });

    test('3.3-10 刷新过程中离开页面 → 不产生无效状态更新', () async {
      final repo = _threeRepo();
      // 不用 _container（它注册了 tearDown dispose）；手动建容器、手动销毁。
      final container = ProviderContainer.test(
        overrides: [repositoryProvider.overrideWithValue(repo)],
      );
      container.listen(organizeProvider, (_, __) {});
      final notifier = container.read(organizeProvider.notifier);
      await notifier.refresh();
      final gate = Completer<void>();
      repo.questionByIdGates.add(gate);
      final ocrFuture = notifier.refreshOcrForQuestion('q1');
      await Future<void>.delayed(Duration.zero);
      container.dispose();
      gate.complete();
      await ocrFuture; // 不抛即通过。
    });

    test('3.3-11 OCR 刷新与手动编辑并发 → 手动编辑的表单值不被旧回调覆盖', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      final gate = Completer<void>();
      repo.questionByIdGates.add(gate);
      final ocrFuture = notifier.refreshOcrForQuestion('q1');
      await Future<void>.delayed(Duration.zero);
      // 用户手动改文件夹并保存（保存成功，代次+1）。
      notifier.toggleFolder('f1');
      final ok = await notifier.saveCurrent(
        answer: '',
        explanation: '',
        notes: '',
      );
      expect(ok, isTrue);
      expect(repo.stored('q1')!.folderIds, ['f1']);
      // 旧 OCR 回调现在才落地：队列行与表单都不得被写回旧值。
      gate.complete();
      await ocrFuture;
      final s = container.read(organizeProvider);
      expect(s.queue.first.folderIds, ['f1']);
      expect(s.folderIds, ['f1']);
    });
  });

  group('WP-B R3-6 代次与 loadedQuestionId', () {
    test('两次快速连续 refresh → 最终显示第二道题的值', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      final gate1 = Completer<void>();
      final gate2 = Completer<void>();
      repo.allGates.addAll([gate1, gate2]);
      final r1 = notifier.refresh();
      await Future<void>.delayed(Duration.zero);
      // r1 已读到旧列表 [q1,q2,q3]，挂在门上；此时 q1 在别处被确认。
      repo.questions.removeWhere((q) => q.id == 'q1');
      final r2 = notifier.refresh();
      await Future<void>.delayed(Duration.zero);
      // r2（新）先完成：队列 [q2,q3]，current q2。
      gate2.complete();
      await r2;
      var s = container.read(organizeProvider);
      expect(s.queue.map((q) => q.id), ['q2', 'q3']);
      expect(s.current?.id, 'q2');
      expect(s.loadedQuestionId, 'q2');
      // r1（旧）后完成：不得把队列与表单写回旧值。
      gate1.complete();
      await r1;
      s = container.read(organizeProvider);
      expect(s.queue.map((q) => q.id), ['q2', 'q3']);
      expect(s.current?.id, 'q2');
      expect(s.loadedQuestionId, 'q2');
    });

    test('jumpTo 中途 → loadedQuestionId 先置 null，加载完才置新 id', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      expect(container.read(organizeProvider).loadedQuestionId, 'q1');
      final gate = Completer<void>();
      repo.foldersGates.add(gate);
      final jump = notifier.jumpTo('q3');
      // 同步段已执行：下标已改、表单已下线（null），loadForm 尚未跑。
      final mid = container.read(organizeProvider);
      expect(mid.index, 2);
      expect(mid.loadedQuestionId, isNull);
      gate.complete();
      await jump;
      final s = container.read(organizeProvider);
      expect(s.current?.id, 'q3');
      expect(s.loadedQuestionId, 'q3');
    });

    test('连续两次 jumpTo → 只有最新一次的 loadForm 落地', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      final gate1 = Completer<void>();
      final gate2 = Completer<void>();
      repo.foldersGates.addAll([gate1, gate2]);
      final j1 = notifier.jumpTo('q2');
      await Future<void>.delayed(Duration.zero);
      final j2 = notifier.jumpTo('q3');
      await Future<void>.delayed(Duration.zero);
      gate2.complete();
      await j2;
      expect(container.read(organizeProvider).current?.id, 'q3');
      expect(container.read(organizeProvider).loadedQuestionId, 'q3');
      gate1.complete();
      await j1;
      final s = container.read(organizeProvider);
      expect(s.current?.id, 'q3');
      expect(s.loadedQuestionId, 'q3');
    });

    test('队列清空 → loadedQuestionId 变回 null，旧单题刷新不能恢复旧题', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      expect(container.read(organizeProvider).loadedQuestionId, 'q1');
      repo.questions.clear();
      await notifier.refresh();
      final s = container.read(organizeProvider);
      expect(s.queue, isEmpty);
      expect(s.current, isNull);
      // 哨兵机制：有值 → null 可验证。
      expect(s.loadedQuestionId, isNull);
      await notifier.refreshOcrForQuestion('q1');
      expect(container.read(organizeProvider).queue, isEmpty);
    });
  });

  group('WP-B S1-4 A→B→A 代次守门', () {
    test('旧保存卡在 repo 调用之前 → 切 B 再切回 A，放行后不得写库', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      // 卡点：旧保存保存前的重读（repo.all() 调用，保存尚未发出；
      // 用 all() 而不用 questionById：Notifier 的保存前重读走 all()，
      // 旧 fake 未覆盖 questionById 时基类读真实库会永挂）。
      final preReadGate = Completer<void>();
      repo.allGates.add(preReadGate);
      notifier.toggleFolder('f1');
      final oldSave = notifier.saveCurrent(
        answer: 'OLD',
        explanation: '',
        notes: '',
      );
      await Future<void>.delayed(Duration.zero);
      // 旧任务挂在 pre-read 门上：repo.save 一次也未被调用。
      expect(repo.saveCalls, 0);
      // 切 B（generation+1），再切回 A（generation 再+1）。
      await notifier.jumpTo('q2');
      await notifier.jumpTo('q1');
      var s = container.read(organizeProvider);
      expect(s.current?.id, 'q1');
      expect(s.loadedQuestionId, 'q1');
      // 表单是最新 loadForm 载入的值（不是旧保存的值）。
      expect(s.folderIds, isEmpty);
      // 放行旧任务：代次已变，不得写库。
      preReadGate.complete();
      expect(await oldSave, isFalse);
      expect(repo.saveCalls, 0);
      expect(repo.appliedWrites, 0);
      s = container.read(organizeProvider);
      expect(s.current?.id, 'q1');
      expect(s.folderIds, isEmpty);
      expect(repo.stored('q1')!.folderIds, isEmpty);
    });
  });

  group('WP-B U1-4 A→B→A 版本令牌', () {
    test('旧保存卡在事务内、写之前 → 新保存先落库，放行后旧任务零写库', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      // 卡点：旧保存的 repo.save 已进入“事务”，真实写库之前。
      final saveGate = Completer<void>();
      repo.saveGate = saveGate;
      notifier.toggleFolder('f1');
      final oldSave = notifier.saveCurrent(
        answer: 'OLD',
        explanation: '',
        notes: '',
      );
      await repo.saveEntered.future;
      expect(repo.saveCalls, 1);
      expect(repo.appliedWrites, 0);
      // 切 B，再切回 A。
      await notifier.jumpTo('q2');
      await notifier.jumpTo('q1');
      // 一次更新的保存先落库（改题型 → contentVersion 0→1）。
      notifier.setQuestionType('choice_single');
      notifier.toggleFolder('f2');
      final newOk = await notifier.saveCurrent(
        answer: 'NEW',
        explanation: '',
        notes: '',
      );
      expect(newOk, isTrue);
      expect(repo.appliedWrites, 1);
      expect(repo.stored('q1')!.contentVersion, 1);
      expect(repo.stored('q1')!.questionType, 'choice_single');
      // 放行旧任务：令牌版本不符（期望 0，实际 1）→ 零写库。
      saveGate.complete();
      expect(await oldSave, isFalse);
      expect(repo.appliedWrites, 1);
      expect(repo.rejectedWrites, 1);
      expect(repo.stored('q1')!.answer, 'NEW');
      expect(repo.stored('q1')!.folderIds, ['f2']);
      expect(repo.stored('q1')!.questionType, 'choice_single');
      final s = container.read(organizeProvider);
      expect(s.current?.id, 'q1');
      expect(s.questionType, 'choice_single');
      // 题目 id 再次变回 A，旧任务不恢复有效性：已结束的任务不再写库。
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(repo.appliedWrites, 1);
      expect(repo.stored('q1')!.answer, 'NEW');
    });
  });

  group('WP-B U1 连续合法保存（同一表单会话）', () {
    test('第一次保存后内存模型版本已刷新，第二次合法保存不被误杀', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      notifier.setQuestionType('choice_single');
      final ok1 = await notifier.saveCurrent(
        answer: '',
        explanation: '',
        notes: '',
      );
      expect(ok1, isTrue);
      expect(repo.stored('q1')!.contentVersion, 1);
      expect(
        container.read(organizeProvider).queue.first.contentVersion,
        1,
      );
      // 同一次表单会话内第二次合法保存：令牌取自已刷新的最新版本。
      notifier.setQuestionType('choice_multi');
      final ok2 = await notifier.saveCurrent(
        answer: '',
        explanation: '',
        notes: '',
      );
      expect(ok2, isTrue);
      expect(repo.stored('q1')!.contentVersion, 2);
      // 只改归类字段（文件夹）不碰版本，第三次保存同样成功。
      notifier.toggleFolder('f1');
      final ok3 = await notifier.saveCurrent(
        answer: '',
        explanation: '',
        notes: '',
      );
      expect(ok3, isTrue);
      expect(repo.stored('q1')!.contentVersion, 2);
      expect(repo.stored('q1')!.folderIds, ['f1']);
    });
  });

  group('WP-B R3-3 generation 失效范围', () {
    test('refresh bump generation；refreshOcrForQuestion 不碰 generation', () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      final g0 = container.read(organizeProvider).generation;
      await notifier.refreshOcrForQuestion('q1');
      expect(container.read(organizeProvider).generation, g0);
      await notifier.refresh();
      expect(container.read(organizeProvider).generation, g0 + 1);
    });

    test('goTo / jumpTo / 排序 / 删题 / 批量确认 / 批量移文件夹都 bump generation',
        () async {
      final repo = _threeRepo();
      final container = _container(repo);
      final notifier = await _ready(container, repo);
      int g() => container.read(organizeProvider).generation;
      final g0 = g();
      await notifier.goTo(1);
      expect(g(), g0 + 1);
      await notifier.jumpTo('q3');
      expect(g(), g0 + 2);
      notifier.applyQueueSort('timeAsc');
      expect(g(), g0 + 3);
      await notifier.deleteQuestion(
        container.read(organizeProvider).queue.first,
      );
      expect(g(), g0 + 4);
      final s = container.read(organizeProvider);
      await notifier.batchConfirmQuestions(s.queue);
      expect(g(), g0 + 5);
      final folder = repo.folderList.firstWhere((f) => f.id == 'f1');
      await notifier.batchAddFolders(s.queue, folder);
      expect(g(), g0 + 6);
    });
  });

  group('WP-B U1 真实库版本令牌', () {
    late QuizDatabase db;
    late QuestionRepository repo;

    Question base(String id, {int contentVersion = 3}) => Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      createdAt: DateTime(2026, 11, 18),
      ocrStem: '旧题干',
      contentVersion: contentVersion,
      answerVersion: 2,
    );

    Future<Question> reload(String id) async =>
        (await repo.questionById(id))!;

    setUp(() async {
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      repo = QuestionRepository(AppDatabase.instance);
    });

    test('过期令牌 → 抛 SaveTokenMismatch，零写入', () async {
      await AppDatabase.upsertQuestionInto(db, base('q1'));
      await expectLater(
        repo.save(
          base('q1').copyWith(ocrStem: '新题干'),
          token: const SaveToken(
            questionId: 'q1',
            expectedContentVersion: 99,
          ),
        ),
        throwsA(isA<SaveTokenMismatch>()),
      );
      final stored = await reload('q1');
      expect(stored.ocrStem, '旧题干');
      expect(stored.contentVersion, 3);
    });

    test('行已消失 + 令牌 → 抛错，不复活已删行', () async {
      await expectLater(
        repo.save(
          base('qx'),
          token: const SaveToken(
            questionId: 'qx',
            expectedContentVersion: 0,
          ),
        ),
        throwsA(isA<SaveTokenMismatch>()),
      );
      expect(await repo.questionById('qx'), isNull);
    });

    test('不传令牌 → 原有行为不变：已删行可重新入库、已存在行正常保存', () async {
      // 已删（不存在）行：无令牌时按旧口径整行插入。
      await repo.save(base('qx'));
      expect((await reload('qx')).ocrStem, '旧题干');
      // 已存在行：无令牌正常保存，版本规则不变。
      await AppDatabase.upsertQuestionInto(db, base('q1'));
      await repo.save((await reload('q1')).copyWith(ocrStem: '新题干'));
      expect((await reload('q1')).contentVersion, 4);
    });

    test('令牌 questionId 与题目不符 → 拒绝写入', () async {
      await AppDatabase.upsertQuestionInto(db, base('q1'));
      await expectLater(
        repo.save(
          base('q1').copyWith(ocrStem: '新题干'),
          token: const SaveToken(
            questionId: 'q2',
            expectedContentVersion: 3,
          ),
        ),
        throwsA(isA<SaveTokenMismatch>()),
      );
      expect((await reload('q1')).ocrStem, '旧题干');
    });

    test('连续两次合法保存：第二次令牌取自第一次保存后的最新版本', () async {
      await AppDatabase.upsertQuestionInto(db, base('q1'));
      await repo.save(
        (await reload('q1')).copyWith(ocrStem: '题干二'),
        token: const SaveToken(questionId: 'q1', expectedContentVersion: 3),
      );
      expect((await reload('q1')).contentVersion, 4);
      await repo.save(
        (await reload('q1')).copyWith(ocrStem: '题干三'),
        token: const SaveToken(questionId: 'q1', expectedContentVersion: 4),
      );
      final stored = await reload('q1');
      expect(stored.contentVersion, 5);
      expect(stored.ocrStem, '题干三');
      // 拿旧令牌再保存 → 拒绝，行内容不变。
      final q4 = await reload('q1');
      await expectLater(
        repo.save(
          q4.copyWith(ocrStem: '题干四'),
          token: const SaveToken(questionId: 'q1', expectedContentVersion: 4),
        ),
        throwsA(isA<SaveTokenMismatch>()),
      );
      expect((await reload('q1')).ocrStem, '题干三');
    });

    test('令牌相符但内容无变化 → 写入成功，版本不递增', () async {
      await AppDatabase.upsertQuestionInto(db, base('q1'));
      await repo.save(
        await reload('q1'),
        token: const SaveToken(questionId: 'q1', expectedContentVersion: 3),
      );
      expect((await reload('q1')).contentVersion, 3);
    });
  });
}
