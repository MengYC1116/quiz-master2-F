# B2 遗留：s8b4_backup_migration_test.dart 密封性（hermeticity）核查

日期：2026-11-14
范围：仅 `test/s8b4_backup_migration_test.dart`（另加本报告）。未动产品代码与其他测试文件，未推送，未跑全量测试套件。

## 结论

**本文件已是密封的，没有发现非密封的测试，无需改代码。**
先前复审所指的“复制真实用户库”写法在当前文件里不存在——文件头的注释已说明它在 P1
改写时就已处理（“备份往返用 createTables 建的合成库（P1：不再读真实用户库）”），
逐组核查证实了这一点。

## 逐组核查

| 组 | DB / 文件来源 | 是否密封 |
|---|---|---|
| B4.2 `backupTables`（1 个 test） | 只读 `AppDatabase.backupTables` 常量，无 I/O | ✅ |
| B4.2 备份导出 + 恢复往返（4 个 test） | 内存库：`databaseFactoryFfi.openDatabase(inMemoryDatabasePath, onCreate: AppDatabase.createTables)`，合成种子数据（1 学科、2 道题、4 张表各一行标记行）；`tmp = Directory.systemTemp.createTemp('s8b4-backup-')`，tearDown 删库删目录 | ✅ |
| B4.3 `copyDatabaseFileTo`（5 个 test） | 全部文件在 `Directory.systemTemp.createTemp('s8b4-migrate-')` 下的 `src/` / `dst/` 子目录内，源文件是手写字符串的替身文件；tearDown 递归删除 | ✅ |

调用的产品方法也只走显式传入的参数，不碰单例/真实路径：`exportBackupJsonFrom(db)`、
`importBackupJsonInto(db, …)`、`copyDatabaseFileTo(src.path, targetDir)`、
`databaseExistsAt(dir)`（已读 `lib/data/database.dart` 对应实现核对，仅作只读核查、未修改）。

## grep 确认

- `local/share`、`getApplicationSupport`、`applicationSupportDirectory`、`Platform.environment`、`HOME`、`/home/`、`path_provider`：**0 命中**。
- 文件中 `quiz-master2.db` 只出现 6 次，均为拼在临时目录路径后的文件名（`p.join(tmp.path, …)` / `p.join(targetDir, …)`），无一指向真实数据目录。
- `Directory.systemTemp.createTemp`：2 处；`inMemoryDatabasePath`：1 处。

## 验证

- `flutter analyze`（全项目）：**No issues found!**
- `flutter test test/s8b4_backup_migration_test.dart`：**10/10 通过**（B4.2 × 5，B4.3 × 5）。
- 真实用户库 `~/.local/share/quiz-master2/quiz-master2.db` 在本机存在（94,208 字节），
  测试运行前后 mtime 均为 2026-11-13 20:42，未被触碰——旁证密封性。

## 附注

- 本文件在 git 中目前是未追踪文件（`?? test/s8b4_backup_migration_test.dart`，不在任何已提交历史里），
  故无旧版本可 diff；上述结论针对工作区当前内容。
- 未改动测试文件本身：改动一个已密封且全绿的文件只会引入风险；若协调方仍希望看到一次
  “改动”，可考虑删掉 B4.2 组里建了却未使用的 `tmp` 目录（仅清理死代码，与密封性无关），
  需另行确认。
