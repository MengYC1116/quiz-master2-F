// 十四批模块 A（Linux 模拟用户核验）：环境/冒烟/迁移/备份恢复/单实例。
//
// 定位：integration_test 下的真实路径测试——testWidgets 驱动真实
// QuizMasterApp / 真实 SettingsPage，Drift 真库、备份/恢复走真实实现
//（AppDatabase.exportBackupZipFromWithReport / importBackupZipInto），
//不 mock 仓库。只读 test/ 下既有测试，不改 lib/。
//
// 覆盖清单：#1（首页/错题本/详情冒烟）、#28（备份含图块与作答）、
// #29（恢复清空暂停会话）、#30（v3 备份恢复进 v5 + 高版本拒绝）、
// #31（v1 副本打开行为 + v4→v5 见 test/b14_m1_migration_test.dart）。
// #33 的 built-app 部分见模块报告（本文件另有 test/b14_m5_* 的重跑记录）。
//
// 运行（串行，勿用 /tmp——本机 /tmp 为 512M tmpfs 且已满）：
//   export PATH="$HOME/.local/bin:$PATH"
//   export TMPDIR=$HOME/workspace/flutter-test-tmp
//   export LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux
//   flutter test integration_test/b14_sim_a_smoke_backup_test.dart \
//     --concurrency=1 --dart-define SIM_A_TMP=$HOME/workspace/batch14-work/sim-tmp-a
//
// SIM_A_TMP 未传时退回系统临时目录。演示库本体与真实备份文件只读、
// 只复制，绝不原地写。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/app.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/stem_correction.dart';
import 'package:quiz_master2/modules/settings/settings_page.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';

const _simTmp = String.fromEnvironment('SIM_A_TMP', defaultValue: '');

Future<Directory> _freshDir(String name) async {
  final base = _simTmp.isEmpty
      ? (await Directory.systemTemp.createTemp('qm2-sim-a-')).path
      : p.join(_simTmp, 'it-$name');
  final dir = Directory(base);
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  return dir;
}

/// 有界手动 pump（仿 test/b8_1_subject_refresh_flow_test.dart）：
/// pump 看条件 + runAsync 切回真实异步等一轮延时 + 再 pump 渲染。
/// testWidgets 体内跑在 fake async 区：真实文件 IO / Future.delayed
/// 必须走 runAsync 才能推进，直接 await 会挂住；Drift 是同步 sqlite3
/// 调用，直接 await 即可。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  required String reason,
  int maxRounds = 30,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    await tester.pump();
    if (cond()) return;
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    if (cond()) return;
  }
  fail('界面未稳定：$reason');
}

