# B3-P01：数据库层路径安全 + _openDb fallback 收窄 + 重框单事务

工人：B3 数据库层（b3-db）。工作树 `~/workspace/quiz-master2-UI`，分支
`ui-replication`。未碰 git 历史（无 commit/push/reset/checkout），未动
`assets/models/` 与 `test/fixtures/` 二进制。未跑全量测试（由协调员统一跑）。

## 0. 动手前核对：哪些已做、哪些还缺

先读了任务点名的各处，现状如下：

| 点 | 动手前已做 | 还缺（本次补） |
| --- | --- | --- |
| `_resolveInsideDir` | 已存在（database.dart L2153 前后），`exportBackupZipFrom` / `importBackupZipInto` / `deleteOrphanFiles` / 孤儿扫描已在用 | 删除函数与 `resolveDataPath` 还没走它 |
| `resolveDataPath` | 相对路径有越界检查 | 绝对路径原样放行（后门） |
| `_deleteDataFileIfUnreferenced` | 已查引用、删失败静默跳过 | 接受任意盘内路径（绝对路径、`imports/` 都能删） |
| `_deleteTaskDirIfUnreferenced` | 已查引用 | 无 taskId 校验；`imports/../slices` 规范化后就是 `slices/`，旧写法会递归删掉整个切片目录 |
| 备份恢复 | zip 条目名已校验（`validateZipEntryName` + 仅 `imports/`/`slices/`） | `backup.json` 里的 `source_path` / `page_image_path` / `slice_path` 值从未校验 |
| `_openDb` | `LegacyDatabaseException` 已 rethrow，不进 fallback | 其余打开错误一律吞掉进 fallback |
| `copyDatabaseFileTo` | 生产无调用（仅 s8b4 测试在用） | 直接 `copy` 覆盖，覆盖中途失败留截断库 |
| 测试钩子 | `testDataDirectory` / `testMarkerDirectory` / `useDatabaseForTest` 已存在 | 无“打开测试库”入口、无单例复位入口 |
| 详情页重框 | `replaceQuestionBoxes` 本身已是单事务 | 换框与保存 slicePath 是两步调用 |

## 1. P0-1 路径删除安全（`lib/data/database.dart`）

### 1.1 `resolveDataPath` 禁绝对路径（L148）

```dart
static String? resolveDataPath(String path, {bool allowAbsolute = false})
```

- 绝对路径默认返回 `null`；相对路径改走 `_resolveInsideDir`
  （替代原来的直接 `p.join` 拼接）。
- 例外通道是显式具名参数 `allowAbsolute: true`，只能出现在测试
  代码里；生产调用点一律不传。测试首选仍是 `testDataDirectory` +
  相对路径。
- 全仓调用点已核对：生产代码传的全是相对路径（ImportService 生成
  的 `imports/…` / `slices/…` 或库里存的相对路径），行为不变；
  演示数据里没有任何绝对路径。

### 1.2 `_deleteDataFileIfUnreferenced` 只接受 `slices/` 前缀（L2152）

