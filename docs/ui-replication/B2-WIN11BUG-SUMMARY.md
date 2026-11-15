# 第二批 Win11 Bug 汇总报告（B2-WIN11BUG-SUMMARY）

- 范围：Meng 的 Win11 真机验收 bug 清单（Bug 1、2+3、4、6a、6b）+ 错题本书架封面（7 处差距，第 1 处英文按 Meng 纠正取消，实际做 6 处）
- 工作树：`~/workspace/quiz-master2-UI`，分支 `ui-replication`；**未推代码**
- 最终验证（协调员复核）：`flutter analyze` 0 问题；全量测试 **575/575 通过**（基线 560，+15）；Linux Release 构建成功（`libapp.so` 11:59 新编，8.1MB）；演示库已恢复，md5 `8f7f9c64…` 与开工备份一致（v1、9 题、3 学科）

## 分项结果

### Bug 1 — 收集中心下拉框选中后灰色（工人 A）
- 根因：不是禁用态。外层 Container 没给底色，DropdownButton 的 InkWell 在 Win11 桌面默认 traditional 高亮模式下，获焦叠 12% 黑 focusColor、悬停再叠 4% 黑 hoverColor，在 surface 上正好是截图的 #D7D6D2（像素取样逐通道吻合）。
- 改动：`collect_page.dart` 学科下拉框外层 Container 显式 `color: palette.surface` + `focusColor: Colors.transparent`；悬停那层 4% 是标准反馈、移开即消失，且 DropdownButton 没有 hoverColor 参数（包主题改会连菜单高亮一起去掉），故保留。占位「请选择学科」未动。
- 报告：[B2-WIN11BUG-COLLECT.md](B2-WIN11BUG-COLLECT.md)

### Bug 2 + Bug 3 — stem 框超界、修框切片框出图（工人 B）
- 根因：**不是任务单怀疑的 Layer-2 坐标系用错**。`question_boxes` 里 Layer-2 框确实是页图相对坐标（0..1，`parent_box_id` 指 Layer-1 框），但整理页 / 放大查看 / 修框切片三处渲染全都不读 `question_boxes`，stem 虚线框是按写死比例画的示意框（stem 上 34% 等），不存在“页图坐标误当题图坐标”的映射错误。
- 真正根因：`QuestionSlice` 的真图按固有像素尺寸渲染（宽条切片窄于容器，左对齐），而叠加层按布局容器尺寸画框，于是向右伸出图片。实测复现（夹具图 500×120）：整理页 overlay 629 vs 图 500；放大查看 680 宽 Stack vs 500 宽图；切片卡 591 vs 卡内图 268。截图 78 里也没有虚线框，伸出图片的是卡片边框本身。
- 改动（只动 `organize_page.dart`、`widgets.dart` 的框渲染处及测试）：整理页 `_paperImage` 与放大查看 `_ZoomDialog` 的 Stack 外包 `Align(topLeft)`，让 Stack 收成切片实际尺寸——stem/option/figure 同一个叠加层，一并收进图内；`QuestionRegionOverlays` 外包 `ClipRect` 兜底，框一律按图片边界裁剪；修框切片：有真实切片文件时卡外包 `Align` + 卡头 Row 收窄（新增 `hugContent` 参数），卡贴图；文字卡保持整宽；文件缺失时不收窄。保存时夹取不改（已存在：收集页 `_clampInner` + 表级 CHECK 0..1）。
- 副作用：放大查看初始缩放按真实纸面尺寸算，上报那类 500 宽的题徽标会从 132% 变为 150%（公式未变）。
- 报告：[B2-WIN11BUG-ORGANIZE.md](B2-WIN11BUG-ORGANIZE.md)

### Bug 4 — 整理表单只能开一个（工人 B）
- **本树里未复现，无需改代码**。四区一直是四个独立布尔值（从 v2 重写至今，全分支无单 `_openSection` 版本；单区互斥只在学科管理页存在），截图 79 本身也显示两区同时展开。已加 widget 测试锁定该行为（同时开三区 + 文件夹都保持展开，默认文件夹展开、其余折叠）。
- 遗留：`QmFoldSection` 的文档注释称“调用方收起其他段”，与实际不符——按分工未动 `uikit.dart`，建议另行修正。
- 报告：见 [B2-WIN11BUG-ORGANIZE.md](B2-WIN11BUG-ORGANIZE.md)

