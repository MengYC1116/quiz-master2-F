// 十四批 M5 修复轮 4（D-159 / D-160 / D-161；GPT fix3 P1-1、P1-2）：
// ZIP 组装阶段暂存区文件缺失/读取失败的分类处理 + 派生路径非法警告
// + finally 注销保障。
//
// 故障注入：导出函数新增仅测试用的可选钩子 onStagedForTest，在
// withLock 返回后、ZIP 组装循环前调用一次，测试在钩子里删/换
// 暂存区里的文件。先查过代码库同类测试钩子先例：FileLifecycleGuard
// 的 debugClearPendingForTest / debugClearStagingForTest、
// YoloOnnxService.loadGateForTest 都是“测试专用可变状态/入口”
// 的先例；本轮钩子按任务要求用 Impl/Wrapper 的可选命名参数实现，
// 生产调用不传，行为不变。
// 全部用临时目录 / 内存库，不碰真实用户库。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/models/models.dart';

Future<({List<int> bytes, List<String> warnings, List<String> brokenFiles, BackupExportStatus status})> _backup(
  QuizDatabase db,
  Directory dataDir, {
  void Function(Directory stagingDir, List<String> stagedRels)?
  onStagedForTest,
}) => AppDatabase.exportBackupZipFromWithReport(
  db,
  dataDir: dataDir.path,
  onStagedForTest: onStagedForTest,
);