- 先把 `\` 归一化为 `/`，不以 `slices/` 开头的一律拒绝删除
  （绝对路径、`imports/`、`..` 越界都在内），再经
  `_resolveInsideDir` 解析、再查引用。删失败仍静默跳过（孤儿清理兜底）。
- 调用方只传题的 `slice_path`（5 处调用点已核对，全是 slice_path），
  正常清理不受影响。

### 1.3 `_deleteTaskDirIfUnreferenced` 校验 taskId（L2195）

- 新增 `_safeTaskIdPattern = RegExp(r'^[A-Za-z0-9_-]+$')`（L182），
  校验放在查引用之前；`../slices`、`a/b`、`a%b`、`..`、空串、
  含空格的 id 直接返回，不删目录。不能靠前缀检查蒙混的原因见代码注释：
  `imports/../slices` 规范化后就是 `slices/` 本身。
- 目录解析改走 `_resolveInsideDir(dataDirectoryPath(), 'imports/$taskId')`。

### 1.4 备份恢复校验文件路径（L163、L2941、L2952）

- 新增 `isAllowedDataRelativePath`：只允许 `imports/` 或 `slices/`
  下的相对路径；空串表示“没有文件”放行；拒绝绝对路径、盘符（`:`）、
  `..` / `.` / 空段（含 `..` 即使最终仍落在数据目录内也拒绝，
  备份里的路径必须是干净的规范形式）。
- `validateBackupData` 的行循环里新增 `_validateBackupRowPaths`：
  只校验 `questions` 的 `source_path` / `page_image_path` /
  `slice_path` 与 `collect_tasks` 的 `source_path`；非法值抛
  `BackupRestoreException`（带表名、行 id、列名与原值），拒绝整个
  恢复，不静默跳过。JSON 备份与 zip 备份都走这条校验
  （zip 是 `_decodeBackupJson` → `validateBackupData`，在文件进位
  之前就拒绝，所以非法 zip 的文件一步都不会进位）。
- 其余列不动：`settings.databaseLocation` 是目录配置不是文件路径，
  不在此列；`file_name` 是显示名，不校验。

### 1.5 统一走 `_resolveInsideDir`

- `resolveDataPath` 本身、`_deleteDataFileIfUnreferenced`、
  `_deleteTaskDirIfUnreferenced` 现全部经 `_resolveInsideDir`；
  备份导出/恢复、孤儿扫描/删除此前已在走它（未改）。
- 例外（有意保留）：库文件自身路径（`quiz-master2.db`，固定名，
  database.dart L530/L648）与设置页展示用的数据目录路径
  （`settings_page.dart` L382/L482，固定路径非用户输入），不是
  库内相对路径，不走 resolver。

### 1.6 受影响测试的同步修改（绝对路径夹具改走 testDataDirectory）

`resolveDataPath` 拒绝对路径后，3 个测试文件的夹具必须改（夹具
二进制未动，只改引用方式）：

- `test/detail_page_test.dart`：页图改写到
  `<tmp>/imports/rework-task/page.png`，`pageImagePath` /
  `sourcePath` 用相对路径 `imports/rework-task/page.png`（新增
  `_pagePngRel`）；FakeRepo 增加 `replaceQuestionBoxesAndSlice`
  覆盖（见 §5）。
- `test/collect_page_test.dart`：页图改写到
  `<tmp>/imports/collect-task/page.png`，任务默认 `sourcePath` 用
  相对路径 `imports/collect-task/page.png`（新增 `_pagePngRel`）；
  `_pagePngPath`（绝对路径）只留给 `_seedPdfPageImages` 的
  `File.copy` 用。
- `test/b2_win11bug_organize_test.dart`：夹具拷进
  `testDataDirectory` 的 `slices/q-real.png`，`slicePath` 用相对路径；
  预热用的绝对路径只传给 `precacheImage` 的 `FileImage`。
- `test/b3_p11_layer2_downgrade_test.dart`（同批另一工人的文件）：
  三个用例的文件都放进 `testDataDirectory` 下的 `slices/`，
  `slicePath` 用相对路径；`testDataDirectory` 在 setUp/tearDown
  里置位/复位。

## 2. `_openDb` fallback 收窄（`lib/data/database.dart` L636、L644）

- 新增 `@visibleForTesting static bool shouldFallbackAfterOpenFailure(String dbPath)`：
  只有主位置**不存在库文件**时才允许回退（全新安装 + 数据目录不可写，
  此时没有既有数据可丢）；已有库文件时一律不回退。
- `_openDb` 改成：`dataDir.create` 也纳入 try；`LegacyDatabaseException`
  照旧 rethrow；其余打开错误先查 `shouldFallbackAfterOpenFailure`——
  不允许回退时抛 `StateError('数据库打不开，已拒绝新建空库，…：$dbPath（$e）')`，
  不静默建空库；允许回退时才走原来的安装目录 `data/` fallback，
  fallback 自身打开失败则原样抛错。
- 未验证的边界（见 §7）：真实“只读文件打不开”场景无法在本机确定性
  复现（root 绕过权限位、SQLite 打开是惰性的），只做到规则级单测 +
  损坏文件端到端测试。

## 3. `copyDatabaseFileTo` 删除（`lib/data/database.dart`）

- 方法整体删除。理由：生产无调用（全仓 grep 只有 s8b4 测试在用）；
  整机迁移走 staging 方式的 `migrateDataFiles`；旧实现直接 `copy`
  覆盖，覆盖中途失败会留截断的库文件，staging 化等于把
  `migrateDataFiles` 的备份-替换逻辑再写一遍，不如删掉。
- `databaseExistsAt` 保留（设置页覆盖对话框在用）。
- `test/s8b4_backup_migration_test.dart` 的 `B4.3 copyDatabaseFileTo`
  组删除 4 个复制测试，改成只留 `databaseExistsAt` 的 1 个测试；
  复制语义由 `test/p3_backup_migration_test.dart` 的 §4.6
  `migrateDataFiles` 组覆盖（该组未动，本次验证通过，见 §6）。

## 4. 测试钩子（`lib/data/database.dart`）

已存在的不动，新增两个（均 `@visibleForTesting`，不改动生产打开路径）：

```dart
// 打开一个测试库（不碰单例、不碰真实库）。
// path 为空 → 内存库；path 给文件路径 → 该路径的库文件（父目录须已存在）。
// 两种都只建表（createTables），不播种演示数据。调用方负责 await db.close()。
static Future<Database> openForTest({String? path})

