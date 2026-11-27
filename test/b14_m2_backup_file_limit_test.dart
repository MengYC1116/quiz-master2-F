// B 包 P1-04：备份文件在 readAsBytes 之前先做 200MB 上限检查。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/state/settings_notifier.dart';

void main() {
  late QuizDatabase db;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('qm2-backup-limit');
    AppDatabase.testDataDirectory = tmp.path;
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
  });

  tearDown(() async {
    await AppDatabase.resetForTest();
    await tmp.delete(recursive: true);
  });

  test('超过 200MB 的备份文件：parseRestoreFile 直接拒绝，不整文件读入', () async {
    final file = File(p.join(tmp.path, 'too-big.qm2backup'));
    final raf = await file.open(mode: FileMode.write);
    await raf.truncate(maxBackupFileBytes + 1);
    await raf.close();
    expect(await file.length(), maxBackupFileBytes + 1);

    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    final notifier = container.read(settingsProvider.notifier);
    await expectLater(
      notifier.parseRestoreFile(file.path),
      throwsA(
        isA<BackupRestoreException>().having(
          (e) => e.message,
          'message',
          contains('200MB'),
        ),
      ),
    );
  });
}