### Bug 6a — 收集任务删除（工人 A）
- 数据现状核对：`questions` 表没有 `collect_task_id`，任务→题靠 `collect_tasks.question_id`（一对一），待整理看 `is_organized`。
- 改动：扩展已有 `deleteCollectTaskFrom`（一事务）：待整理题随任务删（含框/记录/切片），已整理题保留；UI 给待框选/修框中/待整理/已整理行加「删除」，点后弹确认框（统一文案「删了就没了，确定吗？」）。导入中/排队中/失败行的取消与删除仍直接删（现有测试 pin 住的已定行为，未动）。
- 报告：[B2-WIN11BUG-COLLECT.md](B2-WIN11BUG-COLLECT.md)

### Bug 6b — 修框页面太小 + 鼠标行为（工人 A）
- 改动：(1) 对话框高由 `min(648*scale, 视口-48)` 改为 `视口-48`，画布随之变大；删了无用的 `collectEditorDialogHeight` token。(2) 滚轮只在图上缩放、图外交给滚动视图；左键不再画框（改平移图片，框上仍拖框），右键拖动才画框；右键单击=取消（4px 分界，内框模式退出，非内框模式无动作）；触摸仍主按键画框；滚动锁按“右键/框上才锁”重做，并给画布滚动视图显式加鼠标拖动（Flutter 默认拖动滚动不认鼠标）；提示文案同步更新。
- 报告：[B2-WIN11BUG-COLLECT.md](B2-WIN11BUG-COLLECT.md)

### 错题本书架封面（工人 C，6 处；第 1 处英文按 Meng 2026-11-14 纠正取消）
- 第 1 处取消：不恢复英文映射、不加英文元素；grep 确认 `wrongbook_page.dart` 里 0 处英文残留。预览 HTML 里还留着 MATHEMATICS，那是预览和 App 有意的不同点。
- 第 2 处蓝色：代码里的蓝已是预览色 `#2F7CF6`（像素验证），无须改值；“深浅变化”由 inset 阴影实现（两版 HTML 底色都是纯色，无纵向渐变）。
- 第 3 处折角：重写 34×34 渐变（225deg，stops 0.49/0.50/0.52/1.0）+ 左下圆角 8px + `drawShadow` 阴影；中途发现第一版三角画错（纸色落在渐变透明的一半、像小三角旗），逐像素核对预览后修正，并顺带删了 plain 纹样里多余的 28px 白三角。
- 第 4 处虚线内框：inset/线宽/透明度本已一致，只补不对称圆角 4/9/9/4。
- 第 5 处数字条：底色/边框本已一致，只补标签 opacity .92、副标题 .95。
- 第 6 处“数学”位置：上方加 40.4px 占位（英文行 26 + 12×1.2），学科名仍在距封面顶 74.4px 处；实测字墨顶 +74px。副标题 padding-left 未照搬 HTML 的 13.6（实测 Flutter 不计末字后字距，照搬会右偏），取 0 达到预览的居中效果。
- 第 7 处书的感觉：补书页边（右缘 5px、4px 宽、3px 米白 + 1px 暗线循环、.85）+ 两层 inset 阴影；书脊/外阴影已有；另加 HTML 的悬停（上移 4px、阴影加深，实测书顶 158→154）。
- 深色模式：预览无封面深色覆盖规则，封面深浅同色；深/浅各拍一套验证一致。斜纹黄组合正常不显脏。学科管理 52×68 小预览是独立 widget（`QmCoverMini`），不受影响、未动。
- 截图在 `shots/b2-wrongbook-cover/`：改前/改后 × 深/浅/斜纹黄/悬停，另有三联对比 `compare-dark.png`、浅色两联 `compare-light.png`、折角特写 `fold-compare.png`。计数数学 2/2/0、英语 2/0/1、政治 1/0/0（与演示库一致；预览的 3/3/0 是 mock 数据）。
- 报告：[B2-WRONGBOOK-COVER.md](B2-WRONGBOOK-COVER.md)

## 验证汇总

