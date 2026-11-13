# R4 报告：收集中心重建

- 范围：只重建收集中心（`lib/modules/collect/collect_page.dart`，含修框编辑器
  `_BoxEditorDialog`）及收集必需的最小共享改动；不碰其他八页、`lib/data`、
  `lib/services` 的业务语义；YOLO 仍是占位实现，未动。
- 基线：分支 `ui-replication`，基线提交
  `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`；视觉基准
  `quiz-master2-jiao-hu-yuan-xing.html`，SHA256 已核对一致
  `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`。
- 前置：R1（Tokens/Theme/UI Kit）、R2（外壳）、R3（首页）已完成并验证通过。
- 未 commit、未 push。

## 1. 修改文件清单

| 文件 | 改动 |
|---|---|
| `lib/modules/collect/collect_page.dart` | 完全重写：原 892 行 → 现 2452 行。收集页主体 + `_BoxEditorDialog` 修框编辑器 + `_DashedDropPainter` 虚线画笔 + `_BoxEdit` 扩展 |
| `lib/theme/design_tokens.dart` | 新增“收集中心实读度量”一节（R4 增量；该文件为 R1 新增的未跟踪文件，增量不体现在 git diff 里） |
| `test/collect_page_test.dart` | 新增，25 个 widget 测试 |
| `docs/ui-replication/run-shots-r4.sh` | 新增，截图脚本（13 张） |
| `docs/ui-replication/run-regress-r4.sh` | 新增，导航回归脚本（3 张） |
| `docs/ui-replication/shots/r4/` | 新增，13 张截图 + `regress/` 3 张 |
| `docs/ui-replication/R4-REPORT.md` | 本报告 |

git diffstat（只列已跟踪文件；`test/` 与 `docs/ui-replication/` 未跟踪，不计入）：

```
lib/modules/collect/collect_page.dart | 2700 ++++----（2130 insertions, 570 deletions）
```
工作树内 R1–R3 的未提交改动仍在同一工作树内，R4 改动叠加其上；全树
`git diff --stat` 共 6 个已跟踪文件、3032 insertions / 1136 deletions。

## 2. 结构与 token 来源

### 2.1 收集页结构（自上而下）

页头（标题 + 流程副标题）→ 失败错误横幅（有失败任务时，err 档，可关闭）→
导入学科行（下拉默认“请选择学科”，每次导入都自己选，没选不能导入，
选完一批后清空）→ 拖放区（虚线框 + 只收 PDF/JPG/PNG、PDF 50MB / 图片
20MB、手机传文件说明行微信/QQ/局域网，无单独拍照入口）→ 任务区
（标题 + “按导入时间排，新的在上面，不按状态排”口径行 + 状态筛选 chips
全部/导入中/排队中/待框选/修框中/待整理，只过滤不重排）→ 任务列表
（>3 个任务时变内部滚动区，≤3 个用 Column）→ 空状态（`QmEmptyState`）。

- 页内边距已去掉：`SingleChildScrollView(padding: EdgeInsets.zero)`，
  总缩进落到外壳的 26/30（测试“页内无边距”覆盖）。
- 全部取 DesignTokens 与 UI Kit（`QmButton` / `QmChip` / `QmBanner` /
  `QmEmptyState` / `QmRowLine` / `QmFoldSection` / `QmGlyph`）；全文件无
  `Icon`（下拉框图标改用 `QmGlyph(chevronDown)`，并改用 `DropdownButton`
  而非已废弃 `value:` 的 `DropdownButtonFormField`，保证清空学科后下拉能响应）。
- 任务列表顺序 = `collectTasks()` 返回顺序（数据库 `collect_tasks` 表
  `rowid DESC`，即导入时间新→旧），页面不做任何状态重排。
- 左导航收集角标沿用基线口径（`CollectPage.countPendingBox` 待框选 +
  修框中 + 未整理题数 `pendingOrganizeCount`），不改 repository。实测：
  种子库角标 6 = 待框选/修框中 2 + 待整理题 4。

### 2.2 任务行（6 态）

| 状态 | 行内容 |
|---|---|
| 导入中 | 进度条（高 8、圆角 99）+ “导入中 N%”药丸 +「取消导入」直接删任务，无二次确认 |
| 排队中 | “排队中”药丸 +「取消排队」直接删任务 |
| 待框选 | “待框选”药丸 +「修框」+「去整理」 |
| 修框中 | “修框中”药丸 +「继续修框」+「去整理」 |
| 待整理 | “待整理”药丸 +「去整理」 |
| 失败 | “导入失败”药丸 + 具体原因（err 色）+「删除任务」，无二次确认、无重试 |

