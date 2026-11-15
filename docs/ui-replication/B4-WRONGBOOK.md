# B4 · 错题本拆分（wrongbook_page.dart God 类拆分）

- 日期：2026-11-14
- 范围：只拆 `lib/modules/wrongbook/wrongbook_page.dart`（3718 行、约 129KB），不碰 `database.dart`、`collect_page.dart` 及其他工人文件。
- 性质：纯重构，不改行为、不修 bug、不加功能；不改任何测试文件、不改任何调用方（`lib/app.dart` 的 import 不变）。

## 基线（拆分前，已验证）

- `flutter analyze lib/modules/wrongbook/wrongbook_page.dart`：0 问题。
- 相关测试 6 个文件、76 项全绿：`test/wrongbook_page_test.dart`（43 项，含书脊回归测试）、`test/s8b2_subject_sync_supplement_test.dart`、`test/s8_chip_label_test.dart`、`test/p0b1_archived_counts_test.dart`、`test/p0b2_pagesize_test.dart`、`test/b2_leftover_wrongbook_view_test.dart`。
- 演示库 md5：`8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题、3 学科）；拆分前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.b4-wrongbook-start`。相关测试只用 `FakeWrongbookRepo`，不碰真实库。

## 拆分手法

Dart 没有 partial class，`_WrongbookPageState` 的方法不能直接分到几个文件里写。
采用 `part` / `part of` + 同库 extension：

- 主文件保留 `WrongbookPage` 与 `_WrongbookPageState` 的全部状态与业务逻辑，并声明 5 个 `part`；
- 三个视图段的方法原样移入 part 文件，包在 `_WrongbookPageState` 的 extension 里（同库可访问私有字段与私有方法，对外接口不变）；
- 独立小部件与绘制器逐字搬移（只改所在文件）。

拆分由脚本执行（`/tmp/split_wrongbook.py`，一次性工具，未留存），按标记定位边界、逐字搬移，
并校验：全部搬移段按原顺序拼回，与原文 3718 行逐行一致，校验通过后才落盘。

## 唯一一处非逐字改动：`setState` → `_update`（54 处）

extension 方法里直接调 `setState` 会触发 `invalid_use_of_protected_member`
（`setState` 是 `@protected`，只能在 State 子类的实例成员里调用），
首次 analyze 报出 54 项同类 warning。为保持 analyze 0 问题且不用 `// ignore`，
在 `_WrongbookPageState` 内新增等价转发（`wrongbook_page.dart`，`build()` 之前）：

```dart
void _update(VoidCallback fn) => setState(fn);
```

三个 extension 文件里的 54 处 `setState(() { … })` 机械替换为 `_update(() { … })`
（shelf 6 处、directory 20 处、list 28 处，全部是 `setState((` 形式，无 tear-off）。
语义与行为完全相同。封面绘制器与两个叶部件不含 `setState`，保持逐字。

## 拆分对照（原行号 → 新文件）

| 原位置 | 内容 | 新文件 |
|---|---|---|
| L1–1134 + L3320（类闭合 `}`） | imports、类注释、`WrongbookPage`、`_View` / `_DropKind`、`_WrongbookPageState` 全部字段 / `initState` / `dispose` / `_load` / 数据口径 helper（`_subjectFolders` / `_folderCount` / `_isMastered` / `_causeStatusOf` / `_searchHaystack` / `_filteredAll` 等）/ 导航（`_openList` / `_openDirectory` / `_openShelf`）/ 文件夹操作（增 / 改名 / 删 / 移 / 排序 / 拖拽落点）/ 批量操作（标签 / 移文件夹 / 收藏 / 归档 / 删除）/ `build()` / 共用 section helper（`_pageTitle` / `_pageSubtitle` / `_openBookFrame` / `_paperBox` / `_styledDropdown` / `_paperActionButton`）；新增 5 行 `part` 声明与 `_update` 转发 | `wrongbook_page.dart`（1147 行） |
| L1136–1582 | 书架段：`_buildShelf` / `_buildShelfTop` / `_buildShelfPager` / `_buildBook` / `_bookStat` → `extension _WrongbookShelfBuild`；另附 L3322–3365 `_CoverReviewButton`（封面「开始复习」按钮，仅书架用） | `wrongbook_shelf.dart`（496 行） |
| L1584–2180 | 目录页段：`_buildDirectory` / `_buildDirectoryTools` / `_buildMoveSelBar` / `_buildAllRow` / `_buildGapTarget` / `_buildKids` / `_buildFolderRow` → `extension _WrongbookDirectoryBuild` | `wrongbook_directory.dart`（601 行） |
| L2182–3319 | 书内列表段：`_buildList` / `_buildListToolbar` / `_buildFilterPanel` / `_buildMasteredNote` / `_buildArchBar` / `_buildBatchBar` / `_buildPaperEmpty` / `_buildLargeCards` / `_buildLargeCard` / `_buildCompactRows` / `_buildCompactRow` / `_buildArchivedRows` / `_buildArchivedRow` / `_buildPagination` / `_buildArchived` → `extension _WrongbookListBuild` | `wrongbook_list.dart`（1142 行） |
| L3419–3482 / L3484–3531 / L3533–3559 / L3561–3588 / L3590–3636 / L3665–3718 | 封面绘制器（逐字）：`_CoverFoldPainter`（折角 34×34）/ `_CoverInsetShadowPainter`（书脊贴左边缘的负偏移）/ `_CoverPageEdgePainter` / `_VerticalDashedPainter` / `_DashedBorderPainter`（虚线内框非对称圆角）/ `_CoverPatternPainter` | `wrongbook_cover.dart`（278 行） |
| L3367–3417 / L3638–3663 | 共用叶部件（逐字）：`_QmPaperButton`（纸面小按钮）/ `_PaperStarButton`（紧凑行收藏星） | `wrongbook_widgets.dart`（82 行） |

