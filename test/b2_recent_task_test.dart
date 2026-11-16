// B2 集成：recentTask / saveRecentTask 永久测试（W-settings 遗留①）。
// D-45：库在测试体内建、直接 await（不用 setUp + runAsync）；
// openForTest 内已发 SELECT 1 强制建连。
// 覆盖：空表读 null、覆盖写只留 1 行（CHECK id=1）、旧英文 kind
// 读出归一化（organize → 整理、collect → 收集）、saveSetting
// 同键覆盖写。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';

Future<QuizDatabase> openMemoryDb() async {
  final db = await AppDatabase.openForTest();
  AppDatabase.useDatabaseForTest(db);
  addTearDown(() async {
    await AppDatabase.resetForTest();
  });
  return db;
}

void main() {
  test('空表读 recentTask 返回 null', () async {
    await openMemoryDb();
    expect(await AppDatabase.instance.recentTask(), isNull);
  });

  test('覆盖写只留 1 行：第二次保存覆盖第一次', () async {
    final db = await openMemoryDb();
    await AppDatabase.instance.saveRecentTask(
      kind: '整理',
      subjectId: 'math',
      title: '第一题',
    );
    await AppDatabase.instance.saveRecentTask(
      kind: '收集',
      subjectId: 'english',
      title: '第二题',
    );
    // CHECK (id = 1) 单行表：全表只能有 1 行。
    final rows = await db.select(db.recentTasks).get();
    expect(rows, hasLength(1));
    expect(rows.single.id, 1);
    final back = await AppDatabase.instance.recentTask();
    expect(back, isNotNull);
    expect(back!.kind, '收集');
    expect(back.subjectId, 'english');
    expect(back.title, '第二题');
  });

  test('旧英文 kind 读出归一化：organize → 整理、collect → 收集', () async {
    final db = await openMemoryDb();
    // 直接写旧英文值（模拟 B7 之前入库的行），读出应归一化。
    await db
        .into(db.recentTasks)
        .insert(
          RecentTasksCompanion.insert(
            id: const Value(1),
            kind: 'organize',
            subjectId: 'math',
            title: '旧行',
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
          mode: InsertMode.insertOrReplace,
        );
    final back = await AppDatabase.instance.recentTask();
    expect(back, isNotNull);
    expect(back!.kind, '整理');
    await db
        .into(db.recentTasks)
        .insert(
          RecentTasksCompanion.insert(
            id: const Value(1),
            kind: 'collect',
            subjectId: 'english',
            title: '旧行2',
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
          mode: InsertMode.insertOrReplace,
        );
    final back2 = await AppDatabase.instance.recentTask();
    expect(back2, isNotNull);
    expect(back2!.kind, '收集');
  });

  test('saveSetting 同键覆盖：后写的值胜出', () async {
    final db = await openMemoryDb();
    await AppDatabase.instance.saveSetting('b2-recent-key', 'v1');
    await AppDatabase.instance.saveSetting('b2-recent-key', 'v2');
    // 直接读 settings 表（AppSettings.fromMap 只认已知键，任意键
    // 会被 fromMap 丢掉，不能用 loadSettings 断言）。
    final row = await (db.select(
      db.settings,
    )..where((t) => t.key.equals('b2-recent-key'))).getSingleOrNull();
    expect(row?.value, 'v2');
    final rows = await (db.select(db.settings)..where(
      (t) => t.key.equals('b2-recent-key'),
    )).get();
    expect(rows, hasLength(1));
  });
}
