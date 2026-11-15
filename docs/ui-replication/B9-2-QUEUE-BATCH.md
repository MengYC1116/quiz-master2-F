# B9-2 队列批量操作：全选 / 可选标签 / 布局重排（+ SR3-15 根因修复）

- 范围：`lib/modules/organize/organize_page.dart`（只改 `_QueuePopupState` 区域：字段、`_loadMeta`、`_batchTag`、弹窗头部文案、排序字段、全选行、内联下拉组件、`_batchBar`、Esc 顺序、Stack 菜单层），`test/organize_page_test.dart`（旧引用更新 + 新增 B9-2 组 8 项）。
- 不碰：`_confirmCurrent` / `_batchConfirm`（第 1 项工人的区域）、`_batchAddFolder` / `_batchDelete` / `_batchConfirm` 的行为；不 commit、不推代码。
- 截图：`docs/ui-replication/shots/b9-queue-batch/`（不推）：`before-1280.png` / `before-narrow.png` / `before-folder-menu.png` / `after-1280.png` / `after-narrow.png` / `after-tag-menu.png`。截图条件：Linux Release 真机（Xvfb 1280×720 与 800×720），同一份 v2 截图库（由标准 v1 备份 `~/workspace/demo-db-backup/quiz-master2.db.b9-2-start` 经 B8-9 转换脚本生成，`~/workspace/demo-db-backup/quiz-master2.db.b9-2-v2shots`；拍完已把 live 库恢复为 v1，md5 见验证）。

## 现状核对（与任务书一致，另有两处补充）

- 批量条 `_batchBar()` 两行：第一行固定按钮「批量打标签 #需重做」+ 文件夹下拉（Expanded）+「批量加入该文件夹」；第二行「批量确认整理」+「批量删除」+「取消」；只在 `_selected.isNotEmpty` 时出现。
- `_batchTagRedo()`：打固定标签 '需重做'，打完**不清空选中**，只提示；已保存子集同步回 `_questions`（SR2-5/SR3-15 同款 setState map）。
- `_batchAddFolder()`：同样打完**不清空选中**，只提示「已加入文件夹」（跨学科跳过时报「已加入 N 道，M 道不是本科，跳过」）；**核对确认：文件夹那边没有别的收尾动作**，与打标签完全一致——新标签操作照此办理（不清空选中）。
- 标签来源：预设 `QmChip.presetTags`（易错/常考/需重做）+ 用户自定义标签（主页面 `_loadMeta` 用 `repo.tags()` 读进 `_allTags`；整理表单渲染预设 + 自定义）。**核对确认：队列弹窗自己的 `_loadMeta` 当时确实只读 exams/folders/subjects，不读标签——本次已补上**（`_allTags` 字段 + `_loadMeta` 里 `repo.tags()`）。
- 弹窗头部提示文案当时是「勾了题底部才出现批量条」——已同步改成「全选勾上当前列表，底部出现批量条」。
- 补充发现 1（SR3-15 探针的真相，见下节）：弹窗里的**排序下拉和文件夹下拉两个 DropdownButton 都是坏的**，不是只有一个；新标签下拉若继续用 DropdownButton 会带上同一问题。
- 补充发现 2：`popupCheckboxes` 测试 helper 原来把弹窗内所有 Checkbox 都算作“题行框”；加了全选框后，旧用例的 `.first` 会点到全选框——测试 helper 已改成只取行内框（三态除外），见测试一节。

## 1. 全选方案与理由

- 位置：**列表顶栏**，在搜索/排序行与题目列表之间，常驻一行：三态 Checkbox +「全选」+「已选 N / 共 M 道」。不勾题也能点到；离它控制的列表最近；计数常驻可见，不用等批量条出现才知道选了多少。
- 形态：**「全选/取消全选」切换，不另加反选**。理由：切换已覆盖“全选→全清”的主流程；反选是低频操作，多一个控件挤占顶栏，且反选后“已选”语义（筛外已选项被翻进来）更难一眼看懂。
- 范围：**当前筛选出的题（`_filtered`），不是全部题**。理由：所见即所得——用户搜/排之后全选，选中的应是眼前这批；把看不见的题也选上再批量确认/删除，会吓人一跳；与搜索栏「搜到 N 道」的计数口径一致。
- 三态与保留语义：Checkbox 三态——全选上 / 全没选 / 部分选（null，短横）。点按时：没全选上就把当前筛选出的题全勾上；已全选上就**只取消当前筛选出的题，筛选外的已选项保留**。例如先搜“函数”全选（q1），再搜“导数”全选（q2），两批都在；取消时也只取消眼前这批。
- 点全选后批量条随之出现，计数与「已选 N / 共 M 道」一致；筛选为空时全选框禁用。