- 取消导入 / 取消排队 / 删除任务均直接删任务（取消计时器 +
  `deleteCollectTask` + 重载），无二次确认。
- 失败任务同时在页顶出错误横幅（含文件名与原因，可关闭）。
- 重复文件 / 超限不再用 SnackBar：先出黄色 `QmBanner`（重复：“这个文件
  已经导入过。”+「仍然再导一份」/「不导了」；超限：“文件超过大小上限，
  只是提示，不直接判失败。”+「仍要导入」/「先不导」），用户确认后才执行导入。
- 拖放区在 Linux/Windows 下仍只有占位文案（“拖放导入还没接好，先点
  「选择文件」导入”），系统拖拽未接是基线已知未实现项，未谎称已接通。
- 不抄入的纯设计说明：收集页底部的“任务保留口径”长段、页头设计说明文字；
  不复活旧翻卡模型；不照搬静态演示数字（待整理等按库实时算）。

### 2.3 修框编辑器（`_BoxEditorDialog`，860×648）

- 标题行（文件名 + 页码 + 本页题数 + 学科已选定不可改）→ 操作说明折叠区
  → 状态横幅（内框模式 info / 无框 warn“没框到题”/ 重叠 err“框重叠”）
  → 工具栏（删除选中框 / 旋转整页 / 恢复自动框 / 缩放百分比 / 重置视图）
  → 画布 → 底部提示 + 取消/确认 → 页缩略图条（62×34，可点切页，
  “本页修完 ✓”）。
- 多页：`_boxesByPage` 按页存框，切页不丢框。
- 画框：画布底层用 `Listener` 原始指针事件（`onPointerDown/Move/Up`，
  经 `_canvasKey` 的 RenderBox 换算为画布坐标），不走手势竞技场；指针按下
  画布时锁滚动（`_scrollLocked` → `NeverScrollableScrollPhysics`，抬起恢复）。
- 画完弹出类型菜单（默认“题级框 · 默认”高亮，另有 stem/option/figure +
  ✕ 放弃）；外层模式下选 stem/option/figure：落在某题级框内则挂为该题的题内框，
  否则作独立题内框（确认拆分时只按题级框计数）；内框模式下只提供
  stem/option/figure，钳制在所属题级框内。
- 双击题级框进内框模式（首次进入时自动生成 stem/option/figure 三个默认内框，
  纵向三段 50%/22%/22%）；题级框冻结显示（半透明 + “内框模式 · 已冻结”）；
  Esc 退出内框模式；内框横幅（info 档 +「退出内框模式」按钮）。
- 框操作：拖框移动、四角缩放柄（nw/ne/sw/se）、题级框右上角旋转圆柄（`↻`，
  按指针相对框中心的角度算旋转角，`Transform.rotate` 呈现）；旋转/缩放柄拖动时
  `_suppressDraw` 抑制画框误触。题内框用虚线边（`_DashedDropPainter` 作前景画笔，
  HTML `.inner-region` 为 1.5px dashed 区域色）。
- 「旋转整页」每次 +90°，真实变换百分比坐标：
  `(x,y,w,h) → (1-y-h, x, h, w)`，并显示“整页已旋转 N°（图片和框一起转的）”；
  「恢复自动框」重新调 `YoloOnnxService().detectPage`；「重置视图」恢复缩放
  1.0；滚轮缩放 0.5–3.0 并显示百分比。
- 确认拦下条件：总题级框数为 0、任意页题级框重叠（`_hasOverlap`）、或有未选
  类型的待定框时确认按钮禁用；无框时出 warn 横幅“没框到题”，重叠时出 err
  横幅“框重叠”。
- 打开时先把任务置为 boxing 并保存；取消（返回 null）时任务保持 boxing
  （不回待框选），只重载；确认返回各页题级框的 Map，调用方按框数拆分：
  每框建一个 Question（标题“文件名 · 第P页 · 第i题”）+ 一个 pendingOrganize
  新任务，删掉原任务，保存 recentTask，提示“已生成 N 道题，去整理吧”。
- 没有框偏提示，自己看图拖边改。
- 已知取舍：圆柄旋转是编辑器内视觉旋转（`Transform.rotate`），`QuestionBox`
  模型没有旋转字段、框也不落库（当前架构里框只决定拆分题数与标题），所以圆柄
  旋转不改变返回的百分比坐标；「旋转整页」则真实变换百分比坐标。

