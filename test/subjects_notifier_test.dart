// ARCH-PLAN-A 第 2 阶段（B 路）：SubjectsNotifier 单测（不启动 widget）。
// 拿 notifier 的方式与 Stage 1 一致：`ProviderContainer.test` +
// `repositoryProvider.overrideWithValue(repo)` 注入（见
// docs/ui-replication/A-READING-GUIDE.md）；FakeRepo 只覆盖 Notifier
// 实际调的方法，不碰真实库。
// 覆盖首读（学科/计数/知识点树默认科）、学科增删改名 + 封面、
// 章节/知识点增删改名、标签/试卷增删改名、读库失败态。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/subjects_notifier.dart';

Question _tq(
  String id, {
  String subjectId = 'math',
  List<String> tags = const [],
  String? examId,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: subjectId,
  tags: tags,
  examId: examId,
  createdAt: DateTime.now(),
  isOrganized: true,
  sliceKind: 'material',
  sliceText: '题',
);

class FakeSubjectsNotifierRepo extends QuestionRepository {
  FakeSubjectsNotifierRepo({this.throwOnLoad = false})
    : super(AppDatabase.instance);

  bool throwOnLoad;
  List<Subject> subjectsList = List.of(Subject.all);
  List<Question> questions = [
    _tq('q1'),
    _tq('q2'),
    _tq('q3', tags: ['易错'], examId: 'exam-1'),
    _tq('q4', subjectId: 'english', tags: ['易错']),
    _tq('q5', subjectId: 'english'),
    _tq('q6', subjectId: 'politics', examId: 'exam-1'),
  ];
  List<KnowledgePoint> kps = [
    const KnowledgePoint(
      id: 'kp-1',
      subjectId: 'math',
      chapter: '函数与极限',
      name: '函数极限',
    ),
    const KnowledgePoint(
      id: 'kp-2',
      subjectId: 'math',
      chapter: '函数与极限',
      name: '导数应用',
    ),
    const KnowledgePoint(
      id: 'kp-3',
      subjectId: 'english',
      chapter: '词汇',
      name: '学术词汇',
    ),
  ];
  List<String> tagsList = ['易错', '常考'];
  List<Exam> examsList = [
    Exam(id: 'exam-1', name: '2026 期中考试', date: DateTime(2026, 11, 5)),
  ];
  List<Folder> savedFolders = [];
  int saveSubjectCalls = 0;

  void _throw() {
    if (throwOnLoad) throw StateError('db down');
  }

  @override
  Future<List<Subject>> subjects() async {
    _throw();
    return List.of(subjectsList);
  }

  @override
  Future<List<Question>> all({bool includeArchived = false}) async {
    _throw();
    return List.of(questions);
  }

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async {
    _throw();
    return List.of(kps);
  }

  @override
  Future<List<String>> tags() async {
    _throw();
    return List.of(tagsList);
  }

  @override
  Future<List<Exam>> exams() async {
    _throw();
    return List.of(examsList);
  }

  @override
  Future<void> saveSubject(Subject s) async {
    saveSubjectCalls++;
    final i = subjectsList.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      subjectsList[i] = s;
    } else {
      subjectsList.add(s);
    }
  }

  @override
  Future<void> deleteSubject(String id) async {
    subjectsList.removeWhere((e) => e.id == id);
    questions.removeWhere((q) => q.subjectId == id);
  }

  @override
  Future<void> saveFolder(Folder f) async {
    savedFolders.add(f);
  }

  @override
  Future<void> addKnowledgePoint(KnowledgePoint kp) async {
    kps.add(kp);
  }

  @override
  Future<void> renameKnowledgePoint(String id, String newName) async {
    final i = kps.indexWhere((e) => e.id == id);
    if (i >= 0) {
      kps[i] = KnowledgePoint(
        id: id,
        subjectId: kps[i].subjectId,
        chapter: kps[i].chapter,
        name: newName,
      );
    }
  }

  @override
  Future<void> deleteKnowledgePoint(String id) async {
    kps.removeWhere((e) => e.id == id);
  }

  @override
  Future<void> renameChapter(
    String subjectId,
    String oldChapter,
    String newChapter,
  ) async {
    for (var i = 0; i < kps.length; i++) {
      if (kps[i].subjectId == subjectId && kps[i].chapter == oldChapter) {
        kps[i] = KnowledgePoint(
          id: kps[i].id,
          subjectId: subjectId,
          chapter: newChapter,
          name: kps[i].name,
        );
      }
    }
  }

  @override
  Future<void> deleteChapter(String subjectId, String chapter) async {
    kps.removeWhere((e) => e.subjectId == subjectId && e.chapter == chapter);
  }

  @override
  Future<void> addTag(String name) async {
    tagsList.add(name);
  }

  @override
  Future<void> renameTag(String oldName, String newName) async {
    final i = tagsList.indexOf(oldName);
    if (i >= 0) tagsList[i] = newName;
  }

  @override
  Future<void> deleteTag(String name) async {
    tagsList.remove(name);
  }

  @override
  Future<void> addExam(Exam e) async {
    examsList.add(e);
  }

  @override
  Future<void> renameExam(String id, String newName) async {
    final i = examsList.indexWhere((e) => e.id == id);
    if (i >= 0) {
      examsList[i] = Exam(id: id, name: newName, date: examsList[i].date);
    }
  }

  @override
  Future<void> deleteExam(String id) async {
    examsList.removeWhere((e) => e.id == id);
  }
}

