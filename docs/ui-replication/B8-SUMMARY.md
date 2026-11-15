# 第八批修复总结（B8-SUMMARY）

**范围：** Meng 在 Win11 真机验收时提的 9 项（截图 image-89～97，另补 image-98 错题本书架残留）+ 审计裁决 P1-2 + 第 1 项扫尾。
**基线：** Batch 7 已推 head `622b6b6`（测试 879/879）。工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`。
**状态：** 9 项全部完成并通过门禁验证。**未提交、未推代码**——推送须 Meng 另外批准。

## 一、逐项结果

| # | 内容 | 结果 |
|---|---|---|
| 1 | 删学科后残留（导航速览、收集下拉、错题本书架、首页） | ✅ 完成。根因：8 处 `subjects.isEmpty ? Subject.all : subjects` 回退，删光学科后空表被重新解释为预设三科。修法：空表就是空，各处直接用库里列表，删空后给空状态。另补扫尾：同模式剩余 5 处（详情、整理×2、报告、复习）+ 5 处 `_subjects = Subject.all` 初始值一并清掉；现 `grep "isEmpty ? Subject.all" lib/` 零命中，仅剩 `db_schema.dart` 建表种子（正确保留）。`Subject.byId` 兜底未动（仅数据不一致时触发）。 |
| 1补 | 导航顺序/贴合度纠正（Meng 15:45） | ✅ 完成。B8-1 初版“顺序已对、不用改”结论作废：问题不是顺序，是贴合度——速览区 `Expanded` 撑满剩余空间，科少时行贴区顶、设置贴底，中间留大段空。改法：速览块底部锚定贴紧设置（`mainAxisAlignment.end` 推到底，设置顶边距 8→0，最后一行底边与设置按钮顶边重合；行多/窗口矮时区内滚动）。回归用例断言两者相邻（3 科与 0 科时底边差为 0，容差 1px）。 |
| 2 | 去掉内框模式 | ✅ 完成。内框模式横幅、“题级框 4”标签、“这个框是？” stem/option/figure 选择、双击进内框全部删除；画框直接落成题级框。`box_editor.dart` 2360→1662 行；整理页 region 开关、区域切片卡、真实二层坐标叠加层删除（B3/P1-1 特意保留的手动二层框与叠加层按 Meng 新决定一并去掉）；`widgets.dart` 的 `realRegionRects` / `QuestionRegionOverlays` 删除；stem/option/figure 三色 token 删除。只留三处重接入接口：`yolo_onnx_service` 的 `intraEnabled=false` 开关 + `_detectIntra` 占位、`question_boxes` 表（含 `layer` 列，Schema 不动）、`docs/代码地图.md` 第 8 节一处重接入点说明。decision-log 追加 D-24。删除 53 个测试（3 个整文件 + 20 个单测）。 |
| 3 | 框四角拖动不灵敏 | ✅ 完成。三个病根一起修（均在 `box_editor.dart`）：柄移到画布级浮层（`_resizeHandleOverlay`，与框体平级画在最上，不再嵌在框的 `GestureDetector` 里）；浮层柄与框移动不再争手势竞技场；`_moveBox`/`_resizeBox` 改传 `boxId`、每次按 id 读最新态（旧闭包快照丢增量）。柄命中区 24×24（视觉仍 13×13）。 |
| 4 | 鼠标滚轮 | ✅ 完成。旧外层 `Listener` 拦不住滚轮（`PointerSignalResolver` 先注册者独占、内层 `Scrollable` 先注册）。改为滚动视图内容里的 `Listener`（`_onWheel`）先注册缩放回调独占事件，图外/纯横向滚轮不注册、照常滚动；另加 `_zoomAtCursor`（双 `ScrollController`，缩放后用滚动偏移补偿，指针下的内容点保持在指针下）。步进与 0.5~3.0 范围不变。 |
| 5 | 框大小不设限制 | ✅ 完成。`_replaceBox`、`_onDrawEnd` 改传 `clampToPage(..., minSize: false)`，`_onDrawUpdate` 下限 0.01→0.0；仍钳制在页内（交集语义），拖过对边翻转归一；`<0.02` 画框丢弃保留（点按/拖动区分）。 |
| 6 | 整理工作台右侧单开手风琴 | ✅ 完成。新增 `_RightSection` 枚举 + `_toggleRightSection()`（点未展开的区只开它、其余全收；点已展开的区收起它，四区可全收）；确认校验拦下与“待补充”跳转改走 `_openRightSectionOnly()`；左栏“修框切片”独立、不参与；默认态不变（只文件夹展开）。**口径翻转：见第二节。** |
| 7 | 题目详情页重新设计 | ✅ 完成。Meng 15:44 定稿 **A 紧凑**并已落地为最终代码；B/C 方向代码分支已删，仅截图留档。实现：内容宽 1160、整题图限高 460、标题前学科图标章、副标题两行、信息条（文件夹 chip + `#标签` + 加入复习 pill）、三段头各加摘要行、底部操作收进满宽卡片；三段默认折叠、大图在上、编辑/收藏/归档/删除/上下题/加入复习行为未动。另按审计裁决做 P1-2（见第四节）。 |
| 8 | 错题本书架封面固定尺寸 | ✅ 完成。根因：宽窗口 `Row`+`Expanded` 把单本拉满全宽、窄窗口 `Column` 占满宽。定死宽 **300px** × 高 **376px**（300 的依据：HTML 预览 `.wrap` 1260 − padding − 导航 − `.main` padding 后书架区 940px，(940−44)/3 ≈ 299，取整 300；高沿用 HTML `.nb-book` min-height 376），只 × 字号缩放因子，不随窗口变；`Row`/`Column` 两路改为 `Wrap`（gap 22）；悬停、书脊、折角、虚线框、计数牌、“开始复习”未动，分页与每页 6 本未动。截图：1000px 每行 2 本、1600px 每行 3 本同尺寸、单本居左不拉满。 |
| 9 | 题目列表 UI 重新设计 | ✅ 完成。Meng 15:44 定稿 **A 留白卡片**并已落地；`b8ListStyle` 开关与 B/C 分支已删，仅截图留档。去蓝框后大卡片各成白卡，紧凑/归档行共用白卡；空状态文案已修：文件夹空显示“这个文件夹还是空的”+ 去收集/去整理引导 +“返回目录”，搜索无结果仍是“没找到这道题，换个词试试”，另有学科空、全已解决两种分流。附带修了去蓝框后分页下拉触发 `dropdown.dart:438` 的 `menuLimits` 框架断言（24px 页尾留白，产品侧修）。 |