## 2. 标签下拉方案

- 字段 + 按钮：批量条第 1 行改成「下拉选标签 + 批量打标签」按钮。字段当前值默认 `#需重做`（与旧固定按钮一次点按的行为一致）；下拉内容与整理表单一致：预设在前（易错 / 常考 / 需重做），自定义在后（`_allTags` 去重预设后按库顺序）。
- 方法：`_batchTagRedo()` 改名为 `_applyBatchTag()`，按 `_batchTag` 字段打标签；其余逻辑原样保留：逐题保存、已保存子集 finally 同步回 `_questions`（SR3-15 同款）、部分失败报「部分保存失败：已给 M 道题打上 #标签，其余请重试」、成功报「已给 N 道题打上 #标签」、**打完不清空选中**。
- 空标签保护：`_batchTag` 为空时提示「先选标签」（实际上默认值保证了正常流程里不会走到这支）。

## 3. 布局排法与截图

- 批量条改成三行：**第 1 行标签**（下拉 Expanded +「批量打标签」）、**第 2 行文件夹**（下拉 Expanded +「批量加入该文件夹」）、**第 3 行确认/删除/取消用 Wrap**（`spacing 8 / runSpacing 8`，窄窗口自动换行不溢出）。标题「批量操作 · 已选 N 道」保留在顶部。
- 截图（`docs/ui-replication/shots/b9-queue-batch/`）：
  - `before-1280.png`：改前 1280×720，勾 1 道——固定按钮「批量打标签 #需重做」，两行批量条，无全选。
  - `after-1280.png`：改后 1280×720，点全选——4 道全勾，「已选 4 / 共 4 道」，三行新批量条。
  - `before-narrow.png` / `after-narrow.png`：800×720 窗口（弹窗宽约 534），改前 / 改后批量条均完整显示、无溢出。另有 widget 用例在 480 宽（无外壳直泵整理页）下全选后断言无溢出。
  - `before-folder-menu.png`：改前点文件夹下拉——菜单完全不可见（SR3-15 证据，见下节）。
  - `after-tag-menu.png`：改后点标签下拉——内联菜单可见（#易错 / #常考 / #需重做 ✓），下方空间不足时自动向上展开。

## SR3-15 结论：是产品问题，不是测试环境问题

### 复现（真实点按测试 + 真机截图，双重确认）

- 探针（改前代码，临时用例 `test/b9_probe_test.dart`，已删）：打开队列、勾 1 道，真实点按文件夹下拉再点菜单项「平时作业」——**菜单仍开着、值不生效**，随后点「批量加入该文件夹」也落不到 f2（保存行仍是旧文件夹）；排序下拉真实点按「时间升序」同样不改变顺序。两个下拉在测试里都复现了 B7 探针所述现象。
- 真机截图（改前二进制，`before-folder-menu.png`）：在真机上点文件夹下拉，**菜单完全不可见**——不是“测试里点不到、真机上能用”。

### 根因（已用 Flutter 3.47.9 SDK 源码核实）

1. 队列层是直接插进 Overlay 的 `OverlayEntry`（`_openQueue` 里 `Overlay.of(context).insert(entry)`）；`DropdownButton` 的菜单走 `Navigator.push(_DropdownRoute)`。
2. Navigator 每次 push 后都会调 `OverlayState.rearrange(_allRouteOverlayEntries)`；`rearrange` 的文档写明：不在 `newEntries` 里的条目（即直接插入的队列层）“as a group is left on top, with all the rearranged entries below”——**路由菜单永远被排到队列层之下**。
3. 绘制与命中测试都按这个顺序：菜单被画在队列层下面（弹窗是不透明底色，菜单被盖住所以看不见）；点按时队列层外框 `Container` 的 `BoxDecoration` 经 `RenderDecoratedBox.hitTestSelf` 认领了弹窗范围内的所有点按，`Stack` 的命中测试到此为止，根本到不了下面的菜单路由；弹窗范围外的点按则被队列层的背景 `GestureDetector`（点按关队列）截住，同样到不了菜单的屏障。
4. 所以 B7 探针的“菜单能打开”只是指菜单路由已创建、finder 能找到菜单项；**像素上不可见、点按上不可达**。键盘 Tab+Enter 能选中（旧 SR2-26 用例的绕路），是因为键盘焦点不走命中测试——这也反证了根因在命中/绘制层级，不在菜单逻辑本身。

