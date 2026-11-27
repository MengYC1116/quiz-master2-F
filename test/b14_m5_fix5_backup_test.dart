// 十四批 M5 修复轮 5（D-162；GPT fix4 §7 新增 P1）：
// 备份引用集入口 fail-closed——越界直接引用被引用集静默丢弃的修复。
//
// 背景：`_toDataRelative` 对越出数据目录的引用返回 null，
// `_directlyReferencedRelativePaths` / `_referencedRelativePaths`
// 直接丢弃它，备份仍成功、零警告，但 backup.json 仍引用该文件，
// 与 D-155 fail-closed 冲突。本轮在备份快照内并行建一份非法引用
// 收集（原始路径、归属、类别、原因），锁内、复制循环前按类别处理：
// 关键直接引用非法 → 抛错终止备份；图块/派生非法 → warning。
// 归一化后仍在数据目录内的 `..` 是合法的，按原规则正常处理。
// 孤儿扫描与恢复复核不走本收集，不改原函数语义。
// 全部用临时目录 / 内存库，不碰真实用户库。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/models/models.dart';

Future<({List<int> bytes, List<String> warnings, List<String> brokenFiles, BackupExportStatus status})> _backup(
  QuizDatabase db,
  Directory dataDir,
) => AppDatabase.exportBackupZipFromWithReport(
  db,
  dataDir: dataDir.path,
);

void main() {
  late QuizDatabase db;
  late Directory dataDir;

  Future<void> writeBytes(String rel, List<int> bytes) async {
    final f = File(p.join(dataDir.path, rel));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
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
        ocrFigures: ocrFigures ?? '',
      ),
    );
  }

  Future<void> insertTask(String id, String sourcePath) async {
    await db.customInsert(
      'INSERT INTO collect_tasks (id, name, file_name, subject_id, status, '
      'progress, page_count, page, error, question_id, created_at, '
      'source_path, page_rotations) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable.withString(id),
        Variable.withString('任务 $id'),
        Variable.withString('m.pdf'),
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

  /// 数据目录下不得残留备份暂存区（失败也要清理，见 finally；
  /// D-162 的直接引用非法失败发生在建暂存区之前，更不应有残留）。
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
    dataDir = Directory.systemTemp.createTempSync('b14_m5_fix5_backup_');
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

  group('十四批 M5 修复轮 5（D-162）：越界切片引用即备份失败', () {
    test('切片 ../escape.png：导出抛错，指明题目、原始路径与“路径非法”', () async {
      await insertQuestion('q1', slicePath: '../escape.png');
      Object? caught;
      try {
        await _backup(db, dataDir);
      } catch (e) {
        caught = e;
      }
      expect(
        caught,
        isA<BackupRestoreException>(),
        reason: '越界切片引用被引用集排除时，备份仍须失败，不能返回不完整 ZIP',
      );
      final message = (caught as BackupRestoreException).message;
      expect(
        message,
        contains('题目「题 q1」'),
        reason: '失败信息须指明归属题目（F3：列题名，不列题目 ID）',
      );
      expect(message, contains('../escape.png'), reason: '失败信息须列出原始路径');
      expect(message, contains('路径非法'));
      expect(message, contains('备份失败'));
      expectNoStagingLeft();
    });

    test('切片 slices/../../escape.png：导出抛错，指明题目与原始路径', () async {
      await insertQuestion('q1', slicePath: 'slices/../../escape.png');
      Object? caught;
      try {
        await _backup(db, dataDir);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackupRestoreException>());
      final message = (caught as BackupRestoreException).message;
      expect(message, contains('题目「题 q1」'));
      expect(message, contains('slices/../../escape.png'));
      expect(message, contains('路径非法'));
      expectNoStagingLeft();
    });

    test('收集任务原文件越界：导出抛错，指明任务与原始路径', () async {
      await insertTask('t1', '../../outside.pdf');
      Object? caught;
      try {
        await _backup(db, dataDir);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackupRestoreException>());
      final message = (caught as BackupRestoreException).message;
      expect(message, contains('收集任务「t1」'), reason: '失败信息须指明归属任务');
      expect(message, contains('../../outside.pdf'), reason: '失败信息须列出原始路径');
      expect(message, contains('路径非法'));
      expectNoStagingLeft();
    });
  });

  group('十四批 M5 修复轮 5（D-162）：越界图块/派生只警告、不阻断', () {
    test('越界图块裁图：备份成功，警告列出题目与原始路径、ZIP 里无该图块', () async {
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion(
        'q1',
        slicePath: 'slices/q1.png',
        ocrFigures: '[{"crop_path": "../escape-fig.png"}]',
      );
      final report = await _backup(db, dataDir);
      final joined = report.warnings.join('\n');
      expect(joined, contains('题 q1'), reason: '警告须列出题目');
      expect(joined, contains('../escape-fig.png'), reason: '警告须列出原始路径');
      expect(joined, contains('路径非法'));
      final decoded = decodeReport(report);
      expect(decoded.zipNames, contains('slices/q1.png'));
      expect(decoded.zipNames, isNot(contains('../escape-fig.png')));
      expectNoStagingLeft();
    });

    test('越界派生路径：备份成功，警告列出归属任务与原始路径', () async {
      // 任务 id `..` 使构造派生路径归一化后落在 imports/<taskId>/
      // 之外（`imports/../page-normalized.png` → 数据目录根的
      // `page-normalized.png`）：这是经公开导出 API 可达的唯一
      // 越界派生形态——构造派生路径本身不可能越出数据目录，
      // 故派生非法的判定是“归一化后不在 imports/ 或 slices/ 下”
      // （见 D-162）。直接引用 `imports/../original.pdf` 归一化
      // 后仍在数据目录内，按原规则正常处理，不抛错。
      await insertTask('..', 'imports/../original.pdf');
      await writeBytes('pages/p.png', [1, 2, 3]);
      await writeBytes('original.pdf', [1, 2, 3]);
      // 派生枚举要经过 `imports/` 才能走到 `..` 之外的目录：
      // `Directory('.../imports/../pages')` 只有在 `imports/` 真实
      // 存在时才能遍历（与 _referencedRelativePaths 的既有枚举行为
      // 一致——中间目录不存在时 OS 无法穿越 `..`）。先建一个空的
      // imports/ 目录，使 pages/ 与数据目录根的枚举可达。
      Directory(p.join(dataDir.path, 'imports')).createSync();
      final report = await _backup(db, dataDir);
      final joined = report.warnings.join('\n');
      expect(
        joined,
        contains('收集任务「..」的派生文件 imports/../page-normalized.png 路径非法'),
        reason: '警告须列出归属任务与原始派生路径',
      );
      expect(
        joined,
        contains('收集任务「..」的派生文件 imports/../pages/p.png 路径非法'),
      );
      expect(
        joined,
        contains('收集任务「..」的派生文件 imports/../original.pdf 路径非法'),
      );
      expect(report.warnings.where((w) => w.contains('备份失败')), isEmpty);
      expectNoStagingLeft();
    });
  });

  group('十四批 M5 修复轮 5（D-162）：合法的内部 .. 归一化路径按原规则处理', () {
    test('切片 slices/../slices/q1.png：备份成功、无警告、ZIP 里有归一化后的切片', () async {
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion('q1', slicePath: 'slices/../slices/q1.png');
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty, reason: '内部 .. 归一化后仍在数据目录内，不应记非法');
      final decoded = decodeReport(report);
      expect(decoded.zipNames, contains('slices/q1.png'));
      expectNoStagingLeft();
    });
  });
}
