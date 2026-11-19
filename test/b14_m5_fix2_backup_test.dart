// 十四批 M5 修复轮 2（B 路）：备份 JSON 与文件快照一致性（GPT 3.4 P1）+
// 引用口径统一（_directlyReferencedRelativePaths）。
// 全部用临时目录 / 内存库，不碰真实用户库。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/file_lifecycle_guard.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/stem_correction.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';

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

void main() {
  late QuizDatabase db;
  late Directory dataDir;
  late QuestionRepository repo;

  Future<String> writeSlice(String name, {int seed = 1}) async {
    final image = img.Image(width: 100, height: 50);
    img.fill(image, color: img.ColorRgb8(10 + seed, 20, 30));
    final bytes = img.encodePng(image);
    final rel = 'slices/$name.png';
    final abs = p.join(dataDir.path, rel);
    await File(abs).parent.create(recursive: true);
    await File(abs).writeAsBytes(bytes);
    return rel;
  }

  Future<String> sliceHash(String rel) async {
    final bytes = await File(p.join(dataDir.path, rel)).readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// 建一道带图块的题（走接受候选），返回图块裁图相对路径。
  Future<String> insertQuestionWithFigure(String id) async {
    final slice = await writeSlice(id);
    final hash = await sliceHash(slice);
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
    return parseOcrFigures(accepted.ocrFigures).single.cropPath;
  }

  /// 备份一致性不变量：backup.json 里每一道题引用的全部文件
  /// （source_path / page_image_path / slice_path / ocr_figures 的
  /// crop_path），都必须出现在 ZIP 条目里。删题只允许让题整行消失，
  /// 不允许“题还在、文件没了”。
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

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
    dataDir = Directory(AppDatabase.dataDirectoryPath());
    await dataDir.create(recursive: true);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
      AppDatabase.resetForTest();
    });
  });

  group('十四批 M5 修复轮 2：备份 JSON 与文件快照同一逻辑时点', () {
    test('备份读取期间并发删题：备份要么含整题+文件，要么不含该题，绝不出现 JSON 有引用而 ZIP 缺文件', () async {
      final crop1 = await insertQuestionWithFigure('q1');
      final crop2 = await insertQuestionWithFigure('q2');
      final q1 = (await AppDatabase.allQuestionsFrom(db)).singleWhere(
        (q) => q.id == 'q1',
      );

      // 锁门：先占住文件锁。备份在新实现里必须先取锁才碰数据库；
      // 旧实现则在锁外先导 JSON（这 200ms 内必导完），再排队等锁。
      // 这样删题的数据库提交必定落在“备份 JSON 已导 / 快照未取”的
      // 中间——旧实现在此必现不一致，新实现下快照在删题提交之后取，
      // 题整行消失，一致。
      final guard = FileLifecycleGuard.instance;
      final releaseHold = Completer<void>();
      addTearDown(() {
        if (!releaseHold.isCompleted) releaseHold.complete();
      });
      var holdEntered = false;
      final holdFuture = guard.withLock(() async {
        holdEntered = true;
        await releaseHold.future;
      });
      while (!holdEntered) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
      final backupFuture = AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      // 给旧实现留出锁外导 JSON 的时间（小库 16 张表，远小于 200ms）。
      await Future.delayed(const Duration(milliseconds: 200));
      // 删 q1：数据库事务提交后，物理删文件排队等锁（备份排在前面）。
      final deleteFuture = repo.delete(q1);
      // 等删题的数据库提交落地（行已消失），再放行备份。
      var waited = 0;
      while ((await AppDatabase.allQuestionsFrom(
        db,
      )).any((q) => q.id == 'q1')) {
        await Future.delayed(const Duration(milliseconds: 10));
        if (++waited > 500) {
          fail('删题的数据库提交 5 秒未落地');
        }
      }
      releaseHold.complete();
      final report = await backupFuture;
      await deleteFuture;
      await holdFuture;

      final archive = ZipDecoder().decodeBytes(report.bytes);
      final zipNames = archive.files.map((f) => f.name).toSet();
      final jsonEntry = archive.files.firstWhere(
        (f) => f.name == 'backup.json',
      );
      final decoded =
          jsonDecode(utf8.decode(jsonEntry.content as List<int>))
              as Map<String, dynamic>;
      // 核心不变量：JSON 有引用的题，文件必在 ZIP 里。
      expectBackupConsistent(decoded, zipNames);
      // 新实现下的确定终态：q1 的删题提交在快照之前，题整行不在备份里；
      // 未删的 q2 完整在备份里（备份不是空的、不是坏的）。
      final ids = (decoded['questions'] as List)
          .map((r) => (r as Map<String, dynamic>)['id'] as String)
          .toSet();
      expect(ids, isNot(contains('q1')));
      expect(ids, contains('q2'));
      expect(zipNames, contains('slices/q2.png'));
      expect(zipNames, contains(crop2));
      expect(zipNames, isNot(contains('slices/q1.png')));
      expect(zipNames, isNot(contains(crop1)));
      expect(report.warnings, isEmpty);
    });

    test('无并发时备份一致：JSON 引用的切片与图块全在 ZIP 里', () async {
      final crop1 = await insertQuestionWithFigure('q1');
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      expect(report.warnings, isEmpty);
      final archive = ZipDecoder().decodeBytes(report.bytes);
      final zipNames = archive.files.map((f) => f.name).toSet();
      final jsonEntry = archive.files.firstWhere(
        (f) => f.name == 'backup.json',
      );
      final decoded =
          jsonDecode(utf8.decode(jsonEntry.content as List<int>))
              as Map<String, dynamic>;
      expectBackupConsistent(decoded, zipNames);
      expect(zipNames, contains('slices/q1.png'));
      expect(zipNames, contains(crop1));
    });
  });

  group('十四批 M5 修复轮 2：引用口径统一', () {
    test('ZIP 含收集任务派生文件（pages/、original.*、page-normalized.png）', () async {
      // 任务行只引用 original.pdf；派生文件没有任何行直接引用，
      // 靠 _referencedRelativePaths 的派生保护进备份。
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
      for (final rel in [
        'imports/task-1/original.pdf',
        'imports/task-1/page-normalized.png',
        'imports/task-1/pages/p1.png',
      ]) {
        final f = File(p.join(dataDir.path, rel));
        await f.parent.create(recursive: true);
        await f.writeAsBytes([1, 2, 3]);
      }
      final report = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      final archive = ZipDecoder().decodeBytes(report.bytes);
      final zipNames = archive.files.map((f) => f.name).toSet();
      expect(zipNames, contains('imports/task-1/original.pdf'));
      expect(zipNames, contains('imports/task-1/page-normalized.png'));
      expect(zipNames, contains('imports/task-1/pages/p1.png'));
      // 孤儿文件仍不进备份（口径统一没有放宽到无引用文件）。
      final orphan = File(p.join(dataDir.path, 'slices/orphan.png'));
      await orphan.parent.create(recursive: true);
      await orphan.writeAsBytes([0]);
      final report2 = await AppDatabase.exportBackupZipFromWithReport(
        db,
        dataDir: dataDir.path,
      );
      final zipNames2 = ZipDecoder()
          .decodeBytes(report2.bytes)
          .files
          .map((f) => f.name)
          .toSet();
      expect(zipNames2, isNot(contains('slices/orphan.png')));
    });
  });
}
