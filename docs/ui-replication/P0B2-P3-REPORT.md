# P3 收尾实施报告

- 分支：`ui-replication`（未 commit、未 push）
- 方案：`docs/ui-replication/DB-CHANGE-PLAN.md` v2.1（§2.3、§4.5、§4.6、§7 的 P3 行）
- 范围：只做 P3 四项；不做 PDF 渲染（最后单独一轨）；不改产品 UI 流程（除孤儿清理入口与空间显示这两处方案已定的设置项）；不动依赖（zip 是手写纯 Dart，未引 `archive` 包）
- 日期：2026-11-14

## 验证总览

| 项 | 结果 |
|---|---|
| `flutter analyze` | 0 问题 |
| 全量 `flutter test` | **523 通过、0 失败**（基线 493，新增 30；YOLO 冒烟需设 `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`） |
| Linux Release 构建 | 成功；`bundle/quiz_master2`；模型已打包进 `data/flutter_assets/assets/models/question/yolo11s-question-v1.onnx` |
| 实例级集成测试（临时文件，跑完已删） | 通过（见 §5） |
| Xvfb 真机端到端（真实文件） | 孤儿清理预览与执行通过；空间占用显示通过；zip 备份/恢复与搬库走实例级集成测试（GUI 文件选择器需 zenity/kdialog，本机没有，见 §5 说明） |
| 演示库 | 已恢复原状（见 §5 末尾：按任务指定的 v1 演示库恢复，并说明了与开工时所见状态的差异） |

---

## 1. §2.3 zip 文件级备份

### 改了什么

