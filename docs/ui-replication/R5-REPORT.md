# R5-REPORT — 整理工作台重建

- 分支：`ui-replication`（基线 `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`）
- 视觉基准：`~/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html`，SHA256 `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`（已核对一致）
- 状态：完成并验证通过；未 commit、未 push。

## 1. 修改文件清单

| 文件 | 改动 |
|---|---|
| `lib/modules/organize/organize_page.dart` | 完全重写（约 2400 行）：H 布局、左图 + 修框切片、右表单 4 段、队列弹出层 `_QueuePopup`、两种空状态 |
| `lib/widgets/widgets.dart` | 新增 `sliceKindLabel`、`regionsOfQuestion`、`QuestionRegionOverlays`（虚线区域 + 标签）；`QuestionSlice` 失败占位改 HTML `imgFailHTML` 形态；`showQuestionZoomDialog` 重写为 `_ZoomDialog`（文字符号按钮、滚轮缩放、InteractiveViewer 平移、首帧后绕中心 1.5×）；区域标签行高 1.2→1.5（见 §5） |
| `lib/widgets/uikit.dart` | `QmGlyphs` 新增 `minus = '－'`（放大浮层 － 按钮） |
| `lib/theme/design_tokens.dart` | 新增“整理工作台实读度量”一节（grid gap 22、断点 1102、队列弹窗宽 720/顶距 54、切片卡体上限 66px、纸面最大高 480、放大浮层 900×600 等，全部取自 HTML 实读 CSS） |
| `lib/app.dart` | `OrganizePage` 构造加 `onGoCollect: () => _go('/collect')`（从未有题空状态 CTA） |
| `test/organize_page_test.dart` | 新增，23 个测试（见 §4） |
| `docs/ui-replication/run-shots-r5.sh` | 新增：normal（亮/深 × 标准/大/特大 6 张）/ empty（两种空状态）/ queue / batch / zoom |
| `docs/ui-replication/run-regress-r5.sh` | 新增：收集 → 整理 → 回首页导航回归（3 张） |
| `docs/ui-replication/shots/r5/` | 截图 14 张（11 张整理页 + 3 张回归） |

未动：其他八页、`lib/data`、`lib/services`、`lib/models` 的业务语义、`pubspec.lock`、数据库 Schema、`app_icon.ico`；R0 §6-B 业务问题、R3 待定夺项、R4 未解决问题均未顺手改。

## 2. git diffstat

R1–R5 均未提交，`git diff --stat` 为相对基线的累计值（7 文件，+5610/−1994）。R5 直接相关的部分：

```
lib/modules/organize/organize_page.dart | 3043 ++++----（2238+/805-，基本等于整页重写）
lib/widgets/widgets.dart                |  483 ++++--（累计，R5 占区域推导/高亮/放大浮层/标签行高部分）
lib/app.dart                            |  297 +---（累计，R5 仅 onGoCollect 一行）
lib/widgets/uikit.dart / lib/theme/design_tokens.dart：未追踪新文件（R1 建立，R5 追加整理度量与 minus 符号）
test/organize_page_test.dart            |  630 行（新增）
```

## 3. 结构与 token 来源