// 复位单例与测试目录重定向（只供测试调用）。
// 关掉单例当前持有的库（若有）、清 _dbFuture 与 dbPathUsed、
// 把 testDataDirectory / testMarkerDirectory 置回 null。
// 同一文件里多个测试都要碰单例时，在 tearDown 里调它。
static Future<void> resetForTest()
```

已存在、可继续用的：

```dart
static String? testDataDirectory;    // 数据目录重定向到临时目录
static String? testMarkerDirectory;  // db_location.txt 标记重定向
static void useDatabaseForTest(Database db);  // 把已打开的库设为单例
static String? resolveDataPath(String path, {bool allowAbsolute = false});
  // allowAbsolute: true 是显式例外通道，只能出现在测试代码里
```

## 5. 详情页「重新框选」单事务

- `lib/data/database.dart` L2582 新增
  `replaceQuestionBoxesAndSliceInto(db, {questionId, boxes, slicePath, sliceWidth, sliceHeight})`：
  一次事务内换框（复用新抽出的 `_replaceBoxesTxn`，L2631）+
  更新题的 `slice_path` / `slice_width` / `slice_height`；
  题行不存在（update 影响 0 行）时抛 `StateError`，整个事务回滚。
  旧的 `replaceQuestionBoxesInto` / `replaceQuestionBoxes` 原样保留
  （改走 `_replaceBoxesTxn`，行为不变）。
- `lib/data/database.dart` L2609 实例版
  `replaceQuestionBoxesAndSlice(…)`（成功后 `bumpBadgeVersion`），
  `lib/data/repository.dart` L359 同名透传。
- `lib/modules/detail/question_detail_page.dart` L368：原来的两步调用
  （`replaceQuestionBoxes` + `repo.save(q.copyWith(…))`）改成一次
  `replaceQuestionBoxesAndSlice` 调用；其余逻辑不动（切片文件仍在
  事务前写盘，写不进去不进事务）。
- 残留（见 §7）：切片文件本身写在事务前，事务失败后新裁的切片字节
  已落盘（路径与旧切片相同，都是 `slices/<qid>.png`），库里仍是旧的
  宽高；下一次成功重框即纠正。

## 6. 验证结果

环境：Flutter 3.47.9，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`。
演示库 `~/.local/share/quiz-master2/quiz-master2.db` 事先备份到
`~/workspace/demo-db-backup/quiz-master2.db.b3-db`，md5
`8f7f9c64405dc6e484ac2bf8e5e1a807`；跑完 `p0_hardening_test`
（§4.1 会打开真实库单例）后立即恢复并核对 md5 一致。

