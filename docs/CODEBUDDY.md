# CodeBuddy 交接说明（quiz-master2）

> 给接手这个项目的 AI 编程助手（CodeBuddy）看的。先读完下面列出的文档再动手。
> 负责人是 Meng，他本人也在用 CodeBuddy 维护这个项目；推代码前必须经他确认。

## 项目是什么

- **quiz-master2**：Windows 个人智能错题本，只给单个大学生自己用。
- 技术栈：**Flutter 3.47.9 / Dart 3.13.7 + SQLite**，Windows 优先，Android 以后可能做。
- 核心流程：收集 → 整理 → 复习 → 掌握。错题管理是主线，复习按错因治（不是背题）。
- 仓库：`MengYC1116/quiz-master2-F`，当前工作分支 **`ui-replication`**（从 `main` 的 `0c812172` 分出）。

## 先读这三份文档（按顺序）

1. **`docs/代码地图.md`**——代码地图：目录、数据流、九页地图、Dart 速成、常见任务手册。看不懂代码时先翻它。
2. **`docs/decision-log.md`**——决策记录 D-00～D-23：所有已定事项（技术选型、数据库位置、演示数据等）。有疑问先查这里，不要凭感觉改。
3. **`docs/ui-replication/R11-REPORT.md`**——R11 最终验收报告（有条件通过）：九页完成情况、视觉对照结果、未解决问题清单（§8）、Win11 待验证事项（§9）。

## 硬边界（绝不能碰，除非 Meng 明确说可以）

1. 不改 SQLite Schema，不加字段、不改表结构。
2. 不改业务规则、数据口径、状态机（错因治愈规则、复查间隔、分页默认值等）。
3. 不增删产品功能，不改已定的产品决策。
4. 不升级依赖，不改 `pubspec.lock`，不换技术栈。
5. 不动本项目范围外的目录，不删旧备份和原始材料。
6. **不擅自 commit、push**。改完先在本地验证，报给 Meng，他确认后才推。
7. HTML 交互原型（`docs/` 外的 `quiz-master2-jiao-hu-yuan-xing.html`，SHA256 `18c8c434…35e1`）是唯一视觉目标；原型里的死代码（旧翻卡模型、静态演示数字、学科管理死按钮）不实现。

## 改完必须验证（缺一不可）

```powershell
flutter analyze        # 必须 0 问题
flutter test           # 必须全过
flutter build windows --release   # Win11 上必须构建成功
```

界面改动还要在真机窗口里跑一遍、截图，和 HTML 原型对照；Linux 构建成功不替代 Win11 真机验收（字体、DPI、尺寸要在 Win11 上复核）。

## 当前状态（2026-11-15）

- R0–R11 UI 重构、§8 与 P0–P3 实施已完成并推送；分支 **`ui-replication`**，
  本地 head 为 `bca8586`（以 `git log` 为准），远端 head 为 `38cbc4b`
  （快照推送不写本地历史）。
- **Batch 1–6 已推送（Batch 6：2026-11-15 ~11:41，远端 head `38cbc4b`）**；第三次自审
  已做完（见 `docs/ui-replication/SELF-REVIEW-3.md`，只审第六批改动，P0 0、P1 2、P2 33），**第七批修复进行中、
  改动在工作树里，未提交、未推送**；在 Meng 明确批准之前，**不要 push**（针对第七批）。
  也不要 commit、reset、checkout——只改文件，不动 git 历史。