/// 演示库 9 道题的镜像播种（标题/题干文字取自 v1 演示库，只读复制口径）。
Future<void> _seedDemo(QuestionRepository repo, QuizDatabase db) async {
  for (final s in Subject.all) {
    await repo.saveSubject(s);
  }
  const folders = ['试卷', '平时作业', '模拟卷'];
  for (final s in Subject.all) {
    for (final f in folders) {
      await repo.saveFolder(
        Folder(id: 'folder-${s.id}-$f', name: f, subjectId: s.id),
      );
    }
  }
  final questions = [
    ('q-math-1', '函数极限', 'math', true, '题：lim(x→0) sin 3x / x 的值是（　）'),
    (
      'q-math-2',
      '导数应用综合（整题含两问）',
      'math',
      false,
      '题：设 f(x) = x³ − 3x² + 2。\n（1）求 f(x) 的单调区间与极值；\n（2）求曲线 y = f(x) 在点 (1, 0) 处的切线方程。',
    ),
    (
      'q-math-3',
      '定积分阴影面积',
      'math',
      true,
      '题：下图阴影部分由曲线 y = x² 与直线 y = 1 围成。用定积分表示阴影部分的面积，并计算其值。',
    ),
    (
      'q-eng-1',
      '学术词汇辨析',
      'english',
      true,
      '题：The new evidence ______ the original hypothesis, forcing the team to revise the whole model.',
    ),
    (
      'q-eng-2',
      '长篇阅读（节选）',
      'english',
      false,
      '题：Passage: Universities are rethinking the lecture …（节选）\nQuestions 1–3: 主旨题 / 细节题 / 推理题，共 3 问。',
    ),
    (
      'q-eng-3',
      '图表作文',
      'english',
      true,
      '题：Figure 1 · Students’ monthly spending (demo chart)\nFood / Books / Trans / Clothes',
    ),
    (
      'q-pol-1',
      '史纲时间轴图题（带图题）',
      'politics',
      false,
      '题：读图：时间轴标出 1921、1949、1978、2012 四个年份。与 1978 年对应的重大历史事件是什么？它有何历史意义？\n图 1 · 历史时间轴',
    ),
    (
      'q-pol-2',
      '马原',
      'politics',
      true,
      '题：运用矛盾普遍性与特殊性的关系，说明如何推进中国式现代化。',
    ),
    (
      'q-pol-3',
      '材料分析：中国式现代化（整题含两问）',
      'politics',
      false,
      '题：材料：中国式现代化是中国共产党领导的社会主义现代化，既有各国现代化的共同特征，更有基于自己国情的中国特色。（节选）\n（1）中国式现代化的中国特色？\n（2）运用矛盾普遍性与特殊性的关系，说明应如何推进中国式现代化。',
    ),
  ];
  for (final (id, title, subjectId, organized, sliceText) in questions) {
    await repo.save(
      Question(
        id: id,
        title: title,
        subjectId: subjectId,
        createdAt: DateTime(2026, 11, 10),
        isOrganized: organized,
        isDemo: true,
        folderIds: organized ? ['folder-$subjectId-试卷'] : const [],
        sliceText: sliceText,
      ),
    );
  }
  // 错因（与 v1 演示库一致的 7 条）。
  const causes = [
    ('q-math-1', '概念不清', 'math', 'pending', 0),
    ('q-math-2', '方法不会', 'math', 'pending', 0),
    ('q-eng-1', '概念不清', 'english', 'solved', 2),
    ('q-math-3', '计算错误', 'math', 'inProgress', 1),
    ('q-pol-1', '审题失误', 'politics', 'pending', 0),
    ('q-eng-2', '审题失误', 'english', 'pending', 0),
    ('q-pol-3', '方法不会', 'politics', 'pending', 0),
  ];
  for (final (qid, cause, subjectId, status, solved) in causes) {
    await db.customStatement(
      "INSERT INTO cause_records (question_id, cause, subject_id, status, "
      "solved_count, joined_at) VALUES ('$qid', '$cause', '$subjectId', "
      "'$status', $solved, 1793877093020)",
    );
  }
  await repo.saveRecentTask(
    kind: '整理',
    subjectId: 'math',
    title: '函数极限',
  );
}

// ---- 图块播种（仿 test/b14_m2_backup_test.dart 的接受候选路径） ----

const _transform = OcrRequestTransform(
  srcW: 100,
  srcH: 50,
  reqW: 100,
  reqH: 50,
  padX: 0,
  padY: 0,
);

GlmOcrRawData _figureRaw(String hash) => GlmOcrRawData(
  mdResults:
      '看图求值\n\n![](page=0,bbox=[10, 5, 60, 25])\n\nA. 第一项\nB. 第二项\nC. 第三项\nD. 第四项',
  layoutDetails: [
    [
      {
        'bbox_2d': [10, 5, 60, 25],
        'label': 'image',
        'native_label': 'image',
        'width': 100,
        'height': 50,
        'index': 0,
      },
    ],
  ],
  transform: _transform,
  inputHash: hash,
  candidateStatus: OcrCandidateStatus.pending,
);

