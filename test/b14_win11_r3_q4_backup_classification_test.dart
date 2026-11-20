// Win11 后续修复 Round 3（Q4）：备份枚举与孤儿保护拆开——
// 归一化副本（`page-normalized.png`）分必需/可选，只有必需缺失才警告、
// 才变 partial；孤儿保护（`_referencedRelativePaths`，行存在即保护）
// 原语义不动；回收站清扫的文件条目也走同一引用口径复查（§1.9）。
//
// 分类规则（`WIN11-Q4-BACKUP-RACE-INVESTIGATION.md` §3.2，按顺序）：
// 1. source_path 为空或不在 `imports/<本行 id>/` 下 → 可选（拆分行）；
// 2. PDF 行 → 可选；3. status failed/importing/queued → 可选；
// 4. 图片行读原图头 EXIF：方向 1 / 无 EXIF / 非 JPEG → 可选，
//    方向 3/6/8 → 必需；O1：source_hash 不可信（NULL 或不符）→ 可选；
//    O3：全文件哈希只在“方向 != 1 且副本缺失”时才算。
// 全部用临时目录 / 内存库，不碰真实用户库。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
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

  Future<void> insertTask({
    required String id,
    required String sourcePath,
    String fileName = 'photo.jpg',
    String status = 'needBox',
    String? questionId,
    String? sourceHash,
  }) async {
    await db.customInsert(
      'INSERT INTO collect_tasks (id, name, file_name, subject_id, status, '
      'progress, page_count, page, error, question_id, created_at, '
      'source_path, page_rotations, source_hash) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable.withString(id),
        Variable.withString('任务 $id'),
        Variable.withString(fileName),
        Variable.withString('math'),
        Variable.withString(status),
        Variable.withInt(100),
        Variable.withInt(1),
        Variable.withInt(1),
        const Variable<String>(null),
        questionId == null
            ? const Variable<String>(null)
            : Variable.withString(questionId),
        Variable.withInt(1700000000000),
        Variable.withString(sourcePath),
        Variable.withString('{}'),
        sourceHash == null
            ? const Variable<String>(null)
            : Variable.withString(sourceHash),
      ],
    );
  }

  Future<void> insertQuestion(String id, {String? slicePath}) async {
    await AppDatabase.upsertQuestionInto(
      db,
      Question(
        id: id,
        title: '题 $id',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 18),
        slicePath: slicePath,
      ),
    );
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

  /// 最小 JPEG（SOI + APP1 Exif，方向为 [orientation]；无图像数据——
  /// 备份分类只读 EXIF 头，不解码像素）。
  List<int> exifJpeg(int orientation) => [
    0xFF, 0xD8, // SOI
    0xFF, 0xE1, // APP1
    0x00, 0x22, // 段长 34（含长度字段本身）
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // TIFF 头（II, 42, IFD 偏移 8）
    0x01, 0x00, // IFD 条目数 1
    // tag 0x0112（Orientation），SHORT，1 个，值为 orientation。
    0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00,
    orientation, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, // 下一 IFD 偏移 0
    0xFF, 0xD9, // EOI
  ];

  /// 无 EXIF 的最小 JFIF JPEG。
  List<int> jfifJpeg() => [
    0xFF, 0xD8, // SOI
    0xFF, 0xE0, // APP0
    0x00, 0x10, // 段长 16（含长度字段本身）
    0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
    0x01, 0x01, // 版本 1.1
    0x00, // 单位
    0x00, 0x01, // Xdensity
    0x00, 0x01, // Ydensity
    0x00, 0x00, // 缩略图 0×0
    0xFF, 0xD9, // EOI
  ];

  /// 非 JPEG 原图（PNG 文件头几个字节即可；分类只读 EXIF 头）。
  List<int> pngHead() => [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

  /// 在回收站里手工放一条已超 7 天的文件条目（模拟早年移入的条目）。
  void seedTrashEntry(String trashName, String originalRel) {
    final trashDir = Directory(p.join(dataDir.path, '.trash'))
      ..createSync(recursive: true);
    File(p.join(trashDir.path, trashName)).writeAsBytesSync([9, 9, 9]);
    File(p.join(trashDir.path, 'manifest.json')).writeAsStringSync(
      jsonEncode({
        'entries': [
          {
            'trashName': trashName,
            'originalRel': originalRel,
            'movedAtMs':
                DateTime.now().millisecondsSinceEpoch - 8 * 24 * 3600 * 1000,
          },
        ],
      }),
    );
  }

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    dataDir = Directory.systemTemp.createTempSync('b14_win11_r3_q4_');
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

  group('Q4：38 行误报形状——拆分任务行不再警告', () {
    test('拆分任务行（父任务行已删、只有父原图在）：备份 complete、零警告', () async {
      // 真实 38 行形状的缩小版：3 个拆分行共用一个父原图，父任务行
      // 已被 confirmSplit 删掉；没有任何拆分行有自己的目录与归一化副本。
      const parentOriginal = 'imports/task-1795135761439-0-506903/original.png';
      await writeBytes(parentOriginal, [7, 7, 7]);
      for (final (i, status, qid) in [
        (0, 'pendingOrganize', 'q-1'),
        (1, 'pendingOrganize', 'q-2'),
        (2, 'done', null),
      ]) {
        await insertTask(
          id: 'task-1795135761439-818830-1-$i',
          sourcePath: parentOriginal,
          fileName: 'photo.png',
          status: status,
          questionId: qid,
        );
      }
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty, reason: '拆分行按构造就没有归一化副本，缺失不是丢失');
      expect(report.brokenFiles, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      final decoded = decodeReport(report);
      expect(decoded.zipNames, contains(parentOriginal));
      expect(
        decoded.zipNames.where((n) => n.endsWith('page-normalized.png')),
        isEmpty,
      );
      expectNoStagingLeft();
    });

    test('拆分任务行带有效切片：切片全进包', () async {
      const parentOriginal = 'imports/task-parent/original.png';
      await writeBytes(parentOriginal, [7, 7, 7]);
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion('q1', slicePath: 'slices/q1.png');
      await insertTask(
        id: 'task-1795135761439-818830-1-0',
        sourcePath: parentOriginal,
        fileName: 'photo.png',
        status: 'pendingOrganize',
        questionId: 'q1',
      );
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      final decoded = decodeReport(report);
      expect(decoded.zipNames, contains('slices/q1.png'));
      expect(decoded.zipNames, contains(parentOriginal));
      expectNoStagingLeft();
    });
  });

  group('Q4：EXIF 分类——可选缺失不警告，必需缺失才警告', () {
    test('无 EXIF 的原图（PNG）：缺失归一化副本不警告', () async {
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.png',
        fileName: 'photo.png',
      );
      await writeBytes('imports/t1/original.png', pngHead());
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      expectNoStagingLeft();
    });

    test('无 EXIF 的 JPEG（JFIF）：缺失归一化副本不警告', () async {
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
      );
      await writeBytes('imports/t1/original.jpg', jfifJpeg());
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      expectNoStagingLeft();
    });

    test('方向 1 的 JPEG：缺失归一化副本不警告', () async {
      final bytes = exifJpeg(1);
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
        sourceHash: sha256Of(bytes),
      );
      await writeBytes('imports/t1/original.jpg', bytes);
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      expectNoStagingLeft();
    });

    test('方向 6 且归一化副本在盘上：副本进包、无警告', () async {
      final bytes = exifJpeg(6);
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
        sourceHash: sha256Of(bytes),
      );
      await writeBytes('imports/t1/original.jpg', bytes);
      await writeBytes('imports/t1/page-normalized.png', [4, 5, 6]);
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      final decoded = decodeReport(report);
      expect(decoded.zipNames, contains('imports/t1/page-normalized.png'));
      expectNoStagingLeft();
    });

    test('方向 6 但归一化副本缺失：partial，警告注明歧义（O2）', () async {
      final bytes = exifJpeg(6);
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
        sourceHash: sha256Of(bytes),
      );
      await writeBytes('imports/t1/original.jpg', bytes);
      final report = await _backup(db, dataDir);
      expect(report.status, BackupExportStatus.partial);
      expect(
        report.brokenFiles,
        contains('imports/t1/page-normalized.png'),
      );
      expect(
        report.warnings.join('\n'),
        contains('可能已丢失，也可能当初未生成'),
        reason: 'O2：文案须如实注明“丢了 vs 静默降级未生成”的歧义（§2.5 残差）',
      );
      expectNoStagingLeft();
    });

    test('方向 6 但 source_hash 为 NULL：缺失不警告（O1，宁漏勿误报）', () async {
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
        sourceHash: null,
      );
      await writeBytes('imports/t1/original.jpg', exifJpeg(6));
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      expectNoStagingLeft();
    });

    test('方向 6 但 source_hash 不符（原图被换过）：缺失不警告（O1）', () async {
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
        sourceHash: sha256Of([0, 0, 0]),
      );
      await writeBytes('imports/t1/original.jpg', exifJpeg(6));
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      expectNoStagingLeft();
    });

    test('失败状态的图片任务：缺失不警告（无期待）', () async {
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
        status: 'failed',
        sourceHash: sha256Of(exifJpeg(6)),
      );
      await writeBytes('imports/t1/original.jpg', exifJpeg(6));
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      expectNoStagingLeft();
    });
  });

  group('Q4：孤儿保护原语义不动', () {
    test('进行中任务的归一化副本仍受孤儿保护', () async {
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
        status: 'importing',
      );
      await writeBytes('imports/t1/original.jpg', jfifJpeg());
      await writeBytes('imports/t1/page-normalized.png', [4, 5, 6]);
      // 孤儿扫描不得把它列为孤儿。
      final scan = await AppDatabase.scanOrphanFilesFrom(
        db,
        dataDir: dataDir.path,
      );
      expect(
        scan.files.map((f) => f.relativePath),
        isNot(contains('imports/t1/page-normalized.png')),
      );
      // 孤儿删除传进来也须跳过（行存在即保护，db_orphans.dart:519 不动）。
      final result = await AppDatabase.deleteOrphanFiles(
        ['imports/t1/page-normalized.png'],
        dataDir: dataDir.path,
        db: db,
      );
      expect(result.skippedReferencedCount, 1);
      expect(
        File(p.join(dataDir.path, 'imports/t1/page-normalized.png'))
            .existsSync(),
        isTrue,
      );
    });
  });

  group('Q4：枚举后删除仍被发现（暂存区故障注入）', () {
    test('必需副本在暂存区被删：警告 + partial', () async {
      final bytes = exifJpeg(6);
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
        sourceHash: sha256Of(bytes),
      );
      await writeBytes('imports/t1/original.jpg', bytes);
      await writeBytes('imports/t1/page-normalized.png', [4, 5, 6]);
      final report = await _backup(
        db,
        dataDir,
        onStagedForTest: (stagingDir, _) =>
            File(p.join(stagingDir.path, 'imports/t1/page-normalized.png'))
                .deleteSync(),
      );
      expect(report.status, BackupExportStatus.partial);
      expect(
        report.brokenFiles,
        contains('imports/t1/page-normalized.png'),
      );
      expect(
        report.warnings,
        contains('派生文件 imports/t1/page-normalized.png 暂存区文件缺失，未包含在备份中'),
      );
      expectNoStagingLeft();
    });

    test('可选副本在暂存区被删：静默跳过、仍 complete', () async {
      // 拆分行目录下异常存在一张归一化副本（按构造不该有）：快照时
      // 已判可选，暂存区丢失也不警告。
      const parentOriginal = 'imports/task-parent/original.png';
      await writeBytes(parentOriginal, [7, 7, 7]);
      await insertTask(
        id: 'task-1795135761439-818830-1-0',
        sourcePath: parentOriginal,
        fileName: 'photo.png',
        status: 'pendingOrganize',
        questionId: 'q1',
      );
      await writeBytes(
        'imports/task-1795135761439-818830-1-0/page-normalized.png',
        [4, 5, 6],
      );
      final report = await _backup(
        db,
        dataDir,
        onStagedForTest: (stagingDir, _) => File(p.join(
          stagingDir.path,
          'imports/task-1795135761439-818830-1-0/page-normalized.png',
        )).deleteSync(),
      );
      expect(report.warnings, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      expectNoStagingLeft();
    });
  });

  group('Q4 §1.9：回收站清扫的文件条目走引用集口径复查', () {
    test('任务行仍在的归一化副本在回收站里超 7 天 → 留下', () async {
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
      );
      await writeBytes('imports/t1/original.jpg', jfifJpeg());
      seedTrashEntry(
        'old-norm.png',
        'imports/t1/page-normalized.png',
      );
      final result = await AppDatabase.sweepTrashFrom(
        db,
        dataDir: dataDir.path,
      );
      expect(result.deletedCount, 0);
      expect(result.keptReferencedCount, 1);
      expect(
        File(p.join(dataDir.path, '.trash', 'old-norm.png')).existsSync(),
        isTrue,
      );
    });

    test('任务行已删的归一化副本超 7 天 → 物理删除（对照）', () async {
      seedTrashEntry(
        'old-norm.png',
        'imports/t9/page-normalized.png',
      );
      final result = await AppDatabase.sweepTrashFrom(
        db,
        dataDir: dataDir.path,
      );
      expect(result.deletedCount, 1);
      expect(result.keptReferencedCount, 0);
      expect(
        File(p.join(dataDir.path, '.trash', 'old-norm.png')).existsSync(),
        isFalse,
      );
    });
  });
}
