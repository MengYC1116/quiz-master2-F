# 最终自审 · 第四批 God 类拆分完整性验证（SELF-REVIEW-SPLIT）

- 验证员：拆分完整性验证（只审、不改）
- 日期：2026-11-14
- 范围：Batch 4 三处拆分——`lib/data/database.dart` → 10 个 `db_*.dart`；
  `lib/modules/collect/collect_page.dart` → `box_editor.dart` + `collect_widgets.dart`；
  `lib/modules/wrongbook/wrongbook_page.dart` → 5 个 `wrongbook_*.dart`
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 结论：**未发现 P0 / P1 问题；2 项 P2（均为文档口径与格式漂移，无行为影响）。**
  拆分接线完整，`flutter analyze` 0 问题，测试分 5 批共 **628/628 通过**，
  演示库 md5 未变。

## 问题清单

### P2-1 · B4-WRONGBOOK / B4-SUMMARY 的 wrongbook 行数口径与实测不符（文档错误）

- 位置：`docs/ui-replication/B4-WRONGBOOK.md`（“`wrongbook_page.dart`（1141 行）”、
  “总行数 3718 → 3740”）、`docs/ui-replication/B4-SUMMARY.md`（同口径）。
- 现象：实测 `lib/modules/wrongbook/wrongbook_page.dart` 为 **1147 行**，
  6 文件合计 **3746 行**，均比报告多 6 行。其余两处拆分行数与报告一致
  （database 541 + 10 文件 2964；collect 1316 + 2021 + 44 = 3381）。
- 后果：仅文档数字不准，无行为影响。差额 6 行正好等于新增的 5 行 `part` 声明
  + 1 行 `_update` 转发，疑似报告计数时把“原段长度”当成了“落盘后行数”。
- 证据：`wc -l lib/modules/wrongbook/wrongbook_*.dart`：
  1147（page）/ 496（shelf）/ 601（directory）/ 1142（list）/ 278（cover）/ 82（widgets），
  合计 3746；`part` 声明在 `wrongbook_page.dart:9-13`，`_update` 在 `:1006`。
- 修的方向：把两份报告中的 1141 → 1147、3740 → 3746，或注明“行数不含新增的
  part 声明与 `_update` 转发”。

### P2-2 · 6 个拆分文件未通过 `dart format --set-exit-if-changed`（格式漂移）

- 位置：`lib/modules/collect/box_editor.dart`（1 处）；
  `lib/modules/wrongbook/wrongbook_page.dart`、`wrongbook_shelf.dart`、
  `wrongbook_directory.dart`、`wrongbook_list.dart`、`wrongbook_cover.dart`（多处）。
- 现象：`dart format --output=none --set-exit-if-changed` 对 20 个拆分文件检查，
  6 个报 `Changed`。漂移形态均为纯空白：参数表换行方式（如 `box_editor.dart:818`
  的 `_onDrawStart` 参数表）、多行调用本可合并单行、整块缩进差一档
  （如 `wrongbook_shelf.dart:211-244` 的 `Color.fromRGBO` 与 `ClipRRect` 块）。
  `database.dart` + 10 个 `db_*.dart`、`collect_page.dart`、`collect_widgets.dart`
  全部干净（0 changed）。
- 后果：无行为影响；`analysis_options.yaml` 未强制格式，
  `flutter analyze` 仍为 0 问题。
- 证据：`dart format` 对照输出（见上）；拆分前备份
  `~/workspace/demo-db-backup/database-before-b4/database.dart.before-b4`
  本身也不满足 format 检查，说明至少 database 侧的漂移是既有的。
  但 wrongbook / collect 无拆分前备份可逐行比对，且两份 B4 报告均称移动代码
  “逐字”，故无法从现有材料完全排除“漂移由拆分引入”的可能——只能说漂移形态
  （可合并单行的多行调用、与方法体无关的缩进差）与既有手写格式一致，
  不像机械搬移会产生的改动。
- 修的方向：对 6 个文件跑一次 `dart format`（纯空白改动，不改行为）；
  或先与拆分前原文逐行比对确认漂移早于 B4，再决定是否格式化。
  注意：格式化会改动行号，`B4-WRONGBOOK.md` 的原行号对照表需同步失效声明。

## 验证结果

### flutter analyze

- `flutter analyze`（全量，`~/workspace/flutter-install/flutter/bin`）：
  **No issues found!（0 问题）**，用时约 8.5 秒。

### 测试（分 5 批跑，合计 628/628，全部通过）

`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`。
测试文件本身未改动；每批均为 `All tests passed!`（exit 0）。

