# DB 改动方案 v2.1：打通主链（导入 → 框题 → 切片 → 持久化）

- 日期：2026-11-13（v2.1 修订）
- 分支：`ui-replication`
- 状态：**方案稿 v2.1，供 Meng 审阅；未实施**。本文档只写方案，**不改任何代码、不动数据库 Schema、不跑测试、不 commit、不 push**。
- 版本说明：**v2.1 是可开工版。**v2（2026-11-13，521 行）经 CodeBuddy 二审（8.4/10，有条件通过），指出 3 个 P0 + 4 个 P1 + 测试补充；本版逐条补齐并定稿。2026-11-13 补丁：CodeBuddy 三审 v2.1（8.8/10，有条件通过），剩下 1 个 P0 + 3 个 P1 + 若干 P2，本补丁逐条补齐（见下表），版本仍为 v2.1，不升 v3；单框旋转禁用同日由 Meng 确认。未定事项只剩 §5 所列（5 条）；§6 十条已全部定下（2026-11-13）。v2.1 补丁清单、v2 与 v2.1 的改动清单见下，v1 → v2 清单保留在后。
- v2.1 补丁（2026-11-13）：三审剩余项（1 个 P0 + 3 个 P1 + 若干 P2）逐条补齐；新增 §1.6.1（草稿旋转持久化）、§1.5.1（重框同页上下文），修订 §1.2/§1.4/§1.5/§1.6/§2.1/§2.3/§4.6/§5/§6/§8.2；只改本文档，不改代码、不动 Schema、不跑测试。
- §6 九条已定（2026-11-13）：老库直接删除、不迁移，新库从空开始、不预置演示数据；库搬家文件一起搬、上限 2GB；PDF 接受、限体积 50MB 与页数 20 页；多值字段 JSON 照做 + 输入限制做补充；备份做含文件 zip；页图缺失明确报错、不开编辑器；老收集任务删除；第 2 层切片未来再说；空间上限 2GB + 孤儿清理定期提醒开。决定内容见 §6；§1/§2/§3/§5/§7/§8 同步更新；版本仍为 v2.1，不升 v3。
- 依据（以现状代码为准，2026-11-13 读过）：
  - `lib/data/database.dart`（建表、`_jsonValue`、`upsertCollectTask`、`recordSelfCheck` 在 repository、`deleteSubject` / `deleteFolder`、备份/恢复、版本号与 `onCreate` / 无 `onUpgrade`）
  - `lib/data/repository.dart`、`lib/services/import_service.dart`、`lib/services/yolo_onnx_service.dart`、`lib/models/models.dart`
  - `docs/decision-log.md`（D-02 / D-05 数据库位置、D-23 YOLO）、`docs/ui-replication/YOLO-INTEGRATION-REPORT.md` §4、§6、§8
  - 另核对了 `lib/modules/collect/collect_page.dart`（修框编辑器与确认拆题）、`lib/modules/review/review_page.dart`（`_flatQueue` / `_blocksFromFlat`）、`lib/modules/organize/organize_page.dart` 与 `lib/widgets/widgets.dart`（`QuestionSlice` 占位绘制）、`pubspec.yaml`（依赖清单）

## v2.1 相对 v2 的改动清单（审阅时先看这张表）

| # | 来源 | v2 的问题 | v2.1 的定稿 |
|---|---|---|---|
| P0-1 | CodeBuddy 二审 | §1.5“整页 DELETE + INSERT”没区分草稿/重框模式：详情页重框一题时按页删，会把同页其他题的框一起删掉 | 写成三种明确模式（草稿保存 / 详情页重框 / 重检测）+ 取消语义区分（草稿取消保存、重框取消丢弃或弹确认），见 §1.5 |
| P0-2 | CodeBuddy 二审 | 单框旋转只是视觉旋转（`Transform.rotate`），`QuestionBox` 无 rotation 字段；落库后裁剪与屏幕显示不一致 | 定稿：**禁用单框旋转，只保留整页旋转**；UI 明确框只能拖动/缩放，不旋转；2026-11-13 Meng 已确认禁用（补丁，见 §6 第 10 条），见 §1.6 |
| P0-3 | CodeBuddy 二审 | `_pageRotation` 是编辑器全局一个值，多页/重框传播未定义：多页 PDF 会错烘焙，重框一道题再旋转会让同页其他题错位 | 旋转状态按页保存（`Map<int, int>`）；重框模式禁用整页旋转；页图替换同样 evict 缓存，见 §1.6 |
| P1-1 | CodeBuddy 二审 | 平铺备份 + `_meta` 对已发 v1 不安全：v1 校验只看顶层表名、读侧仍 `split(',')`，v2 的 JSON 数组会被静默读坏 | 写明事实：**v1 从未发布，不考虑旧版恢复**；双保险：v2 备份换扩展名 `.qm2backup`（v1 文件选择器只允许 `.json`，选不到）+ 导出时提示“此备份仅新版可恢复”，见 §2.3/§2.5 |
| P1-2 | CodeBuddy 二审 | `.bak` 预拷贝只有一句话、没有具体机制：`db` getter 一调 `openDatabase` 就会触发 `onUpgrade`，事后复制可能已太晚或拷到半截库 | 写清六步预检（存在性 → 只读读 `user_version` → checkpoint WAL → 复制 `.bak` → 关只读连接 → `version: 2` 打开），见 §2.2 |
| P1-3 | CodeBuddy 二审 | 模型加载/推理失败仍静默回占位框（`detectPage` 三处 `return _placeholderBoxes()`），落库后主链又假一次 | 定稿 `DetectionResult { boxes, usedFallback, error }`：模型失败显式提示“自动检测不可用，请手动框选”，不自动写入占位框；只有用户明确手动画框时才落库，见 §1.3/§1.5 |
| P1-4 | CodeBuddy 二审 | `page_image_path` 表述不一致（Schema 注释写 PNG，§1.4 说照片保留原图）；真实题缺图时回退未定 | 统一：`page_image_path` 允许 PNG/JPG（图片导入保留原图；PDF 渲染 PNG），`slice_path` 固定 PNG；图片导入时 `source_path` 与 `page_image_path` 可为同一文件，不重复复制；缩略图用 `cacheWidth`；真实题缺图显示“图片缺失”，`sliceText` 回退只适用于 `isDemo`/老题，见 §1.2(a)/§1.4 |
| P2 | CodeBuddy 二审 | §8 测试清单缺多题重框、旋转、v1 读 v2、`.bak` 预检、模型失败等高风险路径 | 补 6 项 + 另 6 项（`created_at = 0` 排序、partial unique、`parent_box_id` 级联、CHECK 约束、`ReviewQueueItem` 含 `|`/逗号、`FileImage` evict 后新图），见 §8.2 |
| 小项-1 | CodeBuddy 二审 | `QuestionBox` 的 `confidence` / `origin` 表里有、检测服务没填，两列永远为空 | `_toPageBox` 填 `confidence`、填 `origin = 'yolo'`；手画框 `confidence` 为 `NULL`、`origin = 'manual'`，见 §1.2(c) |
| 小项-2 | CodeBuddy 二审 | 方案只写了 `questions`，新拆分 `CollectTask` 行的字段没写 | 新拆分任务行同样写 `source_path` / `created_at` / `page_count`，见 §1.2(b)/§1.5 |
| 小项-3 | CodeBuddy 二审（已过时） | 审阅报告“顺手修”错题本返回刷新、整理/详情新学科显示成数学 | **第一批已完成**（错题本刷新、学科同步扫尾），不再列为待办，见附 |

## v2.1 补丁相对 v2.1 的改动清单（2026-11-13，三审；不升 v3）

| # | 来源 | v2.1 的问题 | 补丁的定稿 |
|---|---|---|---|
| P0 | CodeBuddy 三审 | 草稿旋转只存内存 `Map<int, int>`，取消/重开后框与页图错位；测试只要求“取消不写旋转后的页图” | `collect_tasks` 加 `page_rotations TEXT`（JSON），草稿保存框时一起存，重开按页恢复；测试改为“旋转 → 取消 → 重开 → 框与页图仍对齐”，见 §1.6.1 |
| P1-1 | CodeBuddy 三审 | 重框只加载目标题的框，同页其他题看不见，重叠校验失效；确认后 `collect_task_id` 为 NULL，查同页框的口径未写 | 重框加载同页全部 layer = 1 框（目标可编辑、其他只读），重叠校验对所有框生效；分组键为 `question.page_image_path`，见 §1.5.1 |
| P1-2 | CodeBuddy 三审 | 文件目录 staging + 原子替换，但数据库文件直接覆盖，失败无法恢复目标旧库 | 目标已有库先备份 `quiz-master2.db.old-<时间戳>`（或 staging 原子替换），失败恢复目标旧库与旧文件目录，见 §4.6 |
| P1-3 | CodeBuddy 三审 | “同一文件不重复复制”与“EXIF 归一化生成副本”互相矛盾 | 仅 EXIF != 1 时生成归一化副本；EXIF == 1 时两路径可为同一文件，见 §1.4 |
| P2-1 | CodeBuddy 三审 | 备份恢复选择器扩展名未定；导出文案/测试未同步 | `_pickRestoreFile` 同时允许 `.json` 与 `.qm2backup`；`_meta` 缺失按 v1、`> 2` 拒绝、恢复后 `settings.schemaVersion` 写回 2（后三条 §2.3 已有），见 §2.3 |
| P2-2 | CodeBuddy 三审 | 拆分任务 `page_count`、老题判定、`detectPage` 同步读、`QuestionBox.id` 规则、`page`/`confidence` CHECK 未定 | 逐项定稿：`page_count` 用原任务总页数；老题判 `sourcePath == null && slicePath == null`；检测读图改异步/isolate；id 定为 `box-<taskId>-p<page>-<uuid8>`；`page >= 1`、`confidence` 0..1 加 CHECK，见 §1.2(b)/(c)、§1.4、§8.2 |
| 决定 | Meng 2026-11-13 已确认 | 单框旋转禁用原为提案（§5 第 10 条、§6 第 10 条），待确认 | **确认禁用**：只保留整页旋转，UI 明确框只能拖动/缩放、不旋转；`QuestionBox` / `question_boxes` 不加 `rotation` 字段；§5、§6 同步更新 |

## §6 九条决定总表（2026-11-13，Meng 原话逐条；详情见 §6）

| # | 决定 | 要点 |
|---|---|---|
| 1 | 老库直接删除，不迁移 | v2 首次启动删老 v1 库文件（含 `-wal`/`-shm`），直接 `_onCreate` 建 v2 新库；新库从空开始，**不预置演示数据** |
| 2 | 按提案 | 库搬家文件一起搬；存储上限 2GB |
| 3 | PDF 接受 | 限体积与页数：单个 PDF 不超过 50MB（既有）且不超过 **20 页**，超了提示分批导入；渲染库选型成为 P2 必需 |
| 4 | JSON 照做 + 输入限制做补充（**已定**，2026-11-13） | 多值字段改 JSON；仅在标签名和自定义错因名两个字段禁 `,` `，` `\|` 三个分隔符，输了提示“不能含逗号或竖线”；不禁全部特殊符号（数学、英文、中文标点、表情都允许，JSON 编码已保证数据正确） |
| 5 | 备份做含文件的 zip | P3 做 zip（JSON + `imports/` + `slices/`） |
| 6 | 页图缺失明确报错、不开编辑器 | 修框入口显式报错，不开编辑器 |
| 7 | 老收集任务删除 | 随老库一起删除 |
| 8 | 第 2 层切片未来再说 | 不持久化，暂不议 |
| 9 | 同意提案 | 空间上限 2GB + 超限提示；孤儿清理定期提醒开 |

## v2 相对 v1 的改动清单（审阅时先看这张表）

