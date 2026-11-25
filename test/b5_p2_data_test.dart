// Batch 5 第五阶段 P2 数据层回归测试（SR-P2-1/2/4/5/6/7/8/9/10/11/12/
// 14/15/16/17/36/68）。
// 全部用内存库 + 临时目录，不碰真实演示库；SR-P2-3 与 SR-P2-22 的
// 剩余部分在调用方（详情页 / 收集页），见 B5-P2-DATA.md 的转交说明，
// 本文件不覆盖；SR-P2-13 是删除无调用方的 demoQuestions()，
// 以编译 + 全仓 grep 为证，不另立测试。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/zip_archive.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

Future<QuizDatabase> openTestDb() => AppDatabase.openForTest();

Future<void> insertQuestion(
  QuizDatabase db,
  String id, {
  String subjectId = 'math',
  int isDemo = 0,
  int isOrganized = 0,
  int reviewJoined = 0,
  String folderIds = '[]',
  String title = 't',
  int reviewCount = 0,
}) async {
  await db.customInsert(
    'INSERT INTO questions (id, title, subject_id, folder_ids, created_at, '
    'is_demo, is_organized, review_joined, review_count) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString(title),
      Variable.withString(subjectId),
      Variable.withString(folderIds),
      Variable.withInt(1000),
      Variable.withInt(isDemo),
      Variable.withInt(isOrganized),
      Variable.withInt(reviewJoined),
      Variable.withInt(reviewCount),
    ],
  );
}

Future<void> insertCauseRecord(
  QuizDatabase db,
  String questionId,
  String cause, {
  String subjectId = 'math',
  String status = 'pending',
  int solvedCount = 0,
  int? recheckDate,
}) async {
  await db.customInsert(
    'INSERT INTO cause_records (question_id, cause, subject_id, status, '
    'solved_count, recheck_date, joined_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(questionId),
      Variable.withString(cause),
      Variable.withString(subjectId),
      Variable.withString(status),
      Variable.withInt(solvedCount),
      Variable(recheckDate),
      Variable.withInt(1000),
    ],
  );
}

QuestionBox box({
  required String id,
  int layer = 1,
  String type = 'question',
  int page = 1,
  String? parentBoxId,
  String? questionId,
  String? collectTaskId,
}) => QuestionBox(
  id: id,
  layer: layer,
  type: type,
  x: 0.1,
  y: 0.1,
  w: 0.5,
  h: 0.3,
  page: page,
  parentBoxId: parentBoxId,
  questionId: questionId,
  collectTaskId: collectTaskId,
);

Future<void> insertTask(
  QuizDatabase db,
  String id, {
  String subjectId = 'math',
  String sourcePath = '',
}) async {
  await db.customInsert(
    'INSERT INTO collect_tasks (id, name, file_name, subject_id, status, '
    'source_path) VALUES (?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString(id),
      Variable.withString('t-$id'),
      Variable.withString('f.png'),
      Variable.withString(subjectId),
      Variable.withString('needBox'),
      Variable.withString(sourcePath),
    ],
  );
}

