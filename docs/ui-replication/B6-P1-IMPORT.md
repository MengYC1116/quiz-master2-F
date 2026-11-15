# Batch 6 P1-IMPORT 执行报告（执行员 A-import）

- 范围：SELF-REVIEW-2 的 SR2-1、SR2-2、SR2-12、SR2-60、SR2-71、SR2-72
- 分支：`ui-replication`，工作树 `~/workspace/quiz-master2-UI`
- 只改 3 个文件：`lib/services/import_service.dart`、
  `test/import_service_p1_fixes_test.dart`、
  `test/b5_p2_services_test.dart`（仅 SR-P2-60 组）
- 未提交、未推送。

## 验证

- `flutter analyze lib/services/import_service.dart test/import_service_p1_fixes_test.dart test/b5_p2_services_test.dart`：**0 问题**。
- `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux flutter test --concurrency=1 test/import_service_p1_fixes_test.dart`：**16/16 通过**（约 14 秒）。
- 同命令跑 `test/b5_p2_services_test.dart`：**15/15 通过**（约 5 秒）。
- 未跑全量测试（总协调在阶段关口统一跑）。测试串行跑，无挂起、无需杀进程。

## SR2-1 — 图片分支尾部 upsert 仍在 try 之外（含亚型 a/b）

`lib/services/import_service.dart`

- 图片尾部 upsert 包进 try/catch 走 `_failAndClean`（:437-447）：失败文案
  `导入失败：这张图片导进来了，但写不进任务列表（$e）`，与 PDF 分支
  （:566-573）同款；`_failAndClean` 自身再失败时只返回内存 failed 任务。
- 亚型 (a) 超限 / 超空间失败分支（:249-289）：读长度 / 估算与“失败写库”
  彻底分开——先用 `oversize` / `storageFull` 布尔值在 try 内只做判定，
  判定为真后再在 try 外写 failed 行，该 upsert 各自包 try，失败只返回
  内存 failed 任务。旧形状是 upsert 藏在 `try {} catch (_) {}` 里，抛错
  被吞后继续复制、最终复活成 needBox。
- 复制失败分支的 upsert 也包 try（:325-330）。
- 亚型 (b) EXIF 分支重构（:361-421）：读字节、解码判定、归一化三段分开。
  `decodeError != null`（`canDecodeImageBytes` 为假 / 镜像方向 2/4/5/7）
  是“已判定解不开图片”——目录已删，失败行的 upsert 各自包 try，写库
  失败也只返回内存 failed 任务，`continue` 直接出循环，绝不落入降级
  catch 复活成 needBox。读不到原图（`bytes == null`）或归一化 / 写盘
  失败是“读盘 / 写盘失败”（原图还在）——保留旧降级，按原图进 needBox。
  降级路径里的 `onProgress(90)` / `_updateProgress(90)` 也包了 try，
  避免写库失败从降级路径逃出。
- 每文件循环外包一层兜底 try（:231-238 开、:452-478 收）：单个文件任何
  一步抛错（含初始 importing 行写库失败）都转成该任务的 failed 行
  （`cleanupDir != null` 时走 `_failAndClean` 删目录，否则尽力写 failed
  行），继续下一个文件，绝不逃出 `enqueue`。`task` 已是带具体原因的
  failed 任务时保留原原因，不用笼统文案覆盖。
- `_importPdf` 调用点包 try/catch（:336-350）：其内部失败已由
  `_failAndClean` 转成 failed 任务，这里只接真正意外的异常。
- 尾部两次 `onProgress(100)` 回调包 try（:448-450、:571-573）：回调抛错
  不再把已成功的任务翻成失败。

## SR2-2 — `_failAndClean` 自身的写库无兜底

`lib/services/import_service.dart:581-594`

- `_failAndClean` 内部把 upsert 包进 try（:590-592），失败时返回内存里的
  `_failed(task, error)`，本函数绝不抛错。一处修、九处调用点受益。
- `_importPdf` 尾部因此去掉内层 `try { _failAndClean } catch { _failed }`
  （:566-570 现为直接 `return _failAndClean(...)`），与 SR2-2 修法一致。

## SR2-12 — 导入任务 id 只断言两次不同

`test/b5_p2_services_test.dart`（只动 SR-P2-60 组，:181-230）

- 原用例（:182）加格式断言：两次 id 均匹配
  `^task-\d+-\d+-\d{6}$`（含 6 位随机段），再断言 id 不同。
- 新增用例（:203）`同一毫秒内连续导入（SR2-12）：20 次快速导入 id 全不同`：
  20 次紧凑循环连续导入同一小文件，断言全部 id 格式正确且互不相同，
  库里 20 行。