| # | 来源 | v1 的问题 | v2 的定稿 |
|---|---|---|---|
| P0-1 | CodeBuddy 审阅 | `question_boxes.collect_task_id TEXT NOT NULL`，但确认拆题最后一步删原任务（`collect_page.dart` L343），框的归属悬空 | `collect_task_id` 改**可空**，语义定为“修框阶段的草稿归属”；确认后只保留 `question_id`；删除规则见 §1.2(c) |
| P0-2 | CodeBuddy 审阅 | DDL 漏了 `parent_box_id`（正文提过，`CREATE TABLE` 里没有） | DDL 补 `parent_box_id TEXT` + 索引；删第 1 层框时同事务删其子框；第 2 层手动内框照常持久化，见 §1.2(c) |
| P0-3 | CodeBuddy 审阅 | 页面旋转没有建模：编辑器支持整页旋转（`_rotatePage`，`collect_page.dart` L1174），框坐标是旋转后的坐标系，页图仍是原图，确认后按原图裁切片会错位 | **定稿：确认时把旋转烘焙进页图**（不存 `page_rotation` 列），见 §1.6；EXIF 在导入时归一化；加 90/180/270 裁剪测试要求 |
| P0-4 | CodeBuddy 审阅 | §3.2 说“五处读写点集中改”，实际写点远不止五处（删文件夹、改标签、删知识点等处还在 `join(',')`） | 列出**全部 11 处写点**（§3.1）；数据层收口 `encode/decode` 系列函数，所有读写点统一调用；`_seedCauseRecordsFor` 写 `[]`；`_fromRow` 容错读只保留一个版本，v3 删掉 |
| P0-5 | CodeBuddy 审阅 | 只换 `review_state.queue` 的编码不够：`ReviewSessionState.queue` 是 `List<String>`，复习页用 `split('|')` 解析，自定义错因含 `\|` 仍会切错 | 引入 `ReviewQueueItem { questionId, cause }`，`queue` 改 `List<ReviewQueueItem>`；同步改 `saveReviewState` / `loadReviewState` / `_flatQueue` / `_blocksFromFlat` / 相关测试，见 §3.4 |
| P1-1 | CodeBuddy 审阅 | 备份改成 `{ schemaVersion, appVersion, exportedAt, tables: {...} }` 嵌套结构，旧版无法识别 | **保持表名平铺在顶层**，额外加 `_meta: {schemaVersion, appVersion, exportedAt}`；恢复前先校验再清表；`schemaVersion > 2` 直接拒绝，见 §2.3 |
| P1-2 | CodeBuddy 审阅 | 框的持久化时机、重检测、重框入口没有定义 | 定稿见 §1.5：拖拽只改内存，关闭/取消/切页/确认时批量保存（必要时 200–300ms debounce）；重检测按 task + page 替换；详情页加“重新框选”入口；重切图处理 `FileImage` 缓存；确认拆题四步同事务、切片写盘在事务前 |
| P1-3 | CodeBuddy 审阅 | 页图分辨率、格式与 PDF 渲染是主链硬约束，v1 没定 | 定稿见 §1.4：页图长边 2000–3000；照片页图默认保留原图（不转 PNG）；PDF 渲染未定前只收图片或显式提示暂不支持；加存储上限与孤儿清理 |
| P1-4 | CodeBuddy 审阅 | 文件迁移与路径安全没有设计：`migrateToDirectory` 现只复制数据库 | 定稿见 §4.6：目标冲突用覆盖/保留/取消；跨盘失败回滚（staging + 原子替换）；大目录复制进度/取消；相对路径 + 统一 resolver，禁止 `..` 越界；zip 恢复防路径穿越 |
| P2 | CodeBuddy 审阅 | 测试依赖真实用户库；无 v1 fixture；`AppDatabase` 已 1164 行 | 定稿见 §8：可注入打开路径/测试工厂、签入仓库的 v1 fixture、schema 对比测试、测试清单、拆分建议 |
| 其他-1 | CodeBuddy 审阅 | `collect_tasks.created_at` 回填成迁移时刻，老任务全排在新任务上面 | 改回填 **0**（排到底部），见 §2.2 |
| 其他-2 | CodeBuddy 审阅 | 无防重复约束：一题可能有多个 layer = 1 整题框 | 加 partial unique index（`WHERE layer = 1 AND question_id IS NOT NULL`），见 §1.2(c) |
| 其他-3 | CodeBuddy 审阅 | 无 CHECK 约束 | 加 CHECK（`layer IN (1,2)`、type 枚举、x/y/w/h 在 0..1、w/h >= 0），见 §1.2(c) |
| 其他-4 | CodeBuddy 审阅 | `QuestionBox` 模型与表字段不同步 | **定稿：扩展 `QuestionBox` 模型**（不另建 `StoredQuestionBox`），见 §1.2(c) |
| 其他-5 | CodeBuddy 审阅 | `bumpBadgeVersion` 高频触发、`_simulateImport` 仍是假进度 | 定稿：角标只在状态变化时 bump 或 debounce，见 §4.3；`_simulateImport` 换真实复制/渲染进度，见 §1.4 与 §7 |
| 顺序 | CodeBuddy 审阅 | v1 顺序 P0 → P1 → P2 → P3 | 微调为 **P0 加固 → P0.5 图片链路小样 → P1 迁移 → P2 主链 → P3 收尾**，见 §7 |

## 不确定项（先写在文首：以下不是定论）

1. **PDF 渲染选型未做。** 没有调研过 Dart/Flutter 可用的 PDF 渲染库（选型、Win11 可用性、渲染速度、50MB 大 PDF 的内存占用、是否需原生依赖）。PDF 已接受、限 50MB/20 页（§6 第 3 条，2026-11-13）；渲染是 P2 必需，不再是备选；导入时全渲还是按需渲待选型时定。实施前须单独做一次选型（可列入实施任务的第一步）。
2. **Win11 真机验证仍是空白。** `onnxruntime.dll` 是否随包打包、CPU 推理速度、SQLite 原生资源、字体/DPI（YOLO 报告 §8 与 R11 验收清单）都还没在 Win11 上验过。**本方案的全部存储设计都不依赖 Win11 的验证结果**，但切片裁剪用的图片解码（`dart:ui`）与 PDF 渲染在 Win11 上的表现，实施时须在 Win11 上复核。
3. **磁盘占用没有实测数。** 50MB PDF 渲成 PNG、20MB 手机照片转 PNG 各占多少，没有量过；§1.7 的“占用翻倍”警告是定性估计。实施时须用一张真实 50MB PDF 与一张 20MB 照片实测后，再定是否需要压缩（JPG 页图）或上限。
4. **图片转 JPEG/WebP 需不需要新依赖，未定。** §1.4 定了“照片页图默认保留原图”，若将来要统一转 JPEG/WebP（省空间、统一格式），`dart:ui` 只能输出 PNG，须引入图像编码依赖（选型未做）；在此之前不转码。PDF 页图是渲染库输出，不受此限。
5. **“设置单 owner”不在本文档范围。** CodeBuddy 复审提到的“设置单 owner”问题（多处直接写 `settings` 表）是另一批小正确性修复，与主链 Schema 无关，本文档不展开；实施主链时不要顺手改它。

（原第 7 条 `question_boxes.id` 命名规则已在 v2.1 补丁中定稿：`box-<taskId>-p<page>-<uuid8>`，见 §1.2(c)；原第 10 条单框旋转禁用已由 Meng 于 2026-11-13 确认，见 §1.6 与 §6 第 10 条。）

---

## 0. 现状：主链断在哪（先对齐事实）

主链是：导入真实文件 → 看到原图 → 自动框题 → 修框 → 生成真实切片并持久化。目前断成 5 截，每截的证据都在下面，方案第 1–4 节逐截接上。

| 环节 | 现状（代码证据） | 后果 |
|---|---|---|
| 导入只存文件名 | `ImportService.enqueue`（`import_service.dart`）只取 `file.uri.pathSegments.last` 作 `fileName`，不复制文件、不记原路径；`collect_tasks` 表没有源路径列，也没有 `created_at`。`collect_page.dart` 的 `_importFiles` 只做空文件 / 加密 PDF 启发式检查，通过后就 `enqueue` + `_simulateImport`（定时器假进度，注释自认“真实解析与 YOLO 检测接好后在此替换”）。 | 导入后原文件一移动、重命名、删除（微信/QQ 传输的临时文件尤其如此），题就再也找不回原图。 |
| 检测按文件名找文件 | `collect_page.dart` `_openBoxEditor` 调 `YoloOnnxService().detectPage(imagePath: task.fileName, page: task.page)`——传的是**文件名不是路径**。文件不在当前目录就 `existsSync()` 为假，`detectPage` 静默回占位框（一页一个整题框，`yolo_onnx_service.dart` `_placeholderBoxes`）。YOLO 第 1 层本身已是真实推理（D-23，`onnxruntime` 1.4.1，3 张实测页通过），但**有真模型也跑不到真图上**。 | 用户看到的是“检测成功”的假象，框的位置与试卷内容无关。 |
| 修框画的是占位纸面 | 修框编辑器 `_BoxEditorDialog` 的框只活在内存 `Map<int, List<QuestionBox>> _boxesByPage` 里；底图不是真实试卷页，是占位色块（YOLO 报告 §4、§8 第 4 项已知待办；`organize_page.dart` / `widgets.dart` 的 `QuestionSlice` 是按 `sliceKind` / `sliceText` 画出来的示意纸面）。 | 框与内容贴合程度无法在编辑器里核对，只能事后对照标注图。 |
| 确认拆题时框被丢掉 | `_openBoxEditor` 确认后只按框**数**拆题：新建的 `Question` 只有 `id` / `title` / `subjectId` / `createdAt`，不存任何框坐标、不存切片路径；`QuestionBox`（`id` / `layer` / `type` / `x` / `y` / `w` / `h`，0..1 相对坐标）确认完即丢弃。`questions` 表也确实没有地方存它们：只有 `slice_kind`（默认 `'material'`）和 `slice_text`（演示文字）两个与“切片”有关的列，见 §1。 | 整理页、详情页只能继续画占位切片；“修框”修了等于没修，下次打开同一道题框不存在。 |
| 切片从未真实生成 | 全仓库没有按框裁剪图片并写盘的代码；`pubspec.yaml` 只有 `flutter` / `sqflite_common_ffi` / `path` / `file_picker` / `onnxruntime`，**没有任何 PDF 渲染依赖**，也没有 PDF → 图片的代码。PDF 导入目前只做到“收下文件名 + 判加密”。 | 即使框是对的，也没有真实切片可存、可看。 |

补充两个现状前提，方案都以此为边界：

- 第 2 层（题干 / 选项 / 配图）已按 D-23 暂缓，`YoloOnnxService.intraEnabled = false`，模型已移出仓库。**本方案只打通第 1 层主链**；第 2 层框的存储位置一并留好（见 §1.3），但不为它生成持久切片、不恢复模型。
- 一道题是最小单位、永不拆分；一题只存一份，可挂多文件夹、多标签（MEMORY / D-05 等既定决策）。本方案不碰这条。

---

## 1. 主链 Schema 设计

### 1.1 选型结论

**`questions` 表加标量字段（源文件 / 页图 / 整题切片路径）＋ 另建 `question_boxes` 表（每框一行），不把框塞进 `questions` 的 JSON 列，也不另建切片表。**

理由：

- **框在题之前就存在。** 修框发生在收集任务阶段，确认拆题后题才创建；框的生命周期起点是“任务 + 页”，不是“题”。框若存在 `questions` 里（无论 JSON 列还是标量列），修框中途退出、取消、任务删除时框无处安放——现状 `_BoxEditorDialog` 取消后任务留“修框中”，下次“继续修框”应恢复上次的框，没有独立的框表就做不到。
- **框是多行、可查询、可逐行改的。** 一页 13 道题就是 13 个框（YOLO 报告 §3 实测），拖动、缩放、删除、重画都是逐框操作；JSON 整 blob 改一次就要重写全部框，并发与脏写风险大；按 `question_id` / `collect_task_id` 查框、数框、删框都是 SQL 一句话。
- **切片是派生品，不配一张表。** 整题切片 = 页图按第 1 层框裁剪，一题恰好一个文件；题干 / 选项 / 配图切片 = 同一页图按第 2 层框裁剪，可按需现算（见 §1.4）。一张 `question_slices` 表只会多一层间接寻址，收益为零；将来若要缓存第 2 层切片文件，再加表也不迟。
- **被否掉的备选：**① `questions.boxes_json TEXT`（一题一 JSON）：框先于题存在、修框是逐框写、还要支持按任务查框，三点全撞上；② `questions` 表每框加 4 列（`box_x`…）：一页多题放不下；③ 框与切片都放 `collect_tasks`：任务在确认后会被拆出的新任务替换（`_openBoxEditor` 注释“原任务被拆出的新任务替换，不留原任务”），框的归属会跟着任务一起消失。

### 1.2 改什么

#### （a）`questions` 表：加 7 列（全部可空或带默认值；新库从空开始，无老行）

| 列 | 类型 / 默认 | 用途 |
|---|---|---|
| `source_path` | `TEXT`（相对路径，见 §1.4） | 该题来源文件的**库内副本**路径。演示题不预置（见 §6 第 1 条）。 |
| `source_kind` | `TEXT`（`'pdf'` / `'image'`） | 区分 PDF 页图与直接导入的图片，避免每次按扩展名猜。 |
| `source_page` | `INTEGER` | 该题在源文件中的页码（PDF 页；图片导入为 1）。 |
| `page_image_path` | `TEXT` | 渲染/复制后的**页图**路径（PNG/JPG，见 §1.4：图片导入保留原图、扩展名随原图；PDF 渲染 PNG）。修框底图、详情大图、重做时都读它。EXIF == 1 时与 `source_path` 指向同一文件，不重复复制；EXIF != 1 时指向归一化副本（见 §1.4）。 |
| `slice_path` | `TEXT` | **整题切片**文件路径（PNG）。整理页、详情页、错题本缩略图读它；为空时回退到现有占位绘制（兼容无图的新题；演示题与老题已随老库删除）。`slice_path` 非空但文件缺失时显示“图片缺失，可重新导入/重新框选”，不回退空白纸面；`sliceText` 回退只适用于 `isDemo` 或明确的老题（v2.1，P1-4）。“老题”判定（v2.1 补丁，P2）：`sourcePath == null && slicePath == null` 的真实题视为老题（或将来加显式 `isLegacy` 标记）；有 `sourcePath` 但 `slicePath` 为空的真实题走“图片缺失”，不回退空白纸面。 |
| `slice_width` / `slice_height` | `INTEGER` | 切片像素尺寸。切图时已知，存下来可免每次读文件头；缩略图按比例排版也用得上。 |

不改：`slice_kind` / `slice_text` **保留**（最小改动，不删列）。演示题不再预置；真实题的 `slice_text` 不再填写（真实数据无 OCR）。

`Question` 模型同步加 `sourcePath` / `sourceKind` / `sourcePage` / `pageImagePath` / `slicePath` / `sliceWidth` / `sliceHeight` 字段（全部可空），`copyWith` 照现有 `clearXxx` 模式处理清空语义；`_toRow` / `_fromRow` 照新列读写。

#### （b）`collect_tasks` 表：加 4 列，显示名与源路径分离

| 列 | 类型 / 默认 | 用途 |
|---|---|---|
| `source_path` | `TEXT NOT NULL DEFAULT ''` | 导入时复制进库的**库内副本**绝对/相对路径（见 §1.4）。`file_name` 回归本义：**只做显示名**。现状 `file_name` 又当显示名又当 `detectPage` 的路径，是主链断裂的直接原因，必须拆开。 |
| `created_at` | `INTEGER NOT NULL DEFAULT 0` | 任务创建时间（毫秒）。现状 `allCollectTasks` 靠 `rowid DESC` 排序，见 §4.3 的不稳定问题；本列是它的修复。 |
| `page_rotations` | `TEXT NOT NULL DEFAULT '{}'` | 草稿修框的**按页旋转角度**（JSON，如 `{"1": 90, "2": 0}`；v2.1 补丁，P0）。草稿保存框时与框一起保存；重开“继续修框”时按页恢复旋转，再显示框；确认时按最终角度烘焙页图（见 §1.6.1）。 |
| `page_count` | 已有，不改列、改写入 | 现状 `enqueue` 从不设置，恒为 1。导入 PDF 时由渲染步写真实页数（PDF 单个不超过 20 页，见 §1.4）；图片为 1。 |

