// WP-C #8 U3：备份一致性——回收站 + 引用未知 fail-closed + 备份 BROKEN/PARTIAL + 写路径持锁。
// TDD：先写失败测试，再改代码。只用合成库（内存库 + 临时数据目录），不碰真实库。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/figure_files.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/services/pdf_render_service.dart';

Future<QuizDatabase> openTestDb() => AppDatabase.openForTest();

File writeDataFile(Directory tmp, String rel, List<int> bytes) {
  final f = File(p.join(tmp.path, rel))..createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  return f;
}

Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(10, 20, 30));
  return img.encodePng(image);
}

/// 1×1 假 PDF 引擎：只产一页 10×10 PNG，不碰真实 PDFium。
class _FakePdfEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) async => _FakeDoc();
}

class _FakeDoc implements PdfEngineDocument {
  @override
  int get pageCount => 1;

  @override
  Future<PdfPageRender> renderPage(
    int page, {
    required int targetLongEdge,
  }) async {
    final png = _png(10, 10);
    return PdfPageRender(png: png, width: 10, height: 10);
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Directory tmp;
  late QuizDatabase db;
  late QuestionRepository repo;

  Future<Question> insertQuestion({
    required String id,
    String? slicePath,
    String ocrFigures = '[]',
  }) async {
    final q = Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      createdAt: DateTime(2026, 11, 18),
      slicePath: slicePath,
      ocrFigures: ocrFigures,
    );
    await AppDatabase.upsertQuestionInto(db, q);
    return q;
  }

  Future<void> seedTask({required String id, required String sourcePath}) async {
    await db.customInsert(
      'INSERT INTO collect_tasks (id, name, file_name, subject_id, status, '
      'progress, page_count, page, error, question_id, created_at, '
      'source_path, page_rotations) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?, ?)',
      variables: [
        Variable.withString(id),
        Variable.withString('任务 $id'),
        Variable.withString('m.pdf'),
        Variable.withString('math'),
        Variable.withString('needBox'),
        Variable.withInt(100),
        Variable.withInt(2),
        Variable.withInt(1),
        const Variable<String>(null),
        const Variable<String>(null),
        Variable.withInt(1700000000000),
        Variable.withString(sourcePath),
        Variable.withString('{}'),
      ],
    );
  }

  /// 回收站清单条目（`.trash/manifest.json` 的 entries 数组）。
  List<Map<String, Object?>> readManifest() {
    final f = File(p.join(tmp.path, '.trash', 'manifest.json'));
    if (!f.existsSync()) return [];
    final decoded = jsonDecode(f.readAsStringSync());
    if (decoded is! Map<String, Object?>) return [];
    final entries = decoded['entries'];
    if (entries is! List) return [];
    return entries.whereType<Map<String, Object?>>().toList();
  }

