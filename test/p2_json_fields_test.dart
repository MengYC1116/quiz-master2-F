// P2 §3：多值字段 JSON 编解码收口 + 11 处写点 + review queue。
// 内存库，不碰真实用户库。含 `,`/`|` 的值必须原样往返（旧逗号拆分
// 会把一个值拆成两个）；非法值（不是 JSON 数组）按空列表处理，不猜拆分。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openMemoryDb() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async =>
              AppDatabase.createTables(db)));
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async => db.close());
  return db;
}

Question q({
  String id = 'q1',
  List<String> folderIds = const ['f1', 'f2'],
  List<String> knowledgePointIds = const ['kp1', 'kp2'],
  List<String> errorTypes = const ['计算错误'],
  List<String> customErrorTypes = const [],
  List<String> tags = const ['易错', '常考'],
}) =>
    Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      folderIds: folderIds,
      knowledgePointIds: knowledgePointIds,
      errorTypes: errorTypes,
      customErrorTypes: customErrorTypes,
      tags: tags,
      createdAt: DateTime(2026, 11, 14),
    );

Future<void> seedBase(Database db) async {
  await db.insert('folders', {
    'id': 'f1',
    'name': '试卷',
    'subject_id': 'math',
    'parent_id': null,
    'sort_order': 0,
  });
  await db.insert('folders', {
    'id': 'f2',
    'name': '平时作业',
    'subject_id': 'math',
    'parent_id': null,
    'sort_order': 1,
  });
  await db.insert('tags', {'id': 'tag-易错', 'name': '易错'});
  await db.insert('tags', {'id': 'tag-常考', 'name': '常考'});
  await db.insert('knowledge_points', {
    'id': 'kp1',
    'subject_id': 'math',
    'chapter': '第一章',
    'name': '极限',
  });
  await db.insert('knowledge_points', {
    'id': 'kp2',
    'subject_id': 'math',
    'chapter': '第一章',
    'name': '导数',
  });
  await db.insert('knowledge_points', {
    'id': 'kp3',
    'subject_id': 'math',
    'chapter': '第二章',
    'name': '积分',
  });
}