`CollectTask` 模型同步加 `sourcePath` / `createdAt` / `pageRotations`；`ImportService.enqueue` 改为：复制文件进库 → 写 `source_path` + `created_at` → 再建任务。复制失败则任务直接进 `failed`（见 §1.4）。确认拆题新建的拆分任务行同样写 `source_path`（指向同一任务目录的副本/页图）、`created_at`（新建时刻）、`page_count`（**原任务的总页数**，见下）——否则新任务排序又回到 0、页数又缺失（v2.1 小项-2）。**`page_count` 口径（v2.1 补丁，P2）：用原任务的总页数**——任务行还有 `page`（“第 p 页”），UI 显示“第 2 页 / 共 N 页”才一致；单页任务不显示“共 N 页”。

#### （c）新建 `question_boxes` 表：每框一行（v2 修订版 DDL）

```sql
CREATE TABLE question_boxes(
  id TEXT PRIMARY KEY,              -- 框 id：`box-<taskId>-p<page>-<uuid8>`（v2.1 补丁，P2 定稿；重检测、手画、跨页同名均唯一）
  collect_task_id TEXT,             -- v2 改可空：修框阶段的草稿归属；确认后只保留 question_id（见下）
  question_id TEXT,                 -- 确认拆题后回填；修框中为 NULL
  parent_box_id TEXT,               -- v2 新增：第 2 层框的父框（指向第 1 层框的 id）；第 1 层框为 NULL
  page INTEGER NOT NULL DEFAULT 1 CHECK (page >= 1),
  layer INTEGER NOT NULL CHECK (layer IN (1, 2)),  -- 1 整题 / 2 题内（D-23：目前只写 1；2 预留手画与将来恢复）
  type TEXT NOT NULL CHECK (type IN ('question', 'stem', 'option', 'figure')),
  x REAL NOT NULL CHECK (x >= 0 AND x <= 1),
  y REAL NOT NULL CHECK (y >= 0 AND y <= 1),
  w REAL NOT NULL CHECK (w >= 0 AND w <= 1),
  h REAL NOT NULL CHECK (h >= 0 AND h <= 1),
  confidence REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),  -- YOLO 置信度；手画框为 NULL
  origin TEXT NOT NULL DEFAULT 'manual' CHECK (origin IN ('yolo', 'manual')),
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_boxes_task_page ON question_boxes(collect_task_id, page);
CREATE INDEX idx_boxes_question ON question_boxes(question_id);
CREATE INDEX idx_boxes_parent ON question_boxes(parent_box_id);
CREATE UNIQUE INDEX idx_boxes_one_layer1_per_question
  ON question_boxes(question_id) WHERE layer = 1 AND question_id IS NOT NULL;
```

关键点（v2 定稿）：

- **`collect_task_id` 可空是 v2 的修正，不是疏漏。** v1 写成 `NOT NULL`，但确认拆题的最后一步是删除原任务（`collect_page.dart` L343 `deleteCollectTask(task.id)`；另一处 L356 同理）。确认后框要保留给题（`question_id` 回填），原任务已不存在，`collect_task_id` 只能悬空。语义定为：**“修框阶段的草稿归属”**——框在修框阶段属于任务，确认后归属权转移给题。**不要**把 `collect_task_id` 重指向新拆出的任务：新任务以后也可能被删，框又会悬空；`question_id` 才是确认后的权威归属。
- **删除规则（写进代码，不只写文档）：** 有 `question_id` 的框保留（随题走，删题时随题删，见 §4.5）；无 `question_id` 的框随任务删（`deleteCollectTask` 时同事务删 `collect_task_id = ? AND question_id IS NULL` 的行；若任务已确认拆题，`imports/<task-id>/` 目录的处理见 §4.5——页图可能还被已建的题引用，不能随任务删）。
- **`parent_box_id` 是 v2 补上的列。** v1 正文提过、DDL 里漏了。第 2 层框（`layer = 2`）的归属沿用 `YoloOnnxService.groupInners` 的规则（中心点落在哪个第 1 层框内就归谁；无主的进 `orphans`），持久化时用 `parent_box_id` 表示归属；无主第 2 层框的 `parent_box_id` 为 `NULL`、`question_id` 也为 `NULL`，随任务删。**第 2 层自动检测暂缓，只影响“自动检出”，不影响“手动内框的持久化”**：修框编辑器现在就能手画内框（`_innerModeBoxId`、`_standaloneInner`），用户现在就能产生 `layer = 2` 的框，漏列会导致内框归属丢失。删第 1 层框时，**同事务删除其全部子框**（`parent_box_id = ?` 的行）。
- **唯一约束：** 一题只能有一个 `layer = 1` 的整题框。partial unique index `WHERE layer = 1 AND question_id IS NOT NULL`——修框中的框（`question_id IS NULL`）不受限（一页多题的框在确认前都挂在任务下）；确认回填时若已存在同题整题框，须先删旧框再回填（重复确认/重检测的防呆），不许静默产生两个整题框。
- **CHECK 约束：** `layer IN (1,2)`、type 四值、`x/y/w/h` 在 0..1、`w/h >= 0`。应用层 `clampToPage` 之外再加一层数据库保护；`clampToPage`（`minSize: false` 用于检测框）已是既定规则，入库前仍由它钳制。
- **`QuestionBox` 模型同步扩展（v2 定稿：扩展模型，不另建 `StoredQuestionBox`）。** 表里有的字段模型里也要有：`confidence` / `origin` / `parentBoxId` / `page` / `collectTaskId` / `questionId`（全部可空，编辑器内新建的框只填 `id/layer/type/x/y/w/h`，其余为 `NULL`/默认值）。理由：编辑器用的就是 `QuestionBox`，另建一个模型意味着两处 `x/y/w/h` 与两套转换，长期用裸 `Map` 传更糟；一个模型、一套 `_toRow` / `_fromRow`，存储字段可空即表示“编辑器内未知”。检测服务 `_toPageBox` 填 `confidence`、填 `origin = 'yolo'`；手画框 `confidence` 为 `NULL`、`origin = 'manual'`（v2.1 小项-1；不写这条，两列永远为空）。

#### （d）不建的表

- 不建 `question_slices` 表（理由见 §1.1）。
- 不建 `source_files` 表：源文件与任务是一对一（一次导入一个文件一个任务），`collect_tasks.source_path` 已够用；多页 PDF 的页图是任务的派生文件，不必再有一张表。

### 1.3 为什么这样改（对照断点）

- 导入复制 + `collect_tasks.source_path` → 检测再也不靠文件名猜路径，`detectPage` 传入库内页图路径，找得到文件才跑真推理，找不到应报“页图缺失”而不是静默回占位（占位回退的静默性是现状的坑，见文首不确定项第 4 条）。
- `question_boxes` → 修框中途退出可恢复、确认后框不丢失、详情页可重进修框改框后重新切图。
- `questions.slice_path` + `page_image_path` → 整理页左图、详情大图、错题本缩略图第一次有真实图片可读；`slice_path` 为空时回退到现有占位绘制（新题无图时）。新库从空开始，无老题/演示题。
- **检测失败不回占位（v2.1，P1-3）。** `detectPage` 返回带状态的结果 `DetectionResult { boxes, usedFallback, error }`（或 UI 先检查 `hasRealModel`）；模型缺失/加载失败/推理异常时显示“自动检测不可用，请手动框选”，**不自动写入占位框**；只有用户明确手动画框时才落库。页图缺失时的修框入口行为仍未定，见 §6 第 6 条。

### 1.4 文件落盘位置与导入时复制策略（v2 修订版；§6 第 2、3 条已定，2026-11-13）

数据目录沿用 D-02 / D-05：Win11 为 `%LOCALAPPDATA%\quiz-master2`，Linux 验证为 `~/.local/share/quiz-master2/`，数据库位置改后（`db_location.txt` 标记）文件目录**跟着数据库走**，即以 `AppDatabase.dataDirectoryPath()` 为根——库与文件不分离，否则换库位置后题图全丢。现状 `database.dart` 头注释“切片图也放同一数据目录”只有这句话，没有任何落盘代码，本方案把它落实：

```
<数据目录>/
  quiz-master2.db
  db_location.txt            # 已有
  imports/<task-id>/original.<ext>        # 导入的原文件副本（PDF 或图片原样）
  imports/<task-id>/pages/page-001.png    # PDF 渲染出的页图（PNG）；图片导入时无此文件，页图即 original 副本（见下）
  imports/<task-id>/pages/page-002.png
  slices/<question-id>.png                # 整题切片（第 1 层框裁剪）
  thumbs/<question-id>.png                # 可选：错题本缩略图（小尺寸；不做也行，先用 slice_path 原图缩放显示）
```

- **复制策略：导入时复制，不移动、不引用原路径。** 选文件后立即把原文件复制到 `imports/<task-id>/original.<ext>`，任务的 `source_path` 指向副本。理由：原文件可能在微信/QQ 传输目录、手机传来的临时目录、U盘，随时会被清理；引用原路径等于把题的命交给用户的文件管理习惯。复制失败（磁盘满、权限）→ 任务直接 `failed`，错误写进 `collect_tasks.error`，不建“只有文件名”的空任务。
- **命名：目录与文件一律用 id（`task-…` / `import-…`），不用用户文件名。** 用户文件名可能含中文、空格、超长、重名、非法字符；显示名仍用 `file_name` 原样展示。同一文件重复导入（D-08 已定“仍可再次导入”）时每次生成新 `task-id`、新目录，互不覆盖。
- **页图分辨率（v2 定稿，P1-3）：长边 2000–3000。** YOLO 输入是 1280（letterbox 缩放后送入），但**切片不能从 1280 的图裁**，否则题干文字会糊。正确做法：保存高分辨率页图（长边 2000–3000，手机照片与 PDF 渲染都按这个目标），检测时再 letterbox 到 1280；切片从高分辨率页图裁。分辨率不足的源图（小图）不强行放大，按原尺寸存，检测与裁剪照常走同一流程。
- **页图格式（v2 定稿，P1-3）：照片默认保留原图，不转 PNG。** `dart:ui` 内置只方便输出 PNG，但 PNG 对照片可能膨胀数倍（20MB 照片转 PNG 更大）。在没有额外图像编码依赖的前提下，图片导入最稳的是**保留原图作页图**（JPG/PNG 原样）；PDF 渲染出的页图为 PNG（渲染库自带编码）。若将来要统一转 JPEG/WebP 省空间，须引入图像编码依赖，见文首不确定项第 7 条。**EXIF 方向在导入时归一化（v2.1 补丁，P1-3，二选一已定：仅 EXIF != 1 时生成副本，确定性优先）**：仅当 EXIF 方向 != 1 时生成一张归一化页图副本——`source_path` 保留原图，`page_image_path` 指向副本；EXIF == 1 时不生成副本，两路径可为同一文件。之后流程不再读 EXIF；页图文件本身永远是正向的（EXIF != 1 时已生成归一化副本）。旋转建模见 §1.6，不再依赖 EXIF。（v2.1，P1-4：`page_image_path` 允许 PNG/JPG——图片导入保留原图、扩展名随原图；PDF 渲染 PNG；`slice_path` 固定 PNG。）
- **导入进度（v2 新增）：`_simulateImport` 换真实进度。** 现状定时器假进度（每 160ms 调一次 `saveCollectTask`）在真实导入时必须换掉：复制进度（按字节）+ 渲染进度（按页）+ 检测进度（按页）三段真实进度；三段都走同一个进度回调进任务行。`saveCollectTask` 高频写库时角标刷新只在状态变化时 bump 或 debounce（见 §4.3），不要每次进度更新都触发 `_refreshBadges` 的 5 个查询。
- **PDF 渲染仍是待办，明确写在这里：** 本方案**不包含** PDF → 页图的渲染实现。现状：`pubspec.yaml` 无任何 PDF 依赖，`import_service.dart` 与 `collect_page.dart` 没有任何渲染代码，PDF 只做到收文件名 + 判空 + 判加密启发式。渲染需要新依赖（选型未做，见文首不确定项第 1 条）。**PDF 已接受（§6 第 3 条，2026-11-13）：单个 PDF 不超过 50MB（既有规则）且不超过 20 页，超了提示分批导入；渲染库选型成为 P2 必需**（不再是“暂不支持”的备选）。渲染时机定为**导入时整本渲染**（全部页一次渲好，`page_count` 写实，修框翻页不等待）还是**按需渲染**（翻到哪页渲哪页）待选型时定——导入时全渲简单但大 PDF 耗时与磁盘占用大；按需渲染省空间但修框翻页要等。不要建一个没有页图的任务还假装能修框。
- **存储上限与孤儿清理（v2 新增，P1-3）：** 给 `imports/` + `slices/` 设上限（已定：2GB，见 §6 第 9 条），导入前估算（原文件大小 + 预估页图大小）超限时提示“空间不足，先清理”；设置“数据”组现有“缓存清理”旁加**空间占用显示**（`imports/` 与 `slices/` 各占多少）与**孤儿清理入口**（只删孤儿文件，不删在用文件；见 §4.5）。无上限则 50MB PDF 多导几次就可能占满磁盘。
- **切片生成时机：修框确认时。** 确认后按最终框裁剪页图写 `slices/<question-id>.png`，写盘成功后再建题、回填 `question_boxes.question_id`、建拆分任务，三步同事务（数据库部分）+ 写盘在事务外先行（见 §4.2 顺序说明）。修框里改框后重新确认 → 覆盖写同一 `slice_path`（文件名与题 id 绑定，覆盖即更新；重切图后处理 `FileImage` 缓存，见 §1.5）。第 2 层切片不持久化：整理页的题干/选项/配图切片区按需从页图 + 第 2 层框现裁（内存里做，不写盘）。
- **列表缩略图（v2.1，P1-4）：** 用 `Image.file(..., cacheWidth: ...)` 按显示尺寸解码，不要每张都解码高分辨率大图；`thumbs/` 可选，不是必需。
- **检测读图不要阻塞 UI 线程（v2.1 补丁，P2）：** 页图长边 2000–3000，`YoloOnnxService.detectPage` 现在用 `readAsBytesSync` 在 UI 线程读大图（当初是为了 `testWidgets` 的 `FakeAsync` 才用同步），可能卡顿。定稿：生产用异步读（`readAsBytes`）或 isolate，或提供测试开关；至少 P0.5 实测一次大图打开耗时，写进小样验收。