- **页结构**：页头（24px/800 + 副标题 `一道题一道题补完整，再归档进错题本`）→ 顶栏（`队列`按钮 + accent pill `还剩 N 道` + `当前整理：学科 · 题型（题名）` + 提示文案）→ H 布局：窗口宽 ≥1102 时左右两列 flex 1:1、gap 22，否则上下堆叠；无固定高度盒，整页 `SingleChildScrollView(padding: EdgeInsets.zero)`，外壳 26/30 为唯一内边距。
- **左图**：`QuestionSlice`（maxHeight 480×scale，点开放大，失败态不可点）+ `QuestionRegionOverlays`（2px 虚线框 + 区域名；stem 恒有，题干含 `（　）` 或 `______` 时加 option，sliceKind 为 chart/timeline 时加 figure）+ 三色高亮开关（只显示本题有的区，默认全开）+ 修框切片 `QmFoldSection`（默认展开；切片卡：纸面底 + 纸线边 + `切片图` tag，卡体上限 66px；选项卡为 A–D 迷你条，不编造选项文本；配图卡为迷你图；失败态时切片区隐藏）。
- **右表单**：待补充行（warn 档；只数必填项——只有文件夹；齐了显示必填已齐文案）→ 文件夹（归类，默认唯一展开；QmChip 多选 + 子文件夹 `父 / 子` + 内联新建）→ 来源（可选；试卷下拉含 `＋ 添加新试卷…` / `未归属试卷` / `名（日期）`，内联新建含 `选日期`）→ 分类补充（可选；知识点树 surface-2 容器，章节可折叠 + `已选 N 个`，树外不可新建；错误类型已选可删除芯片 + 固定枚举 + 自定义池 + `添加并选上`；标签预置易错/常考/需重做 + 内联新建）→ 答案·解析·笔记（可选；答案单行、解析 3 行、笔记 4 行，空字段跟随 `(可选，还没填）`）→ work-acts（保存草稿 / 上一道 / 下一道 / 查看题目详情）→ 确认条（QmButton large block `确认整理，去下一道`，56px 高、17.5px 字）。
- **队列弹出层 `_QueuePopup`**（OverlayEntry 定位在队列按钮正下方，宽 min(720×scale, 可用宽)，定高 `视口高 − top − 16` 上限 760×scale）：标题 `待整理队列 · N 道` + `关闭 ×`；搜索框（hint `搜题名、学科、试卷`，只匹配题名/学科/试卷，不搜题干）+ 排序下拉（168px，默认时间降序，另有时间升序、学科首字母升/降）；每行复选框 + 标题 + `删除`（danger small）；详情行只在当前题下方展开一行（`学科 · 题型 · 日期 · 试卷（来源） · 待补充 1 项/必填已齐`）；当前行 2px accent 边框 + accent-soft 底 + 4px 左侧蓝条（`IntrinsicHeight` + `CrossAxisAlignment.stretch`，否则蓝条高为 0）；点行切题（先保存当前题）；打开后滚动定位当前题；排序改动回父页（先保存、重排、回第 1 道）；单删内联确认框；批量条只在有勾选时出现（批量打标签 `#需重做`、批量加入文件夹下拉只列当前题那一科的文件夹、批量确认整理、批量删除二次确认、`取消`）；关闭（关闭按钮/遮罩/Esc）经 `_closeQueue` 清空选择。Overlay 内容包 `Material(type: transparency)`；焦点用显式 `FocusNode`（debugLabel `organize-queue-popup`）+ 首帧后 `requestFocus()`——autofocus 在 OverlayEntry 里不可靠，Esc 实测不生效后改此法。
- **业务语义沿用基线**：切题自动保存、确认后离队（`_index` 不动即指向下一题）、排序四档、文件夹必填拦下、自定义错误类型只跟本题、试卷/文件夹/标签内联新建。两处有意小修：① `_formQuestion` 加 `clearExamId`，使 `未归属试卷` 真能清空（基线 copyWith 传 null 表示保持原值，清不掉）；② 主表单删除按钮删除（HTML 主表单无删除，删除仍在队列行与详情页）。
- **空状态两种**：库里无题 → `没有待整理的题目` + `先去收集题目`；有题但待整理为空 → `都整理完了，去复习吧` + `去复习`。
- **Token 来源**：全部实读值进 `DesignTokens`（§1 表）；组件全部用 UI Kit（QmButton/QmChip/QmFoldSection/QmBanner/QmEmptyState/QmGlyph 文字符号，不用图标字体）；缩放唯一映射 1.00/1.15/1.30，字号只在 app.dart TextScaler 处乘一次，布局尺寸按 `qmScaleOf` 乘一次，不用 Transform.scale。

## 4. 测试与构建结果