Future<String> _writeSlice(Directory dataDir, String name) async {
  final image = img.Image(width: 100, height: 50);
  img.fill(image, color: img.ColorRgb8(10, 20, 30));
  final bytes = img.encodePng(image);
  final rel = 'slices/$name.png';
  final abs = p.join(dataDir.path, rel);
  await File(abs).parent.create(recursive: true);
  await File(abs).writeAsBytes(bytes);
  return rel;
}

Future<String> _insertQuestionWithFigure(
  QuizDatabase db,
  QuestionRepository repo,
  Directory dataDir,
  String id,
) async {
  final slice = await _writeSlice(dataDir, id);
  final bytes = await File(p.join(dataDir.path, slice)).readAsBytes();
  final hash = sha256.convert(bytes).toString();
  final q = Question(
    id: id,
    title: '题 $id',
    subjectId: 'math',
    createdAt: DateTime(2026, 11, 18),
    slicePath: slice,
    ocrManualEdited: true,
    ocrStem: '旧题干',
    ocrRaw: _figureRaw(hash).toJsonString(),
    contentVersion: 5,
    answerVersion: 3,
  );
  await AppDatabase.upsertQuestionInto(db, q);
  final accepted = await acceptCandidateStem(repo, q);
  return parseOcrFigures(accepted.question.ocrFigures).single.cropPath;
}

/// 文件选择器的测试替身：FilePicker.platform 在 flutter_test 里未注册
///（late _instance，直接读抛 LateInitializationError），这里注入一个
/// extends FilePicker 的假实现，pickFiles 直接返回给定的备份文件。
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.path, this.size);

  final String path;
  final int size;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult([
        PlatformFile(name: 'sim29.qm2backup', path: path, size: size),
      ]);
}

Map<String, dynamic> _backupJson(List<int> zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  final entry = archive.files.firstWhere((f) => f.name == 'backup.json');
  return jsonDecode(utf8.decode(entry.content as List<int>))
      as Map<String, dynamic>;
}