| 批次 | 测试文件 | 通过数 |
|---|---|---|
| 1 | `collect_page_test.dart`、`pdf_collect_page_test.dart`、`detail_page_test.dart`、`wrongbook_page_test.dart`、`s8b2_subject_sync_supplement_test.dart`、`s8_chip_label_test.dart`、`p0b1_archived_counts_test.dart`、`p0b2_pagesize_test.dart`、`b2_leftover_wrongbook_view_test.dart` | 146 |
| 2 | `p0_hardening_test.dart`、`p1_schema_backup_test.dart`、`p3_backup_migration_test.dart`、`p2_json_fields_test.dart`、`p2_main_chain_test.dart`、`b3_p01_path_safety_test.dart`、`s8b4_backup_migration_test.dart`、`b2_leftover_data_test.dart`、`b3_p11_layer2_downgrade_test.dart`、`s8b3_startup_test.dart` | 148 |
| 3a | `organize_page_test.dart`、`review_page_test.dart`、`subjects_page_test.dart`、`settings_page_test.dart`、`home_page_test.dart`、`report_page_test.dart` | 141 |
| 3b | `pdf_render_service_test.dart`、`p0b1_subject_sync_test.dart`、`b3_overlay_layer2_test.dart`、`p05_image_pipeline_test.dart`、`p05_image_pipeline_e2e_test.dart`、`s8b2_subject_sync_test.dart`、`s8b4_reminder_test.dart`、`s8b6b7_leftover_test.dart`、`p0b1_settings_owner_test.dart`、`b2_win11bug_organize_test.dart`、`import_service_pdf_fallback_test.dart` | 83 |
| 4 | `app_shell_test.dart`、`nav_hover_regression_test.dart`、`p0b2_nav_palette_test.dart`、`qm_banner_test.dart`、`s8a5_section_scroll_test.dart`、`theme_smoke_test.dart`、`uikit_test.dart`、`widgets_forward_test.dart`、`yolo_onnx_service_test.dart` | 110 |
| **合计** | 45 个测试文件（全量测试文件覆盖） | **628** |

- 覆盖说明：每处拆分至少被其直接相关测试覆盖——database/repository 侧由批次 2
  + 3a/3b 的页面测试覆盖；collect 侧由批次 1 的 collect/detail 测试覆盖；
  wrongbook 侧由批次 1 的 6 个 wrongbook 相关文件覆盖
  （`wrongbook_page_test.dart` 43 项含书脊回归测试）。

### 演示库

- 跑前备份：`~/workspace/demo-db-backup/quiz-master2.db.b4-selfreview-pre`，
  md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`。
- 全部测试跑完后 `~/.local/share/quiz-master2/quiz-master2.db` md5 仍为
  `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题），未被改动，无需恢复。

### 过程记录（非代码问题）

- 一次偶发工具停滞：17 个文件合跑的第三批首次执行时，`flutter test` 在编译后
  15 分钟未产出任何输出、未拉起 tester 进程（`frontend_server` 空闲等待、
  CPU 几乎为 0）。已用精确会话 id 终止该次运行（未按模糊名字杀进程），
  拆成 3a/3b 两批重跑后分别 52 秒 / 62 秒通过。同一批文件此前在 B4 报告中
  也曾通过，判定为偶发工具/环境停滞，与拆分代码无关；如复现建议先重跑、
  再查 `flutter test` 侧。

## 审过且干净的接线清单

### database.dart → 10 个 db_*.dart（对照拆分前备份全文核对）

- `part 'db_*.dart';`（`database.dart:16-25`）与 10 个文件的
  `part of 'database.dart';` 一一对应；part 文件内无任何 `import`/`export`。
- 静态转发 **56 个**全部在位：逐个枚举核对，含记录类型返回值的
  `deleteOrphanFiles`（`Future<({int deletedCount, int freedBytes})>`，
  简单正则会漏掉它，已单独确认转发与 `deleteOrphanFilesImpl` 均存在）。
  每个转发调用的 `<name>Impl` 均在 part 文件中有定义；无调用方在 `lib/data` 外
  直接使用 `*Impl`。
- 56 个转发逐一核查参数转发：脚本比对全部转发体——Impl 名与转发名一致，
  具名参数原样转发，无漏传。另抽查 8 个关键转发逐项比对参数表
  （question_boxes：`boxesForQuestionFrom`、`replaceQuestionBoxesAndSliceInto`；
  备份：`exportBackupZipFrom`、`importBackupZipInto`；
  迁移：`migrateDataFiles`、`rollbackMigrationFiles`；
  路径解析：`resolveDataPath`、`isAllowedDataRelativePath`），
  参数名与具名/位置属性与 Impl 定义一致。
- 私有静态 31 个（`_toRow` / `_fromRow` / `_seed` / `_onCreate` /
  `_deleteQuestionTxn` 等）全部以同名顶层函数存在于 part 文件中，
  `database.dart` 内无残留；新增成员 0 个。
