// GPT 关口审 P1（FR-43 备份恢复 TOCTOU）：校验过的字节与导入的字节
// 必须是同一份。旧流程解析时只记路径、确认前指纹重查、恢复时按路径
// 重读——校验与恢复之间文件被换，恢复的就是用户没确认过的另一份备份。
// 新流程解析时读到的字节一路带到恢复，不再按路径重读，磁盘上的文件
// 在解析后被替换/删除也不影响本次恢复。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/settings_notifier.dart';

class FakeP1Repo extends QuestionRepository {
  FakeP1Repo() : super(AppDatabase.instance);

  List<int>? restoredZipBytes;
  Map<String, dynamic>? restoredJson;

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<void> importBackupZip(List<int> bytes) async {
    restoredZipBytes = bytes;
  }

  @override
  Future<void> importBackupJson(Map<String, dynamic> data) async {
    restoredJson = data;
  }
}

SettingsNotifier makeP1Notifier(FakeP1Repo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  return container.read(settingsProvider.notifier);
}

/// 在内存库里种一科一题（列清单与 b5 的 insertQuestion 一致）。
Future<void> seedBackupDb(QuizDatabase db, String title) async {
  await db.customInsert(
    'INSERT OR REPLACE INTO subjects (id, name, color) VALUES (?, ?, ?)',
    variables: [
      Variable.withString('math'),
      Variable.withString('数学'),
      Variable.withInt(0xFF2E7CF6),
    ],
  );
  await db.customInsert(
    'INSERT OR REPLACE INTO questions (id, title, subject_id, folder_ids, '
    'created_at, is_demo, is_organized, review_joined, review_count) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    variables: [
      Variable.withString('q1'),
      Variable.withString(title),
      Variable.withString('math'),
      Variable.withString('[]'),
      Variable.withInt(1000),
      Variable.withInt(0),
      Variable.withInt(1),
      Variable.withInt(0),
      Variable.withInt(0),
    ],
  );
}

/// 从内存库导出两份内容不同的有效 zip 备份（A：A题，B：B题）。
Future<(List<int>, List<int>)> exportTwoBackups() async {
  final db = await AppDatabase.openForTest();
  addTearDown(() async => db.close());
  await seedBackupDb(db, 'A题');
  final bytesA = await AppDatabase.exportBackupZipFrom(db);
  await db.customUpdate(
    "UPDATE questions SET title = 'B题' WHERE id = 'q1'",
  );
  final bytesB = await AppDatabase.exportBackupZipFrom(db);
  expect(bytesA, isNot(bytesB));
  return (bytesA, bytesB);
}

void main() {
  test('确认前文件被换成另一份有效备份，恢复的仍是解析过的那份', () async {
    final (bytesA, bytesB) = await exportTwoBackups();
    final dir = await Directory.systemTemp.createTemp('qm2-p1-');
    addTearDown(() async => dir.delete(recursive: true));
    final file = File('${dir.path}/backup.qm2backup');
    await file.writeAsBytes(bytesA);

    final repo = FakeP1Repo();
    final notifier = makeP1Notifier(repo);
    final parsed = await notifier.parseRestoreFile(file.path);
    expect(parsed.zipBytes, bytesA);

    // 模拟确认前另一程序把同一路径的文件换成备份 B。
    await file.writeAsBytes(bytesB);
    await notifier.restoreBackup(zipBytes: parsed.zipBytes);

    expect(repo.restoredZipBytes, bytesA);
    expect(repo.restoredZipBytes, isNot(bytesB));
  });

  test('确认前文件被删，恢复仍用解析过的字节、照常成功', () async {
    final (bytesA, _) = await exportTwoBackups();
    final dir = await Directory.systemTemp.createTemp('qm2-p1-');
    addTearDown(() async => dir.delete(recursive: true));
    final file = File('${dir.path}/backup.qm2backup');
    await file.writeAsBytes(bytesA);

    final repo = FakeP1Repo();
    final notifier = makeP1Notifier(repo);
    final parsed = await notifier.parseRestoreFile(file.path);
    await file.delete();

    await expectLater(
      notifier.restoreBackup(zipBytes: parsed.zipBytes),
      completes,
    );
    expect(repo.restoredZipBytes, bytesA);
  });

  test('解析出的题目数与备份一致（确认弹窗的题数来自同一份字节）', () async {
    final (bytesA, _) = await exportTwoBackups();
    final dir = await Directory.systemTemp.createTemp('qm2-p1-');
    addTearDown(() async => dir.delete(recursive: true));
    final file = File('${dir.path}/backup.qm2backup');
    await file.writeAsBytes(bytesA);

    final repo = FakeP1Repo();
    final notifier = makeP1Notifier(repo);
    final parsed = await notifier.parseRestoreFile(file.path);
    final questions = parsed.data['questions'] as List;
    expect(questions, hasLength(1));
    expect((questions.single as Map)['title'], 'A题');
  });
}