### 1.5 框的持久化时机、作用域、重检测与重框入口（v2 新增、v2.1 修订，P0-1/P1-2）

v1 只说了“修框中途退出可恢复”，没说框什么时候写库。本节定稿：

- **写入时机与三种作用域（v2.1 修订，P0-1）：拖拽期间只改内存，关闭/取消/切页/确认时批量保存。** 每次拖动都写库会把 60fps 的指针事件打进数据库；只在确认时写则取消就丢框，与“继续修框”矛盾。定稿：编辑器内拖动、缩放只改内存 `_boxesByPage`（单框旋转已禁用，见 §1.6）；批量保存的作用域必须分三种模式写死，**不许用一个“整页 DELETE + INSERT”走两种模式**（v2 的写法有歧义：详情页重框一题时按页删，会把同页其他题的框一起删掉）：
  - **草稿保存（关闭/取消/切页/确认）：** `DELETE FROM question_boxes WHERE collect_task_id = ? AND page = ? AND question_id IS NULL`，再插入当前页内存里的框（同事务）。只动该任务该页的草稿框。
  - **详情页重框：** `DELETE FROM question_boxes WHERE question_id = ?`（连同 `parent_box_id` 指向该题整题框的子框），只动这一题；同页其他题的框与切片一律不动。
  - **重检测 / “恢复自动框”：** 草稿模式按草稿保存的作用域替换该页框；重框模式按详情页重框的作用域替换该题的框；**已确认的其他题框永远不参与删除。**
  - **取消语义两种模式不同：** 草稿模式取消**应保存**（下次“继续修框”恢复）；重框模式取消**应丢弃本次修改**，或弹“保存/不保存”让用户选，**不能无条件保存**（否则一次误操作就覆盖了原来正确的框）。
  - 其余不变：切页时保存当前页；点“确认修框”时保存全部页；编辑器被系统回收/应用退出前尽力保存，保存失败不阻塞退出；必要时加 200–300ms debounce（拖动停下 300ms 后写一次），不许每个指针事件都写库。
- **重检测 / “恢复自动框”：按作用域替换，不要追加。** 否则旧框 + 新框会重复。草稿模式：`DELETE FROM question_boxes WHERE collect_task_id = ? AND page = ? AND question_id IS NULL` 后插入新检测结果；重框模式：按 `question_id` 删该题的框后插入（见上一条）。替换前若该页/该题已有手改过的框，弹一次确认“将用自动框替换当前页的手动框，确定吗”。**模型失败时不替换、不写占位框**（见 §1.3 的 DetectionResult 定稿）：检测失败只提示“自动检测不可用，请手动框选”，原有框保持不动。
- **详情页加“重新框选”入口。** 没有它，`slice_path` 只能生成一次，框表就是只写不读。入口位置：详情页题目信息区（与“看答案”同级的操作区），点后进修框编辑器（读 `page_image_path` + 同页全部 layer = 1 的框，见 §1.5.1），确认后重新裁剪覆盖 `slice_path`、更新框行。重框不改变题的其它字段（文件夹、错因、知识点不动）。重框模式下**禁用整页旋转**（见 §1.6）；取消语义见本节写入时机（丢弃本次修改或弹“保存/不保存”）。
- **重切图后的图片缓存：** 重新切图覆盖同名文件后，Flutter 的 `FileImage` 缓存可能仍显示旧图。定稿：重切图后调 `imageCache.evict(FileImage(File(slicePath)))`（或 `FileImage(...).evict()`）；若仍有残留，改用版本化文件名（`slices/<question-id>-v<次数>.png`，`slice_path` 跟着改，旧文件由孤儿清理扫掉）。二选一，先用 `evict`，实测无效再换版本化。页图替换（旋转烘焙后 `page_image_path` 变了）同样先 `evict` 再读（v2.1，P0-3）。
- **确认拆题的事务边界（与 §4.2 同一条）：** 建题 + 回填 `question_boxes.question_id` + 建拆分任务 + 删原任务，**四个步骤在同一个事务里**；切片写盘放在事务**前**，失败不写库（文件写盘不可回滚，顺序是：先写切片文件 → 再开事务写库；事务失败则切片成孤儿文件，由 §4.5 的孤儿清理扫掉；反过来先写库再写盘失败会留“有题无图”的坏记录，更糟）。新建的拆分任务行同样写 `source_path` / `created_at` / `page_count`（见 §1.2(b)）。

### 1.5.1 重框同页上下文（v2.1 补丁，P1）

- **问题：** v2.1 的重框入口只读 `page_image_path` + 该题的 `question_boxes` 行。一页多题时，用户看不到同页其他题的框，无法判断是否重叠；编辑器的重叠校验只对传入的框生效，新框可能压到其他题上。且确认后 `collect_task_id` 被置空，要查“同页其他框”只能通过 `questions.page_image_path` 反查，v2.1 没写明口径。
- **定稿：重框编辑器加载同页所有 layer = 1 的框**——目标题的框可编辑，其他题的框只读展示（灰色/锁定态，不可拖动、不可删除）；重叠校验对所有框生效，新框不许与其他题的框重叠（重叠时按现有规则提示“有框重叠了，请调开再确认”，阻断确认）。
- **页面分组键：`question.page_image_path`（同一页图路径）。** 不要只靠 `collect_task_id` 分组——确认后它是 NULL。实现：按 `page_image_path = ? AND question_id IS NOT NULL` 查同页已确认题的整题框（layer = 1），再加目标题自己的框（含其子框）；第 2 层框只加载目标题的（其他题的内框不展示、不参与校验）。
- **测试：** 一页 2–3 道题，重框其中一题，其他题框与切片不受影响，且新框不能与其他题框重叠（见 §8.2）。

### 1.6 页面旋转建模（v2 新增、v2.1 修订，P0-2/P0-3）

- **问题：** 修框编辑器支持“旋转整页”（`_rotatePage`，`collect_page.dart` L1174：`_pageRotation = (_pageRotation + 90) % 360`，框在内存里跟着转）。v1 没有存旋转角度：如果用户把页面转 90° 后确认，框坐标是旋转后的坐标系，但 `page_image_path` 仍是原图；按原图直接裁剪，切片会整体错位。另有两个 v2 没展开的盲区（CodeBuddy 二审 P0-2/P0-3）：① 单框旋转只是视觉旋转（`Transform.rotate`，`collect_page.dart` L974–977 注释自认“已知取舍”），`QuestionBox` 没有旋转字段；② `_pageRotation` 是编辑器全局一个值（L1004），不是按页存——第 1 页转 90° 后切到第 2 页，旋转值仍是 90°，第 2 页会被错烘焙；详情页重框一道题时再旋转页面，同页其他题的页图/框坐标/`slice_path` 全部错位。
- **定稿：确认时把旋转烘焙进页图，不存 `page_rotation` 列。** 两个备选里选后者，理由：烘焙后框坐标与页图永远在同一坐标系，下游（裁剪、显示、重框）全都不用再处理旋转角度；存 `page_rotation` 列则每个读图/裁剪点都要按角度换算，漏一处就是错位。具体做法：确认时若该页旋转角度 != 0，生成一张已旋转的页图（`pages/page-001-r90.png`，原页图保留不动），框坐标按旋转角度换算到新页图坐标系后入库，`page_image_path` 指向旋转后的页图；旋转 0° 时不生成新文件。重进修框时读到的页图已是正向，旋转状态从 0 开始。（注意：此处“不存 `page_rotation` 列”指的是已确认题/页图不存旋转列；**草稿阶段的按页旋转另存 `collect_tasks.page_rotations`**，见 §1.6.1，确认烘焙后即不再需要。）**旋转状态必须按页保存（`Map<int, int>`，页 → 角度），不能用一个全局 `_pageRotation`**（v2.1，P0-3）：按页保存后，切页时读该页的角度，确认时只烘焙有旋转的页。
- **单框旋转：禁用，只保留整页旋转（v2.1 定稿，P0-2；2026-11-13 Meng 已确认禁用，见 §6 第 10 条）。** 现状题级框右上角圆柄旋转只是视觉旋转（`Transform.rotate`，`collect_page.dart` L974–977 注释自认“已知取舍”），`QuestionBox` 没有旋转字段；框落库并拿去裁切片后，视觉旋转就变成 bug——用户看到框转了 30°，但 `x/y/w/h` 没变，裁出来仍是轴对齐矩形，与屏幕显示不一致。定稿：去掉/禁用单框旋转手柄，UI 上明确“框只能拖动/缩放，不旋转”；`QuestionBox` / `question_boxes` **不加** `rotation` 字段。若将来要恢复单框旋转，另立项（加 `rotation` 字段 + 旋转裁剪）。
- **重框模式下禁用整页旋转（v2.1，P0-3）。** 详情页重框一道题时再旋转页面，`page_image_path` 只更新这一题，同页其他题的页图/框坐标/`slice_path` 仍是旧坐标系，全部错位；“一题旋转、全页重切”的实现复杂度远超预期。定稿：重框编辑器不提供整页旋转入口。草稿编辑器内旋转按页保存、确认时按页烘焙；已确认的题不存在“再旋转页面”的场景——若将来要支持，须同时更新该页所有题的 `page_image_path`、框坐标与 `slice_path`，实施前另定。
- **页图替换后同样 evict 缓存（v2.1，P0-3）。** 旋转烘焙后 `page_image_path` 变了，`QuestionSlice` / `FileImage` 的缓存要 `evict` 再读（与 §1.5 重切图 evict 同一条规则）；否则详情页/错题本仍显示旧页图。
- **EXIF 方向：** 导入时归一化（见 §1.4），不进入旋转模型；页图文件本身永远是正向的（EXIF != 1 时已生成归一化副本）。
- **测试要求：** 加 90° / 180° / 270° 的裁剪测试——同一张页图、同一个框，三个角度确认后切片内容一致（旋转后裁出的题干文字方向正确）；另加“旋转 → 取消 → 重开”测试（见 §1.6.1：取消不烘焙旋转页图，`page_image_path` 仍指原页图，但 `page_rotations` 已保存；重开后按页恢复旋转，框与页图仍对齐）；**多页旋转测试**——第 1 页转 90°、第 2 页不转，确认后两页切片都正确（不共用一个全局 `_pageRotation`）；**单框旋转禁用测试**——旋转手柄不存在/不可用（若将来恢复单框旋转，改测旋转 30°/90° 后切片与屏幕显示一致）。

### 1.6.1 草稿旋转持久化（v2.1 补丁，P0——唯一剩下的 P0）

- **问题：** v2.1 定了旋转按页存进内存 `Map<int, int>`、确认时烘焙进页图，但没落库；测试还写“旋转后取消再进：取消不写旋转后的页图，`page_image_path` 仍指原页图”。后果：用户在草稿修框里把第 1 页转 90°，点取消/关闭，按 §1.5 保存了旋转后坐标的框；下次“继续修框”重新打开，页图是原图（没有旋转），框却是旋转后的坐标——框与页面对不上，再确认就会裁错。
- **定稿（两个备选里选前者，理由：改动最小，不新增表）：给 `collect_tasks` 增加 `page_rotations TEXT`（JSON，如 `{"1": 90, "2": 0}`，默认 `'{}'`），草稿保存框时一起保存旋转。** 备选后者是新增 `collect_task_pages(collect_task_id, page, image_path, rotation)`（更干净但多一张表，同时解决草稿页图路径和按页旋转）——本次不采用，若将来草稿页图路径也要持久化，再迁这张表。
- **读写规则：** 草稿保存（关闭/取消/切页/确认，见 §1.5）时，把当前 `_boxesByPage` 的框与当前各页旋转角度一起写库（同事务：`question_boxes` 按 §1.5 草稿作用域替换 + `collect_tasks.page_rotations` 更新）；重开“继续修框”时先读 `page_rotations` 按页恢复旋转（内存 `Map<int, int>` 从该字段初始化），再显示框；确认时按最终角度逐页烘焙页图（见 §1.6），烘焙后该任务的 `page_rotations` 不再使用（任务确认后即删，框已随题走）。
- **与“不存 `page_rotation` 列”不矛盾：** §1.6 的“不存 `page_rotation` 列”指的是已确认题/页图不存旋转列；`page_rotations` 只活在草稿阶段（`collect_tasks` 行上），确认后任务删除、字段随之消失。
- **测试要求（改写 §1.6 的旧测试）：** 把“检查 `page_image_path` 是否原图”升级为“**旋转 → 取消 → 重开 → 框与页图仍对齐**”（当前 P0 的直接验收）：第 1 页转 90° → 点取消 → 重开“继续修框” → 页图仍按 90° 显示、框与页图对齐；`page_image_path` 仍指原页图（取消不烘焙）；确认后切片内容正确。

### 1.7 风险

