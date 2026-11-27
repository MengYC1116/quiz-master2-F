// P2 §3：多值字段 JSON 编解码收口 + 11 处写点 + review queue。
// 内存库，不碰真实用户库。含 `,`/`|` 的值必须原样往返（旧逗号拆分
// 会把一个值拆成两个）；非法值（不是 JSON 数组）按空列表处理，不猜拆分。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/models.dart';

Future<QuizDatabase> openMemoryDb() async {
  final db = await AppDatabase.openForTest();
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
}) => Question(
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

Future<void> seedBase(QuizDatabase db) async {
  await db.customInsert(
    'INSERT INTO folders (id, name, subject_id, parent_id, sort_order) '
    'VALUES (?, ?, ?, ?, ?)',
    variables: [
      Variable.withString('f1'),
      Variable.withString('试卷'),
      Variable.withString('math'),
      const Variable<String>(null),
      Variable.withInt(0),
    ],
  );
  await db.customInsert(
    'INSERT INTO folders (id, name, subject_id, parent_id, sort_order) '
    'VALUES (?, ?, ?, ?, ?)',
    variables: [
      Variable.withString('f2'),
      Variable.withString('平时作业'),
      Variable.withString('math'),
      const Variable<String>(null),
      Variable.withInt(1),
    ],
  );
  await db.customInsert(
    'INSERT INTO tags (id, name) VALUES (?, ?)',
    variables: [Variable.withString('tag-易错'), Variable.withString('易错')],
  );
  await db.customInsert(
    'INSERT INTO tags (id, name) VALUES (?, ?)',
    variables: [Variable.withString('tag-常考'), Variable.withString('常考')],
  );
  await db.customInsert(
    'INSERT INTO knowledge_points (id, subject_id, chapter, name) '
    'VALUES (?, ?, ?, ?)',
    variables: [
      Variable.withString('kp1'),
      Variable.withString('math'),
      Variable.withString('第一章'),
      Variable.withString('极限'),
    ],
  );
  await db.customInsert(
    'INSERT INTO knowledge_points (id, subject_id, chapter, name) '
    'VALUES (?, ?, ?, ?)',
    variables: [
      Variable.withString('kp2'),
      Variable.withString('math'),
      Variable.withString('第一章'),
      Variable.withString('导数'),
    ],
  );
  await db.customInsert(
    'INSERT INTO knowledge_points (id, subject_id, chapter, name) '
    'VALUES (?, ?, ?, ?)',
    variables: [
      Variable.withString('kp3'),
      Variable.withString('math'),
      Variable.withString('第二章'),
      Variable.withString('积分'),
    ],
  );
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
      for (final bad in [
        null,
        '',
        'a,b',
        'a|b',
        'not json',
        '123',
        '{"a":1}',
      ]) {
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
      await db.customInsert(
        'INSERT INTO questions (id, title, subject_id, created_at) '
        'VALUES (?, ?, ?, ?)',
        variables: [
          Variable.withString('q|1'),
          Variable.withString('t'),
          Variable.withString('math'),
          Variable.withInt(0),
        ],
      );
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
        q(tags: const ['a,b', 'c|d', '常考']),
      );
      await AppDatabase.deleteFolderFrom(
        db,
        const Folder(id: 'f1', name: '试卷', subjectId: 'math'),
      );
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
        q(knowledgePointIds: const ['kp1', 'kp2', 'kp3']),
      );
      await AppDatabase.deleteChapterFrom(db, 'math', '第一章');
      final back = (await AppDatabase.instance.allQuestions()).first;
      expect(back.knowledgePointIds, ['kp3']);
      expect(back.folderIds, ['f1', 'f2']);
    });

    test('手写旧格式行（tags 栏是裸逗号串）读出来是空列表，不猜拆分', () async {
      final db = await openMemoryDb();
      await db.customInsert(
        'INSERT INTO questions (id, title, subject_id, folder_ids, '
        'knowledge_ids, error_types, tags, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable.withString('q-old'),
          Variable.withString('旧行'),
          Variable.withString('math'),
          Variable.withString('f1,f2'),
          Variable.withString('kp1|kp2'),
          Variable.withString(''),
          Variable.withString('易错,常考'),
          Variable.withInt(0),
        ],
      );
      final back = await AppDatabase.instance.questionById('q-old');
      expect(back, isNotNull);
      expect(back!.folderIds, isEmpty);
      expect(back.knowledgePointIds, isEmpty);
      expect(back.tags, isEmpty);
    });
  });

  group('cause records', () {
    test('updateCauseRemedy INSERT 写 []：新行 remedyHistory 为空', () async {
      final db = await openMemoryDb();
      await seedBase(db);
      final question = q(
        errorTypes: const ['计算错误'],
        customErrorTypes: const ['手滑'],
      );
      await AppDatabase.instance.upsertQuestion(question);
      // FSRS 全量迁移包2：播种（ensureCauseRecords）已删；改走
      // updateCauseRemedy 的缺行 INSERT 路径（唯一写 cause_records
      // 行的入口），仍须保证 remedy_history 存 '[]' 不是 ''。
      await AppDatabase.instance.updateCauseRemedy(
        CauseRecord(
          questionId: 'q1',
          cause: '计算错误',
          subjectId: 'math',
          joinedAt: DateTime(2026, 11, 1),
        ),
      );
      await AppDatabase.instance.updateCauseRemedy(
        CauseRecord(
          questionId: 'q1',
          cause: '手滑',
          subjectId: 'math',
          joinedAt: DateTime(2026, 11, 1),
        ),
      );
      final records = await AppDatabase.instance.causeRecordsForQuestion('q1');
      expect(records.length, 2);
      for (final r in records) {
        expect(r.remedyHistory, isEmpty);
      }
      // 库里存的是 '[]'，不是 ''。
      final rows =
          (await db
                  .customSelect('SELECT remedy_history FROM cause_records')
                  .get())
              .map((r) => r.data)
              .toList();
      expect(rows.map((r) => r['remedy_history']).toSet(), {'[]'});
    });
  });
}
