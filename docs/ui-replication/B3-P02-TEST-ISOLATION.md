# B3-P02：测试隔离（p0 / s8b3 / s8b6b7 不碰真实库）

工人：B3 测试隔离（b3-testiso）。工作树 `~/workspace/quiz-master2-UI`，分支
`ui-replication`。未碰 git 历史（无 commit/push/reset/checkout），未动
`assets/models/` 与 `test/fixtures/` 二进制，未改 `lib/` 下任何生产代码，
未改本任务之外的测试文件，未跑全量测试（由协调员统一跑）。

钩子来源：`docs/ui-replication/B3-P01-PATH-SAFETY.md` §4（数据库工人提供），
只用它规定的用法，未另造钩子。未新建共享测试辅助文件——三个文件的隔离
模式只有几行（临时目录 + `testDataDirectory` + `resetForTest()`），
且各文件打开单例的方式不同（见 §1–§3），照仓库既有惯例（b3_p01 等）
内联写更清楚。

## 0. 演示库备份与恢复

- 跑任何测试前：`~/.local/share/quiz-master2/quiz-master2.db` 事先备份到
  `~/workspace/demo-db-backup/quiz-master2.db.b3-testiso`，备份前 md5
  `8f7f9c64405dc6e484ac2bf8e5e1a807`（与任务给定的当前 md5 一致）。
- 全部测试跑完后立即恢复（移开的真实目录移回原位），核对 md5 仍为
  `8f7f9c64405dc6e484ac2bf8e5e1a807`，与备份文件 md5 一致。
- 测试用 `TMPDIR=$HOME/workspace/.tmp-b3-testiso`（`/tmp` 是 512M tmpfs），
  用完已删除（`ls` 确认不存在）。
- 环境：Flutter 3.47.9，
  `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`。

## 1. `test/p0_hardening_test.dart`（§4.1 隔离，意图保留）

改动：

- L1–L5：文件头注释更新——旧注释说 §4.1“只读真实库”，改为单例在临时
  目录建全新 v2 库，不碰真实数据目录。
- L7：新增 `import 'dart:io';`（`Directory` 用）。
- L61–L76（`main()` 内文件级 `setUp` / `addTearDown`）：每个测试前
  `Directory.systemTemp.createTemp('p0-hardening-')` 建 fresh 临时目录，
  `AppDatabase.testDataDirectory = tmpDir.path`；测后 `addTearDown` 里
  `await AppDatabase.resetForTest()`（关单例库、清 `_dbFuture` /
  `dbPathUsed`、复位 `testDataDirectory` / `testMarkerDirectory`），
  再删临时目录。
- L77–L80（§4.1 组内注释）：说明意图保留方式——单例**不**预置
  （不用 `useDatabaseForTest`），否则 `_dbFuture` 缓存已命中、测不到
  打开路径；并发 `AppDatabase.instance.db` 仍真实走 `_openDb`，
  只是在临时目录建库。测试体本身（L81–L90，三次并发 `await` + 串行
  再取，断言同一 `Database` 对象）一字未动。

其余各组（§4.2/§4.3/§4.4/§4.5）未动：它们一直用 `openTestDb()` 内存库
（L13–L20），文件级重定向只是兜底。

## 2. `test/s8b3_startup_test.dart`（内存库，不碰真实 settings）

改动：

- L12：新增 `import 'dart:io';`。
- L21–L36（`main()` 内文件级 `setUp` / `addTearDown`）：与 §1 同款——
  每个测试前建 fresh 临时目录（`s8b3-startup-`）并设
  `AppDatabase.testDataDirectory`，测后 `resetForTest()` + 删临时目录。
- L79–L85（`lastRoute 持久化` 组级 `setUp`）：`openForTest()` 开内存库
  （只建表不播种）+ `useDatabaseForTest(db)` 设为单例；
  `QuestionRepository(AppDatabase.instance)`（L86）走单例读写 settings 表，
  全程在内存库里。旧写法（L63 左右 `QuestionRepository(AppDatabase.instance)`
  直读真实演示库 settings 表、先读原值、finally 恢复）已删除。
- 测试体未动：存取往返 + `saveSettings` 不误删 `lastRoute` 的断言不变；
  `finally` 里恢复 `beforeSettings` / `beforeRoute ?? '/home'` 的逻辑保留，
  在 fresh 内存库上就是写回默认值与 `'/home'`，无副作用。
- `resolveStartupRoute` 纯函数组未动（不碰库）。

## 3. `test/s8b6b7_leftover_test.dart`（内存库，不读真实库）

改动：

- L1、L6：文件头注释更新——“临时副本”改为“内存库”，待定3 说明改为
  “`openForTest()` 内存库”。
