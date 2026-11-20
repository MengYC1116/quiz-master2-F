// 十四批 M2：备份/恢复链路 P1-6（导出清单、attempts 全表、
// review_history 新增字段、版本号原样保留、v4 备份兼容）。
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
    final accepted = (await acceptCandidateStem(repo, q)).question;
    return parseOcrFigures(accepted.ocrFigures).single.cropPath;
  }

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
    dataDir = Directory(AppDatabase.dataDirectoryPath());
    await dataDir.create(recursive: true);
  });

  test('ZIP 清单含全部引用的图块 PNG（多题多图）', () async {
    final crop1 = await insertQuestionWithFigure('q1');
    final crop2 = await insertQuestionWithFigure('q2');
    final report = await AppDatabase.exportBackupZipFromWithReport(
      db,
      dataDir: dataDir.path,
    );
    expect(report.warnings, isEmpty);
    final archive = ZipDecoder().decodeBytes(report.bytes);
    final names = archive.files.map((f) => f.name).toSet();
    expect(names, contains(crop1));
    expect(names, contains(crop2));
    expect(names, contains('slices/q1.png'));
    expect(names, contains('slices/q2.png'));
  });

  test('attempts 全表 + review_history 新增字段导出，版本号原样保留', () async {
    final crop = await insertQuestionWithFigure('q1');
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
    final archive = ZipDecoder().decodeBytes(report.bytes);
    final jsonEntry = archive.files.firstWhere((f) => f.name == 'backup.json');
    final decoded = jsonDecode(utf8.decode(jsonEntry.content as List<int>))
        as Map<String, dynamic>;
    // attempts 全表导出。
    final attempts = decoded['attempts'] as List;
    expect(attempts.length, 1);
    final attempt = attempts.single as Map<String, dynamic>;
    expect(attempt['id'], 'a1');
    expect(attempt['mode'], '专项练习');
    expect(attempt['confidence'], '确定');
    expect(attempt['answer_version'], 3);
    expect(attempt['content_version'], 6);
    expect(attempt['submission_id'], 'sub-1');
    // review_history 新增字段导出。
    final history = decoded['review_history'] as List;
    expect(history.length, 1);
    final row = history.single as Map<String, dynamic>;
    expect(row['cause_id'], 'c1');
    expect(row['session_id'], 's1');
    expect(row['review_mode'], '到期复习');
    expect(row['verdict'], '已解决');
    expect(row['verification_status'], '已核验');
    expect(row['verification_source'], '外部资料核对');
    expect(row['attempt_id'], 'a1');
    expect(row['submission_id'], 'sub-1');
    // questions 行含 M2 新增列与版本号。
    final questions = decoded['questions'] as List;
    final qRow = questions.single as Map<String, dynamic>;
    expect(qRow.containsKey('question_type'), isTrue);
    expect(qRow.containsKey('ocr_figures'), isTrue);
    expect(qRow['answer_version'], 3);
    expect(qRow['content_version'], 6);
    // review_state 导出为空（不含未完成会话）。
    expect(decoded['review_state'], isEmpty);

    // 恢复进全新库：attempts 与 review_history 原样回来，版本号不重置。
    final db2 = await AppDatabase.openForTest();
    await AppDatabase.importBackupZipInto(db2, report.bytes, dataDir: dataDir.path);
    final attempts2 = await db2.select(db2.attempts).get();
    expect(attempts2.length, 1);
    expect(attempts2.single.id, 'a1');
    expect(attempts2.single.answerVersion, 3);
    expect(attempts2.single.contentVersion, 6);
    final history2 = await db2.select(db2.reviewHistory).get();
    expect(history2.length, 1);
    expect(history2.single.verificationStatus, '已核验');
    expect(history2.single.attemptId, 'a1');
    final q2 = await db2.customSelect(
      'SELECT answer_version, content_version, ocr_figures FROM questions WHERE id = ?',
      variables: [Variable<String>('q1')],
    ).getSingle();
    expect(q2.data['answer_version'], 3);
    expect(q2.data['content_version'], 6);
    expect(parseOcrFigures(q2.data['ocr_figures'] as String?).length, 1);
    // 图块文件也恢复了。
    expect(File(AppDatabase.resolveDataPath(crop)!).existsSync(), isTrue);
    await db2.close();
  });

  test('v4 备份（缺 attempts 键）恢复不拒绝，attempts 按空表处理', () async {
    await insertQuestionWithFigure('q1');
    final report = await AppDatabase.exportBackupZipFromWithReport(
      db,
      dataDir: dataDir.path,
    );
    final archive = ZipDecoder().decodeBytes(report.bytes);
    final jsonEntry = archive.files.firstWhere((f) => f.name == 'backup.json');
    final decoded = jsonDecode(utf8.decode(jsonEntry.content as List<int>))
        as Map<String, dynamic>;
    // 降级为 v4：去掉 attempts 键，schemaVersion 写 4。
    decoded.remove('attempts');
    (decoded['_meta'] as Map<String, dynamic>)['schemaVersion'] = 4;
    final v4Archive = Archive();
    for (final f in archive.files) {
      if (f.name == 'backup.json') {
        final bytes = utf8.encode(jsonEncode(decoded));
        v4Archive.addFile(ArchiveFile('backup.json', bytes.length, bytes));
      } else {
        v4Archive.addFile(f);
      }
    }
    final v4Bytes = ZipEncoder().encode(v4Archive);
    final db2 = await AppDatabase.openForTest();
    final warnings = await AppDatabase.importBackupZipInto(
      db2,
      v4Bytes,
      dataDir: dataDir.path,
    );
    expect(warnings, isEmpty);
    final attempts2 = await db2.select(db2.attempts).get();
    expect(attempts2, isEmpty);
    final questions2 = await db2.select(db2.questions).get();
    expect(questions2.length, 1);
    expect(questions2.single.id, 'q1');
    await db2.close();
  });

  test('导出 JSON 的 questions 行含 M1/M2 全部新增列', () async {
    await insertQuestionWithFigure('q1');
    final json = await AppDatabase.exportBackupJsonFrom(db);
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    final qRow = (decoded['questions'] as List).single as Map<String, dynamic>;
    for (final col in [
      'question_type',
      'question_type_source',
      'question_background_tags',
      'question_background_tags_source',
      'ocr_figures',
      'correct_option',
      'option_labels',
      'option_labels_confirmed',
      'answer_version',
    ]) {
      expect(qRow.containsKey(col), isTrue, reason: col);
    }
  });
}