### 修复（修共因，三个下拉一起修）

- 弹窗内的下拉**不再用 `DropdownButton`**，改用弹窗自己 Stack 顶层渲染的内联菜单（与 B3 删除确认框同款做法：状态放 `_QueuePopupState`，面板画在弹窗的 Stack 里，不走 Navigator 路由）：
  - `_PopupMenu { sort, folder, tag }` + `_openMenu` 状态；字段是带当前值 +「▾」的 `InkWell`（底边细线沿用 DropdownButton 的视觉）；`_toggleMenu` 按字段的 `GlobalKey` 定位面板，默认向下展开、下方空间不足时向上展开、夹在弹窗上下边之内；面板带全屏透明层，点按任意处只关菜单不关队列；Esc 先关菜单（再是确认框、队列层）。
  - 三个下拉共用同一套组件：排序（时间降序/升序、学科首字母升/降序）、文件夹（「＋ 添加新文件夹…」+ 各文件夹）、标签（预设 + 自定义）。
- 主表单里的 `DropdownButton`（如来源试卷下拉）不在弹窗里，不受影响，不动。
- 旧 SR2-26 排序用例的键盘绕路（Tab+Enter）已改回真实点按，并通过。

## 测试清单与结果

文件：`test/organize_page_test.dart`；整理页全量 **45/45 通过**（基线 37 + 新增 B9-2 组 8）。

| 用例 | 覆盖 |
| --- | --- |
| 全选：点全选勾上全部、批量条计数对；再点取消全选 | 真实点按全选 → 3 道全勾、批量条「已选 3 道」；再点 → 全清、条消失 |
| 全选范围是当前筛选：搜到 1 道时全选只勾那 1 道，筛外已选保留 | 搜“函数”全选只勾 q1；清搜索后全选框三态 null；再搜“导数”全选补 q2（q1 保留）；清搜索全选补满 3 道；再点全清 |
| 批量打标签可选：下拉选预设标签落库，打完不清空选中 | 字段默认 #需重做 → 改选 #易错 → 点批量打标签，q1 落库含「易错」、提示「已给 1 道题打上 #易错」、选中不清空 |
| 批量打标签可选：下拉选自定义标签落库 | 自定义标签「期末重点」出现在菜单（预设在前、自定义在后），选中后落库 + 提示 |
| SR3-15 文件夹下拉：真实点按选平时作业，菜单关闭且值生效 | 点字段 → 菜单出现 → 点「平时作业」→ 菜单关闭、字段显示「平时作业」→ 点批量加入，q1 落库含 f2 |
| SR3-15 文件夹下拉：真实点按“添加新文件夹”打开新建表单 | 点「＋ 添加新文件夹…」→ 菜单关闭、「添加新文件夹」表单出现 |
| Esc 先关内联菜单，不关队列 | 标签菜单开着时按 Esc → 菜单关、队列仍在 |
| 窄窗口 480：全选后批量条无溢出，标签菜单能打开 | 480×720 直泵整理页，全选后无 overflow 异常，标签菜单能打开 |
| 旧用例更新 | 「批量条只在勾选时出现」「批量打标签（默认需重做）」「SR3-15 部分保存失败」「SR2-5 两条」「SR-P1-7 两条」改用新按钮文案；SR2-26 两条排序用例由键盘绕路改回真实点按；`popupCheckboxes` helper 改为只取行内框 |

- 破坏校验（临时改动、已全部恢复，`git diff` 无残留）：
  - A：`_applyBatchTag` 写死 `tag = '需重做'` → 两项标签用例如期失败（预设/自定义），恢复后通过。
  - B：`_toggleSelectAll` 改成空操作 → 三项全选用例如期失败（全选、全选范围、窄窗口），恢复后通过。
- SR3-15 探针文件 `test/b9_probe_test.dart` 为临时复现用，已删除；复现结论已转为上述常驻回归用例。

## 验证结果

