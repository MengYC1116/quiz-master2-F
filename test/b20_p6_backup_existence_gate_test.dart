// 二十批 P6 修法 A（D-237 提案）：备份派生引用只在文件存在时枚举。
//
// 门禁落点：`exportBackupZipFromWithReportImpl` 锁内快照之后、复制循环
// 之前——引用集里除直接引用与图块裁图之外的派生路径，在快照时点逐个
// 查存在性，不在盘上的直接从清单里去掉，不警告、不进 brokenFiles、
// 不变 partial；Q4 的 `_isOptionalNormalized` 逐类打补丁已删除。
// 孤儿保护（`_referencedRelativePaths`，行存在即保护）原语义不动。
//
// 本文件覆盖修法 A 的关键情形：
// 1. 按构造不该有的文件（拆分行 / PDF 行 / EXIF 方向 6 但副本缺失）
//    不警告、不 partial——其中方向 6 缺失是修法 A 有意的取舍：该信号
//    本身有歧义（真丢失 vs 当初静默降级未生成，Q4 调查 §2.5），且副本
//    可由原图再生（原图是直接引用，缺失即整单抛错），备份里不丢任何
//    不可替代的数据；
// 2. 直接引用缺失仍整单抛错（D-155 底线）；
// 3. 配图缺失仍警告、不阻断（D-158 底线）；
// 4. 快照时已在盘上的派生文件在暂存区丢失仍警告——“真丢仍警告”的信号
//    在修法 A 下只对快照时真实存在过的文件保留。
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
        ocrFigures: ocrFigures ?? '[]',
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
  /// 备份分类只读 EXIF 头，不解码像素；修法 A 下本 helper 只用于构造
  // “方向 6 且哈希可信”的取舍用例）。
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

  String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    dataDir = Directory.systemTemp.createTempSync('b20_p6_backup_gate_');
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

  group('修法 A：按构造不该有的文件不警告、不 partial', () {
    test('拆分行（38 行误报形状的缩小版）：complete、零警告', () async {
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
      expect(report.warnings, isEmpty, reason: '拆分行按构造就没有归一化副本，门禁在枚举阶段已去掉');
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

    test('PDF 行：归一化副本缺失不警告、仍 complete', () async {
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.pdf',
        fileName: 'doc.pdf',
      );
      await writeBytes('imports/t1/original.pdf', [1, 2, 3]);
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.brokenFiles, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      expectNoStagingLeft();
    });

    test('方向 6 且哈希可信、副本缺失：不警告、仍 complete（有意的取舍，D-237）', () async {
      // Q4 曾对此记一条注明歧义的警告（O2）；修法 A 下门禁在枚举阶段
      // 直接去掉，不再区分必需/可选。取舍理由：信号本身有歧义
      // （真丢失 vs 当初静默降级未生成，调查 §2.5 完全同构），且副本
      // 可由原图再生——原图是直接引用，缺失即整单抛错，备份里不丢
      // 任何不可替代的数据。
      final bytes = exifJpeg(6);
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
        sourceHash: sha256Of(bytes),
      );
      await writeBytes('imports/t1/original.jpg', bytes);
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.brokenFiles, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      expectNoStagingLeft();
    });

    test('归一化副本在盘上：进包、无警告', () async {
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
  });

  group('修法 A：底线——直接引用缺失仍整单抛错（D-155）', () {
    test('题目切片缺失：抛错，门禁不得把它静默掉', () async {
      await insertQuestion('q1', slicePath: 'slices/q1.png');
      Object? caught;
      try {
        await _backup(db, dataDir);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackupRestoreException>());
      expect((caught as BackupRestoreException).message, contains('slices/q1.png'));
      expectNoStagingLeft();
    });

    test('收集任务原图缺失：抛错', () async {
      await insertTask(
        id: 't1',
        sourcePath: 'imports/t1/original.jpg',
        fileName: 'photo.jpg',
      );
      Object? caught;
      try {
        await _backup(db, dataDir);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackupRestoreException>());
      expect(
        (caught as BackupRestoreException).message,
        contains('imports/t1/original.jpg'),
      );
      expectNoStagingLeft();
    });
  });

  group('修法 A：底线——配图缺失仍警告、不阻断（D-158）', () {
    test('图块裁图缺失：备份成功，警告列出题目、状态 partial', () async {
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion(
        'q1',
        slicePath: 'slices/q1.png',
        ocrFigures: '[{"crop_path": "slices/q1-fig.png"}]',
      );
      final report = await _backup(db, dataDir);
      expect(report.status, BackupExportStatus.partial);
      expect(report.brokenFiles, contains('slices/q1-fig.png'));
      expect(report.warnings.join('\n'), contains('题 q1'));
      final decoded = decodeReport(report);
      expect(decoded.zipNames, contains('slices/q1.png'));
      expect(decoded.zipNames, isNot(contains('slices/q1-fig.png')));
      expectNoStagingLeft();
    });
  });

  group('修法 A：快照时在盘上的派生文件真丢仍警告', () {
    test('归一化副本在暂存区被删：警告 + partial', () async {
      // 门禁只去掉“快照时就不在盘上”的派生文件；在盘上即进清单，
      // 之后丢了就是真实丢失，按通用派生口径警告。
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
  });
}
