# 第五批修复第四阶段文档 P1：其他文档（B5-DOCS-OTHER）

- 范围：SR-P1-33～SR-P1-39（decision-log / 四方分工 / CODEBUDDY / 代码地图）
- 时间：2026-11-15
- 工作树：`~/workspace/quiz-master2-UI`，分支 `ui-replication`
- 只改了下列 4 个文档文件，未改任何代码文件，未动 git 历史，未 commit、未 push。
- 依据：`docs/ui-replication/SELF-REVIEW.md`（SR-P1-33～SR-P1-39 各节）与
  `SELF-REVIEW-SUMMARY.md`；行数与验证结论以 `docs/ui-replication/B4-SUMMARY.md`、
  `B3-SUMMARY.md` 为准，并对照代码现状核对（`lib/data/database.dart` 的 `part`
  声明、`lib/data/db_*.dart` 各文件头注释、`lib/modules/collect/` 与
  `lib/modules/wrongbook/` 的文件清单）。

## SR-P1-33 decision-log D-07：标注已被 D-23 取代

文件：`docs/decision-log.md`

- 标题由“YOLO 与 onnxruntime（待 Win11 测试）”改为
  “YOLO 与 onnxruntime（已被 D-23 取代，仅留作历史）”。
- 正文首行加引用块：“本条已被 D-23 取代（2026-11-13），仅留作历史；
  占位服务现仅为模型缺失 / 加载失败时的回退路径，不要按本条行事。”
- 正文其余内容原样保留，只作历史记录。

## SR-P1-34 decision-log D-04：注明新库从空开始、不预置演示题

文件：`docs/decision-log.md`

- D-04 末尾补注：“注（§6 第 1 条，2026-11-13/14）：新库建库时从空开始、
  不预置演示题；`demoQuestions()` 仅作定义保留，目前没有任何生产调用方，
  上面 9 道题是演示库 v1（老库）的口径，不是新库的初始内容。”

## SR-P1-35 decision-log D-06：删除“继续上次”优先级规则

文件：`docs/decision-log.md`

- D-06 末尾补记（2026-11-14 定，已删除）：“原规则‘同时存在时优先级为
  复习 > 整理 > 收集’删除，改为最后一次活动优先——`recent_tasks` 是只有
  id=1 一行的单行表，`saveRecentTask` 是纯 REPLACE 后写优先，无三方比较逻辑；
  谁最后保存，谁就是‘继续上次’恢复的那一个。本条只改文字记录，
  不改 `saveRecentTask` 代码。”
- 同一规则在 D-01 也有半句（“首页‘继续上次’按它恢复（复习 > 整理 > 收集）”），
  一并改为“最后一次活动优先”，并注“原规则已删除，见 D-06”——否则同一文件内
  两处自相矛盾。边界文档 §4.1 的同款表述不在本任务范围，由另一工人负责。

## SR-P1-36 四方分工：基线 head 与测试数更新

文件：`docs/四方分工.md`

- 基线行改为：head 本地 `bca8586` / 远端 `afb68e3`（以远端为准；快照推送不写
  本地 git 历史，本地 `git log` 查不到远端 head 属正常），全量测试 628/628
  通过（Batch 4 结束时，2026-11-14；第五批修复进行中，通过数会随修复推进
  变化，最新数以第五批汇总 `docs/ui-replication/B5-SUMMARY.md` 为准）。
- 旧数 537 已清除。注：写报告时 `B5-SUMMARY.md` 尚未生成，该引用是待出的
  第五批汇总文件的指针。

## SR-P1-37 CODEBUDDY.md：“当前状态”补 Batch 4 拆分一节

文件：`docs/CODEBUDDY.md`

- “Batch 1/2/3 的改动在工作树里”改为“Batch 1/2/3/4 的改动在工作树里”。
- “最终自审还没做完”改为“最终自审已做完（见
  `docs/ui-replication/SELF-REVIEW-SUMMARY.md`，第五批修复进行中）”——
  自审已完成是现状，原句已过期；“不要 push / 不要 commit、reset、checkout”
  的纪律原样保留。
- 新增 Batch 4 一节（纯重构，细节见 `B4-SUMMARY.md`）：
  - `database.dart` 3191 行 → 541 行入口 + 10 个 `db_*.dart` part 文件
    （附清单与“找实现先看入口的 `part` 声明与转发行”的提示）；
  - `collect_page.dart` 3349 行 → 1316 行入口 + `box_editor.dart`（修框编辑器）
    + `collect_widgets.dart`；
  - `wrongbook_page.dart` 3718 行 → 1141 行入口 + 5 个 `wrongbook_*.dart`
    part 文件（附清单）；
  - 拆分后协调员最终统一验证：`flutter analyze` 0 问题、全量测试 628/628 通过；
  - 明确标注“以上行数与测试数均为 Batch 4 结束时，2026-11-14”。

## SR-P1-38 代码地图：头注“最终验证还没跑”改为已跑

文件：`docs/代码地图.md`