- `flutter analyze`：0 问题。
- 整理页测试：`flutter test --concurrency=1 test/organize_page_test.dart` → **45/45 通过**。
- 全量测试：`flutter test --concurrency=1`（串行，默认 /tmp，未改 TMPDIR；`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）→ **896/896 通过**（含第 1 项工人新增的 `b9_1_collect_done_test.dart`；其中一项复用了本批的全选做批量确认）。第一次全量中途停滞在 subjects 页加载、另有 2 项设置缓存测试因 /tmp 写满失败（见“过程中遇到的问题”第 5 条），杀掉重跑后全部通过；第 1 项工人随后独立跑的同一套全量也是 896/896 全过。
- Linux Release 构建：`flutter build linux --release` → 通过（改后代码；另有改前基线构建一次通过，用于改前截图；构建产物已用二进制内字符串核对：改前含「批量打标签 #需重做」不含「全选勾上当前列表」，改后相反）。
- 演示库：全量测试前后均以 `~/workspace/demo-db-backup/quiz-master2.db.b9-2-start` 备份；截图用的 v2 库是单独副本；完工后 live 库已恢复为 v1，md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`（`user_version=1`，9 道题）。
- 全量日志：`~/workspace/demo-db-backup/b9-2-full2.log`（896/896，第二次跑）；第一次跑的日志 `~/workspace/demo-db-backup/b9-2-full.log`（中途停滞、2 项 /tmp 写满失败）；整理页日志：`~/workspace/demo-db-backup/b9-2-organize-after2.log`；构建日志：`~/workspace/demo-db-backup/b9-2-build-baseline.log` / `b9-2-build-after.log`。

## 过程中遇到的问题（供批末参考）

1. **VM 中途被替换**：拍改前截图期间，`/usr` 下后装的工具（xdotool、ImageMagick、ninja、clang、GTK 开发包）全部丢失，运行中的应用与 Xvfb 一并消失；`~/workspace` 与 `~/.pub-cache` 完好，代码与测试未丢。已按 `docs/ui-replication/restore-linux-toolchain.sh` 恢复工具链；另发现恢复后 Mesa 版本对不上（DRI 是 25.2.8，脚本装的 libegl-mesa0 是 noble 的 24.0.5，应用启动报 `libEGL fatal: did not find extension DRI_Mesa version 1`），已从 noble-updates 单独取 libegl-mesa0 / libgbm1 / mesa-libgallium 25.2.8 覆盖安装后恢复。`/tmp` 也被清空（探针脚本与 Xvfb 日志丢失，无影响——探针已转为常驻用例）。
2. **应用启动会删 v1 演示库**：`openAt` 按 §6 第 1 条删老库建 v2 新库——第一次直接跑基线应用时，live v1 库被删成空 v2（0 道题）。已从备份恢复 v1，并改用 B8-9 的 v1→v2 转换脚本生成截图专用库（`~/workspace/demo-db-backup/make-v2-shot-db-b9-2.py`，SRC/OUT 改成本批路径）；拍完已恢复 v1 并核对 md5。
3. **截图驱动的坑**：`xdotool search --name "quiz-master2"` 搜不到窗口——窗口名实际是 `quiz_master2`（下划线）；且有两个同名窗口，主窗口需按几何尺寸辨认（1280×720 的那个）。`xdotool windowsize` 的窗口 ID 在尺寸参数之前。
4. **旧用例 `.first` 点到全选框**：见“补充发现 2”——`popupCheckboxes` 已修正。
5. **第一次全量中途停滞 + /tmp 写满**：第一次全量跑到 subjects 页加载时停滞 12 分钟无进展（编译进程 CPU 几乎为 0，日志不再推进），同时 2 项设置缓存测试因 `/tmp` 写满（`No space left on device`，512M tmpfs）失败。已杀掉停滞的进程重跑；重跑前 /tmp 已回落到 14%，第二次跑 896/896 全过。第 1 项工人在此期间也独立跑了一次全量，同样 896/896 全过——两项失败确认为环境性（/tmp 写满），与本批代码无关。教训：同目录双全量并行会争 CPU 与 /tmp，全量应串行错开跑。

## 未动事项

- 第 1 项工人的区域（`_confirmCurrent` / `_batchConfirm` 的任务状态流转、以及 `lib/data/db_questions.dart` 里的回填）未碰；完工时 `organize_page.dart` 的 B9-2 标记全部落在 1885–2906 行（`_QueuePopupState` 内），`_confirmCurrent` 仍是 B8-6 原样。
- 未写 B9-SUMMARY.md，未发完成邮件（本批保持开放）。
