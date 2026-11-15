# B4 收集中心拆分报告（collect_page.dart）

- 工人：收集中心拆分（只拆 `lib/modules/collect/collect_page.dart`）
- 时间：2026-11-14
- 原则：纯重构，不改行为、不修 bug、不加功能；不碰 database.dart / wrongbook_page.dart / 其他工人文件；不碰等 Meng 决定的两件事（.gitignore 是否忽略 38MB 模型文件；红色无框警告范围是否收窄）；不碰第三批遗留问题；未执行任何 git 命令。

## 拆分前

- `lib/modules/collect/collect_page.dart`：约 129KB、3349 行，含 `CollectPage` 页面态 + 修框编辑器（约 1900 行）+ 拖放虚线画笔。

## 拆分后（3 个文件，共 3381 行）

| 文件 | 行数 | 内容（原文件行号） |
|---|---|---|
| `lib/modules/collect/collect_page.dart` | 1316 | 原 L1–1312：`CollectPage`（L35）+ `_PendingImport`（L69）+ `_CollectPageState`（L83–1312：任务列表、导入、确认拆题、删除、任务行/状态 pill/筛选）；另新增 import + re-export（见下） |
| `lib/modules/collect/box_editor.dart` | 2021 | 原 L1352–3349 逐字移出：`BoxEditorMode`（原 L1356）、`BoxEditorResult`（原 L1360）、`showBoxEditorDialog`（原 L1389）、`_BoxEditorDialog` 及其 State（原 L1445–3349）、末尾 `extension _BoxEdit on QuestionBox` |
| `lib/modules/collect/collect_widgets.dart` | 44 | 原 L1314–1350 逐字移出：`_DashedDropPainter` → 改名为公开的 `DashedDropPainter`（画法一字未动） |

行数变化说明：3381 − 3349 = +32 行，全部是两个新文件的文件头注释 + 各文件 import 行 + `collect_page.dart` 的 re-export 行；被移动的代码本体一字未改（除 `_DashedDropPainter` 改名与两处调用点同步改名，见下）。

## 具体改动点（除整块移动外，仅以下 4 处）

1. `collect_page.dart`：删除拆分后不再使用的 3 个 import（`dart:math`、`dart:ui`、`package:flutter/gestures.dart`）——它们只被修框编辑器使用；其余原 import 全部保留（含 `page_image_pipeline.dart`，`_openBoxEditor` 仍用其中的顶层函数 `rotateBoxToRotatedPage`）。
2. `collect_page.dart`：新增 `import 'box_editor.dart';`、`import 'collect_widgets.dart';`，以及：
   ```dart
   /// 修框编辑器公开符号仍从本文件 re-export（B4 纯拆分）：`question_detail_page.dart`
   /// 等现有调用方 import 本文件一字不用改。
   export 'box_editor.dart';
   ```
3. `collect_page.dart:974` 与 `box_editor.dart:1786`：`_DashedDropPainter(` → `DashedDropPainter(`（仅调用点改名，与改名后的类同步）。
4. `box_editor.dart`：import 从原文件按需取子集；另新增 `import '../../services/page_image_pipeline.dart';`（修框编辑器三处调用其中的顶层函数 `rotateBoxToRotatedPage`），删除原文件里修框编辑器并不用的 `../../widgets/widgets.dart` import。以上两处均为拆分后 analyze 报错/警告指出的 import 归属修正，不涉及行为代码。

## 接口有无调整

- **无。** 公开接口零调整：
  - `BoxEditorMode`、`BoxEditorResult`、`showBoxEditorDialog` 仍可从 `lib/modules/collect/collect_page.dart` import 得到（经 `export 'box_editor.dart'` re-export）。
  - `lib/app.dart`（`import 'modules/collect/collect_page.dart'`）与 `lib/modules/detail/question_detail_page.dart:34`（`import '../collect/collect_page.dart'`，L320 调用 `showBoxEditorDialog(..., mode: BoxEditorMode.rework)`）**一字未改**。
  - 全部测试文件**未改**。
  - 唯一改名的是原私有类 `_DashedDropPainter` → 公开 `DashedDropPainter`（私有符号本就不能被外部引用；全仓 grep 确认除原文件外无任何引用）；其余私有类（`_PendingImport`、`_CollectPageState`、`_BoxEditorDialog`）仍留在原文件/随编辑器整体移出，未改名。
  - `_CollectPageState` 的任务行/状态 pill/筛选 chips/导入行等方法未抽成独立 widget：它们与 state 字段、回调深度耦合，抽出需重构签名，风险大于收益；本次只做“编辑器整体移出 + 共用画笔移出”两处低风险切割。`collect_page.dart` 仍有 1316 行，后续如需再拆可单独立项。

## 验证结果

- `flutter analyze`（先指定 5 个文件，后全量）：**No issues found!（0 问题）**。
  - 注：拆分后首次 analyze 曾报 3 个 error + 4 个 warning，均为 import 归属问题（`rotateBoxToRotatedPage` 定义在 `page_image_pipeline.dart`，修框编辑器需该 import；拆分后 `collect_page.dart` 的 `dart:math`/`dart:ui`/`gestures` 不再被使用；`box_editor.dart` 不用 `widgets.dart`），已按上文第 1、4 点修正，修正后全量 0 问题。
- 相关测试（`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，未跑全量 `flutter test`，由协调员最后统一跑）：
  - `test/collect_page_test.dart`：**43/43 通过**
  - `test/pdf_collect_page_test.dart`：**1/1 通过**
  - `test/detail_page_test.dart`：**26/26 通过**
  - 合计 **70/70，All tests passed**（另做过一次三文件联合运行，同样 70/70）。
- 演示库：测试前后 `~/.local/share/quiz-master2/quiz-master2.db` md5 均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（与基线一致，未改动，无需恢复）。测试前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.b4-collect-start`（md5 相同）。
- 未截图（非 UI 工作）。

## 改动文件

- 改：`lib/modules/collect/collect_page.dart`（3349 行 → 1316 行）
- 新：`lib/modules/collect/box_editor.dart`（2021 行）
- 新：`lib/modules/collect/collect_widgets.dart`（44 行）
- 新：`docs/ui-replication/B4-COLLECT.md`（本报告）
- 未改：`lib/app.dart`、`lib/modules/detail/question_detail_page.dart`、全部测试文件、其他工人文件。

## 遗留问题

- 无阻塞遗留。`collect_page.dart` 仍有 1316 行（含 `_CollectPageState` 约 1230 行），如需进一步拆任务行/筛选等 state 方法，需另立项评估（见“接口”一节说明）。
- 拆分过程中发现、但按禁令未动：原文件 `page_image_pipeline.dart` 的 import 在拆分前看似“未被使用”，实际是修框编辑器用的顶层函数 `rotateBoxToRotatedPage`——已通过 import 归属修正解决，不属遗留问题。
- 与其他工人无文件冲突（本次只新增/改动 `lib/modules/collect/` 下的三个文件）。