| 风险 | 说明 |
|---|---|
| 磁盘占用翻倍 | 原文件副本 + 页图 + 切片三份。50MB PDF 渲成多页 PNG 可能上百 MB；手机拍的 20MB 图片再转 PNG 更大（v2 已改为照片默认保留原图，见 §1.4，但 PDF 页图仍是 PNG）。须在设置“数据”组现有“缓存清理”旁加**空间占用显示与清理入口**（只删孤儿文件，不删在用文件；见 §4.5），并在导入超限提示里说明。 |
| 库与文件分离 | 用户用设置“改数据库位置”搬库时，`migrateToDirectory` 现只复制 `quiz-master2.db`（+ `-wal` / `-shm`），**不搬 `imports/` 与 `slices/`**。搬库后题还在、图全丢。必须把文件目录纳入迁移（见 §4.6：staging + 原子替换，失败则整个迁移回滚）。 |
| 路径存相对还是绝对 | 提案存**相对数据目录的路径**（如 `imports/<task-id>/original.pdf`），读取时拼 `dataDirectoryPath()`。绝对路径在换盘符、换电脑、改库位置后全失效；相对路径要求“文件目录永远跟着数据库走”这条不变量被所有搬库/备份/恢复路径遵守；另须统一 resolver 并禁止 `..` 越出数据目录（见 §4.6）。 |
| 备份不含文件 | 现有备份只是 12 张表的 JSON（见 §2），恢复后 `slice_path` 指向的文件不存在。恢复流程必须处理缺文件（见 §2.3）。 |
| 旋转烘焙多一份页图 | 每次旋转确认多存一张旋转后的页图（§1.6）；原页图保留作“原件”。单页多转几次只保留最后一次的旋转图，旧旋转图由孤儿清理扫掉；不因此改存储上限的提案值。 |

### 1.8 是否影响老用户数据

- **没有老用户数据。** 老库直接删除，老题（`questions` 已有行）、老收集任务、演示题全部随库删除；新库从空开始（见 §6 第 1 条）。
- `page_rotations` 无回填问题（新任务新建时写实，老任务不存在）。

### 1.9 实施顺序建议（本节内）

§6 已定（文件布局、PDF 接受与限额见 §6 第 2、3 条）→ 先做 §4 加固 → 再做 §2 的删库建库 → 再接导入复制与框表写入 → 最后接切片生成与各页读图。不要先写读图 UI 再补落盘，否则 UI 又要对着不存在的文件画占位。框的写入时机（§1.5）与旋转烘焙（§1.6）随修框编辑器的接线一起做，不要拆成两批。PDF 渲染选型是 P2 的前置（见 §7）。

---

## 2. 版本：v2 从空建库（老库直接删除，不迁移）

### 2.1 改什么

- `OpenDatabaseOptions(version: 2, onCreate: _onCreate)`，**不补 `onUpgrade`**（§6 第 1 条：老库直接删除，不迁移）。`_onCreate` 直接建 **v2 全量结构**：`questions` 含 §1.2 的 7 列、`collect_tasks` 含 `source_path` / `created_at` / `page_rotations`、`question_boxes` 表及四个索引、多值字段用 §3 的 JSON 编码。
- **新库从空开始，不预置演示数据**（§6 第 1 条，2026-11-13）：`is_demo` 演示题不建。学科/知识点树等产品预置项仍按既有 `_onCreate` 种子写入（不是演示数据；种子里的多值字段直接用新 JSON 编码，不必先写旧编码再迁移）。
- `settings` 表写 `schemaVersion = '2'`（与备份里的版本号同一口径，见 §2.3；与 `PRAGMA user_version` / sqflite 的 `version` 参数是两回事，别混用——sqflite 的 version 是打开时驱动的，`settings.schemaVersion` 是给备份/恢复与排障看的）。
- 首次启动流程见 §2.2（删老库 → `_onCreate` 建新库）。
- `onDowngrade`：仍直接抛错并提示“请用新版打开”，不许静默删库重建（若旧版应用打开 v2 库）。

### 2.2 老库处理：直接删除（§6 第 1 条已定，2026-11-13）

- v2 首次启动：判断数据库文件是否存在；存在 → 删除 `quiz-master2.db`（+ `-wal` / `-shm`，若存在）→ `_onCreate` 建 v2 新库。不存在 → 全新安装，直接 `_onCreate`，跳过删除。
- 删除不可逆；v1 从未发布、只有 Meng 本人在用，无其他用户数据。删除前是否加一次确认提示，实施时按既有删除确认惯例处理（本文档不另定）。
- 删除失败（文件被占用、权限不足）→ **拒绝打开并报错**，不许在老库尚在的情况下建新库（避免新旧库并存、读写串库）；下次启动重试删除。
- **以下原内容全部删除（§6 第 1 条决定后没有老数据了）：** `onUpgrade` v1→v2、六步 `.bak` 预检、v1 fixture 升级测试、老数据迁移（§3.3）、`_fromRow` 逗号兼容读、演示数据预置、`collect_tasks.created_at` / `source_path` 回填。**P1 工作量因此大幅缩小**（见 §7）。

### 2.3 备份 JSON：保持平铺 + `_meta` + `.qm2backup` 扩展名（v2 修订、v2.1 补扩展名，P1-1）

现状：`exportBackupJsonFrom` 只导出 12 张表（`backupTables`），顶层就是表名 → 行数组，没有任何版本字段；`importBackupJsonInto` 已是事务（先清 12 张表再插回，缺的表键跳过），但**不校验版本、不校验列**，旧备份插进新库、新备份插进旧库都不会报错，只会静默丢数据或插错列。

**v2 定稿：保持表名平铺在顶层，额外加 `_meta`。** v1 提案的嵌套结构 `{ schemaVersion, appVersion, exportedAt, tables: {...} }` 被 CodeBuddy 否掉：当前 v1 的 `_pickRestoreFile` 会校验顶层 `questions` / `subjects`，v2 嵌套备份在 v1 上会被拒绝（不会静默清空，但用户会看到“不是备份文件”）；更老的版本如果校验较松，风险更大。平铺 + `_meta` 的好处：旧版至少能识别表名，不会因为找不到 `tables` 而完全无法处理。

```json
{
  "_meta": { "schemaVersion": 2, "appVersion": "0.1.0+1", "exportedAt": 1730000000000 },
  "subjects": [ … ],
  "questions": [ … ],
  "question_boxes": [ … ]
}
```

- `backupTables` 加 `question_boxes`，变为 13 张表；恢复时清表顺序里 `question_boxes` 放在 `questions` 之前清、之后插（外键是逻辑上的，没有声明 FK，顺序只是为可读性）。`_meta` 不是表，恢复时跳过（恢复的清表/插表循环只走 `backupTables` 里的表名，不把 `_meta` 当表处理）。
- **扩展名与 v1 兼容（v2.1，P1-1）：先写明事实——v1 从未发布，只有 Meng 本人在 Win11 上用，不存在老用户拿 v1 读 v2 备份的场景，故“v1 未发布，不考虑旧版恢复”。** 双保险：v2 备份换扩展名 **`.qm2backup`**（v1 的文件选择器只允许 `.json`，正常流程下选不到 v2 备份文件）；导出时提示“此备份仅新版可恢复”。若用户强行改后缀用 v1 打开，恢复校验（`_meta.schemaVersion > 2` 拒绝，见下）仍会挡住，不会静默读坏。
- **恢复选择器（v2.1 补丁，P2；§6 第 1 条后修订）：** `_pickRestoreFile` 的 `allowedExtensions` 只含 `.qm2backup`（v2 备份）；v1 备份不再支持恢复（v1 从未发布、老库已删，不存在合法的 v1 备份），`.json` 不再列入恢复选择器。导出 `.qm2backup` 时文件名、提示文案、备份测试同步改（见 §8.2）。`_meta.schemaVersion` 缺失 → 拒绝恢复（见下）、`> 2` 拒绝、恢复后 `settings.schemaVersion` 写回 2。
- 恢复规则（写进代码，不只写文档）：
  - **恢复前必须先校验，再清表。** 校验顺序：① JSON 合法（`jsonDecode` 通过）；② `_meta.schemaVersion` 存在且为整数（缺失 → 按 v1 备份处理，见下）；③ 关键表齐全（`subjects` / `questions` 为数组，行是对象）；④ 每行是对象、主键列存在。任一步不过 → **拒绝恢复，一律不动原库**，并提示具体原因（不是笼统的“恢复失败”）。这是 v1 §2.4 就定的规则，v2 再强调一次：**先校验再清表**，校验不过就不动原库。
  - `_meta` 缺失 → **拒绝恢复：v1 备份不再支持**（v1 从未发布、老库已删，不存在合法的 v1 备份；见 §6 第 1 条）。
  - `schemaVersion == 2` → 直接恢复。
  - `schemaVersion > 2`（未来新版备份拿到旧版应用上）→ **直接拒绝恢复**，提示“备份来自更新的版本，请先更新应用”，不许部分恢复。
- **备份仍不含图片文件。** JSON 备份恢复后，`source_path` / `page_image_path` / `slice_path` 指向的文件大概率不存在。已定：P3 做含文件的 zip（见 §6 第 5 条）；**做 zip 时**，注意两点：① **zip slip**——解压时校验每个条目的路径，禁止 `../` 穿越出数据目录（与 §4.6 同一条规则）；② 恢复失败的文件回滚——先解压到 staging 目录，校验通过后再原子替换，失败则删 staging、不动原文件。② 与 §4.6 的迁移回滚是同一套做法。
- 恢复的 `delete` 清单与 `backupTables` 是两份手写清单的问题（CodeBuddy P0-5 附带）：v2 定稿——恢复时只按 `backupTables` 一份清单走（清表、插表都以它为准），删掉另一份手写清单；`_confirmRestore` 的 `finally` 之外要加 `catch`，恢复失败要向用户报错（现在失败是静默的）。

### 2.4 风险

| 风险 | 说明 |
|---|---|
| 删老库时断电 / 崩溃 | 删除是单文件操作；删一半失败 → 老库文件可能残留，下次启动重试删除，拒绝打开、不建新库；不许新旧库并存。`.bak` + 事务回滚不再适用（无升级）。 |
| 建表时的 SQLite 限制 | 新库直接按 v2 全量建表，不走 `ALTER TABLE`；将来 v3 若要改列，仍受 `ALTER TABLE` 限制（删列/改类型须重建表），届时另写方案。 |
| 旧版应用打不开新库 | 没有 v2 → v1 的降级路径；`onDowngrade` 直接抛错并提示“请用新版打开”，不许静默删库重建。用户若在两台电脑 / 新旧安装包之间来回用同一个库文件，旧版打开 v2 库会报错。须在更新说明里写明“v2 库请勿用旧版打开”。 |
| 备份恢复整体覆盖的破坏力 | 现有恢复就是“先清 12 张表再插回”，一旦备份文件损坏、版本不对，当前库已被清空。v2 恢复必须改成：**先校验（版本 + JSON 合法 + 关键表齐全）再清表**，校验不过一律不动原库。 |

### 2.5 是否影响老用户数据

- **没有老用户数据。** 老库直接删除，老题、老学科、老文件夹、老复习记录、老收集任务、演示题全部随库删除；新库从空开始（见 §6 第 1 条）。
- v1 备份不再支持恢复（见 §2.3）；v2 备份（`.qm2backup`）可恢复到 v2。
- 删除失败时：老库原样保留，应用拒绝打开并报错，下次启动重试删除。

### 2.6 实施顺序建议（本节内）

先做 §4 的加固（`jsonEncode`、事务、UPDATE-first），因为后续步骤本身就要用它们 → 再做备份版本字段（先加后用：新备份带 `_meta`）→ 再删老库建 v2 新库（§2.2，无迁移）。不要先建库再修备份，否则当天的备份是无版本、不可恢复的。**P1 因此大幅缩小：无 `onUpgrade`、无老数据迁移、无迁移报告、无 `.bak` 预检**（见 §7）。

---

## 3. 多值字段：逗号拼串改 JSON 还是关联表

### 3.1 现状盘点（v2 修订：全部读写点清单，逐个核对过 `database.dart` 与 `models.dart`）

v1 只列了 7 个字段、说“五处读写点集中改”，是错的。CodeBuddy 核对后，实际写点至少还有下面这些——**只要漏一处，执行“删文件夹 / 改标签 / 删知识点 / 删章节”后，JSON 列就会被写回逗号串，下一次读取直接解析失败或变成一项。** v2 的清单以本节为准，实施时逐项打勾：

| # | 位置 | 字段 | 现状编码 | 值里能不能含分隔符 |
|---|---|---|---|---|
| 1 | `questions.folder_ids`（`_toRow` / `_fromRow`） | 文件夹 id 列表 | `join(',')` / `split(',')` | 不能。id 是 `folder-<学科>-<名>` 这种程序生成值，不含逗号。 |
| 2 | `questions.knowledge_ids`（`_toRow` / `_fromRow`） | 知识点 id 列表 | 同上 | 不能。id 为程序生成值。 |
| 3 | `questions.error_types`（`_toRow` / `_fromRow`） | 固定枚举 | 同上 | 不能。枚举值是 `审题失误 / 概念不清 / 计算错误 / 方法不会 / 其他`，无逗号。 |
| 4 | `questions.custom_error_types`（`_toRow` / `_fromRow`） | 用户自定义错因 | 同上 | **能。** 用户自由输入，完全可能含逗号（如“计算错误，粗心”）。 |
| 5 | `questions.tags`（`_toRow` / `_fromRow`） | 标签名列表 | 同上 | **能。** 标签名是用户自由输入（`insertTag` 不校验逗号），含逗号的标签会被拆成两个。 |
| 6 | `cause_records.remedy_history`（`upsertCauseRecord` L531 / `_causeFromRow`） | 补救历史列表 | `join('\n---\n')` / `split('\n---\n')` | **能。** 补救是用户自由写的文字，含换行 + `---` 并不罕见。 |
| 7 | `review_state.queue`（`saveReviewState` L557 / `loadReviewState`） | 复习队列 | `join(',')`，项是 `"questionId\|cause"`（`models.dart` 注释） | **能，且有两层分隔符。** `cause` 是错因字符串（固定枚举或自定义），自定义错因可含 `,` 与 `\|`；解析时按第一个 `\|` 切分只是约定，`cause` 里一旦有 `\|` 就切错。 |
| 8 | `deleteFolder`（`database.dart` L692） | 改某题的 `folder_ids` | `rest.join(',')` 直接写回 | 同 1（程序生成 id，拆分无损；但**编码必须统一**，否则该列一半 JSON 一半逗号串）。 |
| 9 | `renameTag` / `deleteTag`（L733 / L746） | 改某题的 `tags` | `tags.join(',')` 直接写回 | 同 5（**能含逗号**，漏改即错）。 |
| 10 | `deleteKnowledgePoint` / `deleteChapter`（L825 / L860） | 改某题的 `knowledge_ids` | `kps.join(',')` / `kept.join(',')` 直接写回 | 同 2（程序生成 id，拆分无损；编码须统一）。 |
| 11 | `_seedCauseRecordsFor`（L270） | 新题种子记录的 `remedy_history` | 写 `''`（空串） | 空串不是合法 JSON 数组；v2 改写 `[]`（见 §3.2）。 |