- 新增 `lib/services/zip_archive.dart`（纯 Dart，不引新依赖）：写 deflate（`ZLibCodec(raw: true)`）+ 手写 CRC32；读 stored/deflate；`validateZipEntryName` 拒绝绝对路径、盘符、`..` 段（含 `..\`）；`isZipBytes`（`PK\x03\x04` 魔数）识别 zip 还是老 JSON；解压总大小上限 4GB（防 zip 炸弹；合法备份上限 2GB，不会触及）；任一条目非法或结构损坏 → 抛 `ZipFormatException`，调用方拒绝整个包（不许跳过坏条目继续解）。
- `lib/data/database.dart`：
  - `exportBackupZipFrom` / `exportBackupZip`：`backup.json`（即现有 JSON 导出，含 `_meta`）+ 库里引用到的文件（questions 的 source_path / page_image_path / slice_path + collect_tasks 的 source_path，限 `imports/` / `slices/` 下）；无引用的孤儿文件不进备份；路径在库里、文件不在盘上的不进包（恢复后该题走“图片缺失”，不静默造假文件）。
  - `readBackupJsonFromZip`：只读 `backup.json`，供设置页“选完文件先确认”时预览题数与版本校验；不是 zip / 缺 backup.json / JSON 非法 / 版本校验不过 → 抛 `BackupRestoreException`（带具体原因），原库不动。
  - `importBackupZipInto` / `importBackupZip` / `importBackupZipFile`：① 解包并校验每个条目路径（zip slip：任一条目非法 → 拒绝整个包；含 `imports/` / `slices/` 之外的文件条目也拒绝）；② 先解到 staging 目录（数据目录内的 `.restore-staging-<时间戳>`，上次崩溃残留的同类目录顺带清掉），再校验 backup.json；③ 校验通过后文件原子替换进位（被覆盖的原文件先挪到 staging 的 `.overwritten/` 里），再走 `importBackupJsonInto` 整体覆盖数据库；④ 任一步失败 → 删 staging、不动原库（数据库失败时已移入的文件也从 `.overwritten/` 移回）。
- `lib/modules/settings/settings_page.dart`：`_backup` 改调 `exportBackupZip`，扩展名仍是 `.qm2backup`，内容改为 zip，提示文案改为“备份已保存（含题目图片，此备份仅新版可恢复）”；`_pickRestoreFile` 改按魔数识别（不靠扩展名）：zip 走 `readBackupJsonFromZip` 预览，确认时按路径重读恢复（zip 可能很大，不常驻内存）；老 JSON 内容走原来的 JSON 校验与恢复。口径按 §2.3 写清：
  - 新 zip（`.qm2backup`，内容 zip）：正常恢复，JSON + 文件一起回来；
  - 老 JSON 备份（`.qm2backup` 但内容是 JSON，P1/P2 时代导出的）：仍能恢复，走 `importBackupJsonInto`（只恢复数据，图按“图片缺失”处理——老 JSON 本来就不含文件）；
  - v1 备份（无 `_meta` 的 JSON）：拒绝恢复（既有口径不变）；
  - `schemaVersion > 2`：拒绝恢复，提示“备份来自更新的版本”；
  - 不是 zip 也不是合法 JSON / 缺 `backup.json` / 含穿越路径：拒绝恢复，原库不动，并报具体原因，不静默读坏。
- `lib/data/repository.dart`：加 `exportBackupZip` / `importBackupZip` / `importBackupZipFile` 包装。

### 测试

`test/p3_backup_migration_test.dart`（§2.3 组 7 项）+ `test/s8b4_backup_migration_test.dart`（既有 JSON 组仍通过）：

- zip 导出含 `backup.json` + 被引用的图，不含孤儿文件；
- zip 备份 → 删图删库 → 恢复 → 图回来（字节一致）；
- zip 路径穿越（`../evil-p3.txt` 条目）：拒绝整个包，原库不动、盘外不写文件；
- zip 缺 `backup.json`：拒绝，原库不动；
- zip 里 `backup.json` 版本 99：拒绝，原库不动；
- zip 恢复失败回滚（`backup.json` 里有行缺 `title`，校验放行、入库时 NOT NULL 失败）：已移入的文件恢复旧内容，库行数不变；
- 老 JSON 备份仍能走通（导出 JSON → 清库 → `importBackupJsonInto` 恢复，图还在）。

---

## 2. §4.5 文件级联 + 孤儿清理入口

### 改了什么

- 文件级联（`lib/data/database.dart`，只删无引用文件；宁留孤儿，不误删；文件删失败静默跳过、不回滚数据库，由孤儿清理兜底）：
  - `deleteQuestionFrom`：事务提交后删该题独占的切片（`slices/<qid>.png`）；页图不删（同页多题共享）。
  - `deleteSubjectFrom`：删前快照该科题的切片与任务 id，事务提交后删切片 + 无引用的任务目录（`imports/<taskId>/`）。
  - `deleteFolderFrom`：删前快照全部题的切片，事务提交后只删库里已不存在的题的切片（只移走关联的题不动文件）。
  - `deleteCollectTaskFrom`：事务提交后，若没有任何题的 source_path / page_image_path 还指向 `imports/<taskId>/`，删整个任务目录；已确认拆题的任务页图还被题引用，目录保留。
  - `clearDemoDataFrom`：同上，删演示题的无引用切片。
  - 引用检查 `_isFileReferenced`（questions 三列 + collect_tasks.source_path）与 `_deleteTaskDirIfUnreferenced`（`LIKE 'imports/<taskId>/%'` 查两列）是级联的统一口径。
- 孤儿清理入口（`lib/data/database.dart` + 设置页）：
  - `OrphanFile` / `OrphanScan`（相对路径 + 字节数 + 总数/总字节）；`scanOrphanFilesFrom`（扫 `imports/` + `slices/`，列出无任何 questions / collect_tasks 行引用的文件）；`deleteOrphanFiles`（只接受 `imports/` / `slices/` 下的相对路径且解析后必须在数据目录内，其它路径静默跳过；删完把空的父目录清到 `imports/<taskId>` 这一层；返回实际删掉的文件数与释放字节数）；实例版 `scanOrphans` / `cleanOrphans`；`lib/data/repository.dart` 加 `scanOrphanFiles` / `deleteOrphanFiles` 包装。
  - 设置页数据组新增“孤儿清理”行：打开数据组时扫描一次（§6 第 9 条“定期提醒开”就落在这里——每次打开数据组，有孤儿就提示一次）；预览“发现 N 个无用文件，共约 X MB：删题、删学科后留下的旧图片。清理只删这些没人用的文件，题目图片不会动。”；点“清理无用文件”弹内联确认框（“将删掉 N 个没人用的文件（共约 X MB），题目和数据不动，删了找不回来。确定清理吗？”），确认后执行并提示“已清理 N 个无用文件，释放 X MB”，随后重新扫描。
- 空间上限（§6 第 2、9 条）：导入时的 2GB 检查沿用 P2 已有的 `ImportService.enqueue` 检查；本次补齐设置侧的显示与提示（见 §4）。

### 测试

`test/p3_backup_migration_test.dart`（§4.5 组 7 项）+ `test/settings_page_test.dart`（新增 3 项 widget 测试）：

- 删题：切片删掉，共享页图保留，任务行保留；
- 删学科：该科切片与任务目录删掉，别科的文件不动；
- 删任务：已确认拆题（页图被题引用）保留目录，无引用删目录；
- 删文件夹：单文件夹的题切片删掉，多文件夹的题切片保留；
- 孤儿扫描：只列无引用文件，带字节数；在用文件不在列；
- 孤儿清理：只删无引用文件，在用文件保留，空任务目录顺带清掉；
- 孤儿清理：越界路径与 `imports/` / `slices/` 外路径不删；
- 设置页 widget：有孤儿时预览（“发现 2 个无用文件”“共约 3.0 KB”），确认后清理并提示“已清理 2 个无用文件，释放 3.0 KB”；无孤儿时按钮置灰、不弹确认。
- 顺带：新增的设置行把“清空演示数据”顶出可视区，旧测试直接 tap 打偏——测试侧加 `ensureVisible`（只改测试，不改产品代码）。

---

## 3. §4.6 文件迁移（migrateToDirectory 搬文件目录）

### 改了什么

- `lib/data/database.dart`：
  - 新增静态可单测核心 `migrateDataFiles(sourceDir, targetDir, {overwrite, onProgress, isCancelled})`，不碰标记文件、不碰单例：① 先算总字节（进度用），再把库文件（`quiz-master2.db` + `-wal` / `-shm`）与 `imports/`、`slices/` 下的全部文件复制到目标旁的 staging 目录（`<目标>.staging-<时间戳>`）；复制中途失败/取消 → 删 staging，目标原封不动；② 复制完成并校验（文件数与总字节对得上）后，目标已有文件先备份：库 → `quiz-master2.db.old-<时间戳>`，目录 → `imports.old-<时间戳>` / `slices.old-<时间戳>`；③ 再把 staging 里的内容 `rename` 到目标位置（同盘 rename 是原子操作）；备份与替换在同一个 try 里，任一步失败 → 删掉已移过去的新文件、把 `.old` 移回，返回 failed；④ 成功后删 `.old` 备份与 staging，进度报到 1.0。`onProgress` 按已复制字节回调 0..1；`isCancelled` 返回 true 时停在当前文件之后，删 staging，返回 cancelled（新增 `DbMigrationOutcome.cancelled`）。
  - `migrateToDirectory` 重写：先关当前库 → 调 `migrateDataFiles` 搬库文件 + `imports/` + `slices/` → 最后写 `db_location.txt` 标记（标记是提交点：写标记前失败，旧库与旧标记都原地不动）；复制成功后把 `databaseLocation` 写进新库（写失败也不影响——标记文件才是依据）。`copyDatabaseFileTo` 保留不变（既有测试用它）。
  - 目标冲突三选一：沿用设置页已有的覆盖 / 保留 / 取消对话框（文件目录沿用同一选择——覆盖则目标旧库与旧文件目录先备份 `.old` 再替换；保留则直接用新位置原来的题库，不调迁移；取消则什么都不动）。
  - 相对路径 + 统一 resolver 不变（沿用 P2 的 `resolveDataPath`，禁止 `..` 越出数据目录；备份恢复与迁移共用同一条路径安全规则）。
- `lib/data/repository.dart`：`migrateToDirectory` 透传 `onProgress` / `isCancelled`。
- `lib/modules/settings/settings_page.dart`：`_migrateDb` 传进度回调与取消标志，搬库进行中在数据库位置行下显示“正在迁移…xx%（题库和图片一起搬，搬完前不要退出）”与“取消迁移”按钮；冲突对话框文案补一句“题库和图片一起搬过去”；新增 `DbMigrationOutcome.cancelled` 分支，提示“已取消迁移，仍用原来的题库”。

### 测试

`test/p3_backup_migration_test.dart`（§4.6 组 5 项，`migrateDataFiles` 静态核心，不碰标记——整机迁移见 §5 的实例级测试）：

- 搬库后图还在：库 + `imports/` + `slices/` 都在，字节一致，源不动，无 staging 残留，进度回调走到 1.0；
- 目标库覆盖失败回滚：源里放悬空符号链接（复制时抛错），目标已有哨兵库与哨兵切片 → 返回 failed，目标旧库与旧图字节不变，无 `.old` / staging 残留；
- 取消：第一次进度回调后取消 → 返回 cancelled，目标不建库，源不动，无 staging 残留；
- 目标已有库且不覆盖：返回 targetExists，目标不动；
- 同一位置：返回 sameLocation。

---

## 4. 空间占用显示

### 改了什么

- `lib/services/import_service.dart`：`storageUsageBytes` 改走新增的 `storageUsageBreakdown`（分项：`importsBytes` / `slicesBytes`）；新增 `formatBytes`（`512 B` / `2.0 KB` / `3.0 MB`）；新增 `storageLimitMessage(totalBytes)`（超 2GB 才返回提示文案“题图与原图已超过 2GB 上限（现在 X），先清理孤儿文件或删掉不需要的题目，再导入新题。”，不超返回 null）。
- `lib/data/repository.dart`：加 `storageUsageBreakdown` 包装（设置页走 repository，便于 widget 测试 fake）。
- `lib/modules/settings/settings_page.dart`：数据组新增“空间占用”行（打开数据组时统计）：“题图与原图共占 X（原图 Y、切片 Z），上限 2GB。”；超限时下方另起一行显示超限提示。

### 测试

`test/p3_backup_migration_test.dart`（空间组 3 项）+ `test/settings_page_test.dart`（新增 1 项 widget 测试）：

- 分项统计：`imports/` 与 `slices/` 各算各的（3 字节 / 2 字节，合计 5 字节）；
- 上限提示：超 2GB 才提示，不超（100 字节、恰好 2GB）返回 null；
- `formatBytes`：512 → `512 B`，2048 → `2.0 KB`，3MB → `3.0 MB`；
- 设置页 widget：分项 2048/1024 字节时显示“共占 3.0 KB”“原图 2.0 KB”“切片 1.0 KB”“上限 2GB”。

---

## 5. 验证：实例级集成测试 + Xvfb 真机

### 实例级集成测试（临时文件，跑完已删，不进仓库）

`test/zz_p3_instance_e2e_test.dart`（跑完已删）：在 `XDG_DATA_HOME=/tmp/p3-e2e-xdg` 下跑，标记文件只写临时位置，不动真实标记。

- 实例 `exportBackupZip` → 删图删库 → 实例 `importBackupZip` → 图回来（字节一致）；
- 实例 `migrateToDirectory` → 返回 migrated；标记文件 `/tmp/p3-e2e-xdg/quiz-master2/db_location.txt` 内容为新位置；新位置库与图都在（字节一致）；清掉 `testDataDirectory` 后按标记重开库，读得到题。
- 结果：**1/1 通过**。跑的过程中修了一个临时测试自己的 bug（`_openDb` 已播种 math 学科，测试又 INSERT 了一次导致 UNIQUE 冲突，改 REPLACE 后通过；产品代码未动）。

### Xvfb 真机（Release 包，真实文件）

环境：自启 Xvfb `:99`（1280×800，`-ac`）；Release bundle 启动；窗口 1280×720；日志只有环境噪声（Atk-CRITICAL、GSettings assertion、libEGL DRI3 警告、Impeller 后端行），无应用错误。种子：真实试卷页（`~/workspace/yolo-test-images/16676QPFVu1ck984AfWQHruoHWRfTz99b.png`，290721 字节）作 `imports/task-e2e-p3/original.jpg` 与 `slices/q-e2e-p3.png`，另放 2 个孤儿文件（`imports/task-orphan/original.jpg`、`slices/orphan-e2e.png`）。

- 首页正常渲染，种子学科在列；点左下“设置”进设置页（`settings.lastRoute` 变 `/settings`），五组默认全折叠；
- 展开“数据”组：备份行文案含“（.qm2backup，含题目图片）”；空间占用显示“题图与原图共占 1.1 MB（原图 567.8 KB、切片 567.8 KB），上限 2GB。”（2 张 290721 字节原图 + 2 张同大小切片，数对得上）；孤儿清理显示“发现 2 个无用文件，共约 567.8 KB”；
- 点“清理无用文件”：确认框出现在可视区下方（滚下去才看到——这是 720px 窗口下内容变长的正常表现，不是 bug），文案“将删掉 2 个没人用的文件（共约 567.8 KB），题目和数据不动，删了找不回来。确定清理吗？”；点“确认清理”后 SnackBar“已清理 2 个无用文件，释放 567.8 KB”；文件系统核对：`slices/orphan-e2e.png` 与 `imports/task-orphan/` 已删，`slices/q-e2e-p3.png` 与 `imports/task-e2e-p3/original.jpg` 还在；孤儿行变“没有无用文件（所有图片都有题目在用）。”，按钮置灰；空间占用刷新为“共占 567.8 KB（原图 283.9 KB、切片 283.9 KB）”。
- zip 备份 → 删图 → 恢复、改库位置搬家这两项没走 GUI 点按：本机无 zenity/kdialog，`file_picker` 的保存/选择对话框打不开（旧版同样打不开，与本次无关）——按任务要求，用单测 + 真实文件测试验证（§1 的 7 项单测 + §5 的实例级集成测试，覆盖备份恢复后图还在、路径穿越拒绝、搬库后图还在、目标库覆盖失败回滚、标记更新与重开读题）。

### 演示库恢复

- 开工时所见的本机库已不是任务描述的 v1 演示库：`~/.local/share/quiz-master2/quiz-master2.db` 是 v2 空库（user_version=2、0 道题、3 学科、themeMode=system、pageSize=10），应是此前某次运行已触发 P1 的删老库逻辑。开工前已把它备份到 `/tmp/qm2-p3-demo-backup/`（保留，如需该状态可拷回）。
- 验证后按任务指定的原状恢复：从 `/tmp/qm2-p2-demo-backup/quiz-master2.db` 拷回，并删掉 e2e 种子文件（`imports/`、`slices/`）与可能残留的标记。核对：user_version=1、**9 道题、3 学科、深色（themeMode=dark）、pageSize=10**。应用与 Xvfb 已停（`pkill -x quiz_master2` / `pkill -x Xvfb`）。

---

## 6. 已知边界（未修，写下来）

1. **标记写失败的回滚不完整**：`migrateToDirectory` 里，文件搬完、标记（`db_location.txt`）写失败时返回 failed，应用仍用旧位置（无数据丢失），但新位置会留下一份重复的库与文件副本（`.old` 备份已在搬库成功时删掉，无法再移回）。复制阶段的失败回滚是完整的（§3 的单测覆盖）；标记写失败本身极罕见（与 `setCustomDataDirectory` 同一个写操作），未再为它加一层备份保留。
2. **目标只有孤儿文件、没有库时，不覆盖迁移会失败**：`overwrite=false` 且目标已有 `imports/` 或 `slices/`（但无 `quiz-master2.db`）时，staging 的 `rename` 会因目标目录已存在而失败，返回 failed，目标原封不动、无数据丢失；用户清掉目标目录或选覆盖即可。未做“跳过已存在文件”的合并式迁移（方案只定了覆盖/保留/取消三选一，未定合并口径）。
3. **zip 恢复不删备份里没有的旧文件**：恢复是“数据库整体覆盖 + 备份里的文件进位”；当前数据目录里有、备份里没有的孤儿文件会留下来（由孤儿清理入口扫，不自动删——误删风险更大）。
4. **迁移/恢复的 staging 清理**：崩溃残留的 `.restore-staging-*` 在下次恢复时顺带清掉；`<目标>.staging-*` 残留只在本次迁移失败时清掉，崩溃残留需下次迁移时……目前未在下次迁移时顺带清（只在本次失败时清）。残留目录在目标旁，不影响使用，量极小。

---

## 7. 改动清单

| 文件 | 改动 |
|---|---|
| `lib/services/zip_archive.dart`（新增） | 纯 Dart ZIP 读写 + CRC32 + 条目名校验 + 魔数识别 |
| `lib/data/database.dart` | zip 备份/恢复；文件级联（删题/删学科/删文件夹/删任务/清演示）；孤儿扫描/清理；`migrateDataFiles` + `migrateToDirectory` 重写；`DbMigrationOutcome.cancelled` |
| `lib/data/repository.dart` | zip / 孤儿 / 空间占用 / 迁移进度透传 |
| `lib/services/import_service.dart` | `storageUsageBreakdown` / `formatBytes` / `storageLimitMessage` |
| `lib/modules/settings/settings_page.dart` | zip 备份/魔数识别恢复；空间占用行；孤儿清理行 + 确认框；迁移进度与取消；冲突文案补“题库和图片一起搬” |
| `test/p3_backup_migration_test.dart`（新增，27 项） | zip×5、备份恢复×7、级联×4、孤儿×3、迁移×5、空间×3 |
| `test/settings_page_test.dart`（+3 项） | 空间占用行、孤儿清理确认流程、无孤儿置灰；另 2 处旧测试加 `ensureVisible` |
