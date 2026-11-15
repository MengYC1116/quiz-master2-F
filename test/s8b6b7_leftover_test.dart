// S8 B6–B7 / 待定1 / 待定3 补测（不碰真实库，全部用内存库或纯函数）。
//
// - B7：`normalizeRecentKind` 纯函数（旧英文值读出时映射成中文，
//   不丢数据）；写入点中文由 organize/collect 的 widget 测试断言。
// - 待定3：备份失败标志 `backupFailed` 在 settings 表 key/value
//   里往返（可单测的静态方法 + openForTest() 内存库，与 B4.2 同做法）。
// - B6 与待定1 的 widget 测试见 test/review_page_test.dart；
//   待定3 首页横幅点“知道了”调回调见 test/home_page_test.dart。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // 全文件：每个测试前把 testDataDirectory 指到 fresh 临时目录，
  // 任何落盘路径都不碰真实数据目录；测后 resetForTest() 复位单例
  // 与重定向并删临时目录。
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('s8b6b7-');
    AppDatabase.testDataDirectory = tmp.path;
    addTearDown(() async {
      await AppDatabase.resetForTest();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
  });

  group('B7 normalizeRecentKind', () {
    test('旧英文值映射成中文', () {
      expect(AppDatabase.normalizeRecentKind('collect'), '收集');
      expect(AppDatabase.normalizeRecentKind('organize'), '整理');
    });

    test('中文值与未知值原样返回', () {
      expect(AppDatabase.normalizeRecentKind('收集'), '收集');
      expect(AppDatabase.normalizeRecentKind('整理'), '整理');
      expect(AppDatabase.normalizeRecentKind('review'), 'review');
      expect(AppDatabase.normalizeRecentKind(''), '');
    });
  });

  group('待定3 备份失败标志（内存库）', () {
    late Database db;

    setUp(() async {
      // 内存库只建表不播种，不读真实库；复位与临时目录清理见文件级 setUp。
      db = await AppDatabase.openForTest();
      await db.delete('settings',
          where: 'key = ?', whereArgs: [AppDatabase.backupFailedKey]);
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });
    });

    test('默认无标志；置起 → 读到 true；清掉 → 读到 false', () async {
      expect(await AppDatabase.loadBackupFailedFrom(db), isFalse);
      await AppDatabase.saveBackupFailedInto(db, true);
      expect(await AppDatabase.loadBackupFailedFrom(db), isTrue);
      await AppDatabase.saveBackupFailedInto(db, false);
      expect(await AppDatabase.loadBackupFailedFrom(db), isFalse);
    });

    test('标志键与 lastRoute / 提醒键不同，不会互相覆盖', () {
      expect(AppDatabase.backupFailedKey, isNot(AppDatabase.lastRouteKey));
      expect(AppDatabase.backupFailedKey,
          isNot(AppDatabase.lastRecheckReminderKey));
    });
  });
}