另：`collect_page.dart` 的 `_importFiles` 里 `saveRecentTask(title: paths.map(…).join('、'))` 用顿号拼多个文件名——那是展示用字符串，不入库做列表，不在本次范围。

### 3.2 选型结论

**全部 11 处改 JSON TEXT（`dart:convert` 的 `jsonEncode` / `jsonDecode`），不建关联表。**

理由：

- **值里含分隔符的字段（`tags` / `custom_error_types` / `remedy_history` / `review_state.queue`）用任何分隔符方案都修不好**，换分号、换 `\u0001` 都是把问题往后推——用户总能输入下一个分隔符。JSON 是唯一“值里含什么都不怕”的编码。
- **查询模式不需要关联表。** 现状所有筛选（错题本按文件夹/标签/学科/试卷/时间、复习按错因/学科、报告按错因/知识点统计）都是把 `allQuestions()` / `allCauseRecords()` 全读进内存后在 Dart 里过滤（`repository.dart` 的 `dueToday` / `subjectCounts` / 各 `where` 均如此）。没有任何一处用 SQL 的 `WHERE folder_ids LIKE …` 查多值字段。关联表带来的 SQL 查询能力目前用不上，却要多 5 张 junction 表 + 每次读写多 5 次联动 + 迁移多 5 张表的回填。
- **改动面最小、回滚最易。** 列名、列类型（`TEXT`）都不变，只换单元格里的编码；§3.1 的 11 处读写点集中改，测试可逐字段覆盖。
- **被否掉的备选：** 关联表（`question_folders` / `question_knowledge` / `question_tags` / `question_error_types` + `cause_remedies` / `review_queue`）：关系上最干净，支持 SQL 级联删除与按标签 SQL 查询；但本应用是单人本地库、全量读内存过滤，收益在可预见的将来为零，代价是迁移与读写代码翻倍。**将来若出现 SQL 级筛选需求（如题量上万后内存过滤变慢），再迁关联表；届时 JSON 数组是结构化数据，可直接生成 junction 行，比逗号串好迁得多。** 这条写下来当作未来的升级路径，不是现在的决定。

**收口规则（v2 新增，P0-4，强制）：**

- 数据层收口四对编解码函数，**所有读写点统一调用，不许在业务代码里再出现裸 `join(',')` / `split(',')`**：
  - `encodeStringList(List<String>)` / `decodeStringList(String?)`——供 `folder_ids` / `knowledge_ids` / `error_types` / `custom_error_types` / `tags` 五列；
  - `encodeRemedyList(List<String>)` / `decodeRemedyList(String?)`——供 `remedy_history`（与字符串列表同构，单列一对函数是为了将来补救条目变对象时只改一处）；
  - `encodeQueue(List<ReviewQueueItem>)` / `decodeQueue(String?)`——供 `review_state.queue`（对象数组，见 §3.4）。
  - 空串 `''` 与 `NULL` 统一解码为 `[]`；编码空列表写 `[]`，**不写 `''`**。
- `_seedCauseRecordsFor` 写 `[]` 而不是 `''`（§3.1 第 11 项）。
- **输入限制补充（§6 第 4 条，已定，2026-11-13）：** 仅在标签名和自定义错因名两个字段禁 `,` `，` `|` 三个分隔符，输了提示“不能含逗号或竖线”；不禁全部特殊符号（数学、英文、中文标点、表情都允许）。JSON 本身已解决值里含分隔符的问题，输入限制只是额外的前端防护，不是 JSON 的替代品。
- **实施后全仓库 grep `join(',')` / `join('\n---\n')` / `split(',')`：除编解码函数内部与展示用字符串外，应为 0 处。** 这条写进 P0 的验收清单。

### 3.3 老数据迁移办法：无（§6 第 1 条决定后没有老数据）

本节原内容（老行逐行读出 → 逗号串转 JSON → 写回、含逗号值的语义拆分、迁移报告、升级后一次提示）已随 §6 第 1 条“老库直接删除、不迁移”的决定**全部删除**。老库随文件一起删除，没有老行需要迁移；含逗号的标签/自定义错因也不存在“拆分后语义变了”的问题——新数据从一开始就是 JSON 编码。

两点保留说明：

- **新数据的含分隔符值不再是问题。** 标签/自定义错因/补救文字里含逗号、`|`、`---`，JSON 编码照常存取，不拆错。另见 §6 第 4 条的输入限制补充（已定）：仅在标签名和自定义错因名两个字段禁 `,` `，` `|`，输了提示“不能含逗号或竖线”——那是额外的前端防护，不是 JSON 的替代品。
- **`_fromRow` 不做逗号兼容读。** 原定的“`jsonDecode` 失败退回 `split(',')` 再读一个版本、v3 删掉”已删除——没有老数据、没有 v1 备份需要兼容，读侧只认 JSON；读到非法值直接按数据损坏处理，不猜。

### 3.4 复习队列模型改 `ReviewQueueItem`（v2 新增，P0-5）

- **问题：** 只换 `review_state.queue` 的数据库编码不够。当前 `ReviewSessionState.queue` 是 `List<String>`，复习页用 `split('|')` 解析（`review_page.dart` L300 `_blocksFromFlat`、L303 `entry.split('|')`、L514 `_flatQueue`）。如果数据库里的 queue 改成 JSON 对象数组，但模型仍是 `List<String>`、加载后又拼回 `qid|cause`，那么自定义错因里含 `|` 的问题仍然存在——编码换了，模型没换，等于没修。
- **定稿：** 引入 `ReviewQueueItem { questionId, cause }`（`models.dart`，两个 `String` 字段，`==` / `hashCode` 照现有模型模式），`ReviewSessionState.queue` 改 `List<ReviewQueueItem>`。同步改：`saveReviewState` / `loadReviewState`（`database.dart`，走 `encodeQueue` / `decodeQueue`）、`_flatQueue`（返回 `(List<ReviewQueueItem>, int)`）、`_blocksFromFlat`（入参改 `List<ReviewQueueItem>`，删掉 `split('|')`）、相关测试（`review_page_test` 里手写 `queue: ['q1|审题失误']` 的用例全部改构造 `ReviewQueueItem`）。
- **迁移：无。** 新数据从一开始就是 JSON 对象数组，不存在 v1 逗号串需要转换（老库已删，见 §6 第 1 条；§3.3 原迁移办法已删除）。
- **连带：** `deleteQuestion` 从 `review_state.queue` 里去掉该题的项（§4.5）时，按 `questionId` 匹配，不再拼字符串比对。

### 3.5 风险

| 风险 | 说明 |
|---|---|
| 含分隔符值的新数据 | 新数据从一开始就是 JSON 编码，值里含逗号 / `\|` / `---` 不拆错；另见 §6 第 4 条的输入限制补充（已定）。老数据不存在，§3.3 原迁移办法已删除。 |
| 备份恢复的编码识别 | 无 v1 备份需要识别：`_meta` 缺失 → 拒绝恢复（见 §2.3）；`schemaVersion == 2` 直接恢复，`> 2` 拒绝。恢复函数里不要“试 `jsonDecode`，失败再 `split`”这种猜测——按版本号走，不猜。 |
| 漏改一处写点 | §3.1 的 11 处只要漏一处，JSON 列就会被写回逗号串。验收必须含：删文件夹、改标签、删标签、删知识点、删章节后重新读题仍能正确解析（见 §8 测试清单）；另全仓库 grep 裸 `join(',')` 应为 0 处（§3.2 收口规则）。 |
| 体积微增 | JSON 的引号与括号比逗号串略大；题量级（个人错题本，千级）可忽略。 |

### 3.6 是否影响老用户数据

- **没有老用户数据。** 老库直接删除，无迁移、无数据损失问题（见 §6 第 1 条）；§3.3 原迁移办法已删除。

### 3.7 实施顺序建议（本节内）

先写纯函数版编解码（可单测：`encodeStringList` / `decodeStringList` / `encodeRemedyList` / `decodeRemedyList` / `encodeQueue` / `decodeQueue`），再接进各读写点；`ReviewQueueItem` 模型改动与编解码同一批做，不要先换编码再换模型。本节与 §2 的删库建库无依赖（新库从空开始，新数据直接用 JSON 编码），可随 P0 加固一起做。

---

## 4. 数据层加固

以下 5 项**都不需要改 Schema**，可独立于 §1–§3 先做；其中 4.1、4.3、4.4 是 §2 迁移的前置（迁移函数本身会用到事务与 `jsonEncode`）。v2 新增 §4.6（文件迁移与路径安全）。

### 4.1 `AppDatabase.db` 缓存 `Future<Database>`，消并发竞争

- **改什么：** 现状 `Future<Database> get db` 是 `if (_db != null) return _db!; … _db = await factory.openDatabase(…)`。两个调用方同时 `await db` 时都看到 `_db == null`，都会执行 `openDatabase`，后完成的覆盖 `_db`，先完成的连接泄漏（没人持有、没人关闭），两个连接同时写同一 SQLite 文件。改为缓存 Future 本身：
  ```dart
  Future<Database>? _dbFuture;
  Future<Database> get db => _dbFuture ??= _openDb();
  ```
  `_openDb()` 里做现在的建目录 / 打开 / fallback 逻辑；打开失败时把 `_dbFuture` 置空（否则失败的 Future 会被永久缓存，之后每次都返回同一个错误）；`migrateToDirectory` 里 `close()` 后同时清 `_db` 与 `_dbFuture`（现状只清 `_db`，`_dbFuture` 若已缓存会继续返回已关闭的库）。
- **为什么：** 应用启动时首页、收集、复习等多个模块几乎同时 `await db`，竞争不是理论上的，是每次启动都发生的。sqflite_ffi 的多连接写同一文件在单用户场景下多半“碰巧没事”，一旦出现就是偶发数据库锁 / 写丢失，极难复现。
- **风险：** 低。只改 getter 与 close 点；`dbPathUsed` 的赋值时序不变。注意 `_openDb` 里的 fallback（数据目录不可写时回退到可执行文件同级 `data/`）仍在 Future 内完成，失败重试时重新走 fallback 判断。
- **是否影响老用户数据：** 不影响。只改连接获取方式，不改数据。
- **实施顺序：** 第一批做（§4 里最先），因为它是所有事务性改动的前提。

### 4.2 `recordSelfCheck`、`deleteSubject` / `deleteFolder` 加事务

现状与改法（逐个核对过代码）：

| 方法 | 现状（非原子） | 改法 |
|---|---|---|
| `repository.recordSelfCheck` | 三次独立写：`upsertCauseRecord`（改状态/计数/复查日）→ `addCauseCheckHistory`（插 `review_history`）→ `upsertQuestion`（`reviewCount + 1`）。中间崩溃/抛错会留下“状态已变、历史没记、次数没加”的半截记录；报告的复查通过率按 `review_history` 算（`repository.dart` 注释），半截状态会让报告与列表对不上。 | 在 `AppDatabase` 加一个事务入口（如 `recordSelfCheckTxn`），三步用同一个 `Transaction` 对象做；`repository` 只算新值、不直接写。注意 `upsertCauseRecord` 里调了 `bumpBadgeVersion()`（通知外壳重查角标）——事务内不要调 UI 通知，提交成功后再调一次。 |
| `AppDatabase.deleteSubject` | 循环删 `cause_records` → 删 `questions` → 删 `folders` → 删 `knowledge_points` → 删 `subjects`，无事务；中途抛错会留“题删了、学科还在”或反过来的半截状态。另见 §4.5 的级联缺口。 | 整个方法包进 `db.transaction`。 |
| `AppDatabase.deleteFolder` | 递归：每道题 `deleteQuestion` 或改 `folder_ids`，子文件夹递归再调自己，最后删 `folders` 行；全程无事务，且每题都是一次全表读（`d.query('questions')` 无条件）。中途失败会留“部分题已删、文件夹还在”。 | 递归函数改传 `Transaction txn` 进去，不在递归里开新事务（sqflite 不支持嵌套事务，递归里再 `transaction` 会抛错或死锁——这是实施时要特别注意的点）；顶层一次 `db.transaction` 包住整棵子树。 |
| 附带：`deleteChapter` / `deleteKnowledgePoint` / `renameTag` / `deleteTag` / `clearDemoData` / `importBackupJsonInto` | 同样是“多步写、无事务”（逐题改 `knowledge_ids` / `tags`）。`importBackupJsonInto` **已有**事务，是正面先例。 | 与上面同一批改：凡是“读全表 → 逐行改/删”的方法，一律包事务。`clearDemoData` 另见 §4.5。 |
| 附带：修框确认（`_openBoxEditor` 的拆题循环） | 确认后循环 `save(Question)` + `saveCollectTask`，无事务；中途失败会留“部分题已建、原任务还在/已删一半”。 | 与 §1.2(c) 的回填同一次事务：建题 + 回填 `question_boxes.question_id` + 建拆分任务 + 删原任务，四步同事务；切片写盘在事务**外**先行（见 §1.5）。 |