### 2.4 Token 来源（`design_tokens.dart`“收集中心实读度量”一节）

| Token | 值 | 来源 |
|---|---|---|
| `collectDropPadding` | 30 | HTML `.collect-slot .drop` padding 实读 |
| `collectDropTitleFontSize` | 17 | HTML `.drop .dt` 字号实读 |
| `collectTaskScrollHeight` | 408 | HTML `.task-scroll` 高 408px（桌面宽基准） |
| `collectTaskRowPaddingV/H` | 14 / 6 | 任务行内边距实读 |
| `collectEditorDialogWidth/Height` | 860 / 648 | 编辑器对话框实读 |
| `collectEditorThumbWidth/Height` | 62 / 34 | HTML `.page-thumb .pt-box` 62×34 |
| `collectEditorCanvasWidth/Height` | 560 / 700 | 画布基准（页比例 560:700） |

其余颜色/字号/圆角/间距全部取 R1 Tokens 与 UI Kit，未引入新色值与新字号。

## 3. 验证结果

### 3.1 analyze / 测试 / 构建

- `flutter analyze`：**No issues found!**
- `flutter test` 全量：**103/103 通过**（R1–R3 的 78 个 + R4 新增 25 个；
  `test/collect_page_test.dart` 单独跑也是 25/25）。
- `flutter build linux --release`：**成功**，产物
  `build/linux/x64/release/bundle/quiz_master2`（见 §3.4 构建环境记录）。
- Flutter/Dart 3.47.9 / 3.13.7，位置
  `~/workspace/flutter-install/flutter/bin/flutter`（不在默认 PATH，需 export）。

### 3.2 测试覆盖（`test/collect_page_test.dart`，25 个）

6 态渲染、只按导入时间排、筛选不重排、>3 任务内部滚动区、≤3 无滚动区、
没选学科警告、取消导入直接删、失败删除无确认、去整理回调、空状态、
取消修框留修框中、双击进内框 + Esc 退出、画新框选类型 + 确认拆成 2 个
待整理任务并替换原任务（原任务 id 在 `deletedTaskIds` 中，2 个新
pendingOrganize 任务 + 2 个 Question）、重叠拦确认、无框提示 + 确认不可点、
旋转整页 90°/180°、缩略图条 + 旋转圆柄拖动、单框确认、亮/深 × 三档缩放
（1.00/1.15/1.30）无溢出、修框编辑器三档缩放、空状态三档缩放、收集页与
编辑器无 `Icon`、页内无边距（`SingleChildScrollView` padding 为
`EdgeInsets.zero`），另加本轮新增的 2 个回归测试：

- 内框模式三个默认内框全部落在画布可视区内（画布按页 fit，见 §4.1）；
- 有框未选中时底部提示不是“没框到题”，删空后才是（见 §4.2）。

### 3.3 截图（Xvfb 1280×720，`docs/ui-replication/shots/r4/`）

种子库（6 态各 1，显示顺序为 rowid DESC）：导入中 68% 数学
“高等数学导数练习.pdf”（2 页）、排队中英语、待框选数学（3 页）、
修框中政治、待整理英语、失败“政治模拟卷.pdf”（“PDF 损坏打不开：
无法读取任何页面”）。截图前整库备份到 `/tmp/qm2-r4-orig.db`，跑完恢复
原库与 settings 原值（themeMode/fontSize）；验证库最终状态：questions
9 道、collect_tasks 0 条、themeMode=dark、fontSize=standard。

| 截图 | 内容 |
|---|---|
| `collect-light-standard.png` | 亮 / 标准 |
| `collect-light-large.png` | 亮 / 大 |
| `collect-light-extraLarge.png` | 亮 / 特大 |
| `collect-dark-standard.png` | 深 / 标准 |
| `collect-dark-large.png` | 深 / 大 |
| `collect-dark-extraLarge.png` | 深 / 特大 |
| `collect-empty-light-standard.png` | 空状态（亮） |
| `collect-empty-dark-standard.png` | 空状态（深） |
| `collect-failed-light-standard.png` | 失败态（列表滚到底，失败行完整露出原因） |
| `editor-light-standard.png` | 修框编辑器（亮） |
| `editor-inner-light-standard.png` | 修框编辑器 · 内框模式（亮） |
| `editor-dark-standard.png` | 修框编辑器（深） |
| `editor-inner-dark-standard.png` | 修框编辑器 · 内框模式（深） |
| `regress/nav-collect.png` | 回归：收集中心 |
| `regress/nav-organize.png` | 回归：整理工作台 |
| `regress/nav-back-home.png` | 回归：回首页 |