/// 种子一个最小合法库并导出备份 JSON（各组 P2-4/5/6 的变造基线）。
/// 可对同一库重复调（REPLACE 去重）。
Future<Map<String, dynamic>> exportedJson(QuizDatabase db) async {
  await db.customInsert(
    'INSERT OR REPLACE INTO subjects (id, name, color) VALUES (?, ?, ?)',
    variables: [
      Variable.withString('math'),
      Variable.withString('数学'),
      Variable.withInt(0xFF2E7CF6),
    ],
  );
  await db.customUpdate(
    'DELETE FROM questions WHERE id = ?',
    variables: [Variable.withString('q1')],
  );
  await insertQuestion(db, 'q1', isOrganized: 1);
  return jsonDecode(await AppDatabase.exportBackupJsonFrom(db))
      as Map<String, dynamic>;
}

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('b5-p2-data-');
    AppDatabase.testDataDirectory = tmpDir.path;
    addTearDown(() async {
      await AppDatabase.resetForTest();
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    });
  });

  group('SR-P2-1 删学科清草稿框', () {
    test('该科任务的草稿框（含 2 层子框）随学科删干净，他科不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.customInsert(
        'INSERT INTO subjects (id, name, color) VALUES (?, ?, ?)',
        variables: [
          Variable.withString('math'),
          Variable.withString('数学'),
          Variable.withInt(0xFF000000),
        ],
      );
      await db.customInsert(
        'INSERT INTO subjects (id, name, color) VALUES (?, ?, ?)',
        variables: [
          Variable.withString('english'),
          Variable.withString('英语'),
          Variable.withInt(0xFF000000),
        ],
      );
      await insertTask(db, 'ct-math', subjectId: 'math');
      await insertTask(db, 'ct-eng', subjectId: 'english');
      await insertBoxRow(db, box(id: 'b1', collectTaskId: 'ct-math'));
      await insertBoxRow(
        db,
        box(
          id: 'b1-stem',
          layer: 2,
          type: 'stem',
          parentBoxId: 'b1',
          collectTaskId: 'ct-math',
        ),
      );
      await insertBoxRow(db, box(id: 'b2', collectTaskId: 'ct-eng'));
      await AppDatabase.deleteSubjectFrom(db, 'math');
      final left = (await db.customSelect('SELECT * FROM question_boxes').get())
          .map((r) => r.data)
          .toList();
      expect(left.map((r) => r['id']).toList(), ['b2']);
      expect(
        await db.customSelect('SELECT * FROM collect_tasks').get(),
        hasLength(1),
      );
    });
  });

  group('SR-P2-4 备份校验缺口', () {
    test('缺表键拒绝恢复，原库不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      data.remove('cause_records');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, data),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('cause_records'),
          ),
        ),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });

    test('主键 null 拒绝恢复', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      (data['questions'] as List).first['id'] = null;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, data),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });

    test('必填列缺失 / 类型不对拒绝恢复', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final noTitle = await exportedJson(db);
      (noTitle['questions'] as List).first.remove('title');
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, noTitle),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('title'),
          ),
        ),
      );
      final badType = await exportedJson(db);
      (badType['questions'] as List).first['title'] = 123;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, badType),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });

    test('插库残余异常包成 BackupRestoreException（不露 sqlite 原文）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      (data['questions'] as List).first['no_such_col'] = 1;
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, data),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('备份数据有问题'),
          ),
        ),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });

    test('空串主键 / 必填列空串拒绝恢复（SR2-16）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      // 学科 id ''：'' 是合法 String，旧校验只查 is! String 会放过。
      final emptyId = await exportedJson(db);
      (emptyId['subjects'] as List).first['id'] = '';
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, emptyId),
        throwsA(isA<BackupRestoreException>()),
      );
      // 必填列 name ''：同样拒绝。
      final emptyName = await exportedJson(db);
      (emptyName['subjects'] as List).first['name'] = '';
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, emptyName),
        throwsA(isA<BackupRestoreException>()),
      );
      // settings key ''：同样拒绝。
      final emptyKey = await exportedJson(db);
      (emptyKey['settings'] as List).add({'key': '', 'value': 'x'});
      await expectLater(
        () => AppDatabase.importBackupJsonInto(db, emptyKey),
        throwsA(isA<BackupRestoreException>()),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });
  });

  group('SR-P2-5 备份恢复 2GB 上限', () {
    Future<List<int>> validZip(QuizDatabase db) async {
      final json = await AppDatabase.exportBackupJsonFrom(db);
      return buildZip([ZipEntryData('backup.json', utf8.encode(json))]);
    }

    test('现有占用超 2GB 时拒绝整个恢复，原库不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await exportedJson(db);
      // 稀疏文件：逻辑 2GB+1 字节，几乎不占真实磁盘。
      final huge = File(p.join(tmpDir.path, 'imports', 'huge.bin'));
      await huge.parent.create(recursive: true);
      final raf = await huge.open(mode: FileMode.write);
      await raf.truncate(2 * 1024 * 1024 * 1024 + 1);
      await raf.close();
      final zip = await validZip(db);
      await expectLater(
        () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('2GB'),
          ),
        ),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });

    test('现有占用 1GB 时恢复放行（对照）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await exportedJson(db);
      final big = File(p.join(tmpDir.path, 'imports', 'big.bin'));
      await big.parent.create(recursive: true);
      final raf = await big.open(mode: FileMode.write);
      await raf.truncate(1024 * 1024 * 1024);
      await raf.close();
      final zip = await validZip(db);
      await AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path);
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });

    test('恰好 2GB 放行：两条文件条目累加 incoming，== 上限不拒（SR2-58/SR2-65）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await exportedJson(db);
      final json = await AppDatabase.exportBackupJsonFrom(db);
      // 现有占用 2GB − 200 字节（稀疏文件，几乎不占真实磁盘）。
      final big = File(p.join(tmpDir.path, 'imports', 'big.bin'));
      await big.parent.create(recursive: true);
      final raf = await big.open(mode: FileMode.write);
      await raf.truncate(2 * 1024 * 1024 * 1024 - 200);
      await raf.close();
      // 两条文件条目各 100 字节：incoming 累加为 200，峰值恰好 2GB。
      final zip = buildZip([
        ZipEntryData('backup.json', utf8.encode(json)),
        ZipEntryData('slices/q1.png', List.filled(100, 1)),
        ZipEntryData('slices/q2.png', List.filled(100, 2)),
      ]);
      await AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path);
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
      expect(
        await File(p.join(tmpDir.path, 'slices', 'q1.png')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(tmpDir.path, 'slices', 'q2.png')).exists(),
        isTrue,
      );
    });

    test('峰值超 2GB 拒绝：将被覆盖的文件不抵扣峰值（SR2-19/SR2-65）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await exportedJson(db);
      final json = await AppDatabase.exportBackupJsonFrom(db);
      // 现有占用 2GB − 100 字节：其中 slices/q1.png 占 500 字节，
      // 将被备份里 200 字节的新 q1.png 覆盖。
      final big = File(p.join(tmpDir.path, 'imports', 'big.bin'));
      await big.parent.create(recursive: true);
      final raf = await big.open(mode: FileMode.write);
      await raf.truncate(2 * 1024 * 1024 * 1024 - 600);
      await raf.close();
      final old = File(p.join(tmpDir.path, 'slices', 'q1.png'));
      await old.parent.create(recursive: true);
      final rafOld = await old.open(mode: FileMode.write);
      await rafOld.truncate(500);
      await rafOld.close();
      // 峰值 = (2GB − 100) + 200 = 2GB + 100，超限拒绝；
      // 旧口径恢复后占用 = (2GB − 100) − 500 + 200 < 2GB，本会放行。
      final zip = buildZip([
        ZipEntryData('backup.json', utf8.encode(json)),
        ZipEntryData('slices/q1.png', List.filled(200, 9)),
      ]);
      await expectLater(
        () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('2GB'),
          ),
        ),
      );
      // 原文件原样不动（500 字节，未被 200 字节的新文件覆盖）。
      expect(await old.length(), 500);
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });
  });

  group('SR-P2-7 setCustomDataDirectory', () {
    test('标记写到 testMarkerDirectory，不动默认位置', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      final markerDir = await Directory.systemTemp.createTemp('b5-p2-marker-');
      addTearDown(() async {
        try {
          await markerDir.delete(recursive: true);
        } catch (_) {}
      });
      AppDatabase.testMarkerDirectory = markerDir.path;
      final target = await Directory.systemTemp.createTemp('b5-p2-target-');
      addTearDown(() async {
        try {
          await target.delete(recursive: true);
        } catch (_) {}
      });
      await AppDatabase.instance.setCustomDataDirectory(target.path);
      final marker = File(p.join(markerDir.path, 'db_location.txt'));
      expect(await marker.exists(), isTrue);
      expect(await marker.readAsString(), target.path);
      final rows =
          (await db
                  .customSelect(
                    'SELECT * FROM settings WHERE key = ?',
                    variables: [Variable.withString('databaseLocation')],
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      expect(rows.single['value'], target.path);
    });

    test('不存在的目录拒绝，不写标记也不写设置', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      final markerDir = await Directory.systemTemp.createTemp('b5-p2-marker-');
      addTearDown(() async {
        try {
          await markerDir.delete(recursive: true);
        } catch (_) {}
      });
      AppDatabase.testMarkerDirectory = markerDir.path;
      await expectLater(
        () => AppDatabase.instance.setCustomDataDirectory(
          p.join(tmpDir.path, 'no-such-dir'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        await File(p.join(markerDir.path, 'db_location.txt')).exists(),
        isFalse,
      );
      expect(
        await db
            .customSelect(
              'SELECT * FROM settings WHERE key = ?',
              variables: [Variable.withString('databaseLocation')],
            )
            .get(),
        isEmpty,
      );
    });

    test('标记写失败时设置回滚到旧值', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      final markerDir = await Directory.systemTemp.createTemp('b5-p2-marker-');
      addTearDown(() async {
        try {
          await markerDir.delete(recursive: true);
        } catch (_) {}
      });
      AppDatabase.testMarkerDirectory = markerDir.path;
      // 把标记文件位置占成目录，writeAsString 必失败。
      await Directory(p.join(markerDir.path, 'db_location.txt')).create();
      await AppDatabase.instance.saveSetting('databaseLocation', '/old/dir');
      final target = await Directory.systemTemp.createTemp('b5-p2-target-');
      addTearDown(() async {
        try {
          await target.delete(recursive: true);
        } catch (_) {}
      });
      await expectLater(
        () => AppDatabase.instance.setCustomDataDirectory(target.path),
        throwsA(anything),
      );
      final rows =
          (await db
                  .customSelect(
                    'SELECT * FROM settings WHERE key = ?',
                    variables: [Variable.withString('databaseLocation')],
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      expect(rows.single['value'], '/old/dir');
    });
  });

  group('SR-P2-8 加入/同步复习同事务', () {
    Question joinedQ() => Question(
      id: 'q1',
      title: 't',
      subjectId: 'math',
      errorTypes: ['计算错误', '概念不清'],
      reviewJoined: true,
      isOrganized: true,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

    test('setReviewJoinedInto：题行 + 错因记录一次建出', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', isOrganized: 1);
      final ok = await AppDatabase.setReviewJoinedInto(db, joinedQ(), true);
      expect(ok, isTrue);
      final q =
          (await db
                  .customSelect(
                    'SELECT * FROM questions WHERE id = ?',
                    variables: [Variable.withString('q1')],
                  )
                  .get())
              .map((r) => r.data)
              .toList()
              .single;
      expect(q['review_joined'], 1);
      final records =
          (await db.customSelect('SELECT * FROM cause_records').get())
              .map((r) => r.data)
              .toList();
      expect(records.map((r) => r['cause']).toList(), ['计算错误', '概念不清']);
    });

    test('setReviewJoinedInto 中途失败：题行一起回滚', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.customStatement(
        "CREATE TRIGGER trg_fail_cause BEFORE INSERT ON cause_records "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      await expectLater(
        () => AppDatabase.setReviewJoinedInto(db, joinedQ(), true),
        throwsA(anything),
      );
      expect(await db.customSelect('SELECT * FROM questions').get(), isEmpty);
      expect(
        await db.customSelect('SELECT * FROM cause_records').get(),
        isEmpty,
      );
    });

    test('错因是空的题加不进复习，返回 false、不写库', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', isOrganized: 1);
      final q = Question(
        id: 'q1',
        title: 't',
        subjectId: 'math',
        isOrganized: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      expect(await AppDatabase.setReviewJoinedInto(db, q, true), isFalse);
      expect(
        (await db
                .customSelect(
                  'SELECT * FROM questions WHERE id = ?',
                  variables: [Variable.withString('q1')],
                )
                .get())
            .map((r) => r.data)
            .toList()
            .single['review_joined'],
        0,
      );
    });

    test('syncCauseRecordsInto：删旧错因、补新错因同事务', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', isOrganized: 1, reviewJoined: 1);
      await insertCauseRecord(db, 'q1', '计算错误');
      await insertCauseRecord(db, 'q1', '概念不清');
      final q = joinedQ().copyWith(errorTypes: ['计算错误', '审题失误']);
      await AppDatabase.syncCauseRecordsInto(db, q);
      final records =
          (await db
                  .customSelect(
                    'SELECT * FROM cause_records ORDER BY cause ASC',
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      expect(records.map((r) => r['cause']).toList(), ['审题失误', '计算错误']);
    });
  });

  group('SR2-14 全行 REPLACE 快照覆盖库内新值', () {
    test('旧快照 setReviewJoinedInto 不把 review_count 打回旧值', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', isOrganized: 1, reviewCount: 5);
      // 自查一次：库内 review_count 5 → 6（SQL +1）。
      await AppDatabase.recordSelfCheckInto(
        db,
        updated: CauseRecord(
          questionId: 'q1',
          cause: '计算错误',
          subjectId: 'math',
          joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
        questionId: 'q1',
        result: 'solved',
      );
      expect(
        (await db
                .customSelect(
                  'SELECT * FROM questions WHERE id = ?',
                  variables: [Variable.withString('q1')],
                )
                .get())
            .map((r) => r.data)
            .toList()
            .single['review_count'],
        6,
      );
      // 持 reviewCount: 5 的旧快照调 setReviewJoinedInto。
      final stale = Question(
        id: 'q1',
        title: 't',
        subjectId: 'math',
        errorTypes: ['计算错误'],
        reviewJoined: false,
        isOrganized: true,
        reviewCount: 5,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      expect(await AppDatabase.setReviewJoinedInto(db, stale, true), isTrue);
      final q =
          (await db
                  .customSelect(
                    'SELECT * FROM questions WHERE id = ?',
                    variables: [Variable.withString('q1')],
                  )
                  .get())
              .map((r) => r.data)
              .toList()
              .single;
      expect(q['review_joined'], 1);
      expect(q['review_count'], 6);
    });

    test('旧快照 upsertQuestionInto 不把 review_count 打回旧值（收藏/归档/保存同路）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', isOrganized: 1, reviewCount: 6);
      final stale = Question(
        id: 'q1',
        title: 't',
        subjectId: 'math',
        isOrganized: true,
        isFavorite: true,
        reviewCount: 5,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await AppDatabase.upsertQuestionInto(db, stale);
      final q =
          (await db
                  .customSelect(
                    'SELECT * FROM questions WHERE id = ?',
                    variables: [Variable.withString('q1')],
                  )
                  .get())
              .map((r) => r.data)
              .toList()
              .single;
      expect(q['is_favorite'], 1);
      expect(q['review_count'], 6);
    });

    test('旧快照 updateCauseRemedy 只改 remedy_history，不覆盖自查改掉的状态/计数/复查日', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      final recheck = DateTime.now().add(const Duration(days: 7));
      await insertCauseRecord(
        db,
        'q1',
        '计算错误',
        status: 'solved',
        solvedCount: 2,
        recheckDate: recheck.millisecondsSinceEpoch,
      );
      final stale = CauseRecord(
        questionId: 'q1',
        cause: '计算错误',
        subjectId: 'math',
        status: CauseStatus.pending,
        solvedCount: 0,
        remedyHistory: ['2026-11-15：先列错因再算'],
        joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await AppDatabase.instance.updateCauseRemedy(stale);
      final row = (await db.customSelect('SELECT * FROM cause_records').get())
          .map((r) => r.data)
          .toList()
          .single;
      expect(row['status'], 'solved');
      expect(row['solved_count'], 2);
      expect(row['recheck_date'], recheck.millisecondsSinceEpoch);
      expect(AppDatabase.decodeRemedyList(row['remedy_history']), [
        '2026-11-15：先列错因再算',
      ]);
    });

    test('SR3-4：经 saveCauseRecord 改已存在行的 status 被丢弃（按设计），新行才整行写入', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      final repo = QuestionRepository(AppDatabase.instance);
      final recheck = DateTime.now().add(const Duration(days: 7));
      await insertCauseRecord(
        db,
        'q1',
        '计算错误',
        status: 'solved',
        solvedCount: 2,
        recheckDate: recheck.millisecondsSinceEpoch,
      );
      // 已存在行：status / solvedCount 改动被丢弃，remedy_history 写入。
      await repo.saveCauseRecord(
        CauseRecord(
          questionId: 'q1',
          cause: '计算错误',
          subjectId: 'math',
          status: CauseStatus.pending,
          solvedCount: 0,
          remedyHistory: ['2026-11-15：先列错因再算'],
          joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      final row =
          (await db
                  .customSelect(
                    'SELECT * FROM cause_records WHERE question_id = ? AND cause = ?',
                    variables: [
                      Variable.withString('q1'),
                      Variable.withString('计算错误'),
                    ],
                  )
                  .get())
              .map((r) => r.data)
              .toList()
              .single;
      expect(row['status'], 'solved');
      expect(row['solved_count'], 2);
      expect(row['recheck_date'], recheck.millisecondsSinceEpoch);
      expect(AppDatabase.decodeRemedyList(row['remedy_history']), [
        '2026-11-15：先列错因再算',
      ]);
      // 不存在行：整行 INSERT，全列按传入值写（播种路径）。
      await repo.saveCauseRecord(
        CauseRecord(
          questionId: 'q2',
          cause: '概念不清',
          subjectId: 'math',
          status: CauseStatus.inProgress,
          solvedCount: 1,
          remedyHistory: const [],
          joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      final inserted =
          (await db
                  .customSelect(
                    'SELECT * FROM cause_records WHERE question_id = ? AND cause = ?',
                    variables: [
                      Variable.withString('q2'),
                      Variable.withString('概念不清'),
                    ],
                  )
                  .get())
              .map((r) => r.data)
              .toList()
              .single;
      expect(inserted['status'], 'inProgress');
      expect(inserted['solved_count'], 1);
    });
  });

  group('SR2-27 boxesForPageImageFrom 按页与 id 排序', () {
    test('同页多框按 page ASC, id ASC 返回，与插入顺序无关', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      const pageImage = 'imports/t1/original.jpg';
      // 四题同页，题行本身也倒序插入。注意：最终框顺序只由框查询的
      // ORDER BY 决定，题 id 列表的 `orderBy: 'id ASC'` 经本测试不可
      // 观测（它只影响中间 IN 列表，不影响输出顺序）；倒序插入只是
      // 为了排除对插入/rowid 序的依赖，不要把它读成“钉住题 id 顺序”。
      // 注意：question_boxes 对 layer=1 框有“每题一框”的部分唯一索引，
      // 四个框必须挂四个不同的题，不能像草稿那样两框共用一题。
      await insertQuestion(db, 'q4', isOrganized: 1);
      await insertQuestion(db, 'q3', isOrganized: 1);
      await insertQuestion(db, 'q2', isOrganized: 1);
      await insertQuestion(db, 'q1', isOrganized: 1);
      for (final id in ['q1', 'q2', 'q3', 'q4']) {
        await db.customUpdate(
          'UPDATE questions SET page_image_path = ? WHERE id = ?',
          variables: [Variable.withString(pageImage), Variable.withString(id)],
        );
      }
      // 框故意按非排序顺序插入：无 ORDER BY 时行序通常是 rowid 序
      // （即插入序），与 page/id 序不同，旧实现会在这里返回乱序。
      for (final b in [
        box(id: 'b-p2-b', page: 2, questionId: 'q4'),
        box(id: 'b-p1-b', page: 1, questionId: 'q2'),
        box(id: 'b-p2-a', page: 2, questionId: 'q3'),
        box(id: 'b-p1-a', page: 1, questionId: 'q1'),
      ]) {
        await insertBoxRow(db, b);
      }
      final all = await AppDatabase.boxesForPageImageFrom(db, pageImage);
      expect(all.map((b) => b.id).toList(), [
        'b-p1-a',
        'b-p1-b',
        'b-p2-a',
        'b-p2-b',
      ]);
      // 不在该页的题的框不混进来；无题的页图返回空。
      await insertQuestion(db, 'q5', isOrganized: 1);
      await db.customUpdate(
        'UPDATE questions SET page_image_path = ? WHERE id = ?',
        variables: [
          Variable.withString('imports/t1/other.jpg'),
          Variable.withString('q5'),
        ],
      );
      await insertBoxRow(db, box(id: 'b-other', questionId: 'q5'));
      expect(
        (await AppDatabase.boxesForPageImageFrom(
          db,
          pageImage,
        )).map((b) => b.id).toList(),
        ['b-p1-a', 'b-p1-b', 'b-p2-a', 'b-p2-b'],
      );
      expect(
        await AppDatabase.boxesForPageImageFrom(db, 'imports/nope.jpg'),
        isEmpty,
      );
    });

    test(
      'boxesForQuestionFrom / boxesForTaskPageFrom 也按 page ASC, id ASC（SR3-3）',
      () async {
        final db = await openTestDb();
        addTearDown(() async => db.close());
        await insertQuestion(db, 'q1', isOrganized: 1);
        // 同题多框故意按非排序顺序插入：无 ORDER BY 时行序通常是
        // rowid 序（即插入序），与 page/id 序不同。用 layer=2 框——
        // layer=1 框有“每题一框”的部分唯一索引，同题挂四个 1 层框
        // 会违反约束（见 SR2-27 测试的注释）。
        for (final b in [
          box(id: 'b-p2-b', layer: 2, type: 'stem', page: 2, questionId: 'q1'),
          box(id: 'b-p1-b', layer: 2, type: 'stem', page: 1, questionId: 'q1'),
          box(id: 'b-p2-a', layer: 2, type: 'stem', page: 2, questionId: 'q1'),
          box(id: 'b-p1-a', layer: 2, type: 'stem', page: 1, questionId: 'q1'),
        ]) {
          await insertBoxRow(db, b);
        }
        expect(
          (await AppDatabase.boxesForQuestionFrom(
            db,
            'q1',
          )).map((b) => b.id).toList(),
          ['b-p1-a', 'b-p1-b', 'b-p2-a', 'b-p2-b'],
        );
        // 某任务某页的草稿框：同页内按 id 排；他页的框不混进来。
        for (final b in [
          box(id: 'd-b', page: 1, collectTaskId: 'task-1'),
          box(id: 'd-a', page: 1, collectTaskId: 'task-1'),
          box(id: 'd-p2', page: 2, collectTaskId: 'task-1'),
        ]) {
          await insertBoxRow(db, b);
        }
        expect(
          (await AppDatabase.boxesForTaskPageFrom(
            db,
            'task-1',
            1,
          )).map((b) => b.id).toList(),
          ['d-a', 'd-b'],
        );
      },
    );
  });

  group('SR-P2-9 saveSettings 入事务', () {
    test('中途失败：已写的键一起回滚，不留新旧混杂', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.customStatement(
        "CREATE TRIGGER trg_fail_font BEFORE INSERT ON settings "
        "WHEN NEW.key = 'fontSize' "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      final s = AppSettings.defaults.copyWith(
        themeMode: 'dark',
        fontSize: 'large',
      );
      await expectLater(
        () => AppDatabase.saveSettingsInto(db, s),
        throwsA(anything),
      );
      expect(await db.customSelect('SELECT * FROM settings').get(), isEmpty);
    });

    test('成功：全部键一次写进', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await AppDatabase.saveSettingsInto(
        db,
        AppSettings.defaults.copyWith(themeMode: 'dark'),
      );
      final rows =
          (await db
                  .customSelect(
                    'SELECT * FROM settings WHERE key = ?',
                    variables: [Variable.withString('themeMode')],
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      expect(rows.single['value'], 'dark');
    });
  });

  group('SR-P2-10 确认拆题防静默覆盖', () {
    Future<CollectTask> origTask(QuizDatabase db) async {
      final orig = CollectTask(
        id: 'task-orig',
        name: 'orig',
        fileName: 'orig.jpg',
        subjectId: 'math',
        status: CollectStatus.boxing,
      );
      await AppDatabase.upsertCollectTaskInto(db, orig);
      return orig;
    }

    test('同 id 题目已存在：显式失败，旧题原样不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final orig = await origTask(db);
      await insertQuestion(db, 'import-1', isOrganized: 1, title: '旧题');
      await expectLater(
        () => AppDatabase.confirmSplitInto(
          db,
          originalTask: orig,
          questions: [
            Question(
              id: 'import-1',
              title: '新题',
              subjectId: 'math',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ],
          splitTasks: [
            CollectTask(
              id: 'task-split-1',
              name: 's',
              fileName: 'orig.jpg',
              subjectId: 'math',
            ),
          ],
          boxesByQuestionId: const {},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('题目已存在'),
          ),
        ),
      );
      final q =
          (await db
                  .customSelect(
                    'SELECT * FROM questions WHERE id = ?',
                    variables: [Variable.withString('import-1')],
                  )
                  .get())
              .map((r) => r.data)
              .toList()
              .single;
      expect(q['title'], '旧题');
      expect(q['is_organized'], 1);
      expect(
        await db.customSelect('SELECT * FROM collect_tasks').get(),
        hasLength(1),
      );
    });

    test('同 id 拆分任务已存在：显式失败', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final orig = await origTask(db);
      await insertTask(db, 'task-split-1');
      await expectLater(
        () => AppDatabase.confirmSplitInto(
          db,
          originalTask: orig,
          questions: [
            Question(
              id: 'import-1',
              title: '新题',
              subjectId: 'math',
              createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ],
          splitTasks: [
            CollectTask(
              id: 'task-split-1',
              name: 's',
              fileName: 'orig.jpg',
              subjectId: 'math',
            ),
          ],
          boxesByQuestionId: const {},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('拆分任务已存在'),
          ),
        ),
      );
      expect(await db.customSelect('SELECT * FROM questions').get(), isEmpty);
    });

    test('同一题内重复 id 的框：只保留第一个，不静默覆盖（SR2-18/SR2-70）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final orig = await origTask(db);
      await AppDatabase.confirmSplitInto(
        db,
        originalTask: orig,
        questions: [
          Question(
            id: 'import-1',
            title: '新题',
            subjectId: 'math',
            createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        ],
        splitTasks: [
          CollectTask(
            id: 'task-split-1',
            name: 's',
            fileName: 'orig.jpg',
            subjectId: 'math',
          ),
        ],
        boxesByQuestionId: {
          'import-1': [
            box(id: 'b1'),
            // 同 id、不同坐标的重复框：旧写法 REPLACE 会让它静默
            // 覆盖第一个（x 变 0.5）；去重后只保留第一个。
            QuestionBox(
              id: 'b1',
              layer: 1,
              type: 'question',
              x: 0.5,
              y: 0.5,
              w: 0.4,
              h: 0.2,
              page: 1,
            ),
          ],
        },
      );
      final boxes = await AppDatabase.boxesForQuestionFrom(db, 'import-1');
      expect(boxes, hasLength(1));
      expect(boxes.single.id, 'b1');
      expect(boxes.single.x, 0.1);
    });

    test('跨题重复 id 的框：只保留第一题的，不静默覆盖（SR3-9）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final orig = await origTask(db);
      await AppDatabase.confirmSplitInto(
        db,
        originalTask: orig,
        questions: [
          Question(
            id: 'import-1',
            title: '题一',
            subjectId: 'math',
            createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
          Question(
            id: 'import-2',
            title: '题二',
            subjectId: 'math',
            createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        ],
        splitTasks: [
          CollectTask(
            id: 'task-split-1',
            name: 's1',
            fileName: 'orig.jpg',
            subjectId: 'math',
          ),
          CollectTask(
            id: 'task-split-2',
            name: 's2',
            fileName: 'orig.jpg',
            subjectId: 'math',
          ),
        ],
        boxesByQuestionId: {
          'import-1': [box(id: 'b1')],
          // 同 id、不同坐标的框挂到第二题：旧写法按题建集合放行，
          // REPLACE 会把第一题的框改写到第二题、第一题丢框。
          'import-2': [
            QuestionBox(
              id: 'b1',
              layer: 1,
              type: 'question',
              x: 0.5,
              y: 0.5,
              w: 0.4,
              h: 0.2,
              page: 1,
            ),
          ],
        },
      );
      final first = await AppDatabase.boxesForQuestionFrom(db, 'import-1');
      expect(first, hasLength(1));
      expect(first.single.x, 0.1);
      expect(await AppDatabase.boxesForQuestionFrom(db, 'import-2'), isEmpty);
    });

    test('保留任务跨页重复 id 的草稿框：只保留第一页的（SR3-9）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final orig = await origTask(db);
      final retained = CollectTask(
        id: 'task-orig',
        name: 'orig',
        fileName: 'orig.jpg',
        subjectId: 'math',
        status: CollectStatus.needBox,
        pageCount: 2,
        page: 2,
      );
      await AppDatabase.confirmSplitInto(
        db,
        originalTask: orig,
        questions: [
          Question(
            id: 'import-1',
            title: '新题',
            subjectId: 'math',
            createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
          ),
        ],
        splitTasks: [
          CollectTask(
            id: 'task-split-1',
            name: 's',
            fileName: 'orig.jpg',
            subjectId: 'math',
          ),
        ],
        boxesByQuestionId: {
          'import-1': [box(id: 'b-q')],
        },
        retainedTask: retained,
        retainedBoxesByPage: {
          1: [box(id: 'b-dup', page: 1, collectTaskId: 'task-orig')],
          // 同 id 的草稿框又出现在第 2 页：旧写法按页建集合放行，
          // REPLACE 会把它改写到第 2 页、第 1 页丢框。
          2: [
            QuestionBox(
              id: 'b-dup',
              layer: 1,
              type: 'question',
              x: 0.5,
              y: 0.5,
              w: 0.4,
              h: 0.2,
              page: 2,
              collectTaskId: 'task-orig',
            ),
          ],
        },
      );
      final page1 = await AppDatabase.boxesForTaskPageFrom(db, 'task-orig', 1);
      expect(page1, hasLength(1));
      expect(page1.single.x, 0.1);
      expect(
        await AppDatabase.boxesForTaskPageFrom(db, 'task-orig', 2),
        isEmpty,
      );
    });
  });

  group('SR-P2-11 删老库先清附属', () {
    Future<String> v1DbFile() async {
      final path = p.join(tmpDir.path, 'quiz-master2.db');
      final db = await AppDatabase.openForTest(path: path);
      await db.close();
      // 旧口径夹具是“v2 DDL + user_version 1”：把版本位翻回 1，
      // 让 deleteLegacyDatabaseIfPresent 的探针把它认作 v1 老库。
      final raw = sqlite3.sqlite3.open(path);
      raw.execute('PRAGMA user_version = 1');
      raw.close();
      return path;
    }

    test('v1 库 + -wal/-shm：全删掉，返回 true', () async {
      final path = await v1DbFile();
      await File('$path-wal').writeAsString('wal');
      await File('$path-shm').writeAsString('shm');
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(path), isTrue);
      expect(await File(path).exists(), isFalse);
      expect(await File('$path-wal').exists(), isFalse);
      expect(await File('$path-shm').exists(), isFalse);
    });
    
    test('-wal 是目录：探针打不开，拒绝删除、文件原样保留', () async {
      if (!Platform.isLinux) {
      markTestSkipped('SQLite 只读探针在 Win11 上能打开目录 -wal，不走拒绝分支');
      return;
    }
      // SQLite 只读探针遇到目录 -wal 即打不开库（error 14），
      // 按保守口径拒绝删除、不删老库——附属删失败不抛错的分支
      // 是防 Windows 文件锁定的防御代码，Linux 单测无法直接
      // 模拟（删失败的前置条件会先让探针失败），此处只锁定
      // “探针失败即拒绝、不动文件”的行为。
      final path = await v1DbFile();
      await Directory('$path-wal').create();
      await expectLater(
        () => AppDatabase.deleteLegacyDatabaseIfPresent(path),
        throwsA(isA<LegacyDatabaseException>()),
      );
      expect(await File(path).exists(), isTrue);
    });

    test('v2 库：不动，返回 false', () async {
      final path = p.join(tmpDir.path, 'quiz-master2.db');
      final db = await AppDatabase.openForTest(path: path);
      await db.close();
      expect(await AppDatabase.deleteLegacyDatabaseIfPresent(path), isFalse);
      expect(await File(path).exists(), isTrue);
    });
  });

  group('SR-P2-12 框 id 熵', () {
    test('随机段 16 位十六进制，1000 个不碰撞', () {
      final ids = {
        for (var i = 0; i < 1000; i++) AppDatabase.newBoxId('task-1', 1),
      };
      expect(ids, hasLength(1000));
      final sample = ids.first;
      expect(sample.startsWith('box-task-1-p1-'), isTrue);
      final rand = sample.split('-').last;
      expect(rand.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(rand), isTrue);
    });
  });

  group('SR-P2-14 草稿保存的任务行校验与缺页键契约', () {
    test('任务行不存在：抛错回滚，框不写进去', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await expectLater(
        () => AppDatabase.saveDraftBoxesInto(
          db,
          taskId: 'no-such-task',
          boxesByPage: {
            1: [box(id: 'b1', collectTaskId: 'no-such-task')],
          },
          rotations: const {1: 90},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('收集任务不存在'),
          ),
        ),
      );
      expect(
        await db.customSelect('SELECT * FROM question_boxes').get(),
        isEmpty,
      );
    });

    test('被清空的页传空列表键：旧草稿删掉；缺页键的旧草稿保留', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertTask(db, 'task-1');
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-1',
        boxesByPage: {
          1: [box(id: 'b1', collectTaskId: 'task-1')],
          2: [box(id: 'b2', page: 2, collectTaskId: 'task-1')],
        },
        rotations: const {},
      );
      // 只传第 1 页为空列表：第 1 页清空，第 2 页缺键、保留。
      await AppDatabase.saveDraftBoxesInto(
        db,
        taskId: 'task-1',
        boxesByPage: {1: <QuestionBox>[]},
        rotations: const {},
      );
      final left = await AppDatabase.boxesForTaskFrom(db, 'task-1');
      expect(left.map((b) => b.id).toList(), ['b2']);
    });
  });

  group('SR-P2-15 删任务目录查 collect_tasks.source_path', () {
    test('拆分任务行还指着原目录：目录保留', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final dir = Directory(p.join(tmpDir.path, 'imports', 'orig'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'original.pdf')).writeAsString('pdf');
      await insertTask(db, 'orig', sourcePath: 'imports/orig/original.pdf');
      await insertTask(db, 'split-1', sourcePath: 'imports/orig/original.pdf');
      await AppDatabase.deleteCollectTaskFrom(db, 'orig');
      expect(await dir.exists(), isTrue);
      expect(
        (await db.customSelect('SELECT * FROM collect_tasks').get())
            .map((r) => r.data['id'])
            .toList(),
        ['split-1'],
      );
    });

    test('无人引用：目录删掉（对照）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final dir = Directory(p.join(tmpDir.path, 'imports', 'orig'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'original.pdf')).writeAsString('pdf');
      await insertTask(db, 'orig', sourcePath: 'imports/orig/original.pdf');
      await AppDatabase.deleteCollectTaskFrom(db, 'orig');
      expect(await dir.exists(), isFalse);
    });

    test('含 _ 的任务 id：LIKE 转义后不误匹配相邻目录（SR2-68）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      // or_ig 与 orXig：不转义时 'imports/or_ig/%' 的 _ 会通配 X，
      // 删 or_ig 时误以为 orXig 的引用还在，目录被错误保留。
      final dir = Directory(p.join(tmpDir.path, 'imports', 'or_ig'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'original.pdf')).writeAsString('pdf');
      final other = Directory(p.join(tmpDir.path, 'imports', 'orXig'));
      await other.create(recursive: true);
      await File(p.join(other.path, 'original.pdf')).writeAsString('pdf');
      await insertTask(db, 'or_ig', sourcePath: 'imports/or_ig/original.pdf');
      await insertTask(db, 'orXig', sourcePath: 'imports/orXig/original.pdf');
      await AppDatabase.deleteCollectTaskFrom(db, 'or_ig');
      expect(await dir.exists(), isFalse);
      expect(await other.exists(), isTrue);
    });

    test('含 % 的任务 id：安全字符校验不通过，目录保留、不误删（SR2-68）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final dir = Directory(p.join(tmpDir.path, 'imports', 'or%ig'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'original.pdf')).writeAsString('pdf');
      await insertTask(db, 'or%ig', sourcePath: 'imports/or%ig/original.pdf');
      await AppDatabase.deleteCollectTaskFrom(db, 'or%ig');
      // '%' 不在 _safeTaskIdPattern 里：_deleteTaskDirIfUnreferenced
      // 直接返回，目录保留（LIKE 里的 % 通配符到不了查询）。
      expect(await dir.exists(), isTrue);
    });
  });

  group('SR-P2-16 自查按库内值重算', () {
    CauseRecord snapshot() => CauseRecord(
      questionId: 'q1',
      cause: '计算错误',
      subjectId: 'math',
      status: CauseStatus.pending,
      solvedCount: 0,
      joinedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

    test('两次基于同一旧快照的“已解决”：计数 +2，不是 +1', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', reviewCount: 0);
      await insertCauseRecord(db, 'q1', '计算错误');
      final stale = snapshot();
      await AppDatabase.recordSelfCheckInto(
        db,
        updated: stale.copyWith(status: CauseStatus.inProgress, solvedCount: 1),
        questionId: 'q1',
        result: 'solved',
      );
      // 第二次仍拿同一份旧快照（solvedCount 0）：库内值是 1，
      // 重算后应为 2 且已解决，而不是按快照写回 1。
      final written = await AppDatabase.recordSelfCheckInto(
        db,
        updated: stale.copyWith(status: CauseStatus.inProgress, solvedCount: 1),
        questionId: 'q1',
        result: 'solved',
      );
      expect(written.solvedCount, 2);
      expect(written.status, CauseStatus.solved);
      final row = (await db.customSelect('SELECT * FROM cause_records').get())
          .map((r) => r.data)
          .toList()
          .single;
      expect(row['solved_count'], 2);
      expect(row['status'], 'solved');
      expect(
        await db.customSelect('SELECT * FROM review_history').get(),
        hasLength(2),
      );
      final q = (await db.customSelect('SELECT * FROM questions').get())
          .map((r) => r.data)
          .toList()
          .single;
      expect(q['review_count'], 2);
    });

    test('复查通过不加计数：库内 solvedCount 不动，只顺延复查日', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', reviewCount: 0);
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await insertCauseRecord(
        db,
        'q1',
        '计算错误',
        status: 'solved',
        solvedCount: 2,
        recheckDate: yesterday.millisecondsSinceEpoch,
      );
      final written = await AppDatabase.recordSelfCheckInto(
        db,
        updated: snapshot(),
        questionId: 'q1',
        result: 'solved',
        isRecheck: true,
      );
      expect(written.solvedCount, 2);
      expect(written.status, CauseStatus.solved);
      expect(written.recheckDate, isNotNull);
      expect(written.recheckDate!.isAfter(DateTime.now()), isTrue);
    });

    test('unsure 不写库：无行时返回传入值，有行时返回库内值', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', reviewCount: 0);
      // 无行：返回传入值，不写库（无记录、无历史、次数不动）。
      final passed = snapshot().copyWith(
        status: CauseStatus.inProgress,
        solvedCount: 1,
      );
      final noRow = await AppDatabase.recordSelfCheckInto(
        db,
        updated: passed,
        questionId: 'q1',
        result: 'unsure',
      );
      expect(noRow.solvedCount, 1);
      expect(
        await db.customSelect('SELECT * FROM cause_records').get(),
        isEmpty,
      );
      expect(
        await db.customSelect('SELECT * FROM review_history').get(),
        isEmpty,
      );
      expect(
        (await db.customSelect('SELECT * FROM questions').get())
            .map((r) => r.data)
            .toList()
            .single['review_count'],
        0,
      );
      // 有行：返回库内值，库内行原样不动。
      await insertCauseRecord(
        db,
        'q1',
        '计算错误',
        status: 'inProgress',
        solvedCount: 1,
      );
      final withRow = await AppDatabase.recordSelfCheckInto(
        db,
        updated: snapshot(),
        questionId: 'q1',
        result: 'unsure',
      );
      expect(withRow.solvedCount, 1);
      expect(withRow.status, CauseStatus.inProgress);
      final row = (await db.customSelect('SELECT * FROM cause_records').get())
          .map((r) => r.data)
          .toList()
          .single;
      expect(row['solved_count'], 1);
      expect(row['status'], 'inProgress');
      expect(
        await db.customSelect('SELECT * FROM review_history').get(),
        isEmpty,
      );
    });

    test('未解决：solvedCount 清 0，状态回解决中、复查日清掉', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', reviewCount: 0);
      final recheck = DateTime.now().add(const Duration(days: 7));
      await insertCauseRecord(
        db,
        'q1',
        '计算错误',
        status: 'solved',
        solvedCount: 2,
        recheckDate: recheck.millisecondsSinceEpoch,
      );
      final written = await AppDatabase.recordSelfCheckInto(
        db,
        updated: snapshot(),
        questionId: 'q1',
        result: 'unsolved',
      );
      expect(written.solvedCount, 0);
      expect(written.status, CauseStatus.inProgress);
      expect(written.recheckDate, isNull);
      final row = (await db.customSelect('SELECT * FROM cause_records').get())
          .map((r) => r.data)
          .toList()
          .single;
      expect(row['solved_count'], 0);
      expect(row['status'], 'inProgress');
      expect(row['recheck_date'], isNull);
    });

    test('无行时按传入值写库（已解决）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await insertQuestion(db, 'q1', reviewCount: 0);
      final written = await AppDatabase.recordSelfCheckInto(
        db,
        updated: snapshot().copyWith(
          status: CauseStatus.inProgress,
          solvedCount: 1,
        ),
        questionId: 'q1',
        result: 'solved',
      );
      expect(written.solvedCount, 1);
      expect(written.status, CauseStatus.inProgress);
      final row = (await db.customSelect('SELECT * FROM cause_records').get())
          .map((r) => r.data)
          .toList()
          .single;
      expect(row['solved_count'], 1);
      expect(row['status'], 'inProgress');
      expect(
        await db.customSelect('SELECT * FROM review_history').get(),
        hasLength(1),
      );
      expect(
        (await db.customSelect('SELECT * FROM questions').get())
            .map((r) => r.data)
            .toList()
            .single['review_count'],
        1,
      );
    });
  });

  group('SR-P2-17 删文件夹按 folder_ids 粗筛', () {
    test('含 _ 的文件夹 id 不误筛其它文件夹的题', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await db.customInsert(
        'INSERT INTO folders (id, name, subject_id, parent_id, sort_order) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('f_1'),
          Variable.withString('A'),
          Variable.withString('math'),
          const Variable<String>(null),
          Variable.withInt(0),
        ],
      );
      await db.customInsert(
        'INSERT INTO folders (id, name, subject_id, parent_id, sort_order) '
        'VALUES (?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('fX1'),
          Variable.withString('B'),
          Variable.withString('math'),
          const Variable<String>(null),
          Variable.withInt(1),
        ],
      );
      await insertQuestion(db, 'q1', folderIds: '["f_1"]');
      await insertQuestion(db, 'q2', folderIds: '["fX1"]');
      await insertQuestion(db, 'q3', folderIds: '["f_1","fX1"]');
      final deleted = await AppDatabase.deleteFolderFrom(
        db,
        const Folder(id: 'f_1', name: 'A', subjectId: 'math'),
      );
      expect(deleted, 1);
      final left = (await db.customSelect('SELECT * FROM questions').get())
          .map((r) => r.data)
          .toList();
      expect(left.map((r) => r['id']).toList(), ['q2', 'q3']);
      final q3 = left.firstWhere((r) => r['id'] == 'q3');
      expect(q3['folder_ids'], '["fX1"]');
    });
  });

  group('SR-P2-36 文件夹同名判重整科', () {
    test('同科跨层同名拒绝；不同科同名放行；自己原地更新放行', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      await AppDatabase.instance.upsertFolder(
        const Folder(id: 'f1', name: '试卷', subjectId: 'math'),
      );
      // 同科另一父级下同名：拒绝。
      await expectLater(
        () => AppDatabase.instance.upsertFolder(
          const Folder(id: 'f2', name: '试卷', subjectId: 'math', parentId: 'f1'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('已经有了'),
          ),
        ),
      );
      // 不同科同名：放行。
      await AppDatabase.instance.upsertFolder(
        const Folder(id: 'f3', name: '试卷', subjectId: 'english'),
      );
      // 自己原地更新（改排序）：放行。
      await AppDatabase.instance.upsertFolder(
        const Folder(id: 'f1', name: '试卷', subjectId: 'math', sortOrder: 5),
      );
      // 改名撞上同科已有名：拒绝。
      await AppDatabase.instance.upsertFolder(
        const Folder(id: 'f4', name: '作业', subjectId: 'math'),
      );
      await expectLater(
        () => AppDatabase.instance.upsertFolder(
          const Folder(id: 'f4', name: '试卷', subjectId: 'math'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        await AppDatabase.folderNameExistsInSubjectFrom(db, 'math', '试卷'),
        isTrue,
      );
      expect(
        await AppDatabase.folderNameExistsInSubjectFrom(
          db,
          'math',
          '试卷',
          excludeId: 'f1',
        ),
        isFalse,
      );
      expect(
        await AppDatabase.folderNameExistsInSubjectFrom(db, 'math', '不存在'),
        isFalse,
      );
    });

    test('并发同名 upsert：库里只有 1 行（SR2-15）', () async {
      final db = await openTestDb();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => db.close());
      Future<String> attempt(Folder f) async {
        try {
          await AppDatabase.instance.upsertFolder(f);
          return 'ok';
        } catch (e) {
          return 'err:$e';
        }
      }

      final results = await Future.wait([
        attempt(const Folder(id: 'f-a', name: '试卷', subjectId: 'math')),
        attempt(const Folder(id: 'f-b', name: '试卷', subjectId: 'math')),
      ]);
      // 一路成功、一路因“已经有了”被拒（旧写法两路都通过判重，
      // 库里出现两个同名文件夹）。
      expect(results.where((r) => r == 'ok'), hasLength(1));
      expect(results.where((r) => r.contains('已经有了')), hasLength(1));
      final rows =
          (await db
                  .customSelect(
                    'SELECT * FROM folders WHERE subject_id = ? AND name = ?',
                    variables: [
                      Variable.withString('math'),
                      Variable.withString('试卷'),
                    ],
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      expect(rows, hasLength(1));
    });
  });

  group('SR2-66 SR-P2-6 staging 严格匹配 + zip 恢复三档文案', () {
    Future<List<int>> validZip(QuizDatabase db) async {
      final json = await AppDatabase.exportBackupJsonFrom(db);
      return buildZip([ZipEntryData('backup.json', utf8.encode(json))]);
    }

    test('旧 staging 清理只删严格匹配的目录，用户同名目录不动', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      await exportedJson(db);
      // 用户目录：.restore-staging-backup（非纯数字后缀），不动。
      final userDir = Directory(p.join(tmpDir.path, '.restore-staging-backup'));
      await userDir.create();
      await File(p.join(userDir.path, 'keep.txt')).writeAsString('keep');
      // 上次崩溃残留的真 staging：纯数字时间戳，应被顺带清掉。
      final stale = Directory(
        p.join(tmpDir.path, '.restore-staging-1700000000000'),
      );
      await stale.create();
      await File(p.join(stale.path, 'stale.txt')).writeAsString('stale');
      final zip = await validZip(db);
      await AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path);
      expect(await File(p.join(userDir.path, 'keep.txt')).exists(), isTrue);
      expect(await stale.exists(), isFalse);
    });

    test('校验问题原样抛，不包成“文件写不进去”（第一档）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      (data['_meta'] as Map)['schemaVersion'] = 99;
      final zip = buildZip([
        ZipEntryData('backup.json', utf8.encode(jsonEncode(data))),
      ]);
      await expectLater(
        () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            allOf(contains('更新的版本'), isNot(contains('文件写不进去'))),
          ),
        ),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });

    test('数据库失败时文案是“备份数据有问题”，不是“文件写不进去”（第二档）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      await db.customStatement(
        "CREATE TRIGGER trg_fail_q BEFORE INSERT ON questions "
        "BEGIN SELECT RAISE(ABORT, 'boom'); END;",
      );
      final zip = buildZip([
        ZipEntryData('backup.json', utf8.encode(jsonEncode(data))),
      ]);
      await expectLater(
        () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            allOf(contains('备份数据有问题'), isNot(contains('文件写不进去'))),
          ),
        ),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });

    test('IO 失败时文案是“文件写不进去”（第三档）', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      // slices 在盘上是个文件不是目录：进位时建 slices/ 目录失败。
      await File(p.join(tmpDir.path, 'slices')).writeAsString('not-a-dir');
      final zip = buildZip([
        ZipEntryData('backup.json', utf8.encode(jsonEncode(data))),
        ZipEntryData('slices/q1.png', List.filled(10, 1)),
      ]);
      await expectLater(
        () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            contains('文件写不进去'),
          ),
        ),
      );
      expect(await File(p.join(tmpDir.path, 'slices')).exists(), isTrue);
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });
  });

  group('SR2-17 readZip 拒重名条目', () {
    test('重名文件条目抛错；backup.json 重名也拒绝（FR-40）', () {
      final dup = buildStoredZipForTest([
        ('slices/q1.png', [1, 2]),
        ('slices/q1.png', [3, 4]),
      ]);
      expect(
        () => readZip(dup),
        throwsA(
          isA<ZipFormatException>().having(
            (e) => e.message,
            'message',
            contains('重复条目'),
          ),
        ),
      );
      // FR-40：backup.json 重名也不再放行（之前是例外、取最后一个，
      // 两份内容不同的题目数据会静默按后一份恢复）——现在直接拒绝。
      Map<String, dynamic> minimalJson({bool withSubject = false}) => {
        '_meta': {'schemaVersion': 2, 'appVersion': 'test', 'exportedAt': 1},
        for (final t in AppDatabase.backupTables)
          t: withSubject && t == 'subjects'
              ? [
                  {'id': 'math', 'name': '数学', 'color': 1},
                ]
              : <dynamic>[],
      };
      final dupJson = buildStoredZipForTest([
        ('backup.json', utf8.encode(jsonEncode(minimalJson()))),
        (
          'backup.json',
          utf8.encode(jsonEncode(minimalJson(withSubject: true))),
        ),
      ]);
      expect(
        () => readZip(dupJson),
        throwsA(
          isA<ZipFormatException>().having(
            (e) => e.message,
            'message',
            contains('备份里有两份题目数据'),
          ),
        ),
      );
    });

    test('重名文件条目的备份：恢复报“已损坏”，不误报“文件写不进去”', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      final zip = buildStoredZipForTest([
        ('backup.json', utf8.encode(jsonEncode(data))),
        ('slices/q1.png', [1, 2]),
        ('slices/q1.png', [3, 4]),
      ]);
      await expectLater(
        () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            allOf(contains('已损坏'), isNot(contains('文件写不进去'))),
          ),
        ),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });

    test('SR3-1：// 与 /. 变体、反斜杠与大小写变体同样判重', () {
      void expectDup(List<(String, List<int>)> entries) {
        expect(
          () => readZip(buildStoredZipForTest(entries)),
          throwsA(
            isA<ZipFormatException>().having(
              (e) => e.message,
              'message',
              contains('重复条目'),
            ),
          ),
        );
      }

      // `//` 变体：与规范写法同一文件。
      expectDup([
        ('slices//q1.png', [1, 2]),
        ('slices/q1.png', [3, 4]),
      ]);
      // `/.` 变体。
      expectDup([
        ('slices/./q1.png', [1, 2]),
        ('slices/q1.png', [3, 4]),
      ]);
      // 反斜杠变体（Windows 分隔符）。
      expectDup([
        ('slices\\q1.png', [1, 2]),
        ('slices/q1.png', [3, 4]),
      ]);
      // 大小写变体（Windows 大小写不敏感）。
      expectDup([
        ('Slices/Q1.png', [1, 2]),
        ('slices/q1.png', [3, 4]),
      ]);
      // 单条变体本身不重名：可读出，存名原样保留（归一化只用于判重）。
      final single = readZip(
        buildStoredZipForTest([
          ('slices//q1.png', [1, 2]),
        ]),
      );
      expect(single.map((e) => e.name), ['slices//q1.png']);
      expect(single.single.bytes, [1, 2]);
    });

    test('SR3-1：// 变体重名备份恢复报“已损坏”，不误报“文件写不进去”', () async {
      final db = await openTestDb();
      addTearDown(() async => db.close());
      final data = await exportedJson(db);
      final zip = buildStoredZipForTest([
        ('backup.json', utf8.encode(jsonEncode(data))),
        ('slices//q1.png', [1, 2]),
        ('slices/q1.png', [3, 4]),
      ]);
      await expectLater(
        () => AppDatabase.importBackupZipInto(db, zip, dataDir: tmpDir.path),
        throwsA(
          isA<BackupRestoreException>().having(
            (e) => e.message,
            'message',
            allOf(contains('已损坏'), isNot(contains('文件写不进去'))),
          ),
        ),
      );
      expect(
        await db.customSelect('SELECT * FROM questions').get(),
        hasLength(1),
      );
    });
  });

  group('SR-P2-68 readZip 走中央目录', () {
    test('带数据描述符（flag bit 3）的 zip 能读：stored 与 deflate', () {
      final stored = _buildDescriptorZip(
        'backup.json',
        utf8.encode('{"a":1}'),
        method: 0,
      );
      final entries = readZip(stored);
      expect(entries.map((e) => e.name), ['backup.json']);
      expect(utf8.decode(entries.first.bytes), '{"a":1}');
      final deflated = _buildDescriptorZip(
        'slices/q1.png',
        List.filled(5000, 7),
        method: 8,
      );
      final entries2 = readZip(deflated);
      expect(entries2.single.bytes, List.filled(5000, 7));
    });

    test('只含目录条目的 zip 抛错，不静默返回空列表', () {
      final dirOnly = _buildDescriptorZip('imports/', [], method: 0);
      expect(() => readZip(dirOnly), throwsA(isA<ZipFormatException>()));
      final emptyDir = buildZip([const ZipEntryData('imports/', [])]);
      expect(() => readZip(emptyDir), throwsA(isA<ZipFormatException>()));
    });

    test('中央目录与 local header 名不一致：抛错', () {
      final good = buildStoredZipForTest([
        ('backup.json', utf8.encode('{"a":1}')),
      ]);
      // 中央目录在 local 数据之后：把中央目录里的名字首字节改掉。
      final tampered = List<int>.of(good);
      final cd = _findBytes(tampered, [0x50, 0x4B, 0x01, 0x02]);
      tampered[cd + 46] = 'X'.codeUnitAt(0);
      expect(() => readZip(tampered), throwsA(isA<ZipFormatException>()));
    });

    test('超大单条目：解压前按中央目录 rawSize 预判，不先占内存', () {
      // 中央目录谎报 rawSize 10MB，实际只有 3 字节，上限 1KB：
      // 预判必须在解压前触发，而不是解压后。
      final bytes = _buildDescriptorZip('big.bin', [1, 2, 3], method: 0);
      final tampered = List<int>.of(bytes);
      final cd = _findBytes(tampered, [0x50, 0x4B, 0x01, 0x02]);
      // 中央目录 rawSize 在 +24：写成 10MB。
      _writeU32(tampered, cd + 24, 10 * 1024 * 1024);
      expect(
        () => readZip(tampered, maxTotalBytes: 1024),
        throwsA(
          isA<ZipFormatException>().having(
            (e) => e.message,
            'message',
            contains('超过'),
          ),
        ),
      );
    });

    test('空 zip（0 条目）抛错', () {
      final bytes = buildZip([]);
      expect(() => readZip(bytes), throwsA(isA<ZipFormatException>()));
    });
  });
}

