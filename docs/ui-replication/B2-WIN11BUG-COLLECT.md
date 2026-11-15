# B2 Win11 bug 批 · 收集中心（工人 A）报告

- 工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`，未推代码。
- 负责：Bug 1（导入学科下拉框）、Bug 6a（收集任务删除）、Bug 6b（修框 overlay 高度 + 鼠标行为）。
- 只动了：`lib/modules/collect/collect_page.dart`、`lib/data/database.dart`（删除方法语义扩展）、`lib/theme/design_tokens.dart`（删一个已无用的 token）、测试 `test/collect_page_test.dart`、`test/p1_schema_backup_test.dart`。未动 `organize_page.dart`（另一位工人的文件）。
- 报告文件：`docs/ui-replication/B2-WIN11BUG-COLLECT.md`（本文件）。

## 验证总览

- `flutter analyze`：收工时复核 0 问题。（中间一度有 1 条 info 在 `lib/modules/organize/organize_page.dart:184`，是另一位工人并发编辑时引入的，收工复核时已消失，不在本人范围内。）
- `flutter test test/collect_page_test.dart`：37/37 通过（基线 28 + 新增 9）。
- `flutter test test/p1_schema_backup_test.dart`：21/21 通过（基线 20 + 新增 1）。
- `flutter test test/p3_backup_migration_test.dart test/detail_page_test.dart test/pdf_collect_page_test.dart`：54/54 通过。
- Linux 真机启动验证：见末尾「真机验证」一节。
- 全量测试：未由本人单独跑——执行期间另有进程在同一树上跑全量（`flutter test`，自带备份 `/tmp/qm2-b2-cover-mybackup.db`），为避免工具锁争抢与真实库争用，未并行再跑一份。相关测试已全部覆盖本人改动。
- 演示库：开工前本人备份 `~/workspace/demo-db-backup/quiz-master2.db.b2-collectA-start`（md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，与协调员备份一致）。执行期间真实库 md5 一度变为 `2fac7abd…`（11:39:56，并发全量测试的 p0 §4.1 单例测试所致），后由该并发进程恢复回 `8f7f9c64…`；本人未恢复（避免覆盖并发进程的状态），收工时核对仍为 `8f7f9c64…`。本人针对性测试均不碰真实库（FakeRepo / 内存库 / 临时目录）。

## Bug 1 — 选完学科后下拉框一直保持灰色（像禁用态）

### 根因

不是禁用态。`_importRow` 的外层 `Container` 只给了边框、没给底色；`DropdownButton` 内部的 `InkWell` 在 Win11 桌面默认 traditional 高亮模式下，按钮获焦时会画系统 `focusColor`（12% 黑），悬停再叠 `hoverColor`（4% 黑）。截图灰色经像素取样为 #D7D6D2，与 focus+hover 两层叠加在 surface #FFFEF9 上的计算值逐通道吻合（±1）。选完学科后鼠标点过下拉框，按钮一直保有焦点，灰色就一直留在那里；占位态截图里是白的，是因为当时既无焦点也无悬停。Flutter 原生 `DropdownButton` 本身不画背景，灰色完全来自这两层 InkWell 洗色。

### 改动（`lib/modules/collect/collect_page.dart`，`_importRow`）

- 外层 `Container` 增加 `key: Key('collect-subject-select-field')` 与显式 `color: palette.surface`（亮色 #FFFEF9 / 深色 #262B33），字段底色从此有确定值。
- `DropdownButton` 增加 `focusColor: Colors.transparent`，去掉持久的获焦灰洗。
- 悬停那层 4% 黑没动：它是标准 Material 反馈、鼠标移开即消失；`DropdownButton` 本来就没有 `hoverColor` 参数，包一层改主题 `hoverColor` 会连下拉菜单项的高亮一起去掉，得不偿失。
- 占位「请选择学科」仍是原来的 `hint`（muted 色），未动。

### 验证

- 新增 widget 测试（`test/collect_page_test.dart`，B2 组）：
  - 「B2-1 选中学科后下拉框是正常底色，不是禁用灰」：选「数学」后字段 `Container` 的 `BoxDecoration.color` == 亮色 surface，`DropdownButton.value == 'math'`，`focusColor == transparent`，占位文案消失。
  - 「B2-1 深色下选中学科后下拉框也是正常底色」：深色主题下选「英语」，字段底色 == 深色 surface。

## Bug 6a — 收集任务增加删除功能

### 数据现状核对（写代码前已核对）

- `questions` 表**没有** `collect_task_id` 列。任务→题的唯一纽带是 `collect_tasks.question_id`（`CollectTask.questionId`，注释写明“修框确认后产出的题目 id（一对一）”；`_confirmSplit` 里每个拆分任务都带 `questionId: qid`）。
- “待整理 / 已整理”看 `questions.is_organized`（0 = 待整理，1 = 已整理）。
- 已有 `deleteCollectTask` / `deleteCollectTaskFrom`，原来只删草稿框（`collect_task_id = ? AND question_id IS NULL`）+ 任务行 + 无引用任务目录，不删题。所以不需要新方法，扩展原方法语义即可。

### 改动

**数据层（`lib/data/database.dart`，`deleteCollectTaskFrom`）**：一次事务内先读任务指向的题（`is_organized` 在事务内读，避免读到删之间被整理工作台改掉状态）：

- 该题存在且 `is_organized != 1`（待整理）→ 经现有 `_deleteQuestionTxn` 删题（含其框、解决记录、自查历史、复习队列项），事务提交后删其无引用的切片文件（与 `deleteQuestionFrom` 同款）；
- 已整理（`is_organized == 1`）→ 题、框、切片一律不动，只断开任务指向（任务行删除即断开）；
- 再删未确认草稿框、任务行；任务目录仍按 §4.5 规则（无题引用才删）。

**UI（`lib/modules/collect/collect_page.dart`）**：

- `_taskActions` 给原来没有删除入口的行加了「删除」：待框选（修框 / 去整理 / 删除）、修框中（继续修框 / 去整理 / 删除）、待整理（去整理 / 删除）、已整理（删除）。
- 新增 `_deleteTask`：先弹确认框（项目统一文案 `删了就没了，确定吗？`，内容说明删任务 + 草稿 + 未整理题、已整理题保留），确认后调 `repo.deleteCollectTask` 并刷新。
- **有意没动**：导入中 / 排队中 / 失败任务的「取消导入 / 取消排队 / 删除任务」仍走原 `_removeTask`（直接删、无二次确认）——现有测试 `取消导入直接删任务，无二次确认`、`失败任务点删除任务直接删，无二次确认` 是已定行为，本批任务说的是“每行加删除入口”，失败行已有删除入口；是否把失败行的删除也改成弹确认，由 Meng / 协调员定（改动只是一行，见「需 Meng 决定」）。

### 验证

- 新增数据库测试（`test/p1_schema_backup_test.dart`）：「B2-6a 删任务：拆出的待整理题随任务删，已整理的题保留」——待整理题 q1 + 已整理题 q2 各挂一个任务，另有 q1 的确认框、task-1 的草稿框、q2 的确认框；删 task-1 后只剩 q2 / box-q2 / task-2；再删 task-2 后 q2 与框仍在、任务行清空。
- 新增 widget 测试（`test/collect_page_test.dart`，B2 组）：
  - 「B2-6a 待框选/修框中/待整理/已整理行都有删除入口」：3 行共 3 个「删除」。
  - 「B2-6a 点删除先弹确认框，取消不删、确认删除」：弹 `删了就没了，确定吗？`，点「取消」任务还在、`deletedTaskIds` 为空；再删并点「确认删除」，任务消失、`deletedTaskIds` 含该任务。
- 既有测试未改仍通过：`test/p3_backup_migration_test.dart` 的删任务目录测试（其任务 `question_id` 为 null，不受新语义影响）。

## Bug 6b — 修框页面太小 + 鼠标行为

### 6b(1) overlay 高度

- 现状：对话框高 `min(648 * scale, 视口高 - 48)`，1080p 上画布只剩约 480px；对话框宽 860 不变时竖版页图在宽对话框里本来就显小。
- 改动（`_BoxEditorDialogState.build`）：高度改为 `size.height - 48`（只留 `insetPadding` 的 24px 上下边距），画布是 `Expanded`，随对话框一起变大。宽度仍 `min(860 * scale, 视口宽 - 48)`，没动。
- 删了 `DesignTokens.collectEditorDialogHeight`（648）这个 token：全仓只剩这一处引用，留着是死代码。
- 验证：新增测试「B2-6b 修框 overlay 高度接近视口高，画布随之变大」——1280×1000 视口下对话框高 = 952，画布高 > 480（注：720 高视口下画布本来就只有约 357px，任务说的 480 是 1080p 真机数，测试用 1000 高视口才测得出新旧差别）。

### 6b(2) 鼠标行为

**现状核对**：

- 滚轮：画布内层 `Listener.onPointerSignal` 无条件缩放，图外灰色边距滚轮也在缩放。
- 左键：画框层 `Listener` 只认主按键，空白处左键拖动 = 画框；框上的 `GestureDetector.onPanUpdate` = 拖框移动。
- 右键：只在内框模式下按下即退出内框模式，其余情况无动作。
- 另有两个实现前提：Flutter 默认的拖动滚动只认触摸类设备（`ScrollConfiguration.dragDevices` 默认不含鼠标），鼠标左键拖动本身滚不动；滚动锁 `_scrollLocked`（`NeverScrollableScrollPhysics`）会把滚动手势识别器整个移除，是框拖动不被滚动抢走的保障。

**改动（都在 `lib/modules/collect/collect_page.dart` 的 `_BoxEditorDialogState` / `_canvas`）**：

- 滚轮：`onPointerSignal` 里先算指针的画布坐标，落在图片内才缩放；落在图外直接返回，事件交给滚动视图上下滚动（放大后才有可滚范围；未放大时无溢出、滚轮无可见效果，与任何应用一致）。
- 左键：画框层不再认主按键——左键拖动不画框；左键点在框/缩放柄上仍拖框/缩放（框自己的 `GestureDetector` 不变）；左键点在空白处不锁滚动，交给滚动视图平移图片。
- 右键：画框层只认次要按键，用按下坐标 + 4px 分界（`_rightDragSlop`）区分单击与拖动：拖出 4px 才开始画框（按下点即框起点，走原有 `_onDrawStart/_onDrawUpdate/_onDrawEnd`）；抬起时没拖过就是单击 = 取消（内框模式退出内框模式；非内框模式右键单击原来就没有动作，保持不动）。
- 触摸/手写笔：没有左右键区分，仍用主按键画框（保持原有行为；现有 `tester.dragFrom` 触摸画框测试不用改）。
- 滚动锁（外层 `Listener.onPointerDown`）：触摸按下即锁（与原来一致）；鼠标右键按下锁（画框）；鼠标左键只在点落在框/缩放柄上才锁（新增 `_pointHitsInteractive`，缩放柄伸出框外约 6.5*scale，留 8*scale 余量），空白处与图外不锁。
- 画布滚动视图包一层 `ScrollConfiguration`，`dragDevices` 显式加上鼠标（只改修框画布，不动全应用滚动行为），否则左键拖动平移在 Flutter 里根本滚不动。
- 提示文案同步更新：操作说明、没框到题横幅、工具条提示（新增框 / 内框模式）、底部提示里的“拖动可画新框 / 滚轮缩放”改成右键画框、左键平移、滚轮在图上缩放图外滚动。现有测试断言的一处文案（`没框到题，请用鼠标拖一个框…`）同步改成右键版。
- 注意：右键拖动起点落在已有框上时，`_onDrawStart` 仍按坐标判断返回不画框，框自己的手势会拖动该框（与左键在框上拖动一致）；右键单击落在框上时，单击取消照常生效（内框模式下退出）。

### 验证

- 新增 widget 测试（`test/collect_page_test.dart`，B2 组；鼠标手势用 `tester.startGesture(kind: PointerDeviceKind.mouse, buttons: …)`，滚轮用 `tester.sendEventToBinding(PointerScrollEvent…)`）：
  - 「B2-6b 滚轮在图上缩放、在图外滚动」：图上滚轮 100% → 110%，放大到 200% 后图外边距滚轮不改变倍率、竖向滚动偏移变大。
  - 「B2-6b 左键拖动平移图片、不画框」：图内框外空白左键拖动不出「这个框是？」；200% 下图外边距左键拖动使竖向滚动偏移变大。
  - 「B2-6b 左键拖框仍移动框」：先删占位框、右键画一个小框，左键拖其中心，框向右下移动（方向对、位移 > 10px；第一段位移会被手势 slop 吃掉一部分，不按精确像素断言）。
  - 「B2-6b 右键拖动画框、右键单击取消」：删占位框后右键拖动出「这个框是？」；进内框模式后在题级框外、图内的空白处右键单击，退出内框模式且不画框；非内框模式下右键单击空白无动作。
- 既有修框编辑器测试全部通过（画框、重叠拦截、旋转、草稿恢复等均未改行为——触摸画框路径原样保留）。

## 真机验证

- 2026-11-14 约 11:49（CST），Linux Xvfb 下跑 release 包一次：`flutter build linux` 成功（`build/linux/x64/release/bundle/quiz_master2`）；`xvfb-run -a` 启动后进程 45 秒仍在运行，:99 显示器上有 `quiz_master2` 窗口，日志无 Flutter 报错（只有环境相关的 DRI3 软件渲染警告与一条 Atk 无障碍警告），确认不崩溃；按 Meng 的规则未截图。
- 启动验证会打开真实库：应用开/关各写一次库，文件 md5 随之变化（逻辑内容不变，dump 与备份 0 差异）。验证后已从本人备份恢复，md5 两次核对均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，应用进程已全部退出。

## 需 Meng / 协调员决定的地方

1. **失败任务的「删除任务」要不要也弹确认框？** 本批只给新加的「删除」入口弹了确认；导入中 / 排队中 / 失败任务的取消与删除仍是直接删（现有测试明确 pin 住）。如要统一，改 `_removeTask` 走 `_deleteTask` 的确认框即可，但现有两条“无二次确认”测试要同步改。
2. **删除确认框的形式**：本批用的是模态 `AlertDialog`（与本页已有的「恢复自动框」确认同款）；详情页 / 错题本的删除确认用的是行内确认条（`删了就没了，确定吗？` + 确认删除 / 取消）。如要与详情页一致，改成行内确认条即可。
3. **下拉框悬停那层 4% 黑**：已去掉持久的获焦灰洗；鼠标悬停时仍有标准 Material 悬停反馈（极淡、移开即消失）。如要求悬停也完全无灰，需包一层改主题 `hoverColor`，代价是下拉菜单项的高亮一起消失——建议保持现状。
4. **右键拖动起点落在已有框上时仍拖动该框**（不是画新框）：与左键在框上拖动一致，是手势竞技场的自然结果；如要求右键在任何位置拖动都画框，需给框的 `GestureDetector` 加按键过滤（改动较大），请定。
5. **`flutter analyze` 全仓当时有 1 条 info**（`organize_page.dart:184`，另一位工人并发编辑引入），不在本人范围，未动。
6. **全量测试未由本人单独跑**（原因见验证总览：执行期间另有全量进程在跑）；建议协调员在合并前以干净树跑一次全量。