新文件清单（`lib/modules/wrongbook/`）：

- `wrongbook_page.dart`（1147 行）——页面态与业务逻辑，`part` 宿主
- `wrongbook_shelf.dart`（496 行）——书架视图 + 封面复习按钮
- `wrongbook_directory.dart`（601 行）——目录页视图
- `wrongbook_list.dart`（1142 行）——书内列表视图
- `wrongbook_cover.dart`（278 行）——封面绘制器
- `wrongbook_widgets.dart`（82 行）——共用叶部件

总行数 3718 → 3746（+28 行），新增行全部是 `part` 声明、extension 包裹、文件头注释与 `_update` 转发，无新增行为代码。

> 注（SR-P2-91，Batch 5 修正）：原报告误写为 1141 行 / 共 3740 行（+22 行），已按拆分完成时的实测 `wc -l` 更正为 1147 行 / 共 3746 行（1147/496/601/1142/278/82）。以上行数均为 B4 完成时口径；Batch 5 后续改动已使文件行数变化，不再与此处一致。另：上表“原行号对照”中的行号以拆分前原文为准，Batch 5 的 `dart format` 统一格式化（SR-P2-92）已改动 6 个拆分文件的行号，原行号对照不再逐行有效，仅作段落归属参考。

## 接口调整

- 对外接口：无。`app.dart` 的 `import 'modules/wrongbook/wrongbook_page.dart';` 不用改；`WrongbookPage` 公开构造与字段未动；无新增导出符号（extension 与小部件均为库内私有）。
- 对内唯一调整：上述 54 处 `setState` → `_update` 等价转发（见上节）。

## 验证结果

- `flutter analyze lib/modules/wrongbook/`：**No issues found**（0 问题）。
- `flutter analyze`（全量）：**No issues found**（0 问题；当时树上另有 Batch 1/2/3 未提交改动与兄弟工人进行中的改动，全量结果仅作参考，最终以协调员统一跑的为准）。
- 相关测试（同基线 6 个文件，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）：**76/76 全绿**，与基线一致，未跑全量 `flutter test`（协调员最后统一跑，避免与并行工人互相干扰）。
- 演示库：拆分后 md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，未变动；备份文件在 `~/workspace/demo-db-backup/quiz-master2.db.b4-wrongbook-start`。
- 未截图（非 UI 工作）。

## 改动文件

- 改：`lib/modules/wrongbook/wrongbook_page.dart`（3718 行 → 1147 行）
- 新：`lib/modules/wrongbook/wrongbook_shelf.dart`、`wrongbook_directory.dart`、`wrongbook_list.dart`、`wrongbook_cover.dart`、`wrongbook_widgets.dart`
- 新：本文档 `docs/ui-replication/B4-WRONGBOOK.md`
- 未改：任何测试文件、任何调用方（`lib/app.dart` 等）、`database.dart`、`collect_page.dart`、其他工人文件。

## 未碰事项与遗留问题

- 等 Meng 决定的两件事未动：.gitignore 是否忽略 38MB 模型文件；红色无框警告的范围是否收窄。
- 第三批遗留问题未顺手修。
- 未执行任何 git 命令（不 reset / 不 checkout / 不 clean / 不 commit / 不 push）。说明：任务开始时我误跑了一次只读的 `git status` + `git branch`（查看分支与改动状态），未改动任何状态，此后全程未再用 git。
- 无与其他工人文件的冲突；拆分只涉及 `lib/modules/wrongbook/`。
- 遗留问题：无。后续如需进一步瘦身 `wrongbook_list.dart`（1142 行，仍是最大文件），可再按筛选面板 / 卡片 / 分页拆子 widget，但那需要传参重构、超出本次纯搬移范围，需另立任务。