- **与规定修法有出入处**：未能确定性安排“同一毫秒内两次调用”。公开
  `enqueue` API 没有可注入的时钟，id 在循环开头生成、随后是文件复制 +
  解码 + 多次写库，一次调用通常超过 1ms，无法保证两次调用落在同一毫秒。
  20 次快速调用是能做到的最强安排——调用越密，同毫秒碰撞窗口越大，
  随机段是唯一防线；格式正则 + 20 个全不同是本用例的实际钉点。如需
  确定性覆盖，应把 id 生成抽成可注入时钟 / 随机源的纯函数再单测，
  那是重构，不在本批范围。

## SR2-60 — P1-4 未测 `_failAndClean` 本身也失败的分支

`test/import_service_p1_fixes_test.dart:245-282`

- 新增用例`全部 collect_tasks 写操作失败（SR2-60）：enqueue 不抛、返回 2 个内存 failed 任务`：
  BEFORE INSERT + BEFORE UPDATE 双触发器让全部 `collect_tasks` 写操作
  RAISE(ABORT)，2 个 PDF 进 `enqueue`，断言不抛、返回 2 个内存 failed
  任务（`error` 非空）、库里 0 行。
- 另补 SR2-2 的直接用例（:206-243）`_failAndClean 自身写库失败（SR2-2）`：
  BEFORE UPDATE 触发器只让写 `failed` 的 UPDATE 炸，假损坏引擎
  （`_CorruptEngine`，`open` 即抛 `PdfCorruptException`，:87-94）让
  `_importPdf` 进 `_failAndClean`；断言返回 1 个内存 failed 任务
  （error 含“文件损坏”）、目录已删、库里只剩初始 importing 行（failed
  行写不进去是触发器模拟的降级态，内存结果为准）。

## SR2-71 — P1-14 恰好 20MB / 50MB 边界未测

`test/import_service_p1_fixes_test.dart:323-351`

- `恰好 20MB 图片（SR2-71，size == limit）：放行进 needBox`：photo.jpg
  后补 0 到恰好 20MB（`size == limit`），断言进 needBox。实测 JPEG
  解码在 EOI 后停，尾部补零不影响解码。
- `恰好 50MB PDF（SR2-71，size == limit）：放行进 needBox`：50MB 零字节
  文件 + 假引擎，断言进 needBox、pageCount 1。

## SR2-72 — P1-17 同文件不同写法未测

产品改动（规定修法只说“补用例”，但只补用例跑不过——旧去重按原始路径
字符串比较，相对 / 绝对 / 符号链接写法必然建出两个任务；去重键必须先
规范化，故含一处产品改动）：

- `lib/services/import_service.dart:172-191` 新增 `_dedupKey`：去重键 =
  `resolveSymbolicLinks()`（同时完成绝对化与链接解析）再整体小写折叠，
  覆盖 Windows/macOS 不区分大小写的文件系统。去重键只用于比较，实际
  打开的仍是调用方传的原路径。解析失败（如文件不存在）时回退到绝对
  路径小写，仍能覆盖相对 / 大小写写法。
- `lib/services/import_service.dart:213`：`seenPaths` 改为存 `_dedupKey`
  的返回值。
- 测试 `test/import_service_p1_fixes_test.dart:395-431`，三用例各断言只建
  1 个任务、库里 1 行：
  - `同文件相对路径与绝对路径写法（SR2-72）`；
  - `同文件符号链接写法（SR2-72）`（`_tmp` 下建 `Link` 指回夹具）；
  - `同文件大小写不同写法（SR2-72）`（`TEST/FIXTURES/PHOTO.JPG`，Linux
    下该路径本身打不开文件，但去重发生在打开之前）。
- 小写折叠的取舍：Linux 下同目录仅大小写不同的两个文件是病态构造，
  且产品跑在 Windows 上（大小写本就指同一文件）；折叠只影响去重比较，
  不影响实际打开的路径。已在 `_dedupKey` 注释中写明。

## 另补的测试（SR2-1 缺口，见 SELF-REVIEW-2 SR2-1“测试缺口”）

`test/import_service_p1_fixes_test.dart:171-204`

- `图片尾部 upsert 失败（SR2-1）：enqueue 不抛、图片任务失败、整批继续`：
  BEFORE UPDATE 触发器只让写 needBox 炸，2 张图片进 `enqueue`，断言
  2 个 failed 任务（error 含“写不进任务列表”）、目录已删、库里 2 行 failed。

## 测试证据（用例名 + 通过数）

`test/import_service_p1_fixes_test.dart`：16/16 通过（含新增 8 个）