- 实例方法 67 个 extension 方法全部在位（按 B4-DATABASE.md 的分文件清单逐名核对，
  0 缺失）：`db_paths` 1、`db_storage` 1、`db_questions` 16、`db_catalog` 20、
  `db_collect` 9、`db_orphans` 2、`db_settings` 13、`db_backup` 5；
  每个 part 文件恰好 1 个 `extension … on AppDatabase`
  （`db_schema` / `db_codec` 为纯顶层函数文件，无 extension，符合清单）。
- 顶层函数定义无重复（82 个顶层函数定义，0 重名）；无循环引用
  （part 文件之间无 import，只通过同一库共享私有成员）。
- 拆分前备份对照：以
  `~/workspace/demo-db-backup/database-before-b4/database.dart.before-b4`
  为基准，公开静态 56 个 + 测试钩子 3 个
  （`useDatabaseForTest` / `openForTest` / `resetForTest`，仍留在类内，未转发）
  + 私有静态 31 个，数量与归属全部吻合；实例方法除留在类内的 `_openDb`
  与 `toString` 外全部已移入 extension。

### collect_page.dart → box_editor.dart + collect_widgets.dart

- `collect_page.dart:18-19` import 两新文件，`:23` `export 'box_editor.dart';`，
  `BoxEditorMode` / `BoxEditorResult` / `showBoxEditorDialog` 仍可从原路径 import。
- 调用方零改动且通过测试：`collect_page.dart:385`（`mode: BoxEditorMode.draft`）、
  `question_detail_page.dart:320`（`mode: BoxEditorMode.rework`）均编译通过、
  相关测试通过。
- `_DashedDropPainter` → `DashedDropPainter` 改名完整：全仓无 `_DashedDropPainter`
  残留；两处调用点（`collect_page.dart:971`、`box_editor.dart:1786`）已同步改名。
- `box_editor.dart` 的 import 按需取子集且补了 `page_image_pipeline.dart`
  （`rotateBoxToRotatedPage` 3 处调用均在编辑器内）；
  `box_editor.dart` 只被 `collect_page.dart` import，无其他直接引用。
- `collect_page.dart` 行数 1316 与报告一致；`_CollectPageState` 未拆 widget
  的取舍与报告说明一致（与 state 深度耦合）。

### wrongbook_page.dart → 5 个 wrongbook_*.dart

- `part` 声明（`wrongbook_page.dart:9-13`）与 5 个文件的
  `part of 'wrongbook_page.dart';` 一一对应；part 文件内无任何 `import`/`export`。
- 3 个 extension（`_WrongbookShelfBuild` / `_WrongbookDirectoryBuild` /
  `_WrongbookListBuild`）均 `on _WrongbookPageState`；32 个 `_build*` /
  `_bookStat` / `_pageTitle` 等 helper 方法调用点全部有定义，0 缺失调用。
- `_update` 转发：`wrongbook_page.dart:1006`
  `void _update(VoidCallback fn) => setState(fn);`；
  extension 文件中 `_update((` 计数 shelf 6 / directory 20 / list 28，
  合计 **54 处**，与报告一致；extension 文件中 `setState` 残留 0 处；
  宿主文件内 `setState` 仍保留 17 处（合法，State 类内调用）。
- 封面绘制器 6 个（`_CoverFoldPainter` / `_CoverInsetShadowPainter` /
  `_CoverPageEdgePainter` / `_VerticalDashedPainter` / `_DashedBorderPainter` /
  `_CoverPatternPainter`）各定义一次，跨 part 文件引用正常；
  叶部件 `_QmPaperButton` / `_PaperStarButton` 各定义一次，
  分别被宿主文件与 list 文件引用；`_CoverReviewButton` 仅 shelf 内使用。
- `_View` / `_DropKind` 枚举仍在宿主文件内，引用点（`_View.shelf` 等 14 处）正常。
- 无新增导出符号；`app.dart` 的 import 不用改（analyze + 测试通过佐证）。

## 未做事项

- 未改任何代码、未 commit / push、未用 `git stash` / `reset` / `checkout` /
  `clean`（只用过只读的 `git branch --show-current` 与 `git status --short`
  确认分支与改动状态）。
- 未做行为级逐行 body 比对：B4 报告称移动代码“逐字”（wrongbook 有拼回校验、
  database 有脚本覆盖率断言），本次以签名/归属枚举 + analyze 0 问题 +
  628/628 测试通过作为等价验证；如需更强保证，可对拆分前备份做归一化 body
  diff（database 有备份；collect / wrongbook 无拆分前备份留存）。
- 未跑 Linux Release 构建（B4-SUMMARY 称协调员已验证通过，本次未重复）。