## 二、口径翻转记录（第 6 项，必读）

第二批 Bug 4 时 Meng 要求整理表单“能同时打开多个”，`test/b2_win11bug_organize_test.dart` 当时按多开锁了行为。本次他明确改回**一次只能展开一个（手风琴）**，按这次的执行，旧决定作废；该测试文件的 Bug 4 组已按新手风琴口径重写（2/2 通过）。其余口径未变。

## 三、真实交互用例覆盖说明（按 Meng 补充要求）

本次验收暴露的审查缺口是“程序点按复现不了真机鼠标/DPI/事件透传”，第 1、3、4 项按要求加了真实交互用例，不只验逻辑：

- **第 1 项**（`test/b8_1_subject_refresh_flow_test.dart`，1 个）：真实内存库 + 真实整应用 `QuizMasterApp`，按 Meng 的操作真实点按——首页确认三科在 → 学科管理逐科点“删除”并确认 → 删光后导航速览、收集下拉、错题本书架、首页四处逐一断言界面上真的没了（只看界面不看库）。另有 12 个逻辑用例（`b8_1_subject_refresh_test.dart`）与扫尾 6 个（`b8_1_subject_sweep_test.dart`，其中报告页分布行、复习页学科筛选下拉是真能抓 bug 的差分断言）。
- **第 3 项**（`test/b8_345_box_interaction_test.dart` 中 6 个）：真实鼠标拖柄，逐个角拖动（放大 + 缩回）、角外 10px 抓柄（旧柄够不到）、角外 16px 抓不到的对照；用确认返回的 `BoxEditorResult` / 屏幕矩形断言。
- **第 4 项**（同文件，3 个）：真实 `PointerScrollEvent`，250%→260% zoom-to-cursor（框中心原地不动 ±3px）、图外滚轮只滚动；用缩放百分比与滚动偏移断言。
- 测试写法按新装 skill `flutter-testing`（`~/workspace/custom-skills/flutter-testing/SKILL.md`）的分级方法；页图用内嵌 1×1 PNG 同步写临时文件，无异步文件 IO，不用 DB。破坏校验：临时改回默认最小尺寸，缩框用例如期失败，已恢复。

## 四、Audit 与 Meng 的裁决

审计报告 `docs/ui-replication/B8-7-9-AUDIT.md`（xermio 20 分表 + flutter-ui-from-design 实现对照，只审查、不改代码）：