| 测试文件 | 结果 |
| --- | --- |
| `test/b3_p01_path_safety_test.dart`（新增，26 个） | 26/26 通过 |
| `test/s8b4_backup_migration_test.dart` | 通过（B4.3 组已改写） |
| `test/p1_schema_backup_test.dart` | 通过 |
| `test/p3_backup_migration_test.dart` | 通过 |
| `test/detail_page_test.dart` | 通过（含重框单事务链路） |
| `test/b2_win11bug_organize_test.dart` | 4/4 通过 |
| `test/b3_p11_layer2_downgrade_test.dart` | 6/6 通过（单独跑） |
| `test/p0_hardening_test.dart` | 12/12 通过（单独跑） |
| `test/p2_main_chain_test.dart` | 13/13 通过（单独跑） |
| `test/pdf_render_service_test.dart` | 13/13 通过（单独跑） |
| `test/organize_page_test.dart` | 26/26 通过（单独跑；批量跑时 P1-1 对照用例曾偶发失败，单独跑不复现，见 §7） |
| `test/collect_page_test.dart` | 部分通过：正常态 + 修框编辑器 23/23，B2-6b 5/5，B2-6a 2/2，B2-1 2/2，三档缩放 5/5，不用图标字体 1/1，页内无边距 1/1，无框警告 1/1；其余见 §7 |
| `test/pdf_collect_page_test.dart` | 1 个失败，见 §7 |

新增回归测试（`test/b3_p01_path_safety_test.dart`，26 个）：

- `resolveDataPath`：绝对路径默认拒（null）、`allowAbsolute: true`
  显式放行、相对路径拼 `testDataDirectory`、`..` 越界拒。
- `_deleteDataFileIfUnreferenced`（经 `deleteQuestionFrom`）：
  绝对路径切片不删（旧实现会删）、`imports/` 下的“切片”不删、
  `..` 越界不删、合法 `slices/` 无引用照常删、仍被引用的不删。
- `_deleteTaskDirIfUnreferenced`（经 `deleteCollectTaskFrom`）：
  `../slices` 不删 `slices/` 目录（旧实现会整目录删掉）、
  `a/b` / `a%b` / `..` / 空串 / 含空格的 id 同样被拦、合法 taskId
  无引用照常删、仍被题引用的目录不删。
- 备份恢复：`slice_path` 绝对路径拒、`source_path` 含 `..` 拒、
  `page_image_path` 在其它目录拒、`collect_tasks source_path` 为
  Windows 绝对路径拒、合法相对路径恢复成功、zip 备份 JSON 路径非法
  时文件一步都不进位（以上拒绝恢复后均断言原库不动）。
- 重框单事务（`replaceQuestionBoxesAndSliceInto`）：成功时旧框被换、
  切片字段一起更新；写切片中途失败（触发器）时旧框与旧切片整体回滚；
  题不存在时抛 `StateError`、旧框不动。
- `openForTest`：内存库建表可用、无演示数据；文件库关闭重开数据还在。
- `_openDb`：损坏的库文件抛 `LegacyDatabaseException`、`dbPathUsed`
  仍为 null、失败的 Future 不被缓存（再调仍报错）、安装目录
  `data/` 未被创建；`shouldFallbackAfterOpenFailure` 有库文件
  false、无库文件 true。

`flutter analyze`（9 个改动相关文件）：1 个 info 级 warning，
`test/collect_page_test.dart:85`（`_SelectiveYolo` 的 `boxPages`
可选参数从未被显式传值，`unused_element_parameter`）。该参数仍在
被使用（L95 `boxPages.contains(page)`），只是调用方都用默认值；
是同批 P1-2 工人未提交代码里就有的，不是我改动引入的，未动它。
其余 0 问题。