| 组 | 用例 | 结果 |
| --- | --- | --- |
| SR-P1-4 | 收尾 upsert 失败：enqueue 不抛、任务失败、整批继续（既有） | 通过 |
| SR-P1-4 | 对照：写库正常时 PDF 仍成功进 needBox、页图在盘上（既有） | 通过 |
| SR-P1-4 | 图片尾部 upsert 失败（SR2-1）：enqueue 不抛、图片任务失败、整批继续（新增） | 通过 |
| SR-P1-4 | _failAndClean 自身写库失败（SR2-2）：仍返回内存 failed 任务、不抛（新增） | 通过 |
| SR-P1-4 | 全部 collect_tasks 写操作失败（SR2-60）：enqueue 不抛、返回 2 个内存 failed 任务（新增） | 通过 |
| SR-P1-14 | 21MB 图片：直接失败、提示 20MB 上限、不复制进库（既有） | 通过 |
| SR-P1-14 | 对照：20MB 以内图片仍正常进 needBox（既有） | 通过 |
| SR-P1-14 | oversizeHint 与硬判一致（既有） | 通过 |
| SR-P1-14 | 恰好 20MB 图片（SR2-71，size == limit）：放行进 needBox（新增） | 通过 |
| SR-P1-14 | 恰好 50MB PDF（SR2-71，size == limit）：放行进 needBox（新增） | 通过 |
| SR-P1-17 | 同批两次选同一文件：只建一个任务（既有） | 通过 |
| SR-P1-17 | 同批两个不同文件：仍建两个任务（既有） | 通过 |
| SR-P1-17 | 跨批重复仍允许重导（D-08）（既有） | 通过 |
| SR-P1-17 | 同文件相对路径与绝对路径写法（SR2-72）：只建一个任务（新增） | 通过 |
| SR-P1-17 | 同文件符号链接写法（SR2-72）：只建一个任务（新增） | 通过 |
| SR-P1-17 | 同文件大小写不同写法（SR2-72）：只建一个任务（新增） | 通过 |

`test/b5_p2_services_test.dart`：15/15 通过（含 SR-P2-60 组新增 1 个、改动 1 个）

| 组 | 用例 | 结果 |
| --- | --- | --- |
| SR-P2-60 | 同一毫秒两次导入同一文件：两个任务，id 不同（改动：加格式正则断言） | 通过 |
| SR-P2-60 | 同一毫秒内连续导入（SR2-12）：20 次快速导入 id 全不同（新增） | 通过 |
| SR-P2-60 | 同批两次选同一文件：仍只建一个任务（既有） | 通过 |
| 其余各组 | 12 个既有用例 | 全部通过 |

## 与规定修法有出入处

1. **SR2-12 同毫秒确定性安排**：见上节——公开 API 无注入时钟，20 次
   快速调用是最强可安排的覆盖，格式正则 + 20 个全不同是实际钉点。
   未抽取 id 生成函数（重构，超出本批范围）。
2. **SR2-72 含一处规定之外的产品改动**：去重键规范化（`_dedupKey`）。
   规定只说补用例，但旧实现按原始路径字符串去重，相对 / 绝对 /
   符号链接写法必然建两个任务，用例无法通过；改动只影响去重比较键，
   不影响实际打开的路径与跨批重导（D-08）。
3. **SR2-1 兜底 try 的缩进**：每文件兜底 `try {` 打开后循环体未整体
   多缩进一格（保持 diff 最小，`dart format` 未跑——
   `import_service.dart` 在改动前已不是 format-clean，跑 format 会动
   无关行）。`flutter analyze` 0 问题，语义不受影响。

## 遗留问题

- **失败行写不进库时，库内任务仍停在 `importing`**（SR2-1(a) 与 SR2-2
  的共同降级态）：各失败分支的 upsert 包 try 后，写库失败只返回内存
  failed 任务，库里那行仍是 importing；收集页 `_load` 读库后该任务仍
  显示“导入中”、无法重试。这是规定修法本身定下的降级（“失败只返回
  内存 failed 任务”），不是本批引入的；真要根治需写库重试或状态机
  层面的处理，超出本批范围。SR2-2 用例已把该状态钉住（库里 importing
  行 1 条）。
- **EXIF 镜像方向分支的“失败写库”未单独立用例**：与“解不开图片”分支
  共用同一 `decodeError` 路径与同一 upsert 保护，行为由代码结构保证，
  未再为镜像方向单立一个触发器用例。
- **兜底 try 覆盖的 `resolveDataPath(...)!` 强解包**：数据目录不可用时
  仍会抛错，但现已被每文件兜底 try 接住转成 failed 任务，不再逃出
  `enqueue`。
- 未跑全量测试与 Linux Release 构建（总协调在阶段关口统一跑）。
