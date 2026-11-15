# B3 追加项 2：删除确认统一改模态弹窗 + 修框编辑器右键拖动画框

工人：b3-delconfirm。工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`。未 commit、未 push，未碰 `assets/models/`、`test/fixtures/`，未碰 `double` 双线框封面样式。

## (a) 失败任务的「删除」也要弹确认框

- `lib/modules/collect/collect_page.dart:1299`：失败任务行（`CollectStatus.failed`）的「删除任务」按钮由 `_removeTask` 改走 `_deleteTask`（:670，原有模态 `AlertDialog`，标题「删了就没了，确定吗？」，内容含任务/修框草稿/未整理题的后果说明、已整理进错题本的题不动）。
- `lib/modules/collect/collect_page.dart:661-662`：`_removeTask` 注释更新——现在只用于「取消导入 / 取消排队」（仍直接删、无确认，沿用原设计，见审计表第 3 行）。

## (b) 全项目删除确认统一用模态 AlertDialog

只统一形式，不统一文案：各处原有的标题、后果文案、确认按钮文案原样保留在弹窗里。

### 审计清单

| # | 删除点 | 位置（文件:行） | 原来形式 | 改后形式 | 文案是否保留 |
|---|---|---|---|---|---|
| 1 | 收集任务（待框选 / 修框中 / 待整理 / 已整理） | `lib/modules/collect/collect_page.dart:670`（`_deleteTask`），按钮 :1266/:1281/:1290/:1307 | 已是模态 `AlertDialog` | 未变 | 是 |
| 2 | 收集任务（失败） | 同上 :1299 | 直接删（`_removeTask`），无确认 | 模态 `AlertDialog`（改走 `_deleteTask`） | 是（与第 1 行同一文案） |
| 3 | 收集任务（导入中 / 排队中：取消导入 / 取消排队） | 同上 :1243/:1251（`_removeTask`） | 直接删，无确认 | 未变——这是取消进行中的任务，不是删除确认点，按原设计保留 | — |
| 4 | 题目删除 | `lib/modules/detail/question_detail_page.dart:450`（`_askDelete`），按钮 :1829 | 行内确认条（`_confirmDelete` + `_buildConfirmBox`） | 模态 `AlertDialog` | 是：「删了就没了，确定吗？」+「整题图与全部补充内容一并删除，不可恢复。」 |
| 5 | 整理队列单题删除 | `lib/modules/organize/organize_page.dart:2182`（`_askDeleteOne`） | 行内确认条（`_pendingDeleteId` + `_singleDeleteConfirm`） | 模态弹窗（见下「层级问题」） | 是：「确认删除这道题？」+ 原文 |
| 6 | 整理队列批量删除 | `lib/modules/organize/organize_page.dart:2191`（`_askBatchDelete`） | 行内确认条（`_batchDel` + `_batchDeleteConfirm`） | 模态弹窗（同上） | 是：「删了就没了，确定吗？」+「批量删除勾选的 N 道题，删错了不能恢复。」 |
| 7 | 学科删除 | `lib/modules/subjects/subjects_page.dart:240`（`_askDelete`）、调用点 :640 | 行内确认条（`_confirmTarget` + `_confirmBox`） | 模态 `AlertDialog` | 是：长文案（含题数、文件夹后果）与确认按钮「确认删除这一科和全部 N 道题」全保留 |
| 8 | 章节删除 | 同上，调用点 :947 | 行内确认条 | 模态 `AlertDialog` | 是：「删除章节「X」，确定吗？」+ 章节下知识点数文案 |
| 9 | 知识点删除 | 同上，调用点 :990 | 行内确认条 | 模态 `AlertDialog` | 是 |
| 10 | 标签删除 | 同上，调用点 :1099 | 行内确认条 | 模态 `AlertDialog` | 是 |
| 11 | 试卷删除 | 同上，调用点 :1187 | 行内确认条 | 模态 `AlertDialog` | 是 |
| 12 | 文件夹删除 | `lib/modules/wrongbook/wrongbook_page.dart:621`（`_askDeleteFolder`），按钮 :2059 | 行内确认条（`_deleteConfirmFolder` + `_buildDeleteConfirm`） | 模态 `AlertDialog` | 是：标题（只在该文件夹的题数 / 多文件夹题数 / 子文件夹数）与说明（只删这一科）全保留 |
| 13 | 错题本批量删除 | `lib/modules/wrongbook/wrongbook_page.dart:654`（`_askBatchDelete`），按钮 :2794 | 行内两步（`_batchDeleteConfirm`） | 模态 `AlertDialog` | 是：原来行内条只有标题「删了就没了，确定吗？」一句，无补充文案，原样保留，未另加题数 |
| 14 | 设置：清空演示数据 | `lib/modules/settings/settings_page.dart:109`（`_askClearDemo`） | 行内确认条（`_confirmClearDemo` + `_confirmBox`） | 模态 `AlertDialog` | 是：「清空演示数据，确定吗？」+「三科共 N 道演示题会全部删掉，删了就没了，确定吗？」 |
| 15 | 设置：孤儿清理 | `lib/modules/settings/settings_page.dart:185`（`_askOrphanCleanup`） | 行内确认条（`_orphanConfirm` + `_confirmBox`） | 模态 `AlertDialog` | 是 |
| 16 | 设置：恢复（覆盖当前题库） | `lib/modules/settings/settings_page.dart:329`（`_askRestore`），选文件后调用 :386（zip）/:412（JSON） | 行内确认条（`_restoreData` + `_confirmBox`） | 模态 `AlertDialog`；选完文件即弹，取消则丢弃刚选的文件（与原来行内条的取消一致） | 是。注：恢复是覆盖不是删除，但共用同一行内确认条，按「行内确认条全部改掉」一并改 |
| 17 | 复习记录 | 无删除入口（`lib/modules/review/review_page.dart` 全文无「删除」；`repository.deleteCauseRecord` 只在 `syncCauseRecords` 里自动同步时调用，错因改动后自动清掉已不在错因里的记录） | — | —（无可改的确认点） | — |
| 18 | 设置：清理缓存 | `lib/modules/settings/settings_page.dart:572`（`_clearCache`） | 无确认（按钮直接清理） | 未变（原来就没有确认条，不新增） | — |
| 19 | 修框编辑器：删除选中框 | `lib/modules/collect/collect_page.dart:2431` | 无确认（删的是编辑器内草稿框，可重画） | 未变 | — |
| 20 | 芯片 ×（错题本筛选条件、详情/整理编辑态的错因与自定义类型） | 各页 `QmChip.onDelete` | 移除出列表/筛选，非实体删除，无确认 | 未变 | — |

删掉的内联确认条实现：详情页 `_confirmDelete` 字段与删除分支、`_buildConfirmBox` 的删除调用点（取消编辑的调用点保留，见遗留问题）；整理页 `_pendingDeleteId` / `_batchDel` / `_singleDeleteConfirm` / `_batchDeleteConfirm`；学科管理页 `_confirmTarget` / `_confirmBox`（`_rowActions` 改为接受 `onDelete` 回调）；错题本 `_deleteConfirmFolder` / `_buildDeleteConfirm` / `_batchDeleteConfirm`；设置页 `_confirmBox` 改为 `_showConfirmDialog`（:712）。

### 层级问题（整理队列弹窗，实测发现）

队列层本身是直接插进 Navigator overlay 的 `OverlayEntry`（`organize_page.dart:361-378`）。`showDialog` 推的新路由插到它下面，会被队列层盖住、点不到确认按钮（实测：批量删除测试里点「确认删除」命中了队列层列表行的 InkWell，`repo.deletedIds` 为空）。

改法：队列层的删除确认不走 `showDialog`，改在队列层自己的 Stack 顶层渲染 `ModalBarrier` + `AlertDialog`（`organize_page.dart:2512-2540`，`_askConfirm` :2159，`Completer<bool>` 回值，`_resolveConfirm` :2172）。形式仍是模态弹窗，`ModalBarrier`（`dismissible: false`）挡住底下的点按；Esc 开着确认框时先关确认框、不关队列层（:2316）。其他页无 `OverlayEntry`，都正常走 `showDialog`。

## (c) 修框编辑器右键行为

### 根因

旧代码只改了 `_onDrawStart` 的框内拦下是不够的：画框层在 Stack 里压在框下面，而 `RenderBox.defaultHitTestChildren` 在第一个命中的子节点就停——落在框上的右键指针根本到不了画框层（实测：从框中心右键拖动，`这个框是？` 不出现，原框也不动）。所以右键处理必须移到能收到框上事件的地方。

### 改动

- `lib/modules/collect/collect_page.dart:2146`：`_onDrawStart` 增加 `fromRightDrag` 参数；为真时跳过「起点在框内就不画」的拦下（非内框模式的题级框/独立题内框、内框模式的题内框）；触摸 / 主按键画框仍走原来的拦下。内框模式下起点在外框之外仍退出内框模式、不画框（与原来一致）。
- `lib/modules/collect/collect_page.dart:2478` 起（画布祖先级 `Listener`，key `box-editor-canvas`）：右键画框/取消移到这里——该 Listener 在命中路径上，起点落在框上、缩放柄上也能收到右键按下/拖动/抬起（`_rightDownLocal` :2513，拖出 4px 才 `_onDrawStart(..., fromRightDrag: true)` :2525，单击取消 / 拖完 `_onDrawEnd`）。左键拖框仍走框自己的 `GestureDetector`，这里只处理右键、不碰左键。
- 内层画框层只留触摸/手写笔主按键画框，右键分支已删（落在框上的触摸仍到不了这一层，框的点按/拖动不受影响）。
- 4px 阈值 `_rightDragSlop` 不变；右键单击取消不变（内框模式退出内框模式，非内框模式无动作）。
- 提示文案更新：主提示、内框模式提示、底部三态提示里的「空白处右键拖动」改为「右键拖动」（起点在框上也能画）。

## 测试

新增/改动的测试：

- `test/collect_page_test.dart`：失败任务测试改写为「B3 失败任务点删除任务弹确认框，取消不删、确认删除」；新增「B3 右键起点在框上画新框、左键在框上仍拖动」（右键从占位框中心起拖 → 弹出选类型菜单且原框像素坐标不变；选成题级框后新框落下；左键在原框左上角拖动 → 原框移动。注：选成题级框后两框重叠会出警告横幅、画布下移，故选框后不断言原框像素坐标）。
- `test/detail_page_test.dart`：删除测试改名「删除模态弹窗确认：取消留题，确认删除后进下一题」。
- `test/settings_page_test.dart`：清空演示数据测试改名「清空演示数据：模态弹窗确认，确认后清掉并提示」。
- `test/wrongbook_page_test.dart`：批量删除测试改名「单选卡片复选框；批量删除模态弹窗确认」。

结果（`TMPDIR=$HOME/workspace/.tmp-b3-delconfirm`，用完已删）：

- `flutter test test/collect_page_test.dart`：43 项全过。
- `flutter test test/detail_page_test.dart test/organize_page_test.dart`：52 项全过。
- `flutter test test/subjects_page_test.dart test/wrongbook_page_test.dart test/settings_page_test.dart`：90 项全过。
- `flutter analyze`（全量）：No issues found。

环境：跑测试时 VM 重启丢过一次 clang（`pdfium_dart` 原生编译失败），按 `docs/ui-replication/restore-linux-toolchain.sh` 重装工具链后恢复。演示库已备份到 `~/workspace/demo-db-backup/quiz-master2.db.b3-delconfirm`，测试后恢复并核对 md5 为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（与任务给定值一致）。

## 遗留问题

1. 详情页取消编辑的内联确认框保留（`question_detail_page.dart` 的 `_buildConfirmBox` 仅剩「有还没保存的改动，要保存吗？」三选一调用点）：不是删除确认，不在本次范围，未改。
2. 整理队列弹窗的删除确认因 OverlayEntry 层级原因未走 `showDialog`（见上「层级问题」）：形式仍是模态弹窗，但不是路由级弹窗——无路由返回键处理，Esc 由队列层自己的 `Focus.onKeyEvent` 处理（先关确认框）。如后续要求全项目严格走同一 `showDialog`，需另议队列层挂载方式。
3. 全量测试未跑（由协调员最后统一跑）。
4. 右键拖动起点在内框模式的外框之外时，仍按原行为退出内框模式、不画框（内框只能画在外框内）；任务原文「任何位置都画新框」在此边界下不适用，已在代码注释说明。