环境说明：本机 `/tmp` 是 512M tmpfs，多工人并发跑 `flutter test`
时一度写满（一次编译报 `No space left on device`）；之后我的测试
改用 `TMPDIR=$HOME/workspace/.tmp-b3-p01`（已删）。多文件批量跑
曾在 07:37 被异常终止（疑似并行负载下 OOM/被杀），此后改成单文件
逐个跑；批量跑时的个别失败在单跑下不复现（见 §7）。

## 7. 遗留问题

1. **`test/collect_page_test.dart` P1-2 组 2 个用例挂起（与本次改动无关）**：
   「确认前报未框页数，确认后只拆有框页、未框页留任务可继续修框」与
   「确认前对话框点取消」在 `_seedPdfPageImages` 里挂起。探针定位：
   `await File(abs).parent.create(...)` / `await File(_pagePngPath).copy(abs)`
   在 `testWidgets` 的 fake-async zone 里永不完成（最小复现：
   同样调用序列的 `testWidgets` 也挂；`test()` 真实异步下同类 IO
   正常——本次新增的 26 个 `test()` 全部通过）。这是 P1-2 工人
   未提交测试代码里的既有缺陷（该文件里已有他们自己的 `_mark`
   文件探针，正在调同一问题），需 P1-2 工人把 seeding 包进
   `runAsync` 或移到 `setUpAll`。本次未动这段代码。
2. **`test/pdf_collect_page_test.dart` 1 个失败（与本次改动无关）**：
   「PDF 多页：修框切页换底图、自动检测、确认拆出两页的题」单独跑
   也失败：`savedQuestions.length` 为 0。原因：只访问了第 1、2 页，
   第 3 页无框 → P1-2 的「还有 N 页没有框」确认框弹出，测试从未点
   「确认拆题」，拆分一直等确认（编辑器已弹回，所以前一行
   `find.text('修框 ·')` 为空是通过的）。该测试写于 P1-2 确认框
   之前、未同步更新。修法：在点「确认修框，拆成 2 个待整理任务」后
   再点一次「确认拆题」（`collect_page_test` 的 P1-2 用例就是这么
   做的，`tapDialogConfirmAndWait`）。属 P1-2 工人范围，本次未改。
3. **`test/collect_page_test.dart`「有手动框时先弹确认，点取消保留原框」失败
   （与本次改动无关）**：`tester.tap(find.text('取消'))` 找到 2 个
   「取消」（确认框的 + 修框编辑器自身的），tap 要求唯一目标。
   是选择器歧义，需把 tap 限定到确认框内（如 `.last` 或按 dialog
   限定）。属收集页 UI 测试范围，本次未改。
4. **`test/organize_page_test.dart` P1-1 对照用例批量跑时偶发失败**：
   批量跑时曾报 `find.text('stem 题干')` 找到 2 个（应为 1 个）；
   单独跑 26/26 通过，不复现。该用例的题没有任何 `slicePath`，
   不走本次改动的任何代码路径；疑似多文件并行跑时的干扰。留给
   协调员全量跑时再看。
5. **`_openDb` 权限错误分支未做真实复现**：规则级单测 +
   损坏文件端到端测试已覆盖；真实只读文件打不开的场景本机无法
   确定性复现（root 绕过权限位、SQLite 打开是惰性的），见 §2。
6. **重框单事务的残留**：切片文件写盘仍在事务前（§5 末）。
7. **analyze 遗留 1 个 info warning**：`collect_page_test.dart:85`
   `boxPages` 参数（§6 末），同批 P1-2 工人代码里既有的，未动。
8. **未跑全量测试**，由协调员统一跑；批量并行跑在本机不可靠
   （见 §6 环境说明），建议全量跑时留意 §7 第 1–4 项是否复现。