实测坐标记录（标准字号 1280×720）：导航收集中心 (100,139)；特大字号
导航项变高，收集中心移到约 y=170（(100,139) 会点中首页，脚本已按字号
分支）；单任务行「修框」按钮 (820,570)；编辑器内题级框中心 (640,355)，
双击进内框模式。

### 3.4 构建环境记录（本轮新发现，R5–R11 构建前须知）

1. GTK 开发头文件丢失：`flutter build linux` 报
   `PkgConfig::GTK includes non-existent path "/usr/include/gtk-3.0"`。
   用 `apt-get download libgtk-3-dev libgdk-pixbuf-2.0-dev libtiff-dev
   libzstd-dev` 取包后，`dpkg-deb -x` **直接解到 `/usr` 会静默失败**
   （退出 0 但文件不出现，疑似 overlay 怪象）；须先解到 `/tmp` 再
   `cp -r` 进 `/usr`，`pkg-config --exists gtk+-3.0` 验证通过才算装好。
2. 一次失败的 configure 会把 `CMAKE_INSTALL_PREFIX=/usr/local` 写进
   `build/linux` 的 CMakeCache，之后 `flutter build` 会装到 `/usr/local`
   而非 `bundle/`（flutter tool 仍打印 `✓ Built bundle`，容易误判）。
   修复：`rm -rf build/linux` 后用
   `cmake -G Ninja -S linux -B build/linux/x64/release
   -DCMAKE_BUILD_TYPE=Release
   -DCMAKE_INSTALL_PREFIX=$PWD/build/linux/x64/release/bundle`
   预配再构建；当前缓存已是 bundle，之后构建正常。
   附带：只改 Dart 代码时 runner 二进制不重新链接，以
   `bundle/lib/libapp.so` 的时间判断构建是否新鲜。

## 4. 截图审查中发现并修复的三个真问题

审查方法：截图脚本跑完后逐张实读，与 HTML 原型逐条规则对照；发现问题后
先写探针测试定位根因再修，均有回归测试覆盖。

### 4.1 画布固定 560×700 + 滚动视口，默认只露上半页（主修）

- 现象：内框模式截图里只见到 stem 一个虚线框，option/figure 不见了；
  探针测试量得三内框矩形：stem y 299–575、option y 586–708、figure
  y 719–840，而画布可视区只有 y 285–546——框按 700px 页高布局，
  可视区只有 261px（测试视口）/ 约 365px（1280×720 真实窗口），
  option/figure 全在折叠线下。
- 根因：画布是固定 560×700 的页放在内外两层滚动视图里，不 fit 视口。
  而 HTML 原型是“画布完整显示一页题”（`.frameedit.frame-overlay`
  688px 高，`.framepage{flex:1}`，stage 按比例 fit 进可用区、居中放页）。
- 修复：对话框内用 `LayoutBuilder` 量可用区，`fit = min(宽/560, 高/700)`，
  页按 560×700 比例 fit 进可用区，滚轮缩放再乘 `_scale`；页小于视口时
  在画布内居中（HTML 原型也是居中放页），放大超过视口时按页尺寸滚动。
  框按页面百分比存，fit 不改任何框坐标；缩放 >1 时滚动仍可用。
  回归测试“内框模式三个默认内框全部落在画布可视区内”覆盖。
- 附带：居中后两个画框测试的拖动起点落到页外失败，测试改按当前画布
  矩形重算 fit 原点与页尺寸（删框会出 warn 横幅把画布顶下移 90px，
  所以每次拖动前都要重算，不能复用删除前的原点）。

### 4.2 底部提示默认分支恒为“没框到题”

- 现象：编辑器已有 1 个框、未选中任何框时，底部提示仍是“没框到题，
  请用鼠标拖一个框…”。
- 根因：`_foot` 的 hint 三元链默认分支没有区分“无框”和“有框未选中”
  （warn 横幅本身正确地只在 `_boxes.isEmpty` 时出现）。
- 修复：默认分支按 `_boxes.isEmpty` 分流：无框时仍是“没框到题…”；
  有框时改为“本页已框 N 道题 · 点框可选中拖动 / 缩放 · 双击题级框进内框
  模式改题内框 · 空白处拖动可再画新框”。回归测试覆盖。

### 4.3 内框模式冻结标签被 stem 框顶边划穿