void main() {
  group('编解码收口', () {
    test('含逗号/竖线/分隔符字样的值原样往返，不拆分', () {
      const values = ['a,b', 'c|d', 'e，f', 'x---y', '审题，失误'];
      expect(
        AppDatabase.decodeStringList(AppDatabase.encodeStringList(values)),
        values,
      );
      expect(
        AppDatabase.decodeRemedyList(AppDatabase.encodeRemedyList(values)),
        values,
      );
    });

    test('空串 / NULL / 非法值解码为空列表，不猜逗号拆分', () {
      for (final bad in [null, '', 'a,b', 'a|b', 'not json', '123', '{"a":1}']) {
        expect(AppDatabase.decodeStringList(bad), isEmpty, reason: '$bad');
        expect(AppDatabase.decodeRemedyList(bad), isEmpty, reason: '$bad');
        expect(AppDatabase.decodeQueue(bad), isEmpty, reason: '$bad');
      }
      expect(AppDatabase.encodeStringList(const []), '[]');
      expect(AppDatabase.encodeRemedyList(const []), '[]');
      expect(AppDatabase.encodeQueue(const []), '[]');
    });

    test('queue 含 | 与逗号的对象数组往返', () {
      const queue = [
        ReviewQueueItem(questionId: 'q|1', cause: '审题，失误'),
        ReviewQueueItem(questionId: 'q2', cause: '概念不清'),
      ];
      final encoded = AppDatabase.encodeQueue(queue);
      expect(encoded, contains('|'));
      expect(AppDatabase.decodeQueue(encoded), queue);
    });

    test('saveReviewState / loadReviewState 往返（含 | 与逗号）', () async {
      final db = await openMemoryDb();
      await db.insert('questions', {
        'id': 'q|1',
        'title': 't',
        'subject_id': 'math',
        'created_at': 0,
      });
      const queue = [
        ReviewQueueItem(questionId: 'q|1', cause: '审题，失误'),
        ReviewQueueItem(questionId: 'q2', cause: '方法不会'),
      ];
      await AppDatabase.instance.saveReviewState(queue: queue, position: 1);
      final state = await AppDatabase.instance.loadReviewState();
      expect(state, isNotNull);
      expect(state!.queue, queue);
      expect(state.position, 1);
    });

    test('hasBannedNameSeparator：只禁逗号与竖线', () {
      expect(hasBannedNameSeparator('a,b'), isTrue);
      expect(hasBannedNameSeparator('a，b'), isTrue);
      expect(hasBannedNameSeparator('a|b'), isTrue);
      expect(hasBannedNameSeparator('数学·易错!'), isFalse);
      expect(hasBannedNameSeparator('a/b'), isFalse);
      expect(hasBannedNameSeparator('a-b_c'), isFalse);
      expect(hasBannedNameSeparator(''), isFalse);
    });
  });

  group('写点：删改后重读仍能正确解析', () {
    test('删文件夹：题上只去掉该文件夹，其余值（含逗号标签）不动', () async {
      final db = await openMemoryDb();
      await seedBase(db);
      await AppDatabase.instance.upsertQuestion(
          q(tags: const ['a,b', 'c|d', '常考']));
      await AppDatabase.deleteFolderFrom(
          db, const Folder(id: 'f1', name: '试卷', subjectId: 'math'));
      final back = (await AppDatabase.instance.allQuestions()).first;
      expect(back.folderIds, ['f2']);
      expect(back.tags, ['a,b', 'c|d', '常考']);
      expect(back.knowledgePointIds, ['kp1', 'kp2']);
    });

    test('改标签：旧名换新名，含逗号的新名不拆分', () async {
      final db = await openMemoryDb();
      await seedBase(db);
      await AppDatabase.instance.upsertQuestion(q());
      await AppDatabase.renameTagFrom(db, '易错', '易，错');
      final back = (await AppDatabase.instance.allQuestions()).first;
      expect(back.tags, ['易，错', '常考']);
    });

    test('删标签：题上去掉该标签，其余值不动', () async {
      final db = await openMemoryDb();
      await seedBase(db);
      await AppDatabase.instance.upsertQuestion(q());
      await AppDatabase.deleteTagFrom(db, '易错');
      final back = (await AppDatabase.instance.allQuestions()).first;
      expect(back.tags, ['常考']);
      expect(back.folderIds, ['f1', 'f2']);
    });

    test('删知识点：题上去掉该知识点，其余值不动', () async {
      final db = await openMemoryDb();
      await seedBase(db);
      await AppDatabase.instance.upsertQuestion(q());
      await AppDatabase.deleteKnowledgePointFrom(db, 'kp1');
      final back = (await AppDatabase.instance.allQuestions()).first;
      expect(back.knowledgePointIds, ['kp2']);
      expect(back.tags, ['易错', '常考']);
    });

    test('删章节：该章节全部知识点从题上去掉，其余值不动', () async {
      final db = await openMemoryDb();
      await seedBase(db);
      await AppDatabase.instance.upsertQuestion(
          q(knowledgePointIds: const ['kp1', 'kp2', 'kp3']));
      await AppDatabase.deleteChapterFrom(db, 'math', '第一章');
      final back = (await AppDatabase.instance.allQuestions()).first;
      expect(back.knowledgePointIds, ['kp3']);
      expect(back.folderIds, ['f1', 'f2']);
    });

    test('手写旧格式行（tags 栏是裸逗号串）读出来是空列表，不猜拆分', () async {
      final db = await openMemoryDb();
      await db.insert('questions', {
        'id': 'q-old',
        'title': '旧行',
        'subject_id': 'math',
        'folder_ids': 'f1,f2',
        'knowledge_ids': 'kp1|kp2',
        'error_types': '',
        'tags': '易错,常考',
        'created_at': 0,
      });
      final back = await AppDatabase.instance.questionById('q-old');
      expect(back, isNotNull);
      expect(back!.folderIds, isEmpty);
      expect(back.knowledgePointIds, isEmpty);
      expect(back.tags, isEmpty);
    });
  });

  group('cause records', () {
    test('_seedCauseRecordsFor 写 []：新种错因记录 remedyHistory 为空', () async {
      final db = await openMemoryDb();
      await seedBase(db);
      final question = q(errorTypes: const ['计算错误'], customErrorTypes: const ['手滑']);
      await AppDatabase.instance.upsertQuestion(question);
      await AppDatabase.instance.ensureCauseRecords(question);
      final records =
          await AppDatabase.instance.causeRecordsForQuestion('q1');
      expect(records.length, 2);
      for (final r in records) {
        expect(r.remedyHistory, isEmpty);
      }
      // 库里存的是 '[]'，不是 ''。
      final rows = await db.query('cause_records',
          columns: ['remedy_history']);
      expect(rows.map((r) => r['remedy_history']).toSet(), {'[]'});
    });
  });
}