Future<void> insertBoxRow(QuizDatabase db, QuestionBox b) async {
  final row = _boxRow(b);
  await db.customInsert(
    'INSERT INTO question_boxes (id, collect_task_id, question_id, '
    'parent_box_id, page, layer, type, x, y, w, h, confidence, origin, '
    'updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable(row['id']),
      Variable(row['collect_task_id']),
      Variable(row['question_id']),
      Variable(row['parent_box_id']),
      Variable(row['page']),
      Variable(row['layer']),
      Variable(row['type']),
      Variable(row['x']),
      Variable(row['y']),
      Variable(row['w']),
      Variable(row['h']),
      Variable(row['confidence']),
      Variable(row['origin']),
      Variable(row['updated_at']),
    ],
  );
}

Map<String, Object?> _boxRow(QuestionBox b) => {
  'id': b.id,
  'collect_task_id': b.collectTaskId,
  'question_id': b.questionId,
  'parent_box_id': b.parentBoxId,
  'page': b.page,
  'layer': b.layer,
  'type': b.type,
  'x': b.x,
  'y': b.y,
  'w': b.w,
  'h': b.h,
  'confidence': b.confidence,
  'origin': b.origin,
  'updated_at': 1000,
};

void _u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
void _u32(BytesBuilder b, int v) =>
    b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