- L9：`import 'dart:io';` 保留（`Directory` 仍用）；删除
  `import 'package:path/path.dart' as p';`（旧 setUp 里 `p.join` 的唯一
  用途已随真实库复制删除）。
- L16–L31（`main()` 内文件级 `setUp` / `addTearDown`）：与 §1 同款——
  每个测试前建 fresh 临时目录（`s8b6b7-`）并设 `testDataDirectory`，
  测后 `resetForTest()` + 删临时目录。
- L47–L58（待定3 组级 `setUp`）：删除旧逻辑——读
  `File(p.join(AppDatabase.dataDirectoryPath(), 'quiz-master2.db'))`
  （旧 L47 左右）、断言演示库存在、复制到临时文件、再
  `databaseFactoryFfi.openDatabase(copyPath)`；改为
  `db = await AppDatabase.openForTest()`（内存库，只建表不播种），
  随后照旧 `db.delete('settings', where: 'key = ?', ...)` 清
  `backupFailed` 键；`addTearDown` 里 `await db.close()`。
  旧 `sqfliteFfiInit()` 调用删除（`openForTest()` 内部已调）；
  `sqflite_common_ffi` import 保留（`Database` 类型仍用）。
- 测试体未动：标志置起/清掉往返、键不互相覆盖的断言不变。
- B7 `normalizeRecentKind` 纯函数组未动（不碰库）。

## 4. 统一清理方式

三个文件同一模式（文件级 `setUp` + `addTearDown`，`test()` 非
`testWidgets`，真实文件 IO 只在 `setUp` / `addTearDown` 里，不在
`testWidgets` 体内 plain-await——三个文件均无 `testWidgets`）：

| 步骤 | 做法 |
| --- | --- |
| setUp | `Directory.systemTemp.createTemp('<前缀>-')`，`AppDatabase.testDataDirectory = tmp.path` |
| 单例复位 | 每测后 `addTearDown` 里 `await AppDatabase.resetForTest()`（关单例库、清缓存与重定向） |
| 临时目录 | 复位后 `tmp.delete(recursive: true)`（try/catch 包住） |
| 内存库关闭 | s8b6b7 的 `db` 在组级 `addTearDown` 里 `await db.close()`；s8b3 的内存库已挂为单例，由 `resetForTest()` 关 |

## 5. 验证结果

### 5.1 真实目录原位，各文件单独跑

| 测试文件 | 结果 |
| --- | --- |
| `test/p0_hardening_test.dart` | 12/12 通过 |
| `test/s8b3_startup_test.dart` | 8/8 通过 |
| `test/s8b6b7_leftover_test.dart` | 4/4 通过 |

每次跑完核对演示库 md5 均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，未变。

### 5.2 空数据目录验证（任务规定的验收方法）

- 方法：`mv ~/.local/share/quiz-master2 ~/.local/share/quiz-master2.bak-b3-testiso`
  （`ls` 确认真实目录已不存在），然后一次命令连跑三个文件
  `flutter test test/p0_hardening_test.dart test/s8b3_startup_test.dart test/s8b6b7_leftover_test.dart`。
- 结果：**24/24 通过**（12 + 8 + 4，`All tests passed!`）。
- 跑完检查：`~/.local/share/quiz-master2` 未被重建
  （`ls: cannot access ... No such file or directory`），即三个文件在
  真实数据目录不存在时仍全绿、且未访问/重建真实目录。
- 恢复：立即把备份目录移回原位，md5 核对仍为
  `8f7f9c64405dc6e484ac2bf8e5e1a807`，与备份文件一致。

### 5.3 `flutter analyze`

`flutter analyze test/p0_hardening_test.dart test/s8b3_startup_test.dart test/s8b6b7_leftover_test.dart`：
**No issues found!**（0 问题）。

## 6. 遗留问题

1. **未跑全量测试**，由协调员统一跑。本次只跑了上述三个文件（单独 + 三文件合跑）。
2. **p0 §4.1 的临时库是文件库而非内存库**：为保留“并发只 open 一次”的
   测试意图，单例不能预置内存库（见 §1），只能让 `_openDb` 在临时目录
   建真实文件库（含 `_onCreate` 的演示播种）。隔离靠临时目录 + 复位，
   空目录验证已证明不碰真实目录；但严格说该用例不是内存库。
3. **s8b3 `finally` 恢复块现在写的是默认值**：内存库 fresh，`beforeSettings`
   即 `AppSettings.defaults`、`beforeRoute` 为 null，恢复即写回默认值与
   `'/home'`。逻辑保留未动，无副作用。
4. 空目录验证期间真实数据目录被移开约 1 分钟（三次测试合跑耗时约 9 秒，
   加前后检查）；若同期有其他工人依赖真实演示库，可能受影响——本次
   窗口内未收到相关报错，恢复后 md5 已核对无误。