- 现象：放大截图可见冻结标签“题级框 1 · 内框模式 · 已冻结”被 stem
  框的顶边虚线划穿——stem 段从父框顶下 2% 起，父框标签在顶内 2px，
  两者重叠。
- 修复：冻结标签改贴题级框底边（`top: 2` → `bottom: 2`；figure 段
  底在 0.844，父框底在 0.90，底部留白足够）；同时占位页图说明从页中央
  移到页底留白处（中央会被框盖住），且内框模式下不显示占位说明
  （冻结标签已贴底边，会和页底说明重叠；横幅已说明内框模式上下文）。

## 5. HTML 原型对照结论

逐条 HTML CSS/JS 规则 → Flutter 截图实测值（本机无 headless 浏览器，
沿用 R2/R3 做法）：

| HTML 规则 | Flutter 实测 | 结论 |
|---|---|---|
| 导入学科下拉默认“请选择学科”，每次都选，没选不能导入，选完清空 | 下拉默认 null 显示“请选择学科”；没选点导入出黄色 banner“先选学科。”；导入成功后 `_selectedSubjectId` 清空 | ✓ |
| 拖放区虚线框 + 只收 PDF/JPG/PNG、PDF 50MB / 图片 20MB（超限只提示不判失败） | 虚线 accent 边 + accent-soft 底 + 两行规则；超限/重复均为黄色横幅，可选择仍要导入 / 不导 | ✓（横幅逻辑有实现，无 widget 测试覆盖，见 §6） |
| 手机传文件说明行（微信/QQ/局域网，无单独拍照入口） | “手机拍完用微信 / QQ / 局域网传到电脑，再选文件导入即可——传过来的就是文件，不用单独的拍照入口。” | ✓ |
| 任务 6 态 + 各态按钮 | 导入中（进度条 68% + 取消导入）、排队中（取消排队）、待框选（修框/去整理）、修框中（继续修框/去整理）、待整理（去整理）、失败（原因 + 删除任务） | ✓（失败态截图） |
| 列表只按导入时间排，新的在上，永不按状态重排 | 截图顺序：导入中 → 排队中 → 待框选 → 修框中 → 待整理 → 失败（= 插入逆序） | ✓ |
| >3 个任务时列表变内部滚动区（`.task-scroll` 高 408px） | 6 任务时列表为固定高 408×缩放的内部 `ListView`；≤3 时为 Column（测试覆盖） | ✓ |
| 状态筛选 chips 只过滤、不改变时间顺序 | 全部 6 / 各态 1，代码只过滤；测试“筛选不重排”覆盖 | ✓ |
| 修框编辑器：页缩略图条 + 画布 | 缩略图 62×34，三页 +“本页修完 ✓”；画布按页 fit 完整显示（§4.1 修后） | ✓ |
| 两级框（题级框 + stem/option/figure 内框） | 内框模式截图：stem/option/figure 三段虚线框 + 各自标签 + 颜色区分 | ✓ |
| 空白处拖动直接画新框，画完选类型（默认题级框） | 类型菜单默认“题级框 · 默认”高亮；测试覆盖 | ✓ |
| 双击题级框进内框模式 | 双击进内框 + Esc 退出（测试 + 截图）；题级框冻结半透明 | ✓ |
| 题级框右上角圆柄拖动旋转 | 圆柄 `↻` 在右上角；测试“旋转圆柄拖动”覆盖；旋转为编辑器内视觉旋转（§2.3 取舍） | ✓ |
| 「旋转整页」每次 90° | 真实变换百分比坐标；测试 90°/180° 覆盖 | ✓ |
| 框按页面百分比存、只能在图内 | 画框/拖框/缩放均钳制到页内（`_clampBoxSafe`，见 §6） | ✓ |
| 取消中途退出 → 任务留“修框中” | 测试“取消修框留修框中”覆盖 | ✓ |
| 确认按框数拆分，原任务被拆出的新任务替换 | 测试覆盖：2 框 → 2 个 pendingOrganize 新任务 + 2 个 Question，原任务 id 在 `deletedTaskIds` 中 | ✓ |
| 没有框偏提示 | 无相关文案；操作说明只写拖边改 | ✓ |
| 亮/深两套、三档缩放 1.00/1.15/1.30 无溢出 | 6 张正常态截图逐张实读，无溢出；特大字号导航点击坐标已按字号分支（§3.3） | ✓ |
| 左导航收集角标 = 待框选 + 待整理任务数 | 沿用 R2 口径（不改 repository）：截图角标 6 = 待框选/修框中 2 + 待整理题 4 | ✓（口径与 R2 报告一致） |
| 页内无边距，总缩进落到外壳 26/30 | `SingleChildScrollView(padding: EdgeInsets.zero)`；测试覆盖 | ✓ |