- **风险：** 中等。事务持有期间长（删学科/删文件夹树可能涉及数百行），会阻塞其他写操作；单用户本地应用可接受，但不要在事务里做文件 IO、不要在事务里 `await` 网络/检测。另：`bumpBadgeVersion()` 的调用点要从事务内移到提交后，否则角标会按半截状态刷新。
- **是否影响老用户数据：** 不影响正常路径的数据内容；只把“半截写坏”的可能性消除。失败时回滚，数据回到调用前。
- **实施顺序：** 在 §4.1 之后、§2 迁移之前（迁移本身就是事务）。

### 4.3 `upsertCollectTask` 改 UPDATE + `created_at` 稳定排序

- **改什么：** 现状 `upsertCollectTask` 用 `ConflictAlgorithm.replace`（先删后插）。`collect_tasks` 没有 `created_at` 列，`allCollectTasks` 靠 `orderBy: 'rowid DESC'` 排。REPLACE 会删掉旧行、插新行拿新 `rowid`——每次进度更新（`_simulateImport` 每 160ms 调一次 `saveCollectTask`，将来真实导入也是高频更新进度）都会把这行顶到最上面，任务列表在导入过程中会自己跳序。改法照 `upsertSubject` 已有的正面先例（`database.dart` 注释写明了 REPLACE 会把行顶到表尾导致学科乱序，所以改 UPDATE-first）：先 `UPDATE … WHERE id = ?`，影响 0 行再 `INSERT`。同时加 `created_at` 列（§1.2(b)），`allCollectTasks` 改 `ORDER BY created_at DESC, rowid DESC`（`created_at` 相同——同毫秒建的批量任务——时 `rowid` 兜底）。
- **为什么：** 同一个 bug 在 `subjects` 上已经修过一次（`upsertSubject`），`collect_tasks` 是同一个写法，没修。任务列表跳序在真实导入（多文件排队、进度高频更新）时会稳定复现。
- **风险：** 低。`UPDATE` 与 `REPLACE` 在字段全量覆盖时结果一致；唯一差别是 `rowid` 不变——这正是要的。另：`upsertQuestion` 与 `upsertCauseRecord` 也是 REPLACE，但 `questions` 按 `created_at DESC` 排、`cause_records` 按 `joined_at ASC, id ASC` 排，`rowid`/`id` 变化不影响可见顺序；`cause_records` 的自增 `id` 被 REPLACE 后会变大，但没有任何地方按 `id` 做业务排序（`causeRecordsForQuestion` 按 `id ASC`，同一题的记录重建后顺序可能微变——可接受，顺手改 UPDATE-first 更干净，列为可选）。
- **角标刷新节流（v2 新增，其他-5）：** `bumpBadgeVersion()` 现在散在 8 处调用点（`database.dart` L536 / 628 / 644 / 675 / 708 / 869 / 876 / 926），真实导入/复制进度如果高频 `saveCollectTask`，每次都会触发 `_refreshBadges` 的 5 个查询。定稿：**只在状态变化时 bump**（`status` / `pageCount` / 任务增删时 bump，纯进度百分比更新不 bump），或对角标刷新做 debounce（300ms 内多次调用合并一次）。二选一，实施时定；不要在进度回调里每次都 bump。
- **是否影响老用户数据：** 不影响。新库无老任务，无回填；`created_at` 在新建任务时写实。
- **实施顺序：** 与 §4.1 同批（无 Schema 依赖的部分：UPDATE-first 可先做；`created_at` 列与排序改法随 §2 升级一起上）。

### 4.4 备份手写 `_jsonValue` 改 `dart:convert` 的 `jsonEncode`

- **改什么：** 现状 `exportBackupJsonFrom` 用手写 `_jsonEncode` / `_jsonValue`（`database.dart` 末尾）。它只转义了 `\`、`"`、`\n` 三种，**漏了 `\r`、`\t`、`\b`、`\f` 与其它控制字符（`\u0000`–`\u001F`）**，键名也不转义。一个补救文字、笔记、标签里含制表符或回车，导出的备份就是**非法 JSON**，`importBackupJson` 的 `jsonDecode` 会直接抛错——备份导得出、恢复不了，是最坏的那种备份 bug。改为 `jsonEncode(out)`（`dart:convert`，Flutter 自带，无新依赖）。`_jsonValue` / `_jsonEncode` 删掉。
- **为什么：** 手写 JSON 编码器没有存在的理由；标准库处理了全部转义与 Unicode。现状 12 张表的值全是 `String` / `int` / `null` / `List` / `Map`，`jsonEncode` 全覆盖。
- **风险：** 低。输出从“手写格式”变为“标准库格式”，语义相同的 JSON；唯一差别是标准库会对控制字符做 `\uXXXX` 转义，旧版手写导出器漏转义的字符在新版里会被正确转义——这是修复，不是行为变更。**但要注意：** 用户手里已有的旧备份文件若含未转义的控制字符，用新版 `jsonDecode` 恢复时会失败（见 §2.4 的“先校验再清表”——校验不过就不动原库，并提示“这份备份文件本身已损坏”；不要试图写个容错解析器去猜坏 JSON）。
- **是否影响老用户数据：** 不影响库内数据；只影响备份文件的正确性（变好）。
- **实施顺序：** 第一批，与 §4.1 同批；§2.3 的备份版本字段依赖它（版本号要写进合法的 JSON 里）。

### 4.5 删除 / 清空补级联清理（孤儿行 + 孤儿文件）

逐个核对过现状的缺口（`deleteQuestion` / `deleteSubject` / `deleteFolder` / `clearDemoData` / `deleteCollectTask`）：

| 删除动作 | 现状已清 | 现状漏掉的孤儿 | 改法 |
|---|---|---|---|
| `deleteQuestion(id)` | `cause_records`、`questions` | `review_history`（该题的自查历史）；`collect_tasks.question_id`（指向它的任务）；`review_state.queue` 里的 `"id\|cause"` 项；将来 §1 落地后还有 `question_boxes` 行与 `slices/<id>.png` 文件 | 同事务内删 `review_history`、清 `collect_tasks.question_id`（置 `NULL`，任务本身保留）、从 `review_state.queue` 里去掉该题的项（v2：按 `ReviewQueueItem.questionId` 匹配，见 §3.4，不再拼字符串比对）、删 `question_boxes` 行（含该题的第 1 层框及其子框）；事务提交后删切片文件（文件删失败只记日志，不回滚数据库）。 |
| `deleteSubject(id)` | 该科 `cause_records`、`questions`、`folders`、`knowledge_points`、`subjects` | `review_history`（该科题的）；`collect_tasks`（该科的任务行）；`recent_tasks`（单行，若 `subject_id` 是该科）；`imports/` 下该科任务的目录与切片文件 | 同事务内补删上面三处；事务提交后删该科任务对应的 `imports/<task-id>/` 目录与 `slices/` 文件。**注意：** 删学科是不可逆的大动作，现状无二次确认文案之外的保护；文件删除放提交后，失败可事后由孤儿清理扫。 |
| `deleteFolder(f)` | 经 `deleteQuestion` 的题、子文件夹递归、`folders` 行 | 继承 `deleteQuestion` 的缺口；另：只移走关联（多文件夹的题）时不产生孤儿 | 随 `deleteQuestion` 的修复自动补齐；递归本身见 §4.2 的事务化。 |
| `clearDemoData()` | 演示题的 `cause_records`、演示题、`review_state`（整行清空） | 演示题的 `review_history`；演示题若有关联的 `collect_tasks`（现状演示题不是导入的，没有；将来若演示题也走导入流程，要补） | 同事务内删演示题的 `review_history`；`review_state` 整行清空的口径不变（演示题的断点本来就该清）。 |
| `deleteCollectTask(id)` | `collect_tasks` 行 | 将来 §1 落地后：该任务的 `imports/<task-id>/` 目录、未确认的 `question_boxes` 行；**但**若任务已确认拆题，页图可能还被已建的题引用（`page_image_path`），不能随任务删 | 删任务时：先查有无 `question_id` 已回填的框/已建的题；有 → 只删任务行与未确认的框（`question_id IS NULL` 的行），保留 `imports/<task-id>/` 目录；无 → 同事务删框行，提交后删整个任务目录。 |
| 设置“缓存清理”（已有入口，D-05 决策） | — | — | 加一档**孤儿文件清理**：扫描 `imports/` 与 `slices/`，删掉“没有任何 `questions` / `collect_tasks` / `question_boxes` 行引用”的文件与空目录；清理前报数量与大小，用户确认后执行。这是文件级联的兜底——上面各处漏删的文件最终都由它收敛。 |

- **风险：** 中等。级联删的每一步都要核对“是不是真没人引用了”：页图是多题共享的（同一页多道题），删题时**绝不能**删页图，只删该题自己的切片；`imports/<task-id>/` 目录只有在其任务下所有题都被删、且任务本身也被删时才能删。误删文件比留孤儿文件严重得多——孤儿文件只占空间，误删是丢数据。所以规则是：**宁留孤儿，不误删；孤儿由清理入口定期扫。**
- **是否影响老用户数据：** 清孤儿行不影响有效数据（孤儿行本来就查不到）；清孤儿文件只删无引用的文件。**但**：第一次上线级联清理时，老库里已有的孤儿行会被删掉——那是正确的清理，不是数据丢失；仍建议在更新说明里写一句。
- **实施顺序：** 数据库级联（孤儿行）与 §4.2 事务化同批；文件级联随 §1 的落盘一起上（没有文件就没有文件级联）；孤儿清理入口最后上。

### 4.6 文件迁移与路径安全（v2 新增，P1-4）

现状 `migrateToDirectory`（`database.dart` L113–144）只复制数据库文件；v2 要求 `imports/`、`slices/` 跟着库走，但以下四点 v1 没写，本节定稿：

- **目标目录已有文件时：覆盖 / 保留 / 取消，三选一问用户。** 与 B4.3 已有的数据库文件冲突处理一致（覆盖/保留/取消的对话框），文件目录沿用同一选择：选“覆盖”则目标目录的同名文件被替换；选“保留”则跳过已存在的文件（只复制缺失的）；选“取消”则整个迁移取消、不动原库与原文件。**不要**静默覆盖——用户目标目录里可能有另一个库的文件。
- **跨盘复制失败如何回滚：staging 目录 + 原子替换。** 定稿：先把 `imports/` 与 `slices/` 复制到目标目录旁的 staging 目录（`<目标>.staging-<时间戳>`），复制完成并校验（文件数与总字节数对得上）后，再原子替换（`rename` staging 为正式目录；若目标已存在同名目录，先 `rename` 到 `<目标>.old-<时间戳>`，替换成功后再删 `.old`，失败则把 `.old` 移回）。数据库文件本身仍按现有 `copyDatabaseFileTo` 走，但**目标已有数据库且用户选“覆盖”时，先把目标库备份到 `quiz-master2.db.old-<时间戳>`**（与文件目录的 `.old` 同一套做法；或把源库复制到 staging 文件、最后与文件目录一起原子替换——二选一，实施时定，效果相同）；迁移失败时把 `.old` 移回、**恢复目标旧库与旧文件目录**，而不只是保留源库。最后一步才写 `db_location.txt` 标记——**标记是提交点**：标记写之前任何一步失败，整个迁移视为未发生，staging 与 `.old` 全部清理，原库原文件原样不动。
- **大目录复制进度 / 取消：** 复制前先算总字节数，进度按字节回调进 UI（与 §1.4 的导入进度同一套进度回调）；用户取消 → 停在当前文件，删 staging，迁移取消，不动原库与原文件。不要在 UI 线程做复制（`compute` / isolate 或分片 `await`，实施时定）。
- **复制期间其他文件读取的并发行为：** 迁移期间应用处于“搬库中”状态：读图请求若命中正在复制的文件，读旧目录的副本（迁移完成前所有读路径仍指旧目录，标记写完后才切到新目录）；写操作（新导入、新切片）在迁移期间**暂停**（按钮置灰或排队），迁移完成后再放行。不要一边复制一边让新导入写进旧目录——那会丢文件。
- **路径安全（与备份恢复共用一条规则）：** `source_path` / `slice_path` / `page_image_path` 一律存相对路径，读取时走统一 resolver：`p.join(dataDirectoryPath(), relativePath)` 后做规范化校验，**禁止 `..` 越出数据目录**（规范化后必须以数据目录为前缀，否则按“文件缺失”处理并记日志，不许读盘）。zip 恢复（§2.3）解压时同样校验每个条目的路径，含 `../` 或绝对路径的条目直接拒绝整个恢复包（不许跳过坏条目继续解——跳过会让恢复结果不可预期）。

---

## 5. 不确定项（v2.1 补丁后只剩以下 5 条，其余已在改动清单里定稿）

1. **PDF 渲染选型未做。** 没有调研过 Dart/Flutter 可用的 PDF 渲染库（选型、Win11 可用性、渲染速度、50MB 大 PDF 的内存占用、是否需原生依赖）。PDF 已接受、限 50MB/20 页（§6 第 3 条，2026-11-13）；渲染是 P2 必需，不再是备选；导入时全渲还是按需渲待选型时定。实施前须单独做一次选型（可列入实施任务的第一步）。
2. **Win11 真机验证仍是空白。** `onnxruntime.dll` 是否随包打包、CPU 推理速度、SQLite 原生资源、字体/DPI（YOLO 报告 §8 与 R11 验收清单）都还没在 Win11 上验过。**本方案的全部存储设计都不依赖 Win11 的验证结果**，但切片裁剪用的图片解码（`dart:ui`）与 PDF 渲染在 Win11 上的表现，实施时须在 Win11 上复核。
3. **磁盘占用没有实测数。** 50MB PDF 渲成 PNG、20MB 手机照片转 PNG 各占多少，没有量过；§1.7 的“占用翻倍”警告是定性估计。实施时须用一张真实 50MB PDF 与一张 20MB 照片实测后，再定是否需要压缩（JPG 页图）或上限。
4. **图片转 JPEG/WebP 需不需要新依赖，未定。** §1.4 定了“照片页图默认保留原图”，若将来要统一转 JPEG/WebP（省空间、统一格式），`dart:ui` 只能输出 PNG，须引入图像编码依赖（选型未做）；在此之前不转码。PDF 页图是渲染库输出，不受此限。
5. **“设置单 owner”不在本文档范围。** CodeBuddy 复审提到的“设置单 owner”问题（多处直接写 `settings` 表）是另一批小正确性修复，与主链 Schema 无关，本文档不展开；实施主链时不要顺手改它。