| 检查 | 结果 |
|---|---|
| `flutter analyze` | 0 问题（协调员复核） |
| 全量测试 | **575/575 通过**（协调员复核，需设 `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，否则 p05 e2e 因缺原生库失败） |
| 新增测试 | 工人 A：`collect_page_test` +9、`p1_schema_backup_test` +1 删任务语义；工人 B：`test/b2_win11bug_organize_test.dart` 4 项 + 夹具 `test/fixtures/slice-narrow-500x120.png`；工人 C：封面针对性测试 42/42 |
| Linux Release 构建 | 成功（协调员复核，`libapp.so` 11:59 新编；小启动器 `quiz_master2` 本体因只改 Dart 代码未重链，属正常） |
| Linux 真机跑 | 工人 A：Xvfb 下跑 release 包 45 秒，有窗口、无 Flutter 报错、不崩溃（未截图） |
| 演示库 | 恢复并核对 md5 `8f7f9c64…`（v1、9 题、3 学科、深色） |

## 需 Meng 决定的事

1. **整理页叠加层是否改用库里真实的 Layer-2 框坐标**（页图坐标按 Layer-1 框换算到题图坐标，无真实框时回退现推导框）？本次只修了“框不出图”，没换数据源，这是产品行为变化，请 Meng 定。
2. **收集任务删除的细节**：(a) 失败任务的「删除任务」要不要也弹确认框（目前只有新加的「删除」弹确认）；(b) 删除确认用模态 AlertDialog 还是与详情页一致的行内确认条；(c) 右键拖动起点落在已有框上时仍拖动该框（与左键一致），如要求右键任何位置都画框，需给框手势加按键过滤。
3. `double` 样式仍显示折角（HTML 会藏折角）是既有偏差，未动；若要改请另立一项。
4. `QmFoldSection` 文档注释称“调用方收起其他段”与实际不符，建议另行修正（`uikit.dart`）。

## 环境问题记录（影响后续批次）

1. **B2-start 演示库是 v1 库（`user_version=1`），应用一启动就按 §6 删库重建空 v2 库**——工人 C 第一轮截图全是 0 题、深色变浅色就是这个原因。本次封面截图验收用的是把 v1 副本按 v2 DDL 就地升级的 scratch 库 `/tmp/qm2-v2demo.db`（补 7+2 列、`question_boxes` 表、`user_version=2`，脚本 `/tmp/migrate-v2demo.sh`）；live 库每次跑完都恢复并核对 md5。
2. 全量测试每次都会改 live 库（已知 §4.1 单例测试），每次跑完都从备份恢复；最终 live 库 md5 与协调员备份一致。
3. 11:31 本树 release 二进制曾被截断成 0 字节（疑似同期他人工构建），工人 C 的改前二进制改在隔离树 `~/workspace/qm2-before-tree/` 构建，未进仓库，可删。
4. `/tmp` 里的备份会随 VM 重启消失（工人 B 的 /tmp 备份中途消失，改用工作区里的协调员备份恢复）；后续备份直接放工作区，不要放 `/tmp`。
5. 批次中途 `clang` 丢失致测试原生构建失败，按授权跑了 `restore-linux-toolchain.sh`（工人 B：第一次因 `libepoxy-dev` 的 deb 包损坏中断，删包重跑成功；Mesa 按脚本要求走 noble-updates）。
6. 跑全量测试须设 `LD_LIBRARY_PATH` 到 onnxruntime 原生库目录，否则 p05 e2e 失败（与改动无关）。

## 改动文件

- `lib/modules/collect/collect_page.dart`（Bug 1、6a、6b）
- `lib/data/repository.dart`（6a 删除方法扩展；另有第一批遗留问题的改动在同一文件）
- `lib/modules/organize/organize_page.dart`（Bug 2、3）
- `lib/widgets/widgets.dart`（Bug 2、3 框渲染）
- `lib/modules/wrongbook/wrongbook_page.dart`（封面 6 处）
- 测试：`test/collect_page_test.dart`、`test/p1_schema_backup_test.dart`、`test/b2_win11bug_organize_test.dart`（新增）、`test/wrongbook_page_test.dart`、`test/fixtures/slice-narrow-500x120.png`（新增）
- 报告：`docs/ui-replication/B2-WIN11BUG-COLLECT.md`、`B2-WIN11BUG-ORGANIZE.md`、`B2-WRONGBOOK-COVER.md`、本汇总