对照中发现的差异均已在 §4 修完并重拍验证；其余逐项一致。

## 6. 未解决问题与待办

1. **Win11 真机复核（R11 验收项）**：Linux 截图结果不替代 Win11 验收；
   字体/DPI/窗口尺寸（1280×720 以外）待真机复核。
2. **YOLO 真模型接入与 Win11 实测**：仍是占位实现（onnxruntime 版本未锁定、
   真实模型文件未接入），记为后续集成待验证事项；R4 未动 YOLO 业务代码。
3. **系统拖拽未接通**：拖放区只有诚实占位文案，文件拖放导入仍未实现
   （基线已知未实现项）；「选择文件」导入可用。
4. **重复/超限黄色横幅无 widget 测试、无截图**：实现已在（QmBanner warn +
   确认后执行导入），但 25 个测试未覆盖这两条分支，截图种子也未触发；
   建议后续补一个 FakeRepo/文件选择桩覆盖，或在验收时手动点一次。
5. **`clampToPage` 贴边抛错是基线服务缺陷**：`YoloOnnxService.clampToPage`
   要求宽/高至少 0.08，框贴右/下边时（`1.0 - x < 0.08`）会抛
   `ArgumentError`；编辑器内 `_clampBoxSafe` 已兜底（bound 取 0.90，
   注意 0.92 不够：`1.0 - 0.92` 的浮点值是 `0.07999… < 0.08`，仍抛错）。
   YOLO 服务本身未动。
6. **画框时缩放 >1 下滚动锁需一帧生效**：指针按下锁滚动在 pointer-down
   时生效（手势竞技场裁决前），已有测试覆盖；真实高频拖动下的手感待
   Win11 真机复核。
7. **R0 §6-B 业务问题冻结未动**；HTML 死代码未实现；`app_icon.ico` 未动
   （SHA-256 仍为 `c098d3fc85cacff98b8e69811b48e9f0d852fcee278132d794411d978869cbf8`）；
   R3 报告里的待定夺项（最近任务 kind 中英文两套写法、错误态 app 级接线）
   与本页无关，未顺手改。
8. **截图脚本依赖**：`/tmp` 不可靠（一次运行中 `/tmp` 下的临时文件在
   后续调用时消失）；截图脚本的库备份在 `/tmp/qm2-r4-orig.db`，跑完即恢复，
   长期备份不要放 `/tmp`。另：脚本启动时若库已被交互探针弄脏，恢复的
   只是“脚本启动时”的状态——本轮已手动把库恢复为真原值（9 题 / 0 任务 /
   dark / standard），见 §3.3。
9. **圆柄旋转不落库**（§2.3 取舍）：编辑器内视觉旋转，不改变返回的百分比
   坐标；如后续要把旋转角存进模型，需先给 `QuestionBox` 加旋转字段并改
   Schema——不在 R4 范围内。

## 7. 测试中发现并修复的旧问题（R4 代码完成时已修完，列备查）

1. 画框手势与滚动视图竞争：`GestureDetector` 的 pan 会被滚动视图抢走。
   改为 `Listener` 原始指针事件画框 + 指针按下锁滚动。
2. 旋转柄拖动会误触画框（柄在框外，按下同时命中画布层）：柄的
   `onPanDown` 置 `_suppressDraw`，`onPanEnd/Cancel` 清除。
3. 框单击选中延迟：含 `onDoubleTap` 的 `GestureDetector` 会等 300ms
   双击超时才触发 `onTap`；测试里单击框后需 `pump(500ms)` 再断言选中。
4. `pumpWidget` 会复用同型同位置的旧 `State`：循环测试里每轮必须给
   `CollectPage` 传不同的 `Key`（`ValueKey`），否则新 FakeRepo 不生效。
5. `scrollUntilVisible` 在多滚动区（页面滚动 + 任务 ListView）下抛错：
   改用 `ensureVisible`。
6. `QmBanner` 是 `Text.rich`（标题+正文同一 Text），`find.text('标题')`
   精确匹配失败：测试改用 `find.textContaining(...)`。
7. `ListView.builder` 懒构建 + 滚动后丢弃屏外行：6 态测试须按位置分段断言
   （先断言首屏行，再 `ensureVisible` 到各行断言）。