  /// 把某条目（按原相对路径找）的移入时间改成 N 天前。
  void ageTrashEntry(String originalRel, {required int daysAgo}) {
    final f = File(p.join(tmp.path, '.trash', 'manifest.json'));
    final decoded =
        jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    final entries = (decoded['entries'] as List).cast<Map<String, Object?>>();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in entries) {
      if (e['originalRel'] == originalRel) {
        e['movedAtMs'] = now - daysAgo * 24 * 3600 * 1000;
      }
    }
    f.writeAsStringSync(jsonEncode({'entries': entries}));
  }

  /// 回收站里的全部条目文件/目录名。
  List<String> trashNames() {
    final dir = Directory(p.join(tmp.path, '.trash'));
    if (!dir.existsSync()) return [];
    return dir
        .listSync()
        .map((e) => p.basename(e.path))
        .where((n) => n != 'manifest.json')
        .toList();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('wp-c8-u3-');
    AppDatabase.testDataDirectory = tmp.path;
    db = await openTestDb();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
    addTearDown(() async {
      AppDatabase.testDataDirectory = null;
      try {
        await db.close();
      } catch (_) {}
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
  });

  tearDown(() {
    FileLifecycleGuard.instance.debugClearPendingForTest();
    FileLifecycleGuard.instance.debugClearStagingForTest();
  });

  group('U3-2 回收站：删 → 移入回收站，启动清扫才物理删除', () {
    test('删题后切片与图块进回收站，原路径消失、清单有记录', () async {
      writeDataFile(tmp, 'slices/q1.png', _png(100, 50));
      writeDataFile(tmp, 'slices/q1-fig-0.png', _png(50, 20));
      final q = await insertQuestion(
        id: 'q1',
        slicePath: 'slices/q1.png',
        ocrFigures:
            '[{"id":"figure-q1-0","crop_path":"slices/q1-fig-0.png"}]',
      );
      await repo.delete(q);
      expect(File(p.join(tmp.path, 'slices/q1.png')).existsSync(), isFalse);
      expect(
        File(p.join(tmp.path, 'slices/q1-fig-0.png')).existsSync(),
        isFalse,
      );
      final entries = readManifest();
      expect(
        entries.map((e) => e['originalRel']).toSet(),
        containsAll(['slices/q1.png', 'slices/q1-fig-0.png']),
      );
      expect(trashNames().length, 2);
      // 回收站不进孤儿扫描：扫描结果里没有回收站文件。
      final scan =
          await AppDatabase.scanOrphanFilesFrom(db, dataDir: tmp.path);
      expect(scan.files, isEmpty);
    });

    test('清扫：7 天内不删', () async {
      writeDataFile(tmp, 'slices/q1.png', _png(100, 50));
      final q = await insertQuestion(id: 'q1', slicePath: 'slices/q1.png');
      await repo.delete(q);
      final result = await AppDatabase.sweepTrashFrom(db, dataDir: tmp.path);
      expect(result.deletedCount, 0);
      expect(trashNames().length, 1);
      expect(readManifest().length, 1);
    });

    test('清扫：超过 7 天物理删除，清单条目同步去掉', () async {
      writeDataFile(tmp, 'slices/q1.png', [1, 2, 3, 4]);
      final q = await insertQuestion(id: 'q1', slicePath: 'slices/q1.png');
      await repo.delete(q);
      ageTrashEntry('slices/q1.png', daysAgo: 8);
      final result = await AppDatabase.sweepTrashFrom(db, dataDir: tmp.path);
      expect(result.deletedCount, 1);
      expect(result.freedBytes, 4);
      expect(trashNames(), isEmpty);
      expect(readManifest(), isEmpty);
    });

    test('清扫重查：超过 7 天但仍有引用 → 留下', () async {
      writeDataFile(tmp, 'slices/q1.png', _png(100, 50));
      final q = await insertQuestion(id: 'q1', slicePath: 'slices/q1.png');
      await repo.delete(q);
      ageTrashEntry('slices/q1.png', daysAgo: 8);
      // 同一路径又被新题引用（删除与清扫之间重新入库）。
      await insertQuestion(id: 'q2', slicePath: 'slices/q1.png');
      final result = await AppDatabase.sweepTrashFrom(db, dataDir: tmp.path);
      expect(result.deletedCount, 0);
      expect(result.keptReferencedCount, 1);
      expect(trashNames().length, 1);
      expect(readManifest().length, 1);
    });

    test('孤儿清理移入回收站，不直接物理删除', () async {
      writeDataFile(tmp, 'slices/orphan.png', [9, 9]);
      final result = await AppDatabase.deleteOrphanFiles(
        ['slices/orphan.png'],
        dataDir: tmp.path,
        db: db,
      );
      expect(result.deletedCount, 1);
      expect(File(p.join(tmp.path, 'slices/orphan.png')).existsSync(), isFalse);
      expect(readManifest().map((e) => e['originalRel']), [
        'slices/orphan.png',
      ]);
      expect(trashNames().length, 1);
    });

    test('任务目录删除整目录进回收站，清扫超 7 天才删目录', () async {
      await seedTask(id: 't1', sourcePath: 'imports/t1/original.pdf');
      writeDataFile(tmp, 'imports/t1/original.pdf', [1]);
      writeDataFile(tmp, 'imports/t1/pages/page-001.png', [2]);
      await AppDatabase.deleteCollectTaskFrom(db, 't1');
      expect(Directory(p.join(tmp.path, 'imports/t1')).existsSync(), isFalse);
      expect(readManifest().map((e) => e['originalRel']), ['imports/t1/']);
      ageTrashEntry('imports/t1/', daysAgo: 8);
      final result = await AppDatabase.sweepTrashFrom(db, dataDir: tmp.path);
      expect(result.deletedCount, 1);
      expect(trashNames(), isEmpty);
    });

    test('清单损坏时清扫永不删，记日志', () async {
      final logs = <String>[];
      final oldPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      try {
        writeDataFile(tmp, 'slices/q1.png', [1, 2, 3]);
        final q = await insertQuestion(id: 'q1', slicePath: 'slices/q1.png');
        await repo.delete(q);
        ageTrashEntry('slices/q1.png', daysAgo: 8);
        File(
          p.join(tmp.path, '.trash', 'manifest.json'),
        ).writeAsStringSync('不是 json');
        final result = await AppDatabase.sweepTrashFrom(
          db,
          dataDir: tmp.path,
        );
        expect(result.deletedCount, 0);
        expect(result.keptUnknownCount, 1);
        expect(trashNames().length, 1);
        expect(logs.any((l) => l.contains('回收站') && l.contains('清单')), isTrue);
      } finally {
        debugPrint = oldPrint;
      }
    });
  });

  group('U3-2 引用未知：ocrFigures JSON 解析失败 → 永不删除', () {
    test('删题时不删切片与图块，并记日志', () async {
      final logs = <String>[];
      final oldPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      try {
        writeDataFile(tmp, 'slices/q1.png', _png(100, 50));
        writeDataFile(tmp, 'slices/q1-fig-0.png', _png(50, 20));
        final q = await insertQuestion(
          id: 'q1',
          slicePath: 'slices/q1.png',
          ocrFigures: '{不是合法 JSON',
        );
        await repo.delete(q);
        // 引用未知：连回收站都不进，原地保留。
        expect(File(p.join(tmp.path, 'slices/q1.png')).existsSync(), isTrue);
        expect(
          File(p.join(tmp.path, 'slices/q1-fig-0.png')).existsSync(),
          isTrue,
        );
        expect(readManifest(), isEmpty);
        expect(logs.any((l) => l.contains('引用未知')), isTrue);
      } finally {
        debugPrint = oldPrint;
      }
    });

    test('孤儿清理未知时跳过 slices/ 候选，imports/ 仍可清', () async {
      await insertQuestion(id: 'q1', ocrFigures: '[{坏结构}]');
      writeDataFile(tmp, 'slices/orphan.png', [5]);
      writeDataFile(tmp, 'imports/gone-task/x.png', [6]);
      final result = await AppDatabase.deleteOrphanFiles(
        ['slices/orphan.png', 'imports/gone-task/x.png'],
        dataDir: tmp.path,
        db: db,
      );
      expect(result.deletedCount, 1);
      expect(result.skippedReferencedCount, 1);
      expect(File(p.join(tmp.path, 'slices/orphan.png')).existsSync(), isTrue);
      expect(
        File(p.join(tmp.path, 'imports/gone-task/x.png')).existsSync(),
        isFalse,
      );
    });

    test('清扫未知时 slices/ 条目永不删', () async {
      await insertQuestion(id: 'q1', ocrFigures: 'null 不是列表');
      writeDataFile(tmp, 'slices/old.png', [7]);
      final q2 = await insertQuestion(id: 'q2', slicePath: 'slices/old.png');
      await repo.delete(q2);
      // 删题时未知已拦下一次：文件还在原地；手动模拟一条已进回收站的旧条目。
      final trashDir = Directory(p.join(tmp.path, '.trash'))
        ..createSync(recursive: true);
      final moved = File(p.join(trashDir.path, 'old-trash.png'));
      await File(p.join(tmp.path, 'slices/old.png')).rename(moved.path);
      File(p.join(trashDir.path, 'manifest.json')).writeAsStringSync(
        jsonEncode({
          'entries': [
            {
              'trashName': 'old-trash.png',
              'originalRel': 'slices/old.png',
              'movedAtMs':
                  DateTime.now().millisecondsSinceEpoch -
                      8 * 24 * 3600 * 1000,
            },
          ],
        }),
      );
      final result = await AppDatabase.sweepTrashFrom(db, dataDir: tmp.path);
      expect(result.deletedCount, 0);
      expect(result.keptUnknownCount, 1);
      expect(moved.existsSync(), isTrue);
    });
  });

  group('U3-2 备份报告：BROKEN / PARTIAL，永不静默记 COMPLETE', () {
    test('图块缺失 → PARTIAL，brokenFiles 含该图块', () async {
      writeDataFile(tmp, 'slices/q1.png', _png(100, 50));
      await insertQuestion(
        id: 'q1',
        slicePath: 'slices/q1.png',
        ocrFigures:
            '[{"id":"figure-q1-0","crop_path":"slices/q1-fig-missing.png"}]',
      );
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: tmp.path,
      );
      expect(report.status, BackupExportStatus.partial);
      expect(report.brokenFiles, contains('slices/q1-fig-missing.png'));
      expect(report.warnings, isNotEmpty);
    });

    test('干净备份 → COMPLETE，brokenFiles 为空', () async {
      writeDataFile(tmp, 'slices/q1.png', _png(100, 50));
      await insertQuestion(id: 'q1', slicePath: 'slices/q1.png');
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: tmp.path,
      );
      expect(report.status, BackupExportStatus.complete);
      expect(report.brokenFiles, isEmpty);
      expect(report.warnings, isEmpty);
    });

    test('暂存区阶段图块丢失 → PARTIAL，brokenFiles 含该图块', () async {
      writeDataFile(tmp, 'slices/q1.png', _png(100, 50));
      writeDataFile(tmp, 'slices/q1-fig-0.png', _png(50, 20));
      await insertQuestion(
        id: 'q1',
        slicePath: 'slices/q1.png',
        ocrFigures:
            '[{"id":"figure-q1-0","crop_path":"slices/q1-fig-0.png"}]',
      );
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: tmp.path,
        onStagedForTest: (stagingDir, stagedRels) {
          // 模拟暂存区里的图块在 ZIP 组装前丢失。
          File(
            p.join(stagingDir.path, 'slices/q1-fig-0.png'),
          ).deleteSync();
        },
      );
      expect(report.status, BackupExportStatus.partial);
      expect(report.brokenFiles, contains('slices/q1-fig-0.png'));
    });

    test('ocrFigures 非法 JSON → PARTIAL 且有警告，不抛错', () async {
      writeDataFile(tmp, 'slices/q1.png', _png(100, 50));
      await insertQuestion(
        id: 'q1',
        slicePath: 'slices/q1.png',
        ocrFigures: '{坏 json',
      );
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: tmp.path,
      );
      expect(report.status, BackupExportStatus.partial);
      expect(
        report.warnings.any((w) => w.contains('无法解析')),
        isTrue,
      );
    });
  });

  group('U3-1 守门覆盖：写路径持锁', () {
    test('图块写文件：持锁时阻塞，放锁后才落盘', () async {
      final guard = FileLifecycleGuard.instance;
      final sliceBytes = _png(100, 50);
      final figure = OcrFigure(
        id: 'figure-q1-0',
        slicePath: 'slices/q1.png',
        inputHash: null,
        sequenceIndex: 0,
        anchorSource: 'fallback',
        anchorRef: '',
        bbox2d: const [10, 5, 60, 25],
        spaceWidth: 100,
        spaceHeight: 50,
        transform: const OcrRequestTransform(
          srcW: 100,
          srcH: 50,
          reqW: 100,
          reqH: 50,
          padX: 0,
          padY: 0,
        ),
        srcRect: const SrcRect(x: 10, y: 5, width: 50, height: 20),
        cropPath: '',
      );
      final releaseHolder = Completer<void>();
      final holderFuture = guard.withLock(() => releaseHolder.future);
      var done = false;
      final writeFuture = writeFigureFiles(
        dataDir: tmp.path,
        questionId: 'q1',
        sliceBytes: sliceBytes,
        figures: [figure],
      ).then((r) {
        done = true;
        return r;
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(done, isFalse);
      expect(guard.isLocked, isTrue);
      releaseHolder.complete();
      await holderFuture;
      final result = await writeFuture;
      expect(result.figures.single.cropPath, isNotEmpty);
      expect(
        File(
          p.join(tmp.path, result.figures.single.cropPath),
        ).existsSync(),
        isTrue,
      );
      // 收尾：解除登记，不影响同文件后续用例的 pending 断言。
      commitFigureFiles(result.registeredPaths);
    });

    test('PDF 页图渲染写盘：持锁时阻塞，放锁后才落盘', () async {
      final guard = FileLifecycleGuard.instance;
      final outDir = p.join(tmp.path, 'imports', 't1', 'pages');
      final releaseHolder = Completer<void>();
      final holderFuture = guard.withLock(() => releaseHolder.future);
      var done = false;
      final renderFuture = PdfRenderService(
        engine: _FakePdfEngine(),
      ).renderAllPagesToDir('fake.pdf', outDir).then((n) {
        done = true;
        return n;
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(done, isFalse);
      expect(guard.isLocked, isTrue);
      releaseHolder.complete();
      await holderFuture;
      expect(await renderFuture, 1);
      expect(File(p.join(outDir, 'page-001.png')).existsSync(), isTrue);
    });
  });
}