void main() {
  late QuizDatabase db;
  late Directory dataDir;

  Future<void> writeBytes(String rel, List<int> bytes) async {
    final f = File(p.join(dataDir.path, rel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  /// 有效 PNG 字节：图块裁图在锁内复制阶段要过可解码校验
  /// （_decodableFigureBytes），写任意字节会在复制阶段就被判
  /// “已损坏”而进不了暂存区，测不到 ZIP 组装阶段。
  List<int> validPngBytes() =>
      img.encodePng(img.Image(width: 1, height: 1));

  Future<void> insertQuestion(
    String id, {
    String? slicePath,
    String? ocrFigures,
  }) async {
    await AppDatabase.upsertQuestionInto(
      db,
      Question(
        id: id,
        title: '题 $id',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 18),
        slicePath: slicePath,
        ocrFigures: ocrFigures ?? '',
      ),
    );
  }

  Future<void> insertTask(
    String id,
    String sourcePath, {
    String fileName = 'm.pdf',
  }) async {
    await db.customInsert(
      'INSERT INTO collect_tasks (id, name, file_name, subject_id, status, '
      'progress, page_count, page, error, question_id, created_at, '
      'source_path, page_rotations) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable.withString(id),
        Variable.withString('任务 $id'),
        Variable.withString(fileName),
        Variable.withString('math'),
        Variable.withString('needBox'),
        Variable.withInt(100),
        Variable.withInt(1),
        Variable.withInt(1),
        const Variable<String>(null),
        const Variable<String>(null),
        Variable.withInt(1700000000000),
        Variable.withString(sourcePath),
        Variable.withString('{}'),
      ],
    );
  }

  /// 最小 JPEG（SOI + APP1 Exif，方向 6；无图像数据——本 helper 只用于
  /// 构造“快照时在盘上的归一化副本”。二十批 P6 修法 A（D-237）：Q4 的
  /// 必需/可选分类已删除，暂存区丢失是否警告只看快照时点在不在盘上，
  /// 与 EXIF 方向无关；方向 6 在此仅保证原图形状真实。
  List<int> exifOrientation6Jpeg() => [
    0xFF, 0xD8, // SOI
    0xFF, 0xE1, // APP1
    0x00, 0x22, // 段长 34（含长度字段本身）
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // TIFF 头（II, 42, IFD 偏移 8）
    0x01, 0x00, // IFD 条目数 1
    // tag 0x0112（Orientation），SHORT，1 个，值 6。
    0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, // 下一 IFD 偏移 0
    0xFF, 0xD9, // EOI
  ];

  /// 钩子内把暂存区里的文件换成指向 /proc/self/mem 的软链：
  /// File.existsSync() 为真（跟随链接后是文件），readAsBytes()
  /// 确定性抛 EIO（FileSystemException），与 fix3 锁内读取失败
  /// 测试同一手法。不用 chmod：测试以 root 跑，root 能绕过只读
  /// 权限；不用“文件换目录”：File 对目录路径的 existsSync() 为
  /// false，会走缺失分支而不是读取失败分支。
  void replaceStagedWithUnreadableLink(Directory stagingDir, String rel) {
    final target = File(p.join(stagingDir.path, rel));
    target.deleteSync();
    Link(target.path).createSync('/proc/self/mem');
    expect(target.existsSync(), isTrue);
  }

  void deleteStaged(Directory stagingDir, String rel) {
    File(p.join(stagingDir.path, rel)).deleteSync();
  }

  ({Map<String, dynamic> decoded, Set<String> zipNames}) decodeReport(
    ({List<int> bytes, List<String> warnings, List<String> brokenFiles, BackupExportStatus status}) report,
  ) {
    final archive = ZipDecoder().decodeBytes(report.bytes);
    final zipNames = archive.files.map((f) => f.name).toSet();
    final jsonEntry = archive.files.firstWhere(
      (f) => f.name == 'backup.json',
    );
    final decoded =
        jsonDecode(utf8.decode(jsonEntry.content as List<int>))
            as Map<String, dynamic>;
    return (decoded: decoded, zipNames: zipNames);
  }

  /// 数据目录下不得残留备份暂存区（失败也要清理，见 finally）。
  void expectNoStagingLeft() {
    final leftovers = dataDir
        .listSync()
        .where((e) => p.basename(e.path).startsWith('.backup-staging-'))
        .map((e) => e.path)
        .toList();
    expect(leftovers, isEmpty, reason: '备份失败后暂存区未清理：$leftovers');
    expect(
      FileLifecycleGuard.instance.stagingSnapshot,
      isEmpty,
      reason: '备份失败后暂存占用登记未解除',
    );
  }

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    // 每测独立临时数据目录（不用 AppDatabase.dataDirectoryPath() 的
    // 默认目录：那是真实用户库目录；也不用 /tmp：512M tmpfs 已满。
    // TMPDIR 由调用方指到 workspace 下的磁盘目录，systemTemp 跟它走）。
    dataDir = Directory.systemTemp.createTempSync('b14_m5_fix4_backup_');
    AppDatabase.testDataDirectory = dataDir.path;
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
      AppDatabase.resetForTest();
      try {
        dataDir.deleteSync(recursive: true);
      } catch (_) {}
    });
  });

  group('十四批 M5 修复轮 4（D-159）：暂存区直接引用缺失/不可读即备份失败', () {
    test('staging 中切片缺失：导出抛错，指明题目、路径与“暂存区”', () async {
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion('q1', slicePath: 'slices/q1.png');
      Object? caught;
      try {
        await _backup(
          db,
          dataDir,
          onStagedForTest: (stagingDir, _) =>
              deleteStaged(stagingDir, 'slices/q1.png'),
        );
      } catch (e) {
        caught = e;
      }
      expect(
        caught,
        isA<BackupRestoreException>(),
        reason: '原文件复制成功、暂存区文件缺失时，备份仍须失败，不能返回不完整 ZIP',
      );
      final message = (caught as BackupRestoreException).message;
      expect(message, contains('q1'), reason: '失败信息须指明题目 ID');
      expect(message, contains('slices/q1.png'), reason: '失败信息须指明相对路径');
      expect(message, contains('暂存区'), reason: 'ZIP 阶段文案须能区分是暂存区缺失');
      expect(message, contains('缺失'));
      expectNoStagingLeft();
    });

    test('staging 中切片读取失败：导出抛错，指明“暂存区文件无法读取”', () async {
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion('q1', slicePath: 'slices/q1.png');
      Object? caught;
      try {
        await _backup(
          db,
          dataDir,
          onStagedForTest: (stagingDir, _) =>
              replaceStagedWithUnreadableLink(stagingDir, 'slices/q1.png'),
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackupRestoreException>());
      final message = (caught as BackupRestoreException).message;
      expect(message, contains('q1'));
      expect(message, contains('slices/q1.png'));
      expect(message, contains('暂存区'));
      expect(message, contains('无法读取'));
      expectNoStagingLeft();
    });
  });

  group('十四批 M5 修复轮 4（D-159）：暂存区图块/派生缺失只警告、不阻断', () {
    test('staging 中图块裁图缺失：备份成功，警告列出题目、ZIP 里无该图块', () async {
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await writeBytes('slices/q1-fig.png', validPngBytes());
      await insertQuestion(
        'q1',
        slicePath: 'slices/q1.png',
        ocrFigures: '[{"crop_path": "slices/q1-fig.png"}]',
      );
      final report = await _backup(
        db,
        dataDir,
        onStagedForTest: (stagingDir, _) =>
            deleteStaged(stagingDir, 'slices/q1-fig.png'),
      );
      // 分类优先级：图块即使同时在 directRefs 里也只警告不阻断（D-158）。
      expect(report.warnings.join('\n'), contains('题 q1'));
      expect(report.warnings.join('\n'), contains('暂存区'));
      final decoded = decodeReport(report);
      expect(decoded.zipNames, isNot(contains('slices/q1-fig.png')));
      expect(decoded.zipNames, contains('slices/q1.png'));
      expectNoStagingLeft();
    });

    test('staging 中图块裁图读取失败：备份成功，警告列出题目', () async {
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await writeBytes('slices/q1-fig.png', validPngBytes());
      await insertQuestion(
        'q1',
        slicePath: 'slices/q1.png',
        ocrFigures: '[{"crop_path": "slices/q1-fig.png"}]',
      );
      final report = await _backup(
        db,
        dataDir,
        onStagedForTest: (stagingDir, _) => replaceStagedWithUnreadableLink(
          stagingDir,
          'slices/q1-fig.png',
        ),
      );
      expect(report.warnings.join('\n'), contains('题 q1'));
      expect(report.warnings.join('\n'), contains('无法读取'));
      final decoded = decodeReport(report);
      expect(decoded.zipNames, isNot(contains('slices/q1-fig.png')));
      expect(decoded.zipNames, contains('slices/q1.png'));
      expectNoStagingLeft();
    });

    test('staging 中派生文件缺失：备份成功，警告含该派生路径', () async {
      // 二十批 P6 修法 A（D-237）：副本在快照时在盘上即进清单，暂存区
      // 丢失按通用派生口径警告；Q4 的必需/可选分类已删除，不再按
      // EXIF 方向或任务类型区分。
      await insertTask(
        't1',
        'imports/t1/original.jpg',
        fileName: 'photo.jpg',
      );
      await writeBytes('imports/t1/original.jpg', exifOrientation6Jpeg());
      await writeBytes('imports/t1/page-normalized.png', [4, 5, 6]);
      final report = await _backup(
        db,
        dataDir,
        onStagedForTest: (stagingDir, _) => deleteStaged(
          stagingDir,
          'imports/t1/page-normalized.png',
        ),
      );
      expect(
        report.warnings,
        contains('派生文件 imports/t1/page-normalized.png 暂存区文件缺失，未包含在备份中'),
      );
      final decoded = decodeReport(report);
      expect(decoded.zipNames, contains('imports/t1/original.jpg'));
      expect(decoded.zipNames, isNot(contains('imports/t1/page-normalized.png')));
      expectNoStagingLeft();
    });

    test('staging 中派生文件读取失败：备份成功，警告含该派生路径', () async {
      // 二十批 P6 修法 A（D-237）：同上，快照时在盘上的副本暂存区
      // 读取失败按通用派生口径警告。
      await insertTask(
        't1',
        'imports/t1/original.jpg',
        fileName: 'photo.jpg',
      );
      await writeBytes('imports/t1/original.jpg', exifOrientation6Jpeg());
      await writeBytes('imports/t1/page-normalized.png', [4, 5, 6]);
      final report = await _backup(
        db,
        dataDir,
        onStagedForTest: (stagingDir, _) => replaceStagedWithUnreadableLink(
          stagingDir,
          'imports/t1/page-normalized.png',
        ),
      );
      expect(
        report.warnings,
        contains('派生文件 imports/t1/page-normalized.png 暂存区文件无法读取，未包含在备份中'),
      );
      final decoded = decodeReport(report);
      expect(decoded.zipNames, contains('imports/t1/original.jpg'));
      expect(decoded.zipNames, isNot(contains('imports/t1/page-normalized.png')));
      expectNoStagingLeft();
    });
  });

  group('十四批 M5 修复轮 4（D-160）：派生文件路径无法解析', () {
    test('P1-2 边界（D-162 更新，取代 D-160 旧锁定）：任务 id `..` 的派生路径记 warning，直接引用内部 .. 仍正常', () async {
      // D-162 更新说明：本测试在 fix4 时锁定“D-160 的路径非法分支经
      // 公开 API 不可达、该输入下无路径非法警告”。修复轮 5 在引用集
      // 入口补了备份专用的非法引用收集（D-162），任务 id `..` 的
      // 派生路径（`imports/../page-normalized.png` 等归一化后落在
      // imports//slices/ 白名单外）现在按派生非法记 warning——
      // 旧“无警告”锁定被新口径取代。直接引用 `imports/../original.pdf`
      // 归一化后仍在数据目录内，按原规则正常处理：不抛错、不记
      // 直接引用非法；备份仍成功。
      await insertTask('..', 'imports/../original.pdf');
      await writeBytes('pages/p.png', [1, 2, 3]);
      await writeBytes('original.pdf', [1, 2, 3]);
      final report = await _backup(db, dataDir);
      final joined = report.warnings.join('\n');
      expect(
        joined,
        contains('收集任务「..」的派生文件 imports/../page-normalized.png 路径非法'),
        reason: 'D-162：任务 id `..` 的派生路径现在记 warning',
      );
      expect(
        report.warnings.where((w) => w.contains('备份失败')),
        isEmpty,
        reason: '直接引用内部 .. 不抛错，备份仍成功',
      );
      expectNoStagingLeft();
    });
  });

  group('十四批 M5 修复轮 4（D-161）：finally 注销保障', () {
    test('正常导出后：暂存占用全清、暂存目录已删', () async {
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion('q1', slicePath: 'slices/q1.png');
      await insertTask('t1', 'imports/t1/original.pdf');
      await writeBytes('imports/t1/original.pdf', [1, 2, 3]);
      // 派生文件也写上，否则未渲染任务的派生缺失警告会使 warnings 非空。
      await writeBytes('imports/t1/page-normalized.png', [4, 5, 6]);
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(
        FileLifecycleGuard.instance.isStaged('slices/q1.png'),
        isFalse,
        reason: '正常导出后 slices/q1.png 的暂存占用登记须解除',
      );
      expect(
        FileLifecycleGuard.instance.isStaged('imports/t1/original.pdf'),
        isFalse,
        reason: '正常导出后原文件的暂存占用登记须解除',
      );
      expectNoStagingLeft();
    });

    test('导出失败后：暂存占用仍全清、暂存目录已删', () async {
      // 删目录失败本身难以经公开路径注入：deleteDirectoryLocked
      // 内部已吞掉删除异常，deleteDirectory 只在 withLock 本身
      // 失败时才抛错；本测试覆盖可观测的保证——无论主流程成功
      // 还是失败，注销都执行（D-161 内层 finally 的作用）。
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion('q1', slicePath: 'slices/q1.png');
      Object? caught;
      try {
        await _backup(
          db,
          dataDir,
          onStagedForTest: (stagingDir, _) =>
              deleteStaged(stagingDir, 'slices/q1.png'),
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackupRestoreException>());
      expect(
        FileLifecycleGuard.instance.isStaged('slices/q1.png'),
        isFalse,
        reason: '导出失败后暂存占用登记仍须解除，否则残留登记会一直挡住删文件',
      );
      expectNoStagingLeft();
    });
  });
}