- **Batch 4 God 类拆分已完成，已随 Batch 5 一并推送**（Meng 2026-11-14
  批准“马上拆就行”，后追加 `wrongbook_page.dart`；纯重构，不改行为、
  不修 bug、不加功能；细节见 `docs/ui-replication/B4-SUMMARY.md`）：
  - `lib/data/database.dart` 3191 行 → 541 行入口 + 10 个 `db_*.dart`
    part 文件（`db_paths` / `db_schema` / `db_storage` / `db_codec` /
    `db_questions` / `db_catalog` / `db_collect` / `db_orphans` /
    `db_settings` / `db_backup`；同一库 `part` / `part of`，对外接口
    零调整，找实现先看入口文件的 `part` 声明与转发行）；
  - `lib/modules/collect/collect_page.dart` 3349 行 → 1316 行入口 +
    `box_editor.dart`（修框编辑器）+ `collect_widgets.dart`；
  - `lib/modules/wrongbook/wrongbook_page.dart` 3718 行 → 1141 行入口 +
    5 个 `wrongbook_*.dart` part 文件（`wrongbook_shelf` /
    `wrongbook_directory` / `wrongbook_list` / `wrongbook_cover` /
    `wrongbook_widgets`）。
  - 拆分后协调员最终统一验证：`flutter analyze` 0 问题、全量测试
    **628/628 通过**（以上行数与测试数均为 Batch 4 结束时，2026-11-14）。
- YOLO 第 1 层已接真模型（`lib/services/yolo_onnx_service.dart`，
  加载 `assets/models/question/yolo11s-question-v1.onnx`，
  `hasRealModel` 为真当且仅当模型成功加载；依赖 `onnxruntime ^1.4.1`，
  D-23 已 pin）。模型文件约 38MB，由 Meng 自己放进工作树，
  **不进仓库**（`git ls-files assets/models/` 里只有 README）。
  第 2 层暂缓：`intraEnabled = false`，再接入点见该文件注释
  （模型放回 `assets/models/intra/`、开关改 true、实现 `_detectIntra`）。
- Schema 是 **v2**：`AppDatabase.schemaVersion = 2`，`createTables` 建
  **13 张表**（原 12 张 + `question_boxes`），无迁移、无 `onUpgrade`——
  老库首次打开会被删掉重建（见 `openAt` /
  `deleteLegacyDatabaseIfPresent`）。备份/恢复共用 `backupTables`
  清单（13 张表全在里面），备份是含文件的 zip。
- 演示库仍是 **v1**（`user_version = 1`，无 `question_boxes` 表，
  9 道题全是演示题；Linux 验证机 `~/.local/share/quiz-master2/`，
  Win11 在 `%LOCALAPPDATA%\quiz-master2\quiz-master2.db`）。
  应用第一次打开它会删库重建为 v2 空库——**跑测试、跑应用前先备份演示库，
  完事恢复原状并核对无变化**。测试本身已隔离，不碰真实库：
  `AppDatabase.openForTest()` 开测试库（只建表不播种）、
  `resetForTest()` 复位单例与测试目录重定向、
  `testDataDirectory` 重定向数据目录与导入复制目标；
  新测试按这个模式写（临时目录 + 测后 `resetForTest()`）。
- 第三批后的关键行为（2026-11-14，细节见 `docs/代码地图.md` 第 3–4 节
  与 `docs/ui-replication/B3-*.md`）：路径删除安全（`resolveDataPath`
  默认拒绝对路径）、删除确认全项目统一模态 `AlertDialog`、
  P1-2 多页 PDF 未框页保留在任务里（确认前弹框提示页数）。
  二层模型已随第八批第 2 项移除（B8-2，2026-11-15，见
  `docs/ui-replication/B8-2-LAYER2-REMOVAL.md`）：内框模式、题干/选项/
  配图类型选择、二层切片与叠加层全部删除，只留 `intraEnabled` 开关 +
  `_detectIntra` 占位与 `question_boxes` 表两处重接入点。

## 工作方式

- 一次只做一件事，做完一项汇报一次：改了什么、怎么验证的、截图、还有什么没解决。
- 遇到要 Meng 裁决的点（两个页面对同一功能说法不一致、原型在 Flutter 里实现不了），停下来记进 `docs/decision-log.md`，按自己的判断先写、继续往下做，等他事后定——不要中途反复问。
- 回复用简体中文，简短，先说结论。