- **评分：** 详情页 A 紧凑 **12/20**，题目列表 A 留白卡片 **14/20**，均低于 16/20 可交付线；Blocking 问题 0 个。分差主要来自三行被项目既定决定覆盖的项（第 6 行间距 scale、第 7 行平台字阶、第 10 行原生控件）；剔除这三行只看其余 7 行：详情页 9/14，列表页 11/14。两处均无“AI 味”硬伤。
- **实现对照：通过为主。** 两文件零 `Color(0x…)` 字面量，全部走 `DesignTokens` palette；`LayoutBuilder` 用在该用的地方，无固定坐标；列表页工具条用 `Wrap` 防窄窗溢出。轻微项：约 14 处字号字面量与已有 token 值重复却未引用 token；详情页 1160/460、列表页 280/200/76、卡片阴影未进 token；4 个死 token；两文件零 `Semantics`。
- **P1-1（详情页底部操作卡在首屏外）：Meng 裁决接受现状，不改**，不做吸顶/吸底条。改前亦然，是既定取舍。
- **P1-2（详情页题图区大面积留白）：Meng 裁决改成按内容高度自适应，上限 460 不变，不再固定撑满 460。已落实**：`_buildImageBlock` 里 `QuestionSlice` 外包一层 `IntrinsicHeight`，盒子高度取内容固有高度；`imageMaxHeight = 460` 常量与 `QuestionSlice` 自身 `maxHeight: 460` 不动，大图仍限高 460；未动 `widgets.dart`（共享组件、错题本、整理页、放大浮层不受影响）。A 截图已重截（题图盒子约 100 高，三段 + 底部操作卡片全部进首屏）；详情页测试 35/35 → **37/37**（新增 2 个 P1-2 用例：小图渲染高约 96 <200、大图 200×800 真实切片渲染高 =460）。
- **P1-3（10 张大卡/页时分页器在三屏之下）：已是接受的取舍，不用动。**
- **P2 项（字号收敛到 token、死 token 清理、图标控件补 Semantics、空状态跳转）：Meng 这次没定，先不动**，留待批末再说（见第六节）。
- **11 处设计冲突对照：Meng 看完「设计冲突对照」页后定夺，11 处全部选咱们已定的版本，skill 那边的版本一个都不采纳。** 项目既定决定（年轻学习伙伴感、DesignTokens）维持不变，不按 skill 方向改任何设计；审计报告里标注“覆盖”的三行（间距/字阶 scale、平台字阶、原生控件）就按覆盖处理，不再另做对照版。原“冲突时并排做两个版本对比”的规则就此作废。

## 五、门禁验证（协调员最终复核，全部在最终树上跑）