void main() {
  group('模块 A #1 冒烟：真实应用 + 真实库', () {
    testWidgets('首页 9 道题、错题本、详情页都能打开', (tester) async {
      // fake async 区：真实文件 IO 必须走 runAsync，否则挂住。
      final dataDir = (await tester.runAsync(() => _freshDir('smoke')))!;
      AppDatabase.testDataDirectory = dataDir.path;
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      final repo = QuestionRepository(AppDatabase.instance);
      await _seedDemo(repo, db);
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });

      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ProviderScope(child: QuizMasterApp()));
      await _pumpUntil(
        tester,
        () => find.text('数学').evaluate().isNotEmpty,
        reason: '首页未出现数学',
      );
      // 首页：三科 + 继续上次（函数极限）。
      for (final name in ['数学', '英语', '政治']) {
        expect(find.text(name), findsWidgets);
      }
      // “上次停在”副标题是整句 Text（上次停在：整理 · 数学「函数极限」），
      // 用 textContaining 匹配。
      expect(find.textContaining('函数极限'), findsWidgets);
      // 错题本：点导航进错题本（十九批 L1：默认落点是列表，不再默认
      // 进书架；书架从筛选面板顶部「📚 书架（按学科浏览）」进）。
      await tester.ensureVisible(find.text('错题本').first);
      await tester.tap(find.text('错题本').first);
      await _pumpUntil(
        tester,
        () => find.text('全部题目').evaluate().isNotEmpty,
        reason: '错题本 L1 列表未出现',
      );
      await tester.ensureVisible(find.text('筛选 ▾').first);
      await tester.tap(find.text('筛选 ▾').first);
      await _pumpUntil(
        tester,
        () => find.textContaining('书架（按学科浏览）').evaluate().isNotEmpty,
        reason: '筛选面板未出现书架入口',
      );
      await tester.ensureVisible(
        find.textContaining('书架（按学科浏览）').first,
      );
      await tester.tap(find.textContaining('书架（按学科浏览）').first);
      await _pumpUntil(
        tester,
        () => find.textContaining('共 3 本').evaluate().isNotEmpty,
        reason: '错题本书架未出现',
      );
      // 点数学书进目录：含“数学”文字的 InkWell 里，导航在前、书封在后，
      // 取最后一个就是书封。
      final mathWells = find.ancestor(
        of: find.text('数学'),
        matching: find.byType(InkWell),
      );
      await tester.tap(mathWells.last);
      await _pumpUntil(
        tester,
        () => find.text('全部题目').evaluate().isNotEmpty,
        reason: '数学目录未出现',
      );
      // 进“试卷”文件夹看题目列表。十九批 L1 行只显示标题（RichText），
      // 不显示题干切片文本；用 q-math-3 的标题确认两道已整理题都在。
      await tester.ensureVisible(find.text('试卷').first);
      await tester.tap(find.text('试卷').first);
      await _pumpUntil(
        tester,
        () => find
            .textContaining('定积分阴影面积', findRichText: true)
            .evaluate()
            .isNotEmpty,
        reason: '错题本未列出已整理题目',
      );
      // 点 q-math-1 的卡片进详情页（按标题）。
      await tester.ensureVisible(
        find.textContaining('函数极限', findRichText: true).first,
      );
      await tester.tap(
        find.textContaining('函数极限', findRichText: true).first,
      );
      await _pumpUntil(
        tester,
        () => find.textContaining('函数极限').evaluate().isNotEmpty,
        reason: '详情页未显示题名',
      );
      // 详情页标题在长串里（数学 · 整题｜函数极限），用 textContaining。
      expect(find.textContaining('函数极限'), findsWidgets);
      // 详情页题干切片在（注意：列表页也有该文本，不能拿它当进详情的判据）。
      expect(
        find.text('题：lim(x→0) sin 3x / x 的值是（　）'),
        findsWidgets,
      );
    });
  });

  group('模块 A #31 v1 副本打开行为（设计：v1 删除，不迁移）', () {
    test('v1 演示库副本经 openAt 打开后被删除、重建为空 v6 库', () async {
      // v1 夹具来源：~/workspace/demo-db-backup/quiz-master2.db 是保留
      // 的 v1 演示库原件（user_version 1，9 道题）；应用数据目录下的
      // 同名文件现为 live v2 演示库，不再是 v1，不能当夹具。只读副本
      // 验证，原件 md5 全程不变。
      final home = Platform.environment['HOME'] ?? '';
      final demoDb = File(p.join(
        home,
        'workspace',
        'demo-db-backup',
        'quiz-master2.db',
      ));
      if (!await demoDb.exists()) {
        markTestSkipped('本机无 v1 演示库备份，跳过');
        return;
      }
      final md5Before = md5.convert(await demoDb.readAsBytes()).toString();
      final dir = await _freshDir('v1copy');
      final copyPath = p.join(dir.path, 'quiz-master2.db');
      await demoDb.copy(copyPath);
      expect(
        md5.convert(await File(copyPath).readAsBytes()).toString(),
        md5Before,
      );
      // 真实打开路径（含 deleteLegacyDatabaseIfPresent 预检）。
      final db = await AppDatabase.openAt(copyPath);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 6);
      final count = await db.customSelect(
        'SELECT COUNT(*) AS n FROM questions',
      ).getSingle();
      expect(count.data['n'], 0, reason: 'v1 老库按设计整体删除，不保留题目');
      final subjects = await db.customSelect(
        'SELECT id FROM subjects',
      ).get();
      expect(subjects.map((r) => r.data['id']).toSet(), {
        'math',
        'english',
        'politics',
      });
      await db.close();
      // 原件 md5 不变。
      expect(
        md5.convert(await demoDb.readAsBytes()).toString(),
        md5Before,
      );
    });
  });

  group('模块 A #28 备份含图块与作答（真实备份实现）', () {
    late QuizDatabase db;
    late Directory dataDir;
    late QuestionRepository repo;

    setUp(() async {
      dataDir = await _freshDir('backup28');
      AppDatabase.testDataDirectory = dataDir.path;
      db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      repo = QuestionRepository(AppDatabase.instance);
      await repo.saveSubject(Subject.math);
    });

    tearDown(() async {
      await AppDatabase.resetForTest();
    });

    test('图块进 ZIP、attempts 与 review_history 全量、缺图块有可见警告', () async {
      final crop = await _insertQuestionWithFigure(db, repo, dataDir, 'q1');
      await db.customStatement(
        "INSERT INTO attempts (id, question_id, session_id, mode, "
        "selected, correct, confidence, answer_version, content_version, "
        "status, cause_ids, duration_ms, submission_id, created_at) "
        "VALUES ('a1', 'q1', 's1', '专项练习', 'A', 1, '确定', 3, 6, "
        "'已提交', '[\"c1\"]', 12000, 'sub-1', 1795000000000)",
      );
      await db.customStatement(
        "INSERT INTO review_history (question_id, result, reviewed_at, "
        "cause_id, session_id, review_mode, verdict, verification_status, "
        "verification_source, attempt_id, submission_id) "
        "VALUES ('q1', '已解决', 1795000000000, 'c1', 's1', '到期复习', "
        "'已解决', '已核验', '外部资料核对', 'a1', 'sub-1')",
      );

      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      expect(report.warnings, isEmpty);
      final archive = ZipDecoder().decodeBytes(report.bytes);
      final names = archive.files.map((f) => f.name).toSet();
      expect(names, contains(crop));
      expect(names, contains('slices/q1.png'));
      final decoded = _backupJson(report.bytes);
      final attempts = decoded['attempts'] as List;
      expect(attempts.length, 1);
      final attempt = attempts.single as Map<String, dynamic>;
      expect(attempt['selected'], 'A');
      expect(attempt['correct'], 1);
      expect(attempt['confidence'], '确定');
      expect(attempt['answer_version'], 3);
      expect(attempt['content_version'], 6);
      final history = decoded['review_history'] as List;
      expect(history.length, 1);
      expect(
        (history.single as Map<String, dynamic>)['verification_status'],
        '已核验',
      );

      // 缺失图块：备份成功、警告列出题目。
      await File(p.join(dataDir.path, crop)).delete();
      final report2 = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      expect(report2.warnings, isNotEmpty);
      expect(report2.warnings.join('；'), contains('题 q1'));

      // 恢复进全新库：题目/图块/作答/复习记录全在。
      final db2 = await AppDatabase.openForTest();
      final warnings = await AppDatabase.importBackupZipInto(
        db2,
        report.bytes,
        dataDir: dataDir.path,
      );
      expect(warnings, isEmpty);
      final qs = await db2.select(db2.questions).get();
      expect(qs.length, 1);
      expect(qs.single.id, 'q1');
      expect(qs.single.answerVersion, 3);
      expect(qs.single.contentVersion, 6);
      final attempts2 = await db2.select(db2.attempts).get();
      expect(attempts2.length, 1);
      expect(attempts2.single.selected, 'A');
      expect(attempts2.single.confidence, '确定');
      final history2 = await db2.select(db2.reviewHistory).get();
      expect(history2.length, 1);
      expect(history2.single.verificationStatus, '已核验');
      expect(File(AppDatabase.resolveDataPath(crop)!).existsSync(), isTrue);
      await db2.close();
    });
  });

  group('模块 A #29 恢复清空暂停会话', () {
    test('恢复后暂停会话消失、不创建新活动会话、题目还在', () async {
      final dataDir = await _freshDir('restore29');
      AppDatabase.testDataDirectory = dataDir.path;
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      final repo = QuestionRepository(AppDatabase.instance);
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });
      await repo.saveSubject(Subject.math);
      await repo.save(
        Question(
          id: 'q1',
          title: '函数极限',
          subjectId: 'math',
          createdAt: DateTime(2026, 11, 10),
          isOrganized: true,
        ),
      );
      // 先留一个暂停会话。
      await repo.saveReviewState(
        queue: const [ReviewQueueItem(questionId: 'q1', cause: '概念不清')],
        position: 0,
        sessionId: 'sess-paused-1',
        mode: '到期复习',
      );
      expect(await repo.reviewState(), isNotNull);
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      // 恢复同一份备份（备份不含 review_state）。
      final warnings = await AppDatabase.importBackupZipInto(
        db,
        report.bytes,
        dataDir: dataDir.path,
      );
      expect(warnings, isEmpty);
      expect(
        await repo.reviewState(),
        isNull,
        reason: '恢复后暂停会话必须消失',
      );
      expect((await repo.all()).length, 1);
    });

    testWidgets('设置页恢复完成提示文案为写死的那句', (tester) async {
      // fake async 区：真实文件 IO 必须走 runAsync，否则挂住。
      final dataDir = (await tester.runAsync(() => _freshDir('restore29ui')))!;
      AppDatabase.testDataDirectory = dataDir.path;
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      final repo = QuestionRepository(AppDatabase.instance);
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });
      await repo.saveSubject(Subject.math);
      await repo.save(
        Question(
          id: 'q1',
          title: '函数极限',
          subjectId: 'math',
          createdAt: DateTime(2026, 11, 10),
          isOrganized: true,
        ),
      );
      await repo.saveReviewState(
        queue: const [ReviewQueueItem(questionId: 'q1', cause: '概念不清')],
        position: 0,
        sessionId: 'sess-paused-1',
        mode: '到期复习',
      );
      final backup = (await tester.runAsync(
        () => AppDatabase.exportBackupZipFromWithReport(
          db,
          dataDir: dataDir.path,
        ),
      ))!;
      final backupPath = p.join(dataDir.path, 'sim29.qm2backup');
      await tester.runAsync(
        () => File(backupPath).writeAsBytes(backup.bytes),
      );
      final backupSize = backup.bytes.length;

      // 注入文件选择器替身：直接返回刚导出的备份文件（原 late _instance
      // 在 flutter_test 里未初始化，MethodChannel mock 够不着它）。
      FilePicker.platform = _FakeFilePicker(backupPath, backupSize);

      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            theme: AppTheme.light(scale: 1.0),
            home: const Scaffold(body: SettingsPage(loadFailed: false)),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => find.text('设置').evaluate().isNotEmpty,
        reason: '设置页未出现',
      );
      await tester.ensureVisible(find.text('数据').first);
      await tester.tap(find.text('数据').first);
      await _pumpUntil(
        tester,
        () => find.text('选择备份文件…').evaluate().isNotEmpty,
        reason: '数据组未展开出恢复入口',
      );
      expect(find.text('选择备份文件…'), findsOneWidget);
      await tester.ensureVisible(find.text('选择备份文件…'));
      await tester.tap(find.text('选择备份文件…'));
      // 确认恢复弹窗。
      await _pumpUntil(
        tester,
        () => find.text('确认恢复，覆盖当前题库').evaluate().isNotEmpty,
        reason: '恢复确认弹窗未出现',
      );
      await tester.tap(find.text('确认恢复，覆盖当前题库'));
      // D-173：恢复成功文案按恢复前有无未完成会话分支；本例恢复前有
      // 暂停会话，故为“恢复成功，已清除未完成的复习会话”。
      // 恢复走真实文件 IO：每轮先放行真实异步、再渲染，等 snackbar 文案出现。
      // 恢复链路是几十个串联的真实 IO await，每轮只能推进一步，200 轮兜底
      //（探针实测约 99 轮出现）。
      await _pumpUntil(
        tester,
        () =>
            find
                .text('恢复成功，已清除未完成的复习会话')
                .evaluate()
                .isNotEmpty,
        reason: '恢复完成提示文案未出现',
        maxRounds: 200,
      );
      expect(
        find.text('恢复成功，已清除未完成的复习会话'),
        findsOneWidget,
      );
      expect(await repo.reviewState(), isNull);
    });
  });

  group('模块 A #30 v3 备份恢复进 v6（只用副本）', () {
    test('v3 备份恢复后题目都在、库版本为 v6、新字段走默认值；高版本拒绝', () async {
      final backupCopy = File(
        _simTmp.isEmpty
            ? 'quiz-master2-backup.qm2backup'
            : p.join(_simTmp, 'backup-copy.qm2backup'),
      );
      if (!await backupCopy.exists()) {
        markTestSkipped('未传 SIM_A_TMP 或备份副本不存在，跳过');
        return;
      }
      final backupBytes = await backupCopy.readAsBytes();
      final meta = _backupJson(backupBytes)['_meta'] as Map<String, dynamic>;
      // 如实记录：手头这份备份的 _meta.schemaVersion 是 3（v3），不是 v4。
      expect(meta['schemaVersion'], 3);

      final dataDir = await _freshDir('restore30');
      AppDatabase.testDataDirectory = dataDir.path;
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });
      final warnings = await AppDatabase.importBackupZipInto(
        db,
        backupBytes,
        dataDir: dataDir.path,
      );
      // v3 备份含 44 道题、2 科；恢复后版本为 v6。
      final qs = await db.select(db.questions).get();
      expect(qs.length, 44);
      final subjects = await db.select(db.subjects).get();
      expect(subjects.length, 2);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 6);
      final schemaVersion = await db.customSelect(
        "SELECT value FROM settings WHERE key = 'schemaVersion'",
      ).getSingle();
      expect(schemaVersion.data['value'], '6');
      // 新字段走默认值：题型待确认、图块 []、作答记录空。
      expect(qs.every((q) => q.questionType == null), isTrue);
      expect(
        qs.every((q) => parseOcrFigures(q.ocrFigures).isEmpty),
        isTrue,
      );
      expect(await db.select(db.attempts).get(), isEmpty);
      // 备份里的图块/切片文件确实落盘到数据目录（抽查 3 个）。
      final decoded = _backupJson(backupBytes);
      final names = ZipDecoder()
          .decodeBytes(backupBytes)
          .files
          .map((f) => f.name)
          .where((n) => n.startsWith('slices/'))
          .take(3)
          .toList();
      expect(names.length, 3);
      for (final rel in names) {
        expect(File(p.join(dataDir.path, rel)).existsSync(), isTrue);
      }
      expect(warnings, isA<List<String>>());

      // 高于当前版本的备份应被拒绝，原库不动。
      final tampered = Map<String, dynamic>.from(decoded);
      tampered['_meta'] = {'schemaVersion': 99, 'appVersion': '9.9.9'};
      await expectLater(
        AppDatabase.importBackupJsonInto(db, tampered),
        throwsA(isA<BackupRestoreException>()),
      );
      expect((await db.select(db.questions).get()).length, 44);
    });
  });

  group('模块 A：为 built-app 截图播种文件库（9 道演示题，v6）', () {
    test('seed file db for built app', () async {
      if (_simTmp.isEmpty) {
        markTestSkipped('未传 SIM_A_TMP，跳过文件库播种');
        return;
      }
      final home = Directory(p.join(_simTmp, 'seeded-home', 'quiz-master2'));
      if (await home.exists()) await home.delete(recursive: true);
      await home.create(recursive: true);
      AppDatabase.testDataDirectory = home.path;
      final dbPath = p.join(home.path, 'quiz-master2.db');
      final db = await AppDatabase.openAt(dbPath);
      final repo = QuestionRepository(AppDatabase.instance);
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async {
        await AppDatabase.resetForTest();
      });
      await _seedDemo(repo, db);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 6);
      final count = await db.customSelect(
        'SELECT COUNT(*) AS n FROM questions',
      ).getSingle();
      expect(count.data['n'], 9);
      await db.close();
    });
  });
}
