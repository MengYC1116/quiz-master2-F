# P1-3 实测报告：LaTeX 是否以明文出现在备份与本地数据库文件里

- 批次：十三批，P1-3（GPT 关口审 §6.3 sentinel 方法）
- 时间：2026-11-18
- 测试文件：`quiz-master2-UI/test/b13_backup_sentinel_test.dart`（新增，3 项）
- 测试结果：**3/3 通过**；`flutter analyze` 该文件 **No issues found**
- 演示库：跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.b13-p13-start`；跑后 `~/.local/share/quiz-master2/quiz-master2.db` md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，不变
- 未推送代码，未给 Meng 发邮件/消息，未改任何产品代码与备份格式

## 1. 备份格式说明（读代码确认）

实现在 `lib/data/db_backup.dart`，两个导出入口均为产品真实代码路径：

| 导出形式 | 入口 | 内容 |
|---|---|---|
| JSON 备份 | `exportBackupJsonFromImpl`（`AppDatabase.exportBackupJsonFrom`） | 一个 JSON 对象：顶层 `_meta`（`{schemaVersion, appVersion, exportedAt}`，当前 sv=4）+ 15 张表平铺，每表是 `SELECT * FROM <表>` 的全部行，`jsonEncode` 一次编码。`questions` 行原样包含 `ocr_raw`、`ocr_stem`、`ocr_split_status`、`ocr_manual_edited`、`content_version` 五列，无任何过滤、脱敏或加密 |
| zip 备份 | `exportBackupZipFromImpl`（`AppDatabase.exportBackupZipFrom`） | zip 内只有两类条目：`backup.json`（与上面同一份 JSON）+ 库里引用到的 `imports/` / `slices/` 下的文件（`questions` 的 `source_path` / `page_image_path` / `slice_path`、`collect_tasks` 的 `source_path`、`ocr_jobs` 的 `crop_path`，去重后）。**zip 里不含 SQLite `.db` 文件本身**；条目用 deflate 压缩（`lib/services/zip_archive.dart` 的 `buildZip`），无 zip 加密 |

本地库：`questions.ocr_raw` / `ocr_stem` 是 v4 表里的普通 `TEXT` 列（`lib/data/db_schema.dart`），经 `upsertQuestionInto` 全列写回；无字段级加密。`flutter_secure_storage` 只存 API Key，不碰这两列。

## 2. 实验步骤（复现方法）

唯一标记：`\frac{SENTINEL_A}{SENTINEL_B}`。测试里断言与打印只写“命中/未命中 + 文件名”，不打印公式原文。

1. 临时库：`AppDatabase.openAt()` 在 `$HOME/workspace/flutter-test-tmp/b13-sentinel-<毫秒戳>/quiz-master2.db` 新建文件库（全新 v4；`openAt` 会播种演示学科与演示题——见 §5 备注）。不用 `/tmp`，不碰演示库。
2. 写一道题 `q-sentinel`（学科 `math`）：`ocr_stem` 为含标记的题干文本；`ocr_raw` 为 `GlmOcrRawData` 形状的 JSON 包，`md_results` 里含同一标记，`layout_details: []`、`has_unseen_candidate: false`、`job_id: ocr-sentinel`。写后读回确认两列均含标记（布尔值比对）。
3. 走产品真实导出：`AppDatabase.exportBackupJsonFrom(db)` 得 JSON 文本；`AppDatabase.exportBackupZipFrom(db, dataDir: <临时目录>)` 得 zip 字节（本题无 `slice_path`，故 zip 应只含 `backup.json`）。
4. 搜索 JSON 文本（字符串搜索 `SENTINEL_A` 与 `\frac`），并解析 JSON 后按 `questions` 行的 `ocr_raw` / `ocr_stem` 列分别确认。
5. 用产品自己的 `readZip` 解压 zip，列出全部条目名，逐条目解压后搜索 `SENTINEL_A` 与 `\frac`。
6. 关库后（WAL 落盘），对 `.db` 文件做字节搜索（strings 式，搜 `SENTINEL_A` 与 `\frac` 的 UTF-8 字节序列）；同目录的 `-wal` / `-shm` 若存在也一并搜索。

测试环境：`TMPDIR=$HOME/workspace/flutter-test-tmp`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，`flutter test --concurrency=1`。

## 3. 逐文件搜索结果

| 文件 / 位置 | `SENTINEL_A` | `\frac` | 备注 |
|---|---|---|---|
| JSON 备份全文（`exportBackupJsonFrom` 输出） | 命中 | 命中 | 文件内反斜杠为 JSON 转义形态（即 `\\frac`，解码后还原为 `\frac`）；`SENTINEL_A` 原样出现 |
| JSON 内 `questions` 行 `ocr_raw` 列 | 命中 | —（未单列测，见下） | 该列值是含标记的 `md_results` 的 JSON 包原文 |
| JSON 内 `questions` 行 `ocr_stem` 列 | 命中 | —（同上） | 该列值是含标记的题干文本 |
| zip 条目清单 | — | — | 仅 1 个条目：`backup.json`；无 `.db` 文件条目，无其他文件条目 |
| zip 内 `backup.json`（`readZip` 解压后） | 命中 | 命中 | 与 JSON 备份同一份内容 |
| zip 原始字节 | 未测 | 未测 | 只测了解压后的条目内容；zip 条目是 deflate 压缩，命中结果均来自解压后 |

## 4. 本地 SQLite 文件直接检查结果

| 文件 | `SENTINEL_A` | `\frac` | 备注 |
|---|---|---|---|
| 临时测试库 `quiz-master2.db`（关库后字节搜索） | 命中 | 命中 | 以单反斜杠原样存放在文件字节里（SQLite `TEXT` 列明文存储） |
| `quiz-master2.db-wal` | 不存在 | 不存在 | 关库后已无 `-wal` 文件 |
| `quiz-master2.db-shm` | 不存在 | 不存在 | 关库后已无 `-shm` 文件 |

## 5. 备注

- `openAt` 新建文件库时会播种演示数据（含 `math` 学科），首轮运行因重复插入 `math` 学科报 `UNIQUE constraint failed: subjects.id`，3 项失败；改为 `InsertMode.insertOrReplace` 后通过。首轮失败残留的 3 个临时目录已手动删除；通过的两轮运行的临时目录均由测试收尾删除，`flutter-test-tmp` 下无 `b13-sentinel-*` 残留。
- 标记在 `ocr_raw` 与 `ocr_stem` 两列里各放了一份；本次实测不区分“标记来自哪一列”，只确认备份与库文件里能否直接搜到它。
- 本报告只陈述测到的事实，不作产品方案建议。备份里要不要留 LaTeX、是否加密，等 Meng 定。

## 6. D-114 条目草稿（只写事实）

> D-114（十三批 P1-3 sentinel 实测，2026-11-18）：按 GPT 关口审 §6.3 方法实测，标记 `\frac{SENTINEL_A}{SENTINEL_B}` 各一份放入临时测试题的 `ocr_stem` 与 `ocr_raw`（`md_results`）后，走产品真实导出代码路径：JSON 备份全文命中 `SENTINEL_A` 与 `\frac`（文件内为 JSON 转义的 `\\frac` 形态），`questions` 行的 `ocr_raw`、`ocr_stem` 列均命中；zip 备份仅含 `backup.json` 一个条目（不含 `.db` 文件），解压后 `backup.json` 命中 `SENTINEL_A` 与 `\frac`；本地 `.db` 文件关库后字节搜索命中 `SENTINEL_A` 与 `\frac`（单反斜杠原样），`-wal` / `-shm` 关库后不存在。备份格式：JSON 导出为 `_meta` + 15 张表 `SELECT *` 后 `jsonEncode`，`ocr_raw` / `ocr_stem` 无过滤；zip 为 `backup.json` + 引用的 `imports/` / `slices/` 文件，deflate 压缩、无加密。实测文件 `test/b13_backup_sentinel_test.dart`，3/3 通过，`flutter analyze` 0 问题；演示库 md5 跑后仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`。