Future<(FakeSubjectsNotifierRepo, SubjectsNotifier, ProviderContainer)> _setUp({
  bool throwOnLoad = false,
}) async {
  final repo = FakeSubjectsNotifierRepo(throwOnLoad: throwOnLoad);
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  final notifier = container.read(subjectsProvider.notifier);
  await notifier.load();
  return (repo, notifier, container);
}

void main() {
  test('首读：学科/计数/知识点树默认科', () async {
    final (repo, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    final s = container.read(subjectsProvider);
    expect(s.loading, isFalse);
    expect(s.loadError, isFalse);
    expect(s.subjects.map((e) => e.name), ['数学', '英语', '政治']);
    expect(s.questionCounts, {'math': 3, 'english': 2, 'politics': 1});
    expect(s.tagCounts, {'易错': 2});
    expect(s.examCounts, {'exam-1': 2});
    expect(s.kpSubjectId, 'math');
    expect(s.chaptersFor('math'), ['函数与极限']);
    expect(s.subjectName('english'), '英语');
    expect(notifier, isNotNull);
    expect(repo.subjectsList.length, 3);
  });

  test('读库失败：loadError，不一直 loading', () async {
    final (_, _, container) = await _setUp(throwOnLoad: true);
    addTearDown(container.dispose);
    final s = container.read(subjectsProvider);
    expect(s.loading, isFalse);
    expect(s.loadError, isTrue);
  });

  test('新增学科：入库 + 预置文件夹 3 个 + 重名拦下', () async {
    final (repo, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    final r = await notifier.addSubject('物理');
    expect(r.saved, isTrue);
    expect(r.message, isNull);
    expect(
      container.read(subjectsProvider).subjects.any((e) => e.name == '物理'),
      isTrue,
    );
    expect(repo.savedFolders.map((f) => f.name), ['试卷', '平时作业', '模拟卷']);
    expect(
      repo.savedFolders.every((f) => f.subjectId.startsWith('subject-')),
      isTrue,
    );
    final dup = await notifier.addSubject('物理');
    expect(dup.saved, isFalse);
    expect(dup.message, '已经有了这个学科');
  });

  test('学科改名：成功 / 重名拦下 / 同名静默', () async {
    final (_, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    final r = await notifier.renameSubject('math', '高等数学');
    expect(r.saved, isTrue);
    expect(container.read(subjectsProvider).subjectName('math'), '高等数学');
    final dup = await notifier.renameSubject('english', '高等数学');
    expect(dup.saved, isFalse);
    expect(dup.message, '已经有了这个学科');
    final same = await notifier.renameSubject('english', '英语');
    expect(same.saved, isFalse);
    expect(same.message, isNull);
  });

  test('删学科 + 封面样式/颜色点即生效', () async {
    final (_, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    await notifier.deleteSubject('politics');
    var s = container.read(subjectsProvider);
    expect(s.subjects.map((e) => e.id), isNot(contains('politics')));
    expect(s.questionCounts.containsKey('politics'), isFalse);
    final math = s.subjects.firstWhere((e) => e.id == 'math');
    await notifier.setCover(math, style: 'grid', color: 'green');
    s = container.read(subjectsProvider);
    final updated = s.subjects.firstWhere((e) => e.id == 'math');
    expect(updated.coverStyle, 'grid');
    expect(updated.coverColor, 'green');
  });

  test('新增章节：须带第一个知识点；重名拦下', () async {
    final (_, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    final r = await notifier.addChapter(
      subjectId: 'math',
      chapter: '导数',
      kpName: '导数定义',
    );
    expect(r.saved, isTrue);
    expect(container.read(subjectsProvider).chaptersFor('math'), [
      '函数与极限',
      '导数',
    ]);
    final dup = await notifier.addChapter(
      subjectId: 'math',
      chapter: '导数',
      kpName: '导数应用',
    );
    expect(dup.saved, isFalse);
    expect(dup.message, '已经有了这个章节');
  });

  test('知识点增删改名 + 章节改名/删除', () async {
    final (_, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    await notifier.addKnowledgePoint(
      subjectId: 'math',
      chapter: '函数与极限',
      name: '极限四则运算',
    );
    var s = container.read(subjectsProvider);
    expect(s.kps.any((k) => k.name == '极限四则运算'), isTrue);
    final r = await notifier.renameChapter('math', '函数与极限', '极限');
    expect(r.saved, isTrue);
    s = container.read(subjectsProvider);
    expect(s.chaptersFor('math'), ['极限']);
    expect(s.kps.where((k) => k.chapter == '极限').length, 3);
    final dup = await notifier.renameChapter('math', '极限', '极限');
    expect(dup.saved, isFalse);
    await notifier.renameKnowledgePoint('kp-1', '函数极限（改）');
    s = container.read(subjectsProvider);
    expect(s.kps.firstWhere((k) => k.id == 'kp-1').name, '函数极限（改）');
    await notifier.deleteKnowledgePoint('kp-1');
    s = container.read(subjectsProvider);
    expect(s.kps.any((k) => k.id == 'kp-1'), isFalse);
    await notifier.deleteChapter('math', '极限');
    s = container.read(subjectsProvider);
    expect(s.chaptersFor('math'), isEmpty);
  });

  test('标签：禁逗号竖线 / 重名拦下 / 改名删', () async {
    final (_, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    final bad = await notifier.addTag('a,b');
    expect(bad.saved, isFalse);
    expect(bad.message, '不能含逗号或竖线');
    final dup = await notifier.addTag('易错');
    expect(dup.saved, isFalse);
    expect(dup.message, '已经有了这个标签');
    final ok = await notifier.addTag('重点');
    expect(ok.saved, isTrue);
    expect(container.read(subjectsProvider).tags, contains('重点'));
    final renamed = await notifier.renameTag('重点', '必考');
    expect(renamed.saved, isTrue);
    expect(container.read(subjectsProvider).tags, contains('必考'));
    final badRename = await notifier.renameTag('必考', 'x|y');
    expect(badRename.message, '不能含逗号或竖线');
    await notifier.deleteTag('必考');
    expect(container.read(subjectsProvider).tags, isNot(contains('必考')));
  });

  test('试卷：新增 / 重名拦下 / 改名 / 删除', () async {
    final (_, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    final ok = await notifier.addExam('2026 月考', DateTime(2026, 10, 20));
    expect(ok.saved, isTrue);
    expect(
      container.read(subjectsProvider).exams.any((e) => e.name == '2026 月考'),
      isTrue,
    );
    final dup = await notifier.addExam('2026 月考', DateTime(2026, 10, 20));
    expect(dup.saved, isFalse);
    expect(dup.message, '已经有了这张试卷');
    final renamed = await notifier.renameExam('exam-1', '2026 期中（改）');
    expect(renamed.saved, isTrue);
    expect(
      container
          .read(subjectsProvider)
          .exams
          .firstWhere((e) => e.id == 'exam-1')
          .name,
      '2026 期中（改）',
    );
    await notifier.deleteExam('exam-1');
    expect(
      container.read(subjectsProvider).exams.any((e) => e.id == 'exam-1'),
      isFalse,
    );
  });

  test('页签切换只改 kpSubjectId，不重读丢数据', () async {
    final (_, notifier, container) = await _setUp();
    addTearDown(container.dispose);
    notifier.selectKpSubject('english');
    final s = container.read(subjectsProvider);
    expect(s.kpSubjectId, 'english');
    expect(s.chaptersFor('english'), ['词汇']);
    expect(s.subjects.length, 3);
  });

  group('FR-01 删学科后知识点树页签残留', () {
    test('删当前页签学科：页签落到首科，空状态不再错指被删学科', () async {
      final (_, notifier, container) = await _setUp();
      addTearDown(container.dispose);
      notifier.selectKpSubject('english');
      expect(container.read(subjectsProvider).kpSubjectId, 'english');
      await notifier.deleteSubject('english');
      final s = container.read(subjectsProvider);
      expect(s.kpSubjectId, 'math');
      expect(s.subjectName(s.kpSubjectId!), '数学');
      expect(s.subjects.map((e) => e.id), ['math', 'politics']);
    });

    test('删当前页签学科后，用残留 id 加章节/知识点被拒、不写库', () async {
      final (repo, notifier, container) = await _setUp();
      addTearDown(container.dispose);
      notifier.selectKpSubject('english');
      await notifier.deleteSubject('english');
      expect(container.read(subjectsProvider).kpSubjectId, 'math');
      final kpsBefore = repo.kps.length;
      final r1 = await notifier.addChapter(
        subjectId: 'english',
        chapter: '新章节',
        kpName: '新知识点',
      );
      expect(r1.saved, isFalse);
      expect(r1.message, isNotNull);
      final r2 = await notifier.addKnowledgePoint(
        subjectId: 'english',
        chapter: '词汇',
        name: '新知识点',
      );
      expect(r2.saved, isFalse);
      expect(r2.message, isNotNull);
      expect(repo.kps.length, kpsBefore);
      expect(
        repo.kps.any((k) => k.subjectId == 'english' && k.name == '新知识点'),
        isFalse,
      );
    });

    test('删非页签学科：页签不动', () async {
      final (_, notifier, container) = await _setUp();
      addTearDown(container.dispose);
      notifier.selectKpSubject('english');
      await notifier.deleteSubject('politics');
      expect(container.read(subjectsProvider).kpSubjectId, 'english');
    });

    test('load() 重读时残留 kpSubjectId 被重置为首科', () async {
      final (repo, notifier, container) = await _setUp();
      addTearDown(container.dispose);
      notifier.selectKpSubject('english');
      // 绕过 deleteSubject 直接删库行，模拟“别处删科后本页重读”。
      repo.subjectsList.removeWhere((s) => s.id == 'english');
      await notifier.load();
      expect(container.read(subjectsProvider).kpSubjectId, 'math');
    });
  });
}