- 头注改为：仓库里仍有 Batch 1/2/3/4 未提交的改动（分支 `ui-replication`，
  本地 head `bca8586`）；最终验证已跑——B3 与 B4 均已由协调员跑过最终统一验证：
  `flutter analyze` 0 问题、全量测试 628/628 通过（Batch 4 结束时）、
  Linux Release 构建成功，结论见 `B3-SUMMARY.md` 与 `B4-SUMMARY.md`。
- 另补一句“第四批 God 类拆分（Batch 4）后的文件结构见第 2、3、6 节”。

## SR-P1-39 代码地图 §2/§3/§6：按 B4 后结构重写文件引用

文件：`docs/代码地图.md`

- §2：`database.dart` 一行改为入口说明 + 10 个 `db_*.dart` part 文件各一行
  （职责与关键函数名，见文件头注释）；“9 个页面，每页一个文件，一个文件
  就是一个模块”改为“每页一个模块”，收集中心行改为入口 +
  `box_editor.dart`（修框编辑器）+ `collect_widgets.dart`，错题本行改为
  入口 + 5 个 part 文件（附各文件职责）。
- §3：标题“`database.dart` 的 `createTables`”改为“`db_schema.dart` 的
  `createTablesImpl`”；建库流程句补“实现在 `lib/data/db_schema.dart`，
  `database.dart` 只留同签名转发”；“`_onCreate` = `createTables`”改为
  “`_onCreate` = `createTablesImpl`”；“路径删除安全（P0-1，`database.dart`）”
  改为“（P0-1，`lib/data/db_paths.dart`）”。
- §6：“`database.dart` 里没有 `onUpgrade`”改为“`db_schema.dart` 里没有
  `onUpgrade`”；“数据库加字段”第 1 步“`database.dart` 的 `createTables`”
  改为“`db_schema.dart` 的 `createTablesImpl`”，第 2 步 `_seed` 注明在
  `db_schema.dart`，第 3 步 `_toRow` / `_fromRow` 注明在 `db_codec.dart`。

## 核对结果（grep，2026-11-15）

旧表述已清除（在 4 个文件内 grep 无命中）：

- “最终验证还没跑”“不写死全量测试通过数”“537 通过”“每页一个文件”
  “Batch 1/2/3 的改动”“最终自审还没做完”“D-07 — YOLO 与 onnxruntime
  （待 Win11 测试）”。
- “复习 > 整理 > 收集”仅剩两处，均是新写的删除记录句（D-01 注释与 D-06
  补记），用以说明原规则已被删除，不是残留的现行规则。
- `database.dart` 的 `createTables` 引用已全部改为 `db_schema.dart` 的
  `createTablesImpl`（全文 `createTables` 引用共 4 处，均已指向
  `db_schema.dart` / `createTablesImpl`）。
- §2/§3 残留的 `database.dart` 引用逐条核对过，均仍正确：
  入口文件本身、`AppDatabase` 类所在文件、`schemaVersion` 开头注释、
  “`database.dart` 只留同签名转发”、测试隔离钩子（`openForTest` 等仍在
  `database.dart` 内声明）。§6 已无 `database.dart` 引用。
- 未跑测试与构建（按任务要求不需要）；未碰真实演示库。
- `git status` 中除 4 个文档文件外的其他改动（Batch 1/2/3/4/5-P0/P1-DATA/
  P1-COUNTS 的代码与文档改动、另一工人的边界文档改动）均为任务开始前
  已存在的未提交改动，本任务未新增、未修改它们；未 commit、未 push、
  未用 `git reset --hard` / `git checkout --` / `git clean`。

## 遗留问题

1. `B5-SUMMARY.md` 写报告时尚未生成，四方分工里“最新数以第五批汇总为准”
   的引用待该文件生成后自然生效；若汇总换名，需同步改这一处。
2. 代码地图 §5 Dart 速成示例注释仍写“`// lib/data/database.dart`，`_toRow`
   （节选）”——`_toRow` 现已移到 `db_codec.dart`（顶层函数）。§5 不在
   SR-P1-39 的 §2/§3/§6 范围内，本任务未改；建议下一批文档修复时顺手改
   为 `db_codec.dart`，或留待 P2 文档项处理。
3. 代码地图 §4 各页小节标题仍以入口文件命名（如“收集中心 `/collect` ——
   `lib/modules/collect/collect_page.dart`”），入口文件未变，标题本身正确，
   未改；若以后 §4 正文出现指向已拆走的实现位置的引用，需另行核对。
4. 行数说明：CODEBUDDY 新增节与代码地图头注写的 628/628、541/1316/1141 等
   均为 Batch 4 结束时（2026-11-14）的数；当前工作树经第五批修复后行数
   已有微调（实测当时 `database.dart` 552 行、`collect_page.dart` 1323 行、
   `wrongbook_page.dart` 1167 行、`box_editor.dart` 2156 行），文档中均已
   标注“Batch 4 结束时”，以代码为准。