void _writeU32(List<int> bytes, int off, int v) {
  bytes[off] = v & 0xFF;
  bytes[off + 1] = (v >> 8) & 0xFF;
  bytes[off + 2] = (v >> 16) & 0xFF;
  bytes[off + 3] = (v >> 24) & 0xFF;
}

int _findBytes(List<int> bytes, List<int> pattern) {
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

/// 手工造带数据描述符的 zip（SR-P2-68）：local header 置 flag bit 3、
/// 尺寸写 0，真实尺寸只在数据后的描述符与中央目录里。
List<int> _buildDescriptorZip(
  String name,
  List<int> data, {
  required int method,
}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  final nameBytes = utf8.encode(name);
  final compressed = method == 8 ? ZLibCodec(raw: true).encode(data) : data;
  final crc = crc32(data);
  out.add([0x50, 0x4B, 0x03, 0x04]);
  _u16(out, 20);
  _u16(out, 0x0800 | 0x08); // UTF-8 + bit 3：尺寸在数据描述符里
  _u16(out, method);
  _u16(out, 0);
  _u16(out, 0);
  _u32(out, 0);
  _u32(out, 0);
  _u32(out, 0);
  _u16(out, nameBytes.length);
  _u16(out, 0);
  out.add(nameBytes);
  out.add(compressed);
  out.add([0x50, 0x4B, 0x07, 0x08]); // 描述符签名
  _u32(out, crc);
  _u32(out, compressed.length);
  _u32(out, data.length);
  central.add([0x50, 0x4B, 0x01, 0x02]);
  _u16(central, 20);
  _u16(central, 20);
  _u16(central, 0x0800 | 0x08);
  _u16(central, method);
  _u16(central, 0);
  _u16(central, 0);
  _u32(central, crc);
  _u32(central, compressed.length);
  _u32(central, data.length);
  _u16(central, nameBytes.length);
  _u16(central, 0);
  _u16(central, 0);
  _u16(central, 0);
  _u16(central, 0);
  _u32(central, 0);
  _u32(central, 0);
  central.add(nameBytes);
  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  out.add([0x50, 0x4B, 0x05, 0x06]);
  _u16(out, 0);
  _u16(out, 0);
  _u16(out, 1);
  _u16(out, 1);
  _u32(out, centralBytes.length);
  _u32(out, centralOffset);
  _u16(out, 0);
  return out.takeBytes();
}

/// stored 方式打包（同 p3 的 buildStoredZip，带中央目录 + EOCD），
/// 供“中央/本地不一致”篡改测试用。
List<int> buildStoredZipForTest(List<(String, List<int>)> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final (name, data) in entries) {
    final nameBytes = utf8.encode(name);
    final offset = out.length;
    out.add([0x50, 0x4B, 0x03, 0x04]);
    _u16(out, 20);
    _u16(out, 0x0800);
    _u16(out, 0);
    _u16(out, 0);
    _u16(out, 0);
    _u32(out, crc32(data));
    _u32(out, data.length);
    _u32(out, data.length);
    _u16(out, nameBytes.length);
    _u16(out, 0);
    out.add(nameBytes);
    out.add(data);
    central.add([0x50, 0x4B, 0x01, 0x02]);
    _u16(central, 20);
    _u16(central, 20);
    _u16(central, 0x0800);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, crc32(data));
    _u32(central, data.length);
    _u32(central, data.length);
    _u16(central, nameBytes.length);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, 0);
    _u32(central, offset);
    central.add(nameBytes);
  }
  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  out.add([0x50, 0x4B, 0x05, 0x06]);
  _u16(out, 0);
  _u16(out, 0);
  _u16(out, entries.length);
  _u16(out, entries.length);
  _u32(out, centralBytes.length);
  _u32(out, centralOffset);
  _u16(out, 0);
  return out.takeBytes();
}