- `flutter analyze`：**No issues found!**
- `flutter test` 全量：**126/126 通过**（R1–R4 的 103 个 + R5 新增 23 个）；整理页单测 23/23。
- `flutter build linux --release`：**成功**，产物 `build/linux/x64/release/bundle/quiz_master2`。
- Flutter/Dart 3.47.9 / 3.13.7，路径 `~/workspace/flutter-install/flutter/bin/flutter`。
- R5 新增 23 个测试覆盖：H 布局（左图 x < 右表单 x）、页内无边距、零 Icon、待补充行、文件夹必填拦下、确认整理进下一道、切题自动保存、修框切片默认展开、高亮开关、放大浮层（150% pill）、知识点树/自定义错误类型/预置标签、试卷下拉新建、队列单行 + 详情只展开当前题、点行跳转、搜索只匹配题名/学科/试卷（`单调` 只在题干 → `没找到这道题，换个词试试`）、默认时间降序、批量条只在勾选时出现与取消消失、批量打标签 #需重做、批量删除二次确认、单行删除确认与取消不删、关闭清勾选、Esc 关闭清勾选、空状态两种、图加载失败、亮/深 × 1.00/1.15/1.30 无溢出（主页面与队列弹窗各一循环）。

## 5. 截图对照（Xvfb 1280×720，真实库 9 题、待整理 4 道）

截图目录 `docs/ui-replication/shots/r5/`（14 张）。与 HTML 原型整理页逐条对照：

| 截图 | 对照结论 |
|---|---|
| `organize-light-standard.png` / `organize-dark-standard.png` | ✓ 页头、顶栏（队列 `还剩 4 道` + 当前整理 `政治 · 材料分析：中国式现代化`）、H 布局、左图 stem 虚线框 + 题干文本、右表单文件夹段展开 + `模拟卷` 已选、待补充行 `必填已齐`、三色高亮开关。无溢出。 |
| `organize-light-large.png` / `organize-dark-large.png` | ✓ 大档无溢出；顶栏换行（HTML flex-wrap 一致）；stem 标签完整。 |
| `organize-light-extraLarge.png` / `organize-dark-extraLarge.png` | ✓ 特大档无溢出；顶栏换两行；左导航底部需滚动才见设置按钮（R2 外壳 `SingleChildScrollView`，既有行为，见 §6）。 |
| `organize-empty-never-light-standard.png` | ✓ `没有待整理的题目` + 伴学形象 + `先去收集题目`；左导航徽标归 0。 |
| `organize-empty-done-dark-standard.png` | ✓ `都整理完了，去复习吧` + `去复习`；待整理 0、待复习数不变。 |
| `organize-queue-dark-standard.png` | ✓ 弹窗位于队列按钮正下方；`待整理队列 · 4 道` + `关闭 ×`；搜索 + `时间降序`；当前题蓝框（2px accent 边框 + 左侧 4px 蓝条 + accent-soft 底）+ 详情行 `政治 · 材料题 · 2026-11-9 · 试卷（来源）：大学思政期中试卷 · 必填已齐`；其余三行无详情行；每行复选框 + `删除`。 |
| `organize-batch-dark-standard.png` | ✓ 首行勾选后批量条出现：`批量操作 · 已选 1 道` + `批量打标签 #需重做` + 文件夹下拉（试卷）+ `批量加入该文件夹` + `批量确认整理` / `批量删除` / `取消`。 |
| `organize-zoom-light-standard.png` | ✓ 浮层 `整题图 · 放大查看` + `150%` pill + `＋`/`－`/`关闭 ×` 文字符号按钮；纸面居中 1.5×、两侧等量裁切、可拖动（见 §5 第二条）。 |
| `regress/nav-collect.png`、`nav-organize.png`、`nav-back-home.png` | ✓ 收集 → 整理 → 回首页切换正常；回首页后“继续上次：整理工作台 · 数学「函数极限」”正常，首页计数不变（3 道要复习）。 |

### 本轮截图发现并已修的两个真问题