（原第 7 条 `question_boxes.id` 命名规则已在 v2.1 补丁中定稿：`box-<taskId>-p<page>-<uuid8>`，见 §1.2(c)；原第 10 条单框旋转禁用已由 Meng 于 2026-11-13 确认，见 §1.6 与 §6 第 10 条。）

---

## 6. 需要 Meng 定的事

§6 九条已由 Meng 于 2026-11-13 全部定下；第 10 条已确认，留作记录。本节逐条记录决定内容，实施以本节为准：

1. **老库直接删除，不迁移（已定，2026-11-13）。** v2 首次启动时删除老 v1 库文件（含 `-wal` / `-shm`），直接 `_onCreate` 建 v2 新库；**不做 `onUpgrade`、不做老数据迁移**。新库从空开始，**不预置演示数据**（演示题也不建）。后果：老题、老学科、老文件夹、老复习记录、老收集任务全部丢弃——Meng 不需要演示数据；v1 从未发布，只有他本人在用，无其他用户数据。P1 工作量因此大幅缩小（见 §2、§7）。
2. **文件落盘布局按提案（已定，2026-11-13）。** 数据目录跟着数据库位置走，库搬家时文件一起搬（见 §4.6）；存储上限 **2GB**（见 §1.4、§6 第 9 条）。
3. **PDF 接受（已定，2026-11-13）。** 限体积与页数：单个 PDF 不超过 **50MB**（既有规则）且不超过 **20 页**，超了提示分批导入。渲染库选型成为 **P2 必需**（不再是“暂不支持”的备选），见 §1.4；渲染时机（导入时整本渲染 vs 按需渲染）待选型时定。
4. **多值字段 JSON 照做 + 输入限制做补充（已定，2026-11-13）。** JSON 编码照 §3.2 做；另加输入限制做补充——**仅在标签名和自定义错因名两个字段禁 `,` `，` `|` 三个分隔符**，输了提示“不能含逗号或竖线”；**不禁全部特殊符号**（数学、英文、中文标点、表情都允许，JSON 编码已保证数据正确）。注：JSON 本身已解决值里含分隔符的问题（见 §3.2），输入限制只是额外的前端防护，不是 JSON 的替代品。
5. **备份做含文件的 zip（已定，2026-11-13，P3）。** 文件级备份做 zip（JSON + `imports/` + `slices/`），恢复即完整；见 §2.3。
6. **页图缺失明确报错、不开编辑器（已定，2026-11-13）。** 修框入口显式报错，不打开编辑器；见 §1.3。
7. **老收集任务删除（已定，2026-11-13）。** 随老库一起删除；不需要“源文件缺失”标记、重新导入/删除流程。
8. **第 2 层切片未来再说（已定，2026-11-13）。** 不持久化，暂不议；整理页的题干/选项/配图切片区继续按需从页图 + 第 2 层框现裁（见 §1.4）。
9. **空间上限与清理口径同意提案（已定，2026-11-13）。** `imports/` + `slices/` 空间上限 **2GB** + 超限提示；孤儿清理定期提醒**开**；设置“数据”组加空间占用显示与孤儿清理入口（见 §1.4、§4.5）。
10. **单框旋转禁用（已确认，2026-11-13）：** 禁用单框旋转，只保留整页旋转；UI 明确框只能拖动/缩放、不旋转；`QuestionBox` / `question_boxes` 不加 `rotation` 字段。将来若要恢复单框旋转，另立项。

---

## 7. 建议的实施顺序（总览，v2.1 修订）

| 阶段 | 内容 | 依赖 / 前置 |
|---|---|---|
| P0（数据层加固，无 Schema，可先行） | §4.1 `Future<Database>` 缓存；§4.4 `jsonEncode`；§4.3 的 UPDATE-first（不含 `created_at` 列）+ 角标刷新节流；§4.2 事务化（`recordSelfCheck` / `deleteSubject` / `deleteFolder` / 各逐行改方法）；§4.5 数据库级联（孤儿行）；§3.2 编解码收口（纯函数 + §3.1 的 11 处写点全改）+ §3.4 `ReviewQueueItem` 模型 | 无。P0 做完即可单独提测、单独交付，不动用户数据格式。 |
| P0.5（图片链路小样） | 拿**一张真实图片**做最小闭环：复制 → 检测 → 修框 → 裁剪 → 存 PNG → **重启后读回**。验证：页图分辨率（长边 2000–3000）、旋转烘焙（90/180/270 裁剪测试）、`FileImage` 缓存（`imageCache.evict`）、页图格式（保留原图）。小样通过才进 P1；不通过先修小样，不许带着未验证的假设进迁移。 | P0。小样不写迁移代码、不动 Schema，只验证 §1.4–§1.6 的假设。 |
| P1（删库建库，无迁移） | §2 备份版本字段（平铺 + `_meta`，先加后用）→ §2 删老库 + `_onCreate` 建 v2 新库（无迁移、无演示数据）→ §1.2(a)(b) 的模型字段；§8 的 schema 结构测试随 P1 做 | P0、P0.5。P1 大幅缩小：无 `onUpgrade`、无老数据迁移、无迁移报告、无 `.bak` 预检。 |
| P2（主链打通） | §1.4 导入复制 + `source_path` 写入 + 真实进度（替换 `_simulateImport`）；修框读写 `question_boxes`（§1.5 写入时机、重检测按页替换、详情页“重新框选”入口）；确认时裁剪写 `slices/<question-id>.png` + 四步同事务；整理/详情/错题本读 `slice_path` / `page_image_path`，缺图回退占位 | P1；PDF 渲染选型（文首不确定项第 1 条）是 P2 必需的前置——PDF 已接受、限 50MB/20 页（见 §6 第 3 条），渲染落地前 PDF 分支先做图片。 |
| P3（收尾） | §2.3 的 zip 文件级备份（若 §6 第 5 条定做）；§4.5 文件级联 + 孤儿清理入口；§4.6 文件迁移（`migrateToDirectory` 搬文件目录）；空间占用显示 | P2；§6 的决定。 |

每阶段的验收（实施时再细化，不在本文档展开）：P0——并发打开单测 + `recordSelfCheck` 半截写单测 + 含控制字符的备份往返单测 + 11 处写点全改完（全仓库 grep 裸 `join(',')` 为 0 处）+ queue 含 `|`/逗号单测；P0.5——真实图片端到端小样 + 旋转裁剪测试 + 多页旋转测试（第 1 页转 90°、第 2 页不转，两页切片都正确）+ 重启读回；P1——删老库建新库单测（老库文件删除、新库从空开始、无演示题）+ v2 备份恢复单测 + `schemaVersion > 2` 拒绝恢复单测 + schema 结构测试（`_onCreate` 建出的表/列/索引/CHECK 与 §1.2 DDL 一致）；P2——真实图片导入 → 检测 → 修框退出重进 → 确认 → 整理页见真切片的端到端 + 多题页面重框单测（重框其中一题，其他题框与切片不受影响）+ 模型失败单测（不落占位框、显式提示手动框选）+ 单框旋转手柄不存在单测；P3——搬库后图还在、zip 备份恢复后图还在、zip 路径穿越单测。

---

## 8. 测试与代码组织（v2 新增、v2.1 补充，P2）

### 8.1 测试基础设施：不许依赖真实用户库

- **现状的坑（反例）：** `test/s8b4_backup_migration_test.dart` L42–45 直接读真实用户库（`File(p.join(AppDatabase.dataDirectoryPath(), 'quiz-master2.db'))` 并断言 9 道题）——在全新机器/CI 上失败，用户库题数一变也失败。**新的迁移测试不能沿用这种写法。**
- **定稿：** 给 `AppDatabase` 增加**可注入的打开路径 / 测试工厂**（如 `AppDatabase.openForTest(Directory)` 或 `testDbPath` 参数），测试用临时目录或内存库；所有新测试一律走测试工厂，不许读 `dataDirectoryPath()` 下的真实库。
- **无 v1 fixture 库。** 老库直接删除，不做迁移，不需要 v1 fixture（原 v1 fixture 升级测试已随 §6 第 1 条删除，见 §8.2）。
- **schema 结构测试：** `_onCreate` 建 v2 全量结构——加一个测试，对建出的库跑 `PRAGMA table_info` / `sqlite_master`，核对表、列、索引、CHECK 约束、partial unique index 与 §1.2 的 DDL 全对上。原“`_onCreate` v2 与 `onUpgrade` v1→v2 对比测试”已随 §6 第 1 条删除（无 `onUpgrade` 可对比）。

### 8.2 测试清单（按阶段，见 §7 验收）

- P0：并发打开（`Future<Database>` 缓存）单测；`recordSelfCheck` 半截写单测；含 Tab/CR/控制字符的备份往返单测；§3.1 的 11 处写点——删文件夹、改标签、删标签、删知识点、删章节后重新读题仍能正确解析；queue 含 `|` / 逗号的编解码单测。
- P0.5：真实图片最小闭环；旋转 90/180/270 裁剪测试；`imageCache.evict` 后重读新图测试。
- P1：删老库建新库单测（老库文件删除、新库从空开始、无演示题）；v2 备份恢复单测；`schemaVersion > 2` 拒绝恢复单测；schema 结构测试（§8.1）。
- P2：真实图片导入 → 检测 → 修框退出重进 → 确认 → 整理页见真切片的端到端；重检测按页替换不追加单测；详情页“重新框选”后切片更新单测。
- P3：文件迁移单测（目标冲突三种选择、跨盘失败回滚、取消清理 staging）；zip 路径穿越单测（`../` 条目拒绝整个包）；孤儿清理单测（只删无引用文件）。
- v2.1 新增（CodeBuddy 二审 P2）：多题页面重框单测（一页 2–3 道题，重框其中一题，其他题的框和切片不受影响）；单框旋转单测（手柄不存在/不可用；若将来恢复单框旋转，改测旋转 30°/90° 后切片与屏幕显示一致）；多页旋转单测（第 1 页转 90°、第 2 页不转，确认后两页切片都正确）；模型失败单测（模型缺失/加载失败时 UI 不落占位框，显示手动框选提示）；另：`created_at` 排序单测、partial unique index 单测（同题两个 layer = 1 框拒绝写入）、`parent_box_id` 级联删除单测、`question_boxes` CHECK 约束单测、`ReviewQueueItem` 含 `|`/逗号编解码单测、`FileImage` evict 后读到新图单测。（原“v1 读 v2 备份单测”“`.bak` 预检单测”已随 §6 第 1 条删除：无 v1 备份、无 `.bak` 预检。）
- v2.1 补丁新增（CodeBuddy 三审 P2）：草稿旋转 → 取消 → 重开单测（框与页图仍对齐，见 §1.6.1）；多题页面重框单测（重框其中一题，其他题框/切片不变，新框不能与其他题框重叠，见 §1.5.1）；目标库覆盖回滚单测（目标已有库、选“覆盖”、模拟文件复制失败，目标旧库内容不变，见 §4.6）；EXIF 旋转图片单测（带 EXIF 90° 的 JPEG 导入后框、页图、切片方向一致，见 §1.4）；备份选择器单测（恢复选择器只允许 `.qm2backup`；`.json`（无 `_meta`）拒绝恢复，见 §2.3）；拆分任务字段单测（拆分后的 `CollectTask` 行 `source_path` / `created_at` / `page_count` 都正确，排序不回 0，见 §1.2(b)）。

### 8.3 代码组织：`AppDatabase` 拆分

- **现状：** `AppDatabase` 已 1164 行；再加迁移、备份、文件、框 DAO 会失控。**定稿：拆。**
- **拆分建议：** `lib/data/schema.dart`（建表 DDL 与 `onCreate` 的表结构部分）、`lib/data/migrations.dart`（将来 v3+ 的版本迁移函数；v2 无迁移）、`lib/data/backup.dart`（`exportBackupJsonFrom` / `importBackupJsonInto` / 校验）、`lib/data/question_boxes_dao.dart`（框的增删改查 + 回填 + 按任务/题查）、`lib/data/storage_service.dart`（文件目录、复制、页图、切片、resolver、孤儿扫描）。
- **拆分时机：** P1 迁移做之前先拆出 `migrations.dart` 与 `schema.dart`（迁移代码不与 `AppDatabase` 混在一起）；其余随 P2/P3 拆。**拆分本身不改行为**，每拆一处跑全量测试；不要把“拆文件”与“改逻辑”混在同一个提交里。

---

## 附：本文档没改的东西（边界重申）

- 不改复习模型（错因治疗、治愈次数、复查间隔）、不改文件夹/标签/试卷/知识点的产品语义、不改 UI 布局与视觉、不改 `pubspec.yaml` 依赖、不升级 Flutter/Dart。
- 不恢复第 2 层模型（D-23 暂缓不变），不引入 OCR（既定：无 OCR 内容搜索）。
- 不碰 `~/workspace/quiz-master2-F/`（v1 旧项目）与全能题库验收。
- v2.1 本身仍是方案文档：不改代码、不动 Schema、不跑测试、不 commit、不 push；实施须等 Meng 审完 v2.1 再定。
- 第一批小正确性修复已完成，不在本文档的实施范围内：错题本返回刷新（`P0B1-WRONGBOOK-REFRESH-REPORT.md`）、学科同步扫尾（`P0B1-SUBJECT-SYNC-CLEANUP-REPORT.md`）、归档口径统一（`P0B1-ARCHIVED-COUNTS-REPORT.md`）；设置单 owner（第 4 项）是另一批工作，与主链 Schema 无关，见文首不确定项第 8 条。