- `flutter analyze`：**0 问题**。
- 全量测试串行（`--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，默认 `/tmp`）：**874/874 通过，`[E]` 0 处，EXIT 0**，日志 `/tmp/b8-gate-full.log`。总数由 Batch 7 的 879 变为 874：二层清扫删除 53 个测试，各组新增 48 个净测试（新测试文件 5 个：`b8_1_subject_refresh_test.dart` 12、`b8_1_subject_refresh_flow_test.dart` 1、`b8_1_subject_sweep_test.dart` 6、`b8_345_box_interaction_test.dart` 13、`b8_6_accordion_test.dart` 4；其余新增用例在详情页与错题本测试文件内）。
- Linux Release 构建：**通过**（`Built build/linux/x64/release/bundle/quiz_master2`），日志 `/tmp/b8-gate-build.log`。
- 演示库：门禁跑前备份到 `~/workspace/demo-db-backup/quiz-master2.db.b8-gate`（md5 已核）；跑后 live 库核对为 **v1**，md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，`user_version` 1，9 道题、3 学科，无 -wal/-shm 残留。全量测试未动 live 库，无需恢复。
- **SR2-3 的结论（重要）：** 第 9 项与第 3/4/5 项工人全量里 SR2-3（详情页重框事务清理）各失败 1 次，第 6 项工人全量里它通过，门禁单跑（默认 /tmp）**874/874 全过**。根因已查明：**不是产品抖动，是测试环境问题**——`TMPDIR=$HOME/workspace/.tmp-flutter` 时临时目录名本身含 `.tmp-`，SR2-3 用例断言 slices 目录无 `.tmp-` 文件、全路径匹配下恒失败。第 9 项工人因 /tmp 写满改用该 TMPDIR 后引入误报。**今后全量测试必须用默认 /tmp 跑**（或换一个不含 `.tmp-` 的 TMPDIR）；/tmp 写满时先清并行工人的旧 `flutter_tools.*` 目录，不要改 TMPDIR 跑测试。

## 六、遗留与 Win11 真机清单

**本次未动、留待 Meng 定夺或真机复核的：**
- P2 审计项（字号字面量收敛到 token 约 14 处、4 个死 token `detailContentMaxWidth` / `detailSectionGap` / `cardsScrollHeight` / `cardsScrollPadding` 清理、图标控件补 `Semantics`）：Meng 这次没定，等他再说。
- 空状态“去收集/去整理”只有文案、未接跳转（需改共享 `lib/app.dart`，属后续需求）。
- `clampToPage` 默认 `minSize: true` 分支现无调用方，仅为 S8A3 回归测试保留。
- `double` 封面折角仍是 Meng 自己与 CodeBuddy 对接（未变）。

**Win11 真机仍需复核的（Linux 替代不了）：**
- 角柄 24px 手感、zoom-to-cursor 手感、贴边柄（第 3/4 项工人已在测试里覆盖逻辑，真机看手感）。
- 科少/科多/矮窗口时速览块紧贴设置无空隙、区内滚动（第 1 项纠正改了这块布局，真机看观感）；删光后四处目视 + 新建一科即时出现；收集下拉空菜单不出现、“去学科管理”跳转正常。
- SR3-15 队列弹窗文件夹下拉在测试里点按无响应——仍需真机确认是不是产品问题（Batch 7 遗留）。
- SR-P2-11 Windows 文件锁分支、SR-P0-2 真机列表行为（既往遗留）。
- 详情页“重新框选”端到端点通、拖放导入、错题本分页、`flutter build windows`（libpdfium 打包 + onnxruntime.dll + VS C++ 工具链）、字体/DPI/窗口尺寸、SQLite 原生资源、CPU 推理速度。

**过程记录（供下次参考）：**
- /tmp 是 512M tmpfs，6 个并行工人的 `flutter_tools.*` 曾占满致编译报 `No space left on device`；已清各自已死运行的目录，他人活运行未动。今后全量前先 `df -h /tmp`。
- VM 重启又丢过 clang 与 libgtk-3-dev 头文件（clang 装回 18.1.3；GTK 头文件因 libzstd pin 冲突改用 `apt-get download` + 解压只拷头文件/.pc/链接符号进 `/usr`，.deb 暂存 `~/workspace/.tmp-flutter/gtkfix/`）；恢复脚本 `docs/ui-replication/restore-linux-toolchain.sh`。
- 并行工人同文件改动均以精确文本替换 + 事后 grep 核对标记的方式共存，未发生互相覆盖（`wrongbook_shelf.dart` 第 1/2/8 项、`question_detail_page.dart` 第 2/7 项与扫尾、P1-2）。

## 七、报告与截图索引

- `docs/ui-replication/B8-1-SUBJECT-REFRESH.md`（删学科残留 + 导航贴合度纠正）
- `docs/ui-replication/B8-1-SWEEP.md`（剩余 5 处回退清扫）
- `docs/ui-replication/B8-2-LAYER2-REMOVAL.md`（二层模型清扫；全量日志 `~/workspace/b8-2-full-after.log`）
- `docs/ui-replication/B8-345-BOX-INTERACTION.md`（角柄/滚轮/框尺寸 + 真实交互用例）
- `docs/ui-replication/B8-6-ACCORDION.md`（手风琴 + 口径翻转记录）
- `docs/ui-replication/B8-7-DETAIL-REDESIGN.md`（详情页 A 紧凑 + P1-2 自适应）
- `docs/ui-replication/B8-7-9-AUDIT.md`（xermio 评分 + 实现对照 + Meng 裁决）
- `docs/ui-replication/B8-8-SHELF-SIZE.md`（书架封面 300×376）
- `docs/ui-replication/B8-9-LIST-REDESIGN.md`（列表 A 留白卡片 + 空状态文案）
- 截图（不推）：`docs/ui-replication/shots/b8-detail/`（改前 + A/B/C，A 图 P1-2 后已重截）、`docs/ui-replication/shots/b8-list/`（改前 3 张 + A/B/C 各 3 张 + 四格对照）、`docs/ui-replication/shots/b8-shelf/`（1000px / 1600px / 单本）

**未推代码说明：** 本批所有改动均在工作树未提交状态，推送须 Meng 另外批准；截图、测试固件、YOLO 模型（38MB，不进仓库）一律不推。
