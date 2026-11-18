// 十三批 P1-3：LaTeX 备份泄漏 sentinel 实测（GPT 关口审 §6.3）。
//
// 方法：往一道临时测试题的 ocr_stem 与 ocr_raw（md_results）里各放
// 一个唯一公式标记，走产品真实的备份导出代码路径（JSON 导出与 zip
// 导出），再对备份内全部文件与本地 .db 文件本身做字节/字符串搜索，
// 只记录“命中/未命中 + 文件名”，不打印公式原文。
// 临时库放在 TMPDIR（= ~/workspace/flutter-test-tmp）下的子目录，
// 不用 /tmp，不碰演示库与真实用户库。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/zip_archive.dart';

// 唯一公式标记（只在断言里按“命中/未命中”报告，绝不打印其全文）。
const _marker = r'\frac{SENTINEL_A}{SENTINEL_B}';
const _markerToken = 'SENTINEL_A';
const _fracToken = r'\frac';

/// 字节序列搜索（strings 式，不解码整个文件）。
bool _bytesContain(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

String _hit(bool b) => b ? '命中' : '未命中';

Future<Directory> _makeWorkDir() async {
  final base =
      Platform.environment['TMPDIR'] ?? '${Platform.environment['HOME']!}/workspace/flutter-test-tmp';
  final dir = Directory(
    p.join(
      base,
      'b13-sentinel-${DateTime.now().millisecondsSinceEpoch}',
    ),
  );
  await dir.create(recursive: true);
  return dir;
}

/// 建临时文件库并写入一道带标记的题；返回库文件路径。
/// 调用方负责 close 后删临时目录。
Future<({QuizDatabase db, String dbPath, Directory workDir})>
_seedSentinelDb() async {
  final workDir = await _makeWorkDir();
  final dbPath = p.join(workDir.path, 'quiz-master2.db');
  final db = await AppDatabase.openAt(dbPath);
  await db
      .into(db.subjects)
      .insert(
        SubjectsCompanion.insert(id: 'math', name: '数学', color: 0xFF2E7CF6),
        // openAt 会播种演示学科（含 math），用 replace 避免唯一冲突。
        mode: InsertMode.insertOrReplace,
      );
  final rawPackage = jsonEncode({
    'md_results': '已知函数 \$$_marker\$，求其定义域。',
    'layout_details': [],
    'usage': <String, Object?>{},
    'has_unseen_candidate': false,
    'job_id': 'ocr-sentinel',
    'completed_at_ms': 1700000000000,
  });
  await AppDatabase.upsertQuestionInto(
    db,
    Question(
      id: 'q-sentinel',
      title: '哨兵测试题',
      subjectId: 'math',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ocrRaw: rawPackage,
      ocrStem: '已知函数 \$$_marker\$，求其定义域。',
      ocrSplitStatus: OcrSplitStatus.autoSegmented,
      contentVersion: 1,
    ),
  );
  // 确认标记确实写进库了（只比对布尔值，不打印内容）。
  final back = (await AppDatabase.allQuestionsFrom(db)).single;
  expect(back.ocrRaw?.contains(_markerToken), isTrue);
  expect(back.ocrStem?.contains(_markerToken), isTrue);
  return (db: db, dbPath: dbPath, workDir: workDir);
}

void main() {
  group('十三批 P1-3：备份 sentinel 实测（GPT §6.3）', () {
    test('JSON 备份：标记以明文出现在导出 JSON 里', () async {
      final seeded = await _seedSentinelDb();
      final db = seeded.db;
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
        try {
          await seeded.workDir.delete(recursive: true);
        } catch (_) {}
      });
      final json = await AppDatabase.exportBackupJsonFrom(db);
      final markerHit = json.contains(_markerToken);
      final fracHit = json.contains(_fracToken);
      // ignore: avoid_print
      print('sentinel json: backup.json marker=${_hit(markerHit)} frac=${_hit(fracHit)}');
      // 再按解析后的 questions 行确认来源列（只记布尔值）。
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final row =
          (decoded['questions'] as List).single as Map<String, dynamic>;
      final rawHit = (row['ocr_raw'] as String).contains(_markerToken);
      final stemHit = (row['ocr_stem'] as String).contains(_markerToken);
      // ignore: avoid_print
      print('sentinel json: questions.ocr_raw marker=${_hit(rawHit)}');
      // ignore: avoid_print
      print('sentinel json: questions.ocr_stem marker=${_hit(stemHit)}');
      expect(markerHit, isTrue);
      expect(fracHit, isTrue);
      expect(rawHit, isTrue);
      expect(stemHit, isTrue);
    });

    test('zip 备份：逐条目搜索，确认条目清单与命中情况', () async {
      final seeded = await _seedSentinelDb();
      final db = seeded.db;
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
        try {
          await seeded.workDir.delete(recursive: true);
        } catch (_) {}
      });
      // 本题无 slice_path，zip 应只含 backup.json（不含 .db 文件）。
      final zipBytes = await AppDatabase.exportBackupZipFrom(
        db,
        dataDir: seeded.workDir.path,
      );
      final entries = readZip(zipBytes);
      final names = entries.map((e) => e.name).toList();
      // ignore: avoid_print
      print('sentinel zip: 条目=${names.join(',')}');
      expect(names, ['backup.json']);
      expect(names.any((n) => n.endsWith('.db')), isFalse);
      for (final entry in entries) {
        final text = utf8.decode(entry.bytes);
        final markerHit = text.contains(_markerToken);
        final fracHit = text.contains(_fracToken);
        // ignore: avoid_print
        print(
          'sentinel zip: ${entry.name} marker=${_hit(markerHit)} frac=${_hit(fracHit)}',
        );
        expect(markerHit, isTrue);
        expect(fracHit, isTrue);
      }
    });

    test('本地 .db 文件：直接字节搜索是否看得到标记', () async {
      final seeded = await _seedSentinelDb();
      final db = seeded.db;
      final dbPath = seeded.dbPath;
      // 先关库（WAL 落盘），再读文件字节；关库后若 -wal/-shm 仍在也一并查。
      await db.close();
      final dbBytes = await File(dbPath).readAsBytes();
      final markerHit = _bytesContain(dbBytes, utf8.encode(_markerToken));
      final fracHit = _bytesContain(dbBytes, utf8.encode(_fracToken));
      // ignore: avoid_print
      print(
        'sentinel db: quiz-master2.db marker=${_hit(markerHit)} frac=${_hit(fracHit)}',
      );
      for (final suffix in ['-wal', '-shm']) {
        final sidecar = File('$dbPath$suffix');
        if (await sidecar.exists()) {
          final sideBytes = await sidecar.readAsBytes();
          // ignore: avoid_print
          print(
            'sentinel db: quiz-master2.db$suffix marker=${_hit(_bytesContain(sideBytes, utf8.encode(_markerToken)))} frac=${_hit(_bytesContain(sideBytes, utf8.encode(_fracToken)))}',
          );
        } else {
          // ignore: avoid_print
          print('sentinel db: quiz-master2.db$suffix 不存在');
        }
      }
      try {
        await seeded.workDir.delete(recursive: true);
      } catch (_) {}
      expect(markerHit, isTrue);
      expect(fracHit, isTrue);
    });
  });
}
