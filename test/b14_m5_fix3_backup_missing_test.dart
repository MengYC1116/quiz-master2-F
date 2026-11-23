// 十四批 M5 修复轮 3（B 路，D-155 / GPT fix2 P1-2；D-158 修正）：备份缺失资产处理。
//
// 旧行为：备份复制文件时缺失/不可读只对图块加 warning，普通题目切片、
// 页图或其他直接引用文件缺失时直接跳过、不告警——backup.json 有引用、
// ZIP 里没文件、warnings 还可能为空，用户得到看似成功实际不完整的备份。
// 新口径：库行直接引用的资产（题目的 source_path / page_image_path /
// slice_path、收集任务的 source_path、识别任务的 crop_path）缺失或
// 无法读取时备份直接失败（BackupRestoreException，指明题目/任务 ID 与
// 相对路径）；只在派生保护里的文件（任务的 page-normalized.png、
// pages/ 下页图、original.* 枚举，未渲染过的任务本来就没有）缺失/
// 不可读时逐项警告、不阻断备份。
// 二十批 P6 修法 A（D-237 提案）更新：派生文件只在快照时点存在才进
// 清单——按构造从未生成的文件（拆分行、PDF 行、EXIF == 1 行等）缺失
// 时不警告；Q4 的必需/可选分类与 O2 警告已删除，
// 见 b14_win11_r3_q4 专项测试与 b20_p6_backup_existence_gate_test。例外（D-158）：图块裁图缺失/不可读/
// 路径非法时只警告、不阻断（图块可从切片 + bbox 再生，M2 P1-6 既定口径
// “单个图块失败不阻断备份”；警告须列出题目）。图块损坏（读得出但解不
// 出图）仍只警告。全部用临时目录 / 内存库，不碰真实用户库。
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
) => AppDatabase.exportBackupZipFromWithReport(db, dataDir: dataDir.path);

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
    String? pageImagePath,
    String? sourcePath,
  }) async {
    await AppDatabase.upsertQuestionInto(
      db,
      Question(
        id: id,
        title: '题 $id',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 18),
        slicePath: slicePath,
        pageImagePath: pageImagePath,
        sourcePath: sourcePath,
      ),
    );
  }

  /// 备份一致性不变量：backup.json 里每一道题引用的全部文件都必须
  /// 出现在 ZIP 条目里（成功备份的前提；失败备份不适用——失败即无报告）。
  /// 图块例外（D-158）：图块缺失时备份成功、警告列出题目，ZIP 里可以没有
  /// 该裁图文件——本 helper 只用于文件齐全的场景，不对缺图场景调用。
  void expectBackupConsistent(
    Map<String, dynamic> decoded,
    Set<String> zipNames,
  ) {
    final questions = decoded['questions'] as List;
    for (final row in questions) {
      final m = row as Map<String, dynamic>;
      final refs = <String>{
        for (final col in ['source_path', 'page_image_path', 'slice_path'])
          if (m[col] is String && (m[col] as String).isNotEmpty)
            m[col] as String,
      };
      final figures = m['ocr_figures'];
      if (figures is String && figures.isNotEmpty) {
        for (final item in jsonDecode(figures) as List) {
          final crop = (item as Map<String, dynamic>)['crop_path'];
          if (crop is String && crop.isNotEmpty) refs.add(crop);
        }
      }
      for (final ref in refs) {
        expect(
          zipNames,
          contains(ref),
          reason: '题目 ${m['id']} 在 backup.json 里引用了 $ref，但 ZIP 里没有该文件',
        );
      }
    }
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
    dataDir = Directory.systemTemp.createTempSync('b14_m5_fix3_backup_');
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

  group('十四批 M5 修复轮 3：直接引用资产缺失/不可读即备份失败', () {
    test('切片文件缺失：备份失败，错误指明题目 ID 与相对路径', () async {
      await insertQuestion('q1', slicePath: 'slices/q1.png');
      // 只建题行，不写切片文件。
      Object? caught;
      try {
        await _backup(db, dataDir);
      } catch (e) {
        caught = e;
      }
      expect(
        caught,
        isA<BackupRestoreException>(),
        reason: '切片缺失必须使备份失败，不能返回看似成功的报告',
      );
      final message = (caught as BackupRestoreException).message;
      expect(message, contains('q1'), reason: '失败信息须指明题目 ID');
      expect(message, contains('slices/q1.png'), reason: '失败信息须指明相对路径');
      expectNoStagingLeft();
    });

    test('页图缺失：备份失败，错误指明题目 ID 与相对路径', () async {
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion(
        'q1',
        slicePath: 'slices/q1.png',
        pageImagePath: 'slices/q1-page.png',
      );
      Object? caught;
      try {
        await _backup(db, dataDir);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackupRestoreException>());
      final message = (caught as BackupRestoreException).message;
      expect(message, contains('q1'));
      expect(message, contains('slices/q1-page.png'));
      expectNoStagingLeft();
    });

    test(
      '普通引用文件读取失败：备份失败，错误指明题目 ID 与相对路径',
      skip: Platform.isWindows
          ? 'Windows 普通权限下创建不可读 symlink 失败，测试前置条件建不起来'
          : false,
      () async {
      // 故障注入：切片路径上放一个指向 /proc/self/mem 的软链——
      // File.existsSync() 为真（跟随链接后是文件），readAsBytes()
      // 确定性抛 EIO（FileSystemException）。不用 chmod：测试以 root
      // 跑，root 能绕过只读权限；不用“文件换目录”：File 对目录路径
      // 的 existsSync() 为 false，会走缺失分支而不是读取失败分支。
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion('q1', slicePath: 'slices/q1.png');
      final link = Link(p.join(dataDir.path, 'slices/q1.png'));
      await File(p.join(dataDir.path, 'slices/q1.png')).delete();
      await link.create('/proc/self/mem');
      expect(File(p.join(dataDir.path, 'slices/q1.png')).existsSync(), isTrue);
      Object? caught;
      try {
        await _backup(db, dataDir);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackupRestoreException>());
      final message = (caught as BackupRestoreException).message;
      expect(message, contains('q1'));
      expect(message, contains('slices/q1.png'));
      expect(message, contains('无法读取'));
      expectNoStagingLeft();
    });

    test('收集任务原文件缺失：备份失败，错误指明任务 ID 与相对路径', () async {
      await db.customInsert(
        'INSERT INTO collect_tasks (id, name, file_name, subject_id, status, '
        'progress, page_count, page, error, question_id, created_at, '
        'source_path, page_rotations) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('task-1'),
          Variable.withString('任务 task-1'),
          Variable.withString('m.pdf'),
          Variable.withString('math'),
          Variable.withString('needBox'),
          Variable.withInt(100),
          Variable.withInt(1),
          Variable.withInt(1),
          const Variable<String>(null),
          const Variable<String>(null),
          Variable.withInt(1700000000000),
          Variable.withString('imports/task-1/original.pdf'),
          Variable.withString('{}'),
        ],
      );
      Object? caught;
      try {
        await _backup(db, dataDir);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackupRestoreException>());
      final message = (caught as BackupRestoreException).message;
      expect(message, contains('task-1'));
      expect(message, contains('imports/task-1/original.pdf'));
      expectNoStagingLeft();
    });

    test('图块裁图缺失：备份成功，警告列出题目（D-158：图块可从切片再生，不阻断备份）', () async {
      // ocr_figures JSON 里写一条 crop_path，但不写裁图文件。
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await AppDatabase.upsertQuestionInto(
        db,
        Question(
          id: 'q1',
          title: '题 q1',
          subjectId: 'math',
          createdAt: DateTime(2026, 11, 18),
          slicePath: 'slices/q1.png',
          ocrFigures: '[{"crop_path": "slices/q1-fig.png"}]',
        ),
      );
      final report = await _backup(db, dataDir);
      expect(report.warnings.join('\n'), contains('题 q1'));
      final decoded = decodeReport(report);
      expect(decoded.zipNames, isNot(contains('slices/q1-fig.png')));
      expect(decoded.zipNames, contains('slices/q1.png'));
      expectNoStagingLeft();
    });
  });

  group('二十批 P6 修法 A：派生文件只在存在时枚举（原 Q4 必需/可选分类已删除，D-237）', () {
    test('PDF 任务的归一化副本缺失：备份成功且无警告、状态 complete（修法 A）', () async {
      await db.customInsert(
        'INSERT INTO collect_tasks (id, name, file_name, subject_id, status, '
        'progress, page_count, page, error, question_id, created_at, '
        'source_path, page_rotations) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('task-1'),
          Variable.withString('任务 task-1'),
          Variable.withString('m.pdf'),
          Variable.withString('math'),
          Variable.withString('needBox'),
          Variable.withInt(100),
          Variable.withInt(1),
          Variable.withInt(1),
          const Variable<String>(null),
          const Variable<String>(null),
          Variable.withInt(1700000000000),
          Variable.withString('imports/task-1/original.pdf'),
          Variable.withString('{}'),
        ],
      );
      // 修法 A（D-237）：PDF 行只走 _importPdf，归一化副本按构造就
      // 不存在，缺失是预期行为——不在清单里，不警告、不进
      // brokenFiles、不变 partial。
      await writeBytes('imports/task-1/original.pdf', [1, 2, 3]);
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      expect(report.brokenFiles, isEmpty);
      expect(report.status, BackupExportStatus.complete);
      final decoded = decodeReport(report);
      expect(
        decoded.zipNames,
        contains('imports/task-1/original.pdf'),
      );
      expectNoStagingLeft();
    });
  });

  group('十四批 M5 修复轮 3：备份不变量', () {
    test('完整备份成功且无警告时，JSON 引用的文件全在 ZIP 里', () async {
      await writeBytes('slices/q1.png', [1, 2, 3]);
      await insertQuestion('q1', slicePath: 'slices/q1.png');
      await writeBytes('slices/q2.png', [4, 5, 6]);
      await insertQuestion('q2', slicePath: 'slices/q2.png');
      final report = await _backup(db, dataDir);
      expect(report.warnings, isEmpty);
      final decoded = decodeReport(report);
      expectBackupConsistent(decoded.decoded, decoded.zipNames);
      expect(decoded.zipNames, contains('slices/q1.png'));
      expect(decoded.zipNames, contains('slices/q2.png'));
      expectNoStagingLeft();
    });

    test('一题缺失、一题完整：备份整体失败，不返回“成功且无警告”的不完整报告', () async {
      await writeBytes('slices/q2.png', [4, 5, 6]);
      await insertQuestion('q2', slicePath: 'slices/q2.png');
      await insertQuestion('q1', slicePath: 'slices/q1.png');
      // q1 切片缺失：备份必须抛错；绝不能出现“返回报告、warnings 为空、
      // 但 backup.json 引用了 ZIP 里没有的 slices/q1.png”这一结果。
      Object? caught;
      try {
        await _backup(db, dataDir);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<BackupRestoreException>());
      expectNoStagingLeft();
    });
  });
}