1. **区域标签在大/特大档顶部被裁**：暗大档与亮特大档初版里 `stem 题干` 字形顶部被水平切掉。根因：标签 `TextStyle(height: 1.2)` 小于 Linux 回退字体（Noto Serif CJK）的自然行高，`RenderParagraph` 默认 clip 会裁掉超出 1.2em 行框的字形顶部；标准档字形恰好塞得下所以看不出来。修复：标签行高 1.2→1.5、内边距 3→4（`widgets.dart`）。像素扫描复核：特大档标签字形行 219–236 完整（虚线顶边 217–218、纸面顶 209），裁切图确认字形完整。
2. **放大浮层 1.5× 左上角锚定、右侧被裁**：初版纯缩放矩阵以纸面左上角为原点，纸面顶到视口左上、右边裁掉；HTML 的 paperbox 是 left:50%/top:50% 居中放。修复：`_ZoomDialog` 首帧后按纸面实测尺寸把变换改成绕纸面中心缩放（`M = T·S`，平移量 −w/4、−h/4），`translate`/`scale` 已废弃改用 `translateByDouble`/`scaleByDouble`（4 参，末参齐次 w=1）。重拍后纸面居中、两侧等量裁切。

另：截图脚本坐标两次校准——队列按钮点击由 (320,100) 改 (320,117)（落在按钮上缘外打不开弹窗）；批量条复选框点击由 (285,300) 改 (300,345)（原坐标落在搜索区）。`run-shots-r5.sh` 的 `batch` 分支目前会走全量流程（11 张全拍），不影响结果，留待后续脚本整理时再收敛。

## 6. 未解决问题

1. **Win11 字体/DPI/窗口尺寸待真机复核，Linux 结果不替代 Win11 验收。** 尤其 §5 的标签裁切修法是按 Linux 回退字体（Noto Serif CJK）验证的，Win11 用微软雅黑/等线时行高度量不同，需真机确认标签与各处 11px 小字无裁切；1280×720 以外窗口尺寸（HTML 断点 1102px 按窗口宽）也须真机复核。
2. **区域推导为已知近似**：HTML 演示 9 题中 8 题与规则（stem 恒有；题干含 `（　）`/`______` 加 option；sliceKind 为 chart/timeline 加 figure）一致；政治 p1 在 HTML 里是选择题，但 Flutter 演示题干无填空标记，无法推导，暂按 stem only 处理。真实 YOLO 第 2 层接入后以模型框为准。
3. **HTML 表单里的 `错误原因（个人备注）` 字段无对应 Question 模型字段，未加**（不改模型/Schema）。
4. **`imageFailed` 为 R3 `showBackupError` 同款展示开关**：真实图片加载通道尚不存在，失败占位目前靠开关演示。
5. **`未归属试卷` 清空行为的小修**（见 §3）：基线 copyWith 传 null 表示保持原值，`clearExamId` 使清空真实生效；语义不变，但属基线行为的修正，列出备查。
6. **主表单删除按钮移除**（见 §3）：HTML 主表单无删除，删除仍在队列行与详情页。
7. **队列弹窗定高留白**：弹窗定高 `视口高 − top − 16`，题少时列表区下方留白较多（4 道题时约半屏空白）；HTML 弹窗也是 max-height 形态，属可接受取舍，未改为按内容自适应（自适应需另算列表高度）。
8. **特大档左导航底部需滚动**：1280×720 + 1.30 档时左导航整列超出视口高，设置按钮需滚到底才可见；R2 外壳本就是 `SingleChildScrollView`（app_shell.dart:102–108，注释“整列可滚动，不溢出黄条”），行为符合设计，不是 R5 引入的问题。
9. **批量/队列行为的取舍**：批量确认只确认已选文件夹的题、缺文件夹的提示后关闭；关闭弹窗清空选择（下次打开已选 0 道）；排序改动回第 1 道；均按 HTML 与既定决策实现。

## 7. 验收后状态

- 真实库已恢复原状：9 道题、待整理 4 道、`themeMode=dark`、`fontSize=standard`；截图备份 `.qm2-r5-backup.db` 已删除。
- 未 commit、未 push。
