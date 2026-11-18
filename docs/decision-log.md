# decision-log — quiz-master2 v2（从 0 重写）

> v2：2026-11-12 用户要求从 0 重写。旧项目 `~/workspace/quiz-master2-F/`
> 已完整备份到 `~/workspace/quiz-master2-F-old-20261112/`（不动）。
> 本日志从 D-00 起按新项目重新记；v1 的旧决策仍有效，只列与新代码
> 有关的。主预览：artifact `quiz-master2-quan-xin-she-ji-yu-lan`。
> 需用户确认的点先按本日志的判断写，写完由用户验收——沿用 v1 的方法。

## D-00 — 版本锁定（已确认）

Flutter 3.47.9 / Dart 3.13.7。用户在 Win11 上装 3.47.9，不装 3.50。
`pubspec.yaml`：sdk >=3.13.0，flutter >=3.47.0。

## D-01 — 最近任务持久化（已确认，v1 做法沿用）

最近任务存 `recent_tasks` 单行表（kind / subject_id / title），
首页“继续上次”按它恢复（最后一次活动优先；2026-11-14 定：
原“复习 > 整理 > 收集”优先级规则已删除，见 D-06）。

## D-02 — 数据库位置（已确认，v1 D-05 沿用）

`quiz-master2.db` 在 `%LOCALAPPDATA%\quiz-master2`；
Linux 验证时用 `~/.local/share/quiz-master2/`；
数据目录不可写时回退到可执行文件同级 `data/`。

## D-03 — 导航角标（已确认，v1 D-04 沿用）

收集 = 待修框任务（待框选 + 修框中）+ 待整理题数；
整理 = 待整理题数；错题本无角标。写操作后 `badgeVersion` 通知外壳重查。

## D-04 — 演示数据（已确认，v1 D-11 沿用）

数学 / 英语 / 政治各 3 道大学题，`is_demo = 1`；
“清空演示数据”只删演示题。设置页有该入口，首页不再放。
注（§6 第 1 条，2026-11-13/14）：新库建库时从空开始、不预置
演示题；`demoQuestions()` 已于 Batch 5（SR-P2-13）删除，演示题的
唯一合法来源是 v1 老库（已整体删除，不迁移）。上面 9 道题是演示库
v1（老库）的口径，不是新库的初始内容。

## D-05 — 复习模型：错因治疗（已确认，预览定稿）

旧翻卡 + 1/3/7/14 天间隔已废弃，v2 代码里不存在旧口径
（无 review_status / next_review / overdue_days 字段）。
模型：复习按错因治；手动“加入复习”才进列表；同一错因在同一道题上
两次自查“已解决”才算已解决；已解决满复查间隔（默认 7 天）自动回来
复查；复查不过打回解决中；跳过两次留到下次；四步 看错因 → 写补救 →
重做 → 自查；自查三档 已解决 / 未解决 / 不确定（不确定不算）。
设置可调：复查间隔 3/7/14（默认 7）、治愈自查次数 1/2/3（默认 2）、
每次治几个错因 5/10/不限（默认不限）、跳过几次留到下次 1/2（默认 2）。

## D-06 — 首页计数口径（已确认，预览定稿）

首页焦点卡“要复习的数量”与导航学科速览同一口径
`homeRevCounts`：手动加入复习、已整理、未解决（含到复查时间的题），
数题不数错因。学科速览的数字每次渲染刷新，不写死。
每科另三数：要复习 / 待复查 / 已解决（不显示总题数）。
（注：三数指错题本封面徽章口径（`subjectCounts`，要复习 / 待复查 /
已解决）；首页学科格为要复习 / 待整理两数，见 `home_page.dart` 学科格。）

“继续上次”优先级（2026-11-14 定，已删除）：原规则“同时存在时
优先级为复习 > 整理 > 收集”删除，改为最后一次活动优先——
`recent_tasks` 是只有 id=1 一行的单行表，`saveRecentTask` 是纯
REPLACE 后写优先，无三方比较逻辑；谁最后保存，谁就是“继续上次”
恢复的那一个。本条只改文字记录，不改 `saveRecentTask` 代码。

## D-07 — YOLO 与 onnxruntime（已被 D-23 取代，仅留作历史）

> 本条已被 D-23 取代（2026-11-13），仅留作历史；占位服务现仅为
> 模型缺失 / 加载失败时的回退路径，不要按本条行事。

YOLO 两层固定：层 1 整题框 → 整题切片；层 2 仅 stem / option /
figure 辅助区，永不拆题。先用占位服务（一页一个整题框 + 两层框 +
钳制），真实 `best.onnx`（约 37MB）由用户后续提供；onnxruntime
的 Dart 包版本不 pin，等 Win11 上对 Flutter 3.47.9 验证后再定。

## D-08 — 整理工作台布局 H（已确认，预览定稿）

左图右表；队列不常驻，藏在左上角“队列”按钮后，点开弹出层；
无固定高度容器，整页滚动；修框切片默认展开；表单里不显示学科；
文件夹单独一段默认展开；批量在队列弹出层里。

## D-09 — 队列弹出层 D 极简式（已确认，预览定稿）

每道题一行（勾选框 + 题名 + 删除），详情（学科/题型/时间/试卷/
必填状态）只在点中那道题时在下面展开；批量区是底部悬浮条，
勾了题才出现；“取消”清空勾选；关闭弹出层（关闭按钮 / 遮罩 / Esc）
也清空勾选。

## D-10 — 学科管理四段折叠（已确认，预览定稿）

学科 / 知识点树 / 标签 / 试卷四段，默认全折起，一次只展开一个。
文件夹不在学科管理里——文件夹的增删改/移动/排序/搜索只在错题本
目录页。学科段分两层：学科列表 + 错题本封面样式（封面样式块本身
可折叠，默认折起）；封面 6 样式 + 7 预设色。知识点树按学科标签切，
章节默认折起。

## D-11 — 设置五组折叠（已确认，预览定稿）

外观 / 复习 / 错题本 / 数据 / 启动与关于五组，默认全折起，
一次只展开一个。复习组用语方案 B 简洁直接型。问候语默认
“今天也要加油呀”，设置里可改。

字号三档覆盖系统缩放（2026-11-15 Batch 5 P2，SR-P2-73，Meng 定
维持现状）：外观组字号只有标准 / 大 / 特大三档（1.00 / 1.15 /
1.30），`app.dart` 用 `TextScaler.linear(scale)` 全局乘一次，系统
字号设置在应用内不生效；依赖系统大字号的用户需在应用内改三档
设置。备选 `max(设置档, 系统缩放)` 未采纳。

## D-12 — 错题本（已确认，预览定稿）

书架（每页最多 6 本，分页）→ 目录页（文件夹树）→ 题目列表。
大卡片默认视图，紧凑列表可切；筛选 D 折叠式，无文件夹筛选；
默认排序时间新→旧；默认每页 10（10/20/30/40/50）；批量操作按钮
点后才出现勾选与批量条；封面徽章 题数 / 要复习 / 待复查。

## D-13 — 题目详情（已确认，预览定稿）

方案 2 分段折叠式：大图在上，三段 答案解析 / 题目信息 / 复习记录
默认全折起。编辑模式保存才生效，取消有脏检查；学科不可改；
删除确认“删了就没了，确定吗？”后自动进下一题；复习记录用新错因
模型（无旧复习状态下拉与下次复习日期选择器）；“加入复习”按钮在
复习记录段（已整理与已归档的题有，未整理没有）。

## D-14 — 学习报告（已确认，预览定稿）

只答三个问题：弱在哪、有没有效果、接下来练什么。核心数只三项：
已解决错因、待解决错因、复查通过率；弱点 Top 5 按错因与知识点各
一组（“最常错的5个原因”“最常错的5个知识点”，按关联题数排，
“看更多”展开全部）；分布只按学科，纯数字与文字，无图表；
点弱点进错题本按该错因/知识点过滤；默认范围本周。

## D-15 — 收集中心（已确认，预览定稿）

只收 PDF/JPG/PNG（PDF 50MB / 图片 20MB，超限硬判进失败任务，可先压缩再重选）；
导入学科每次都选（默认“请选择学科”，不默认上次/数学）；
修框全鼠标操作（拖动移/改大小/重画，滚轮缩放），双击题框进内框
模式；修框确认后按框生成待整理题进整理队列（任务与题目一对一）；
任务列表只在 >3 个任务时出滚动容器。

## D-16 — 导入与打包（已确认，v1 沿用）

源码上传 GitHub，用户在 Win11 本地 `flutter build windows` 打包；
Inno Setup 做 exe 安装包（桌面快捷方式 + 开始菜单项）。
`windows/` 脚手架若在 Win11 构建报错，用
`flutter create --platforms=windows .` 重生成（不覆盖 `lib/`）。

## D-17 — 数据库位置改后真正生效（统合时补，2026-11-12）

设置页只记 `databaseLocation` 不生效：数据层不读它。
补法：改位置时把新路径同时写进默认数据目录下的 `db_location.txt`
标记文件（`AppDatabase.setCustomDataDirectory`），下次启动
`dataDirectoryPath()` 先读标记文件，读到就用。设置本身存在库里，
换库后读不到旧设置，所以位置必须存在库外。重启后生效的提示不变。

## D-18 — 整理/详情清空字段真正清掉（统合时补，2026-11-12）

`Question.copyWith` 传 null 表示“保持原值”，整理表单把答案/解析/
笔记清空后保存会留旧值。模型层加 `clearAnswer / clearExplanation /
clearNotes / clearExamId` 标志；整理页 `_formQuestion` 空字段传标志。
详情页是直接构造新对象，空字段本来就是 null，不受影响。

## D-19 — 错题本列表只收已整理题（统合时修，2026-11-12）

统合点测发现：数学封面题数 2，但“全部题目”列表显示 3 道——
未整理的函数极限混进来了（`_filteredAll` 没过滤 `isOrganized`）。
修复：非归档分支加 `isOrganized` 过滤；封面口径与列表口径一致。
归档视图不变（归档的题本来就是已整理的）。

## D-20 — 整理页点图改回放大浮层（统合时修，2026-11-12）

A 组把整理页图片的点击写成了进详情，与预览定稿不符（预览：点图
弹出大居中放大浮层，1.5× 起始、滚轮缩放；进详情走「进详情改」）。
修复：放大浮层抽成共享函数 `showQuestionZoomDialog`（widgets.dart，
InteractiveViewer 居中放图，1.5× 起始，滚轮/＋/－缩放，点背景/Esc/
✕ 关闭），详情与整理共用；v1 那个 1.5× 起始偏移、右边文字截断的
问题不再出现（新浮层居中，超出的部分可拖动平移查看）。
详情页旧的 `_showZoom` 改为调共享函数。

## D-21 — Linux 构建环境（验证时记，2026-11-12）

本机 VM 缺 GTK3 开发包，`apt install libgtk-3-dev` 被系统 pin 的
libzstd1 版本挡住（apt 报错 held broken packages）。绕法：直接
`apt-get download` libgtk-3-dev / libgdk-pixbuf-2.0-dev /
libtiff-dev / libjpeg-dev / libpng-dev / libzstd-dev 的 .deb，
`dpkg-deb -x` 解包后把头文件与 .pc 拷进 /usr/include 与
/usr/lib/x86_64-linux-gnu/，不改包数据库。`pkg-config --exists
gtk+-3.0` 通过后构建成功。注意：`flutter build linux --release`
在本机把产物装到了 `/usr/local/quiz_master2`（+ /usr/local/data、
/usr/local/lib），而不是 `build/linux/x64/release/bundle/`——
bundle 目录没生成，原因未深究；Linux 验证直接跑 /usr/local 下的
二进制。Windows 构建不受此影响。

## D-22 — v2 统合验证结果（2026-11-12）

全量 `flutter analyze`：No issues found。Linux release 构建成功。
Xvfb 1280×720 点测通过：首页（问候语默认“今天也要加油呀”，
焦点卡 3 道，学科三数与导航速览一致）、收集中心、整理 H 布局 +
D 队列弹层、错题本（书架 → 目录页 → 列表，修后 2 道与封面对上）、
题目详情（三段默认折起）、复习列表（3 组）+ 全屏四步会话、
学习报告（纯数字文字，无图表）、学科管理四段折叠、设置五组折叠、
深色主题（冷灰）正常。截图 01–20 在 `screenshots-linux/`。
未验证：错题本/复习分页翻页（演示数据每科最多 3 道，只有一页）、
真实文件导入（无真实 PDF/图片）、修框编辑器全流程（无真实文件）。

## D-23 — 真实 YOLO 接入：只接第 1 层，第 2 层暂缓（2026-11-13，Meng 定）

D-07 的“版本故意不 pin”到此为止。pub.dev 上唯一的 Dart 版 ONNX
Runtime 插件是 `onnxruntime`，最新稳定版 **1.4.1**（2024-03-27，
之后无新版），已写入 `pubspec.yaml`（`onnxruntime: ^1.4.1`）；
`pubspec.lock` 只多了这一项（ffi 已是 2.2.0，未动）。该包自带各
平台原生库：Linux 用 `libonnxruntime.so.1.15.1`（即 ORT 1.15.1），
Windows 用 `onnxruntime.dll`（同包同版本）。选它的理由：pub.dev
上没有更新的 Dart onnxruntime 包；1.4.1 的 sdk 约束
（`>=2.17.0 <4.0.0`）兼容 Dart 3.13.7 / Flutter 3.47.9；Linux
Release 实测能加载原生库并跑通模型（见
docs/ui-replication/YOLO-INTEGRATION-REPORT.md）。
**Win11 上须重验**：`flutter pub get` 后 `onnxruntime.dll` 是否随
应用打包、会话能否创建、CPU 推理速度。

第 1 层模型（Meng 提供，已在仓库 `assets/models/question/`）：
`yolo11s-question-v1.onnx`（38,432,570 字节），YOLO11s，输入
1×3×1280×1280，输出 1×5×33600，1 类 question。推理约定
（`lib/services/yolo_onnx_service.dart`）：整页 letterbox 1280
（灰边 114）；置信度 0.45，NMS IoU 0.5；按阅读顺序（先上后下、
同行先左后右）编号；推理在 worker isolate 跑（`runAsync`），
不卡 UI 线程。模型缺失、加载失败或图片文件不存在时返回空框 +
`usedFallback: true`，不回占位框，不抛错。`QuestionBox` 接口不变；
`clampToPage` 只加了一个默认 true 的 `minSize` 可选参数
（默认行为与 A3 回归测试完全一致）：检测输出的框是量出来的
尺寸，用 `minSize: false` 原样保留，否则题行（实测高
0.018~0.10，多在 0.08 以下）全被撑成 0.08，相邻题行互相重叠、
确认被拦，真实推理没法用。

第 2 层暂缓（Meng 2026-11-13 定）：模型还需再训练。
`yolo11s-intra-v1.onnx`（38,406,563 字节，SHA256
8486b519dc184266be559e983ce409d1d78e34100790ff22905353d98b269267）
已从仓库 `assets/models/intra/` 移到仓库外
`~/workspace/yolo-models-archive/` 存着（Drive 上 yolo-intra/
里还有一份），不删除；应用不再打包这 38MB。
暂缓原因（3 张真实试卷页双模型实测，见 YOLO 报告）：
题干/选项基本准，但 figure 误报多——纯文字页上无图的题也被框
成图，3 页 4 个 figure 均存疑；另有 stem/figure 同框重复。
再接入路径：训好的模型放回 `assets/models/intra/`、
`pubspec.yaml` 里把 `assets/models/intra/` 声明加回来、
`YoloOnnxService.intraEnabled` 改 true、按
`_detectIntra` 的注释恢复逐题裁剪推理（绝不在整页上跑——
整页跑时题干框会横跨整页）；后处理 `decodeYoloOutput` 与
归属 `groupInners` 已留好。第 2 层的数据模型与界面不动：
`QuestionBox.layer`、修框内框模式、三色高亮、切片区都保留，
没有模型时用户仍可手动框 stem / option / figure。

导入已真实落盘（`imports/<task-id>/`，`collect_tasks.source_path`
写库内副本的相对路径，`CollectTask.fileName` 只做显示名）：
`detectPage` 按传入路径找文件，找得到跑真实推理，找不到返回空框
+ `usedFallback: true`。PDF 由 `pdf_render_service.dart` 按页渲染，
见 YOLO 报告。

## D-24 — 二层模型整个移除（2026-11-15，Meng 定）

没有第二层模型了：修框编辑器里的内框模式横幅、“题级框 4”标签、
“这个框是？”里的 stem / option / figure 类型选择全部删除；画框直接
默认题级框，不再选二层模型的框。B3/P1-1 曾特意保留的手动二层框与
整理页真实二层坐标叠加层一并去掉（推翻 D-23 里“第 2 层的数据模型与
界面不动”与“没有模型时用户仍可手动框 stem / option / figure”）。

只留未来接入必需的三处接口：① `lib/services/yolo_onnx_service.dart`
里的 `intraEnabled = false` 开关 + `_detectIntra` 占位；
② `question_boxes` 表（含 `layer` 列，Schema 一动不动，库里旧的
layer-2 行保留不动，编辑器读到时直接丢弃）；③ `docs/代码地图.md`
第 8 节一处重接入点说明。其他所有二层引用（UI 文案、类型选择、
内框编辑逻辑、叠加层渲染、相关测试、文档段落）全部删掉，详见
`docs/ui-replication/B8-2-LAYER2-REMOVAL.md`。

## D-25 — 拖放导入插件选型 desktop_drop 0.8.4（2026-11-15，Batch 11）

收集中心落点用 `desktop_drop` 0.8.4（`DropTarget` + `onDragDone`，纯 Dart API，支持 Windows / Linux / macOS，维护活跃）。0.9.x 未采用：它要求 `cross_file ^0.4.0`，与 `file_picker` 8.x 的 `cross_file ^0.3.x` 冲突，升级 file_picker 超出本次范围。备选已排除：`super_drag_and_drop`（更重，还带拖出端能力，本次用不上）、`windows_drop_target` 0.0.1（仅 Windows、刚发布不成熟）、手写 Win32 FFI（原生代码自己维护，成本过高）。落点只收集中心拖放区（全窗口落点、微信 / QQ 窗口拖入不做）；拖入与点选走同一条 `_handleIncomingPaths`（学科、大小限制、重复提示全部复用，行为差异为零）；悬停态只换文案与边框，不改布局、不新增颜色。详见 `docs/ui-replication/B11-1-DRAGDROP.md`。

## D-26 — 批量导入：SHA-256 内容去重、不改 Schema、队列语义、文件名猜测规则（2026-11-15，Batch 11）

- 去重口径：内容哈希 = 全文件 SHA-256（`crypto` 3.0.8，纯 Dart，无原生依赖）。不用“文件名 + 大小”弱哈希：同名不同内容、同内容不同名都要分得清。口径依据是代码实际实现，不是 D-08（D-08 是整理工作台布局 H，与重复导入无关）；代码现状：文件名命中 → 横幅警告、用户确认才重导；同批同路径 → `enqueue` 内静默跳过。本次只在文件名口径旁并列一条内容哈希口径，确认流程不变。
- 不改 Schema：哈希不入库，每次导入时按任务 `sourcePath` 现算已入库原文件的哈希；原文件缺失的任务无法验证，直接跳过（不误拦）。代价：任务很多时每次导入都要读一遍已入库原文件；个人题库量级可接受，后续如需优化再入库存哈希字段。`enqueue` 本身不加哈希去重（仍只做既有路径去重），同批内容去重放在收集页，避免改动已有回归测试覆盖的核心导入路径。
- 队列语义：顺序逐个、失败不中断整批、重试只重导失败项（沿用本批学科）；队列卡片可关闭（只关卡片，不删任务）；新一批导入替换旧队列卡片；单文件导入不建队列。
- 文件名猜学科：关键词命中取最长者，等长时按预设顺序数学 / 英语 / 政治；自定义学科用学科名本身匹配；一批文件必须全部猜到同一学科才预填下拉框；关键词只列 2 字以上，避免单字误撞；英文关键词不分大小写。只建议、不静默指定。
- 文件名猜试卷：去扩展名 → 去日期 → 按分隔符分词 → 丢纯数字词、“第 N 页 / 第 N 题”、学科关键词与通用词 → 剩下 ≥2 字才作为建议；猜不出返回 null，不显示、不写库。
- “没选学科也能先选文件”是 B11-2 的必要前置：以前选文件前必须先选学科，猜测永远没有触发机会；现在文件可暂存，等用户选好学科点“开始导入”再导；“没选学科不能导入”口径不变。详见 `docs/ui-replication/B11-2-BATCH-IMPORT.md`。

## D-27 — 整理“上一道”不新增代码（2026-11-15，Batch 11）

「上一道」按钮自 R5 已在整理工作台 `_workActs`，与「下一道」并排：第一道时 `onPressed` 为 null（禁用），切题只改下标不动队列顺序，切换经自动保存、已填内容原样；行为与 Batch 11 验收逐条一致，故本项不新增代码，只补禁用态与往返的显式测试。若后续要改（如键盘快捷键、长按连续切题），另立项。详见 `docs/ui-replication/B11-4-PREV.md`。

## D-28 — 今日小结：N1 用 settings 计数，不用 organized_at 列（2026-11-15，Batch 11）

- N1（今天已整理的题数）不用新增 `organized_at` 列，改用 settings 表 `organizedToday` 计数（值 `yyyy-MM-dd|N`）。理由：questions 表没有整理完成时间字段；加列要动 Schema，而本库的 `schemaVersion` 同时是 sqflite 的 `version`，升版本会触发 `deleteLegacyDatabaseIfPresent` 把已有 v2 库当老库删掉（§6 第 1 条的删库逻辑以版本是否等于 `schemaVersion` 判断），风险不可接受；settings 键值复用是本项目已有做法（`lastRoute` / `lastRecheckReminderDate` / `backupFailed` / B11-9 的 `examEvents`），不碰 Schema、不碰备份表清单（settings 整表备份，计数随备份走）。如以后要按题反查“今天整理了哪些题”（删题回减、看明细），再立项加 `organized_at` 列 + 专门处理 v2 库的 `onUpgrade`（不动删库逻辑）。
- 小结行只在“队列已空（题都在、都已整理完）”的空状态显示；从未有题的空状态不显示（首次使用引导态，无“今天整理了”的语境）。只一行，不加本周累计与连续天数。
- N2（待复习题数）复用 `dueToday().length`，不另写口径；与首页焦点卡 / 复习角标同一数字。详见 `docs/ui-replication/B11-10-TODAY-SUMMARY.md`。

## D-29 — 批量加入复习：只加未解决错因（2026-11-15，Batch 11，Meng 定规则的落地）

- 跳过口径：一道题没有任何未解决错因时跳过；其中“已解决但到了复查时间”的错因算仍需复习（可加），因为复查题仍在复习队列口径（`reviewBucketOf` 的 `recheck` 桶、`dueToday` 含复查题）里；全部已解决且复查未到的题才跳过。已治愈记录不动靠底层保证：`setReviewJoined` 播种用 `ConflictAlgorithm.ignore`。
- “全部加入”作用域：当前筛选结果（`_filteredAll()`），与 Batch 9“全选当前结果”同口径；不限当前页，不含已掌握默认隐藏的题（筛选状态为“已解决”时才可见并可加）。
- 反馈文案：加入 `已加入复习 N 道；M 道已无未解决错因，跳过`；取消 `已取消加入复习 N 道；M 道未加入复习，跳过`；另有“已不在列表里，跳过”与“保存失败，请重试”分段。
- “开始复习”入口形式：加入结果 Snackbar 的动作按钮（`SnackBarAction`），只在加入成功时出现；点后跳 `/review` 且不限学科（批量可能是跨学科筛选结果）；未另加常驻按钮。
- 分层：判定 + 计数在 `QuestionRepository`（纯判定可单测、批量方法可 Fake 覆盖）；页内只做勾选解析、缺失计数与反馈。取消不二次确认（与详情页单个取消一致，无确认框）；记录保留、重加入恢复。详见 `docs/ui-replication/B11-6-BATCH-REVIEW.md`。

## D-30 — 详情页导出图片：剪贴板用 super_clipboard，分享卡片先预览再保存（2026-11-15，Batch 11）

- Windows 下复制图片可行，不只做保存：Flutter 自带 `Clipboard` 只支持文本，图片必须走插件；用 `super_clipboard ^0.9.1`（最新稳定版，Min Dart SDK 3.0，与 Dart 3.13.7 / Flutter 3.47.9 兼容）。依据：官方 README 明确写支持 Windows + Linux；写 PNG 时 Windows 上按需转 DIB / DIBv5，原生应用（微信、Word、画图）粘贴时拿到标准位图，DIBv5 保留透明通道。备选 `clipboard` 包未采用：只声明 Android / iOS / Web / Windows，不支持 Linux（开发机是 Linux），且是单人维护包；super_clipboard 由 superlist 维护、支持 Linux，长期更稳。代价：Rust 内核，未装 Rust 时构建自动下载对应平台预编译二进制——Windows 上 `flutter build windows` 首次构建需要联网下载；README 仍称插件 experimental。验证边界：服务层复制成功/失败分支已测、Linux Debug 构建通过；Windows 真机粘贴必须另验；Linux 测试环境下没有调真实剪贴板写（带真实写的探针让 `flutter_tester` 空转挂起，原因是无显示服务时原生写调用阻塞）。
- 分享卡片先预览、再保存，不直接静默落盘：点“导出带答案版”先弹预览框，用户确认后再走另存为；不提供“直接保存到默认位置”的静默路径（与保存图片的另存为体验一致）。详见 `docs/ui-replication/B11-8-EXPORT-IMAGE.md`。

## D-31 — 考试事件独立存储，与试卷实体无任何关联（2026-11-15，Batch 11；Meng 2026-11-15 23:19 更正）

- 考试事件是完全独立的数据：存 settings 表 `examEvents` 键（JSON 数组），不新建表、不并入试卷表。理由：备份校验要求 `backupTables` 每表键齐全，新表进清单会使旧备份无法恢复、不进则恢复时静默丢数据；放 settings 表则随备份走、旧备份恢复不受影响；且不改 schema、不写 onUpgrade、v1 演示库不动。`ExamEvent` 与 `Exam`（试卷）无任何关系（不同存储、id 前缀 `exam-event-` vs `exam-`、无引用）。
- 设置页考试管理：用户自己加考试，只填自定义名称 + 考试日期，不选试卷、不关联试卷、不读任何试卷数据；列表支持改名、改日期、删除。考试组单独成组“考试”，放“错题本”与“数据”之间，保持分段折叠风格（默认全折、一次只开一组）。
- 倒计时口径：N = 考试日期 − 今天，按日历日算（不含时分秒）；最近一场 = 未过期里 N 最小，全部过期时取最近过期那场；文案“距离 XX 考试还有 N 天”（当天“今天考试”，过期“已考完”）；日期只存 `yyyy-MM-dd`。
- 标红口径：临近 7 天 / 3 天 / 1 天理解为“7 天内”（0 ≤ N ≤ 7）标红，而非仅在 N 恰好等于 7 / 3 / 1 当天标红。
- 点倒计时进设置页的考试管理（方便改）；不做“可选关联试卷”、不做“点倒计时进该试卷题目列表”、不做“考前冲刺（只练这场考试的错因）”。
- 考试列表懒加载：设置页平时不读考试事件，只在考试组打开时读（从首页倒计时点进来时读一次），避免无谓读库，也避免旧测试被新 repo 调用波及。详见 `docs/ui-replication/B11-9-EXAM-COUNTDOWN.md`。

## D-32 — 错题本列表范围为空：文案不动，“去收集 / 去整理”改成两个按钮（2026-11-16；Meng 2026-11-16 09:42 定“改成按钮”）

- 改动只在错题本列表页范围为空的三种情形（文件夹空 / 学科空 / 整本空）：动作位由单按钮“返回目录 / 返回书架”改成“去收集”（主按钮，实心亮蓝白字，进 `/collect`）+“去整理”（次按钮，白底蓝字细蓝边，进 `/organize`），短文案、10px 圆角，与项目按钮风格一致。文案本身不动（仍写“去收集中心拍一道题，或去整理工作台……”），其余空状态（归档空 / 已解决隐藏 / 搜索无结果）与另外 26 处空状态都不动。
- 实现：`QmEmptyState` 增加可选第二动作位（`secondaryActionLabel` + `onSecondaryAction`，默认次按钮样式；两动作都给时并排 `Wrap` 居中，只给主动作时渲染与原来完全一致，其他 9 处调用点不动）；`WrongbookPage` 增加可空回调 `onGoCollect` / `onGoOrganize`（沿用 B8-1 `onGoSubjects` 的可空模式），`app.dart` 接成 `_go('/collect')` / `_go('/organize')`；`_emptyCopy` 的范围为空分支在两回调齐全时返回双按钮，任一未接通时回落旧单按钮（测试里不传时仍是返回按钮，旧测试不动）。
- 返回入口不丢：列表页头已有“← 目录 / 合上 ✕”按钮；双按钮替代的只是空状态卡片里的返回按钮。
- 不升级依赖、不改 pubspec.lock、不改 Schema、不增删功能。随 B11 一次推送。

## D-33 — 架构 A 第 0 阶段：设置页抽 SettingsController，页面只留 setState 转发（2026-11-16，ARCH-PLAN-A §四第 0 阶段）

- 新建 `lib/modules/settings/settings_controller.dart`：纯 Dart 类 `SettingsController`，构造器接 `QuestionRepository`，不依赖 Flutter、不碰 `BuildContext`、不引入新依赖（不加 riverpod、不改 pubspec.yaml / pubspec.lock、不改 SQLite Schema、不增删功能、不碰 `lib/data/` 与其他页面）。方法只返回结果或抛异常。
- 进了 Controller 的业务（原样搬移，行为零变）：读库（考试事件列表、题数统计含已归档、恢复后重读设置）；问候语校验与默认恢复（纯函数）；备份/恢复编排（导出 zip 字节、备份失败标志记/清、按魔数解析备份文件、zip 与 JSON 恢复分发）；数据库位置与迁移（当前库路径、目标已有库判断、保留现有库、带进度/取消的搬库）；空间占用与孤儿扫描/清理；缓存扫描/清理（`CachePreview` 类与 `_scanCacheSync` 递归算法原样移入，SR2-30 / SR3-19 / SR-P2-50 口径不变）；考试事件增删改（空名/未选日期/重名校验、改名重名校验、改日期、删除）。
- 留在页面的东西：全部 UI 副作用与本地状态——弹窗（确认/改名/选目录/选日期/选时间）、文件选择器（备份另存为、恢复选文件、改库位置选目录）、SnackBar 提示、`onSettingsChanged` 回调（`app.dart` 的 `_updateSettings` 仍负责写库与主题刷新，设置保存本身不进 Controller）、折叠组/输入框等本地 State、`_apply` 的 `setState` 转发。页面除 `widget.repo` 传给 Controller 构造器外不再直接调 `repo`。
- 两处与“原样搬”有意的微差（均不改变任何可达生产行为）：① `addExamEvent` 里日期多做一次 `dateOnly` 归一化——页面传进来的 `_newExamDate` 本就已归一化，纯属兜底；② 备份解析的异常类型收敛为三类（读不到文件 `RestoreFileReadException`、校验不过 `BackupRestoreException`、其余格式问题 `FormatException`），页面按类型提示，文案与原来逐分支的提示一一对应。
- 已知遗留（不在本阶段改）：考试事件 id 用 `exam-event-<毫秒时间戳>`（B11-9 原方案），同一毫秒内连加两场会撞 id、后者覆盖前者；生产上用户手动点两下撞不上的概率可忽略，Controller 单测里多场合用显式 id 写库绕开，不依赖时钟粒度。若后续要修，另立项改 id 生成（不要顺手塞进 Stage 1）。
- 验收：`flutter analyze` 0 问题；设置相关测试全过（`settings_page_test.dart`、`b11_9_exam_countdown_test.dart`、`p0b1_settings_owner_test.dart`、`p0b2_pagesize_test.dart`、`s8a5_section_scroll_test.dart`）；新增 `test/settings_controller_test.dart` 13 个单测（不启动 widget：问候语 3、考试事件 4、题数统计与备份恢复 5、缓存清理 1）；全量串行 1023/1023（基线 1010 + 新增 13）；演示库 md5 不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.a0-gate`）。执行中另发现本机 clang 丢失导致 `flutter test` 无法构建 pdfium 原生资源，已用 `apt-get install clang` 装回 18.1.3（与此前重装版本一致），属环境修复，未改仓库。
- Stage 1 要注意的事：① 本阶段 Controller 仍是“页面持有、页面调”的形态，第 1 阶段按方案改为 `AsyncNotifier` 时，`SettingsController` 的方法签名可直接复用，但 `_apply`/`onSettingsChanged` 的保存路径要与 `settingsProvider` 合并（根组件 `_settings`/`_loadSettings` 改订阅同一 Provider，见方案 §四第 1 阶段第 4 条），不要两处各写各的；② 设置页最终形态是 `ConsumerStatefulWidget`（折叠组等本地交互状态留页面，不进 Provider）；③ 角标本阶段不动，仍走 `badgeVersion`（恢复成功后的 `bumpBadgeVersion()` 仍在页面）；④ 考试事件 id 碰撞问题如在 Stage 1 顺带修，必须先与协调员确认，不自行扩大范围。

## D-34 — 架构 A 第 1 阶段：Riverpod 引入 + 设置页试点 + 根组件订阅同一 settingsProvider（2026-11-16，ARCH-PLAN-A §四第 1 阶段）

- 依赖：`pubspec.yaml` 加 `flutter_riverpod: ^3.4.3`，解析到 3.5.0；`pubspec.lock` 只新增 8 个包（flutter_riverpod 3.5.0、riverpod 3.5.0、state_notifier 1.0.0 及 5 个传递依赖 cupertino_ui / flutter_localizations / intl / listen / material_ui），其余项零改动、零删除。`lib/main.dart`：`runApp` 外包 `ProviderScope`。
- `lib/state/`（新建）：`repository_provider.dart`（`repositoryProvider`，默认 `QuestionRepository(AppDatabase.instance)`，与根组件用的同一单例库；测试用 override 替换）；`settings_notifier.dart`（`settingsProvider` + `SettingsNotifier extends AsyncNotifier<AppSettings>`）。Stage 0 的 `SettingsController`（`lib/modules/settings/settings_controller.dart`）已删除，全部业务方法原样迁入 Notifier（方法签名复用，`repo.` 改为经 `ref.read(repositoryProvider)` 拿——方法在 `build()` 跑完前也能调；`CachePreview` / `_scanCacheSync` / 两类异常随之搬入同一文件）。新增：`build()` 读库（`repo.settings()`）；`saveSettings(s)`（先写库、成功后才 `state = AsyncData(s)`，写失败 state 不动）；`reloadSettings()`（恢复备份后重读，`AsyncValue.guard` 结果一次性赋值，中间无 loading 态、不闪启动屏）。删除：Stage 0 的 `loadSettings()`（恢复流程改为一次 `reloadSettings()`，见下）。考试事件 id 毫秒时间戳碰撞问题未动（D-33 遗留，仍待另立项）。
- `settingsProvider` 的位置与职责：状态是 `AppSettings`，唯一真源仍是 SQLite settings 表，Provider 只做响应式读取 + 写回，不另存一份。读：`ref.watch(settingsProvider)`；写：`ref.read(settingsProvider.notifier).saveSettings(s)`。考试事件列表是懒加载的页面本地展示状态（只在考试组打开时读），增删改走 Notifier 的同名方法。`lib/data/` 与 `lib/services/` 无 riverpod import（白名单见方案 §六-7）。
- 设置页改为 `ConsumerStatefulWidget`（折叠组/输入框/迁移进度等纯界面临时状态留页面本地 State）：构造参数只剩 `loadFailed` / `onBackupFailed` / `initialOpenGroup`，`repo` / `settings` / `onSettingsChanged` 已删除；`_apply` 只调 `notifier.saveSettings`，不再 `setState`（Provider 重建把新值带回，`_s` 是 Provider 值的本地镜像，build 里同步，问候语输入框文本同时跟进、文本相同时不重复赋值）；恢复确认后 `loadSettings() + _apply()` 两步合并为一次 `reloadSettings()`。设置页最终保留了本地状态，故用 `ConsumerStatefulWidget`（未改用 `ConsumerWidget`，方案两种形态无矛盾）。
- `lib/app.dart` 改了什么：根组件改为 `ConsumerStatefulWidget`，删 `_settings` / `_settingsLoaded` / `_settingsLoadFailed` / `_loadSettings()` / `_updateSettings()`；build 里 `ref.watch(settingsProvider)` 拿主题/深浅色/字号，`settings` 值传给 `HomePage`，`SettingsPage` 只接 `loadFailed`（由 provider 的 error 态导出）；设置首次读到时 `_onSettingsReady` 解析一次启动路由（`lastRoute` + `startupPage` + 备份失败标志 + 复查提醒安排 + lastRoute 自愈，与原来 `_loadSettings` 同口径，之后改设置不再重解析）。修复一个 Stage 1 引入的竞态：`_onSettingsReady` 原跑在首帧后回调里，用户在它执行前已点导航时会被拽回初始路由（b8_1 / b9_1 回归失败），现加 `_userNavigated` 守门（四个导航入口 `_go` / `_goSettings` / `_goReview` / `_goWrongbookFiltered` 置起），用户已导航时只应用备份标志与提醒、不动路由。提醒条件的开关与时间改从 provider 读。角标不动，仍走 `badgeVersion`；`lib/data/` 未动；未建 `DataChangeBus`（第 4 阶段的事）。
- 测试迁移（无删除、无弱化，断言口径不变）：Stage 0 的 13 个 Controller 单测迁入 `ProviderContainer.test` + `repositoryProvider.overrideWithValue`（`test/settings_controller_test.dart`），另新增 3 个 Provider 行为测试（build 读库 / saveSettings 写库并更新 state / reloadSettings 重读），该文件共 16 个；设置页直 pump 的 5 个文件（`settings_page_test.dart`、`p0b1_settings_owner_test.dart`、`p0b2_pagesize_test.dart`、`b11_9_exam_countdown_test.dart`、`s8a5_section_scroll_test.dart`）包一层 `ProviderScope` override，保存的观察点从 `onSettingsChanged` 回调改到 FakeRepo 的 `settings()` / `saveSettings()` 记录；整应用 3 个文件（`b8_1_subject_refresh_flow_test.dart`、`b9_3_review_badge_test.dart`、`b9_1_collect_done_test.dart`）只在 `QuizMasterApp` 外包一层 `ProviderScope`。`flutter analyze` 0 问题；全量串行 1026/1026（基线 1023 + 新增 3）；Linux Release 构建通过；演示库 md5 不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.a1-gate`）。另附 `docs/ui-replication/A-READING-GUIDE.md`（Provider 在哪、状态在哪、测试怎么注入）。
- Stage 2 要注意的事：① 本阶段只动了设置页 + 根组件，其余 8 页仍直接调 `repo`，第 2 阶段按页迁移时每页同样先确认“业务走 Provider、纯界面临时状态留本地 State”的划分，不要把折叠/选中/分页等本地状态塞进 Provider；② `repositoryProvider` 的默认值与根组件的 `repo` 字段是两个 `QuestionRepository` 实例、共用同一 `AppDatabase.instance` 单例——目前无状态可分叉（Repository 是无状态代理），第 2 阶段如有页面也经 provider 拿库，仍以单例库为准，不要各建各的数据库连接；③ 启动路由解析仍依赖 `_userNavigated` 守门，第 2 阶段如有页面在启动瞬间就触发导航（如深链），须先复核该守门是否仍适用；④ `settingsProvider` 的 error 态目前只在设置页出横幅（`loadFailed`），第 2 阶段其他 Provider 的 error 态展示方式要逐页定，不要默认沿用本页的横幅做法。

## D-35 — 架构 A 第 2 阶段：四个中等页收进 Provider（2026-11-16，ARCH-PLAN-A §四第 2 阶段；A 路首页+学习报告、B 路学科管理+错题本并行）

- 新增 `lib/state/home_provider.dart`（`homeProvider` + `HomeNotifier extends Notifier<HomeState>`）、`lib/state/report_provider.dart`（`reportProvider` + `ReportNotifier extends Notifier<ReportState>` + `WeakGroup`，原页内 `_WeakGroup` 改公开移入）、`lib/state/subjects_notifier.dart`（`subjectsProvider` + `SubjectsNotifier extends Notifier<SubjectsState>`）、`lib/state/wrongbook_notifier.dart`（`wrongbookProvider` + `WrongbookNotifier extends Notifier<WrongbookState>` + `wrongbookInitialProvider`）。每页 1 个 Provider；状态唯一真源仍是 SQLite，Provider 只做响应式读取（报告另含范围选择），不另存一份、不改 Schema、不增删功能。
- 首页进 Provider 的业务：继续上次（`recentTask`）、每学科待复习/待复查/已解决数（`homeRevCounts` / `dueToday` + `reviewBucketOf` 拆分，SR-P1-1 口径）、待整理数、学科表、最近考试倒计时（`nearestExamEvent`）。`HomeNotifier.load()` / `retry()` 原样搬自 `_load` / `_retryLoad`（SR-P2-48 失败留旧内容口径不变）。
- 报告进 Provider 的业务：时间范围（默认本周）、三个核心数（S8 B1 `lastCheck` 口径）、弱点 Top 5（原因组 / 知识点组，SR-P1-10 按题 id 计数、SR-P1-11 只收已整理未归档未掌握题、SR3-2 已掌握口径）、按学科分布、“接下来练什么”一句。派生计算是 `ReportState` 上的 getter，`setRange()` 只改范围、不重读库；`load()` 原样搬自 `_load`（含逐题 `reviewHistory` 顺序读）。
- 学科管理（原 20 处 setState）：学科/知识点树/文件夹（新学科预置 3 个）/标签/试卷四组增删改名、封面样式/颜色点即生效、新学科取色（12 色 + 金角轮转，SR2-31/SR3-21 原样迁移）进 Notifier；四段折叠、封面块展开、章节展开、改名目标、输入框、新试卷日期、试卷搜索词留页面本地 State。`kpSubjectId` 在 Provider 里。
- 错题本（原 27 处 setState）：书架/目录/列表三个子页共用一个 `wrongbookProvider`；数据 + 视图/范围 + 分页/筛选/选择/目录树状态全进 Provider；派生计算（`filteredAll`、文件夹计数、错因状态、学科首字母排序）是 `WrongbookState` 上的纯函数；封面样式与颜色、目录树、列表搜索/过滤/排序/批量逻辑随 Provider 走。D-32 空状态双按钮（“去收集”进 /collect、“去整理”进 /organize）行为不变，相关测试全过。`wrongbook_cover.dart` / `wrongbook_widgets.dart` 未动。
- 四页改为 `ConsumerStatefulWidget`（错题本与学科管理是外壳 `StatefulWidget` + 内层 `ConsumerStatefulWidget`），页面只留 widget 与纯界面临时状态：首页剩 2 处 `setState`（两条横幅已关闭标志），报告剩 6 处（横幅已关闭 + 两组“看更多”展开/收起）。Notifier 只做数据与状态，不碰 `BuildContext`、不弹 Dialog、不调导航。
- `repo` 构造参数保留：本阶段不碰 `lib/app.dart`，各页在 build 里包一层 `ProviderScope(overrides: [repositoryProvider.overrideWithValue(widget.repo)])` 把构造器接进来的库交进依赖图，页内不再直接调 `repo` 的方法；内层 `Consumer` 的 ref 才属于这层 scope。问候语仍由应用层经构造器传 `settings` 进首页。角标不动，仍走 `badgeVersion`；未建 `DataChangeBus`（第 4 阶段的事）。
- 初始落点用 `wrongbookInitialProvider`（`WrongbookInitial`：`subjectId` / `filterCause` / `filterKnowledgePointId`）：外壳 override 注入，Notifier `build()` 里读它定初始视图。初版在 `initState` 里调 `applyInitial` 同步改 Provider，触犯 Riverpod“禁止在 build/initState 等生命周期里改 Provider”，106 个错题本测试失败；改用本机制后全过，`applyInitial` 已删除。
- 首查在 `Notifier.build()` 里经 `Future.microtask(load)` 触发、配 `_disposed` 守门（代替原 `mounted` 检查），大页迁移时沿用此模式，不要在页面 `initState` 里调 `load()`（外层 `ref` 拿不到内层 override 的库）。
- 验收：`flutter analyze` 0 问题；A 路受影响既有测试 97/97（home_page 18、report_page 26、b11_9 23、b7_p1_sr3_2 2、b8_1_subject_refresh 11、b8_1_subject_sweep 6、s8b2_subject_sync 11）+ 新增 Provider 单测 16 个；B 路受影响测试 256 个全过（学科相关 79、错题本相关 121、间接经过两页的 32、新单测 24）；既有测试文件 0 删除、0 弱化；全量串行测试由协调员合并后统一跑（见本条验收数字）。
- Stage 3 注意点：① 下次动 `app.dart` 时可顺手删掉各页的 `repo` 构造参数与页内嵌套 `ProviderScope`，改走根 `ProviderScope` 的 `repositoryProvider` 默认值（同一单例库），并评估首页问候语是否改由 `settingsProvider` 直读；② `WrongbookNotifier.update((st) => st.copyWith(...))` 是纯界面字段的通用改动口，大页复习/整理/详情迁移时应优先用具名方法、少用它，避免“setState 换皮”；③ `wrongbookInitialProvider` 的“初始参数 Provider”模式可复用到复习页（断点续治入参）与详情页，但不要扩成跨页共享状态；④ 各页 Provider 的 error 态展示方式逐页定，本阶段四页沿用各自原有横幅做法，未统一。

## D-36 — Stage 2 回归修复：四 Provider 改 autoDispose，恢复“回页重读”（2026-11-16，A2-fix-gate）

- 根因：全量验收 1065/1066，只失败 `test/b8_1_subject_refresh_flow_test.dart`（“删光三科后四处界面都不再出现已删学科”，第 5 步回首页后“数学/英语/政治”仍在首页底部学科格里）。嵌套 `ProviderScope` 不会给未 override 的 Provider 新建实例——未 override 的 Provider 与父 scope 共享同一实例、活在根容器里；四个 Stage 2 Provider（home/report/subjects/wrongbook）的 `load()` 只在 `Notifier.build()` 里跑一次，页面卸载后 Provider 不销毁，回页时不再重读库。旧版是 `initState` 里 `_load()`、每次重挂载都重读，所以旧版能过。临时探针验证（探针已删）：`HomeNotifier.build` 全程只跑一次、`dispose` 只在测试结束时；`HomePageState` 中途 dispose 过一次（导航离开时），回页时 `HomePage.build` 又跑了一次，但 Notifier 没重建。
- 修法：只改 4 个 Provider 声明为 `NotifierProvider.autoDispose`——`lib/state/home_provider.dart` 的 `homeProvider`、`lib/state/report_provider.dart` 的 `reportProvider`、`lib/state/subjects_notifier.dart` 的 `subjectsProvider`、`lib/state/wrongbook_notifier.dart` 的 `wrongbookProvider`。`wrongbookInitialProvider`（纯初始参数 Provider）不动；`settingsProvider`（根组件常驻监听）不动；页面文件、测试文件、`lib/data/`、`pubspec` 一律不动。Dispose 安全已逐个确认：四个 Notifier 均无 Timer / Stream / 订阅，只有 `_disposed` 布尔守门 + `ref.onDispose(() => _disposed = true)`，无泄漏的订阅/定时器需要取消，`build()` 里无需补任何处理。页面卸载后 Provider 销毁，回页重建并重读库，恢复旧版“回页重读”行为。详情页是 Navigator 压栈（底层页仍挂载、仍在监听），autoDispose 不会在压栈时销毁——不为此多做处理；跨页实时刷新是第 4 阶段 DataChangeBus 的事，本次不提前做。
- 为什么不用 initState 调 load：① 页面外层 `ref` 拿不到内层 scope override 的库（D-35 末条：`build()` 里包的 `ProviderScope` 只有内层 `Consumer` 的 ref 才属于它），initState 里调不到正确的 repo；② 在 `initState` 里同步调 Notifier 方法改 Provider 状态，触犯 Riverpod“禁止在 build / initState 等生命周期里同步改 Provider”（同 `wrongbookInitialProvider` 前身 `applyInitial` 的违规，当时 106 个错题本测试失败）；③ `build()` 里已有一路 `Future.microtask(load)` 首查，initState 再调一路会造成双份重读。autoDispose 让已有的 `build()` 首查在每次回页重建时自然重跑，改动只有一个声明词，不引入第二路触发点。
- 验收：`flutter analyze` 0 问题；`b8_1_subject_refresh_flow_test.dart` 单独跑通过（回归点已修）；四页受影响测试 17 个文件共 276 个，274 通过；全量串行 1064/1066（1026 + A 路 16 + B 路 24），演示库 md5 不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.a2-fix-gate`）。未达 1066/1066 的原因见下条，属测试写法与 autoDispose 语义的冲突，不是回归本身未修。
- 未闭合项（需协调员裁决，本次修复员未碰测试文件）：全量仅剩 2 失败，都是 Stage 2 新增 Provider 单测里的“只读 state 也能等到加载完成”（`home_provider_test.dart` / `report_provider_test.dart`）。探针验证：autoDispose Provider 无监听者时约一帧后即销毁；测试只 `container.read(provider)` 不监听，`build()` 的 microtask 首查还没写回 state 就被 `_disposed` 守门丢掉，下一次 `read` 又重建一个全新实例，轮询 100 次也等不到 `hasLoaded`；同一探针加 `container.listen` 后立即通过。生产侧不受影响（四页都 `ref.watch`，挂载期间一直有监听者）。建议的闭合方式：两测试各加一行 `container.listen(provider, (_, __) {})` 保活（纯 harness 改动，不断言、不删测、不改口径），或由协调员另定；`ref.keepAlive()` 不可取（会让 Provider 永不销毁，回归重现）。
- Stage 3/4 注意点：① 新 Provider 默认是否 autoDispose 按“页面独占还是常驻监听”定：页面独占（随页生死、回页重读）用 autoDispose；常驻监听（根组件 / 多页共享）不用。② `settingsProvider` 与未来的 `badgeCountsProvider` 常驻监听、不 autoDispose。③ 新 Provider 单测里只 `read` 不监听的写法在 autoDispose 下会提前销毁——单测要么 `container.listen` 保活，要么直接 `await notifier.load()` 后断言，不要用裸 `read` 轮询等首查。④ `build()` 里 `Future.microtask(load)` + `_disposed` 守门的模式继续沿用；autoDispose 后 `_disposed` 守门仍必要（卸载后回包不触 state）。

## D-37 — 架构 A 第 3 阶段：复习页收进 Provider（2026-11-16，ARCH-PLAN-A §四第 3 阶段第 1 条）

- 新增 `lib/state/review_notifier.dart`（唯一新增的状态文件）：`reviewProvider`（`NotifierProvider.autoDispose<ReviewNotifier, ReviewState>`）+ `reviewInitialProvider`（`ReviewInitial`：`subjectId`，带 `==`，外壳每次 build 传等值实例时不触发 override 失效）。每页 1 个 Provider（本阶段只用 1 个，未建第 2 个）；状态唯一真源仍是 SQLite，Provider 只做响应式读取 + 会话状态持有 + 写回，不另存一份、不改 Schema、不增删功能。
- `ReviewState`（原 `_ReviewPageState` 的全部字段原样搬移）：列表数据（settings、subjects、groups、curedGroups、notJoined、pendingByQ、loading/loadError/errorDismissed/hasLoaded、subjectFilter/causeFilter/page/pageSize/pageSizeInitialized/openCuredKey/curedPage/notJoinedExpanded/resume）+ 会话状态（inSession/showSummary/blocks/bi/ci/phase/checks/skips/curedNow/changes/summaryRemaining/scopeLabel/saveError/historyByQ/answerShown）。派生计算（`filtered`/`pageGroups`/`allCauses`/`metaCounts`/`scopeLabelForFilters`/`scopeLabelForBlocks`/`recordOf`/`questionOf`/`subjectOf`）是 `ReviewState` 上的纯函数/ getter。原页内私有类全部改公开移入本文件：`CauseItem` / `CauseGroup`（`status` / `hasRecheck` 口径不变）/ `CauseBlock`（加 `copyWith`）/ `SessionChange` / `ResumeInfo` / `ReviewPhase`（recall/remedy/redo/check）。
- 会话状态归属：断点续治与跳过队列的实时会话状态由本 Provider 持有；自查结果、补救、治愈等持久化写回 SQLite（`recordSelfCheck` / `saveRemedy` / `saveReviewState` / `clearReviewState`）；详情页的复习记录不持有会话状态（详情页是下一页的事，本次未动详情页）。每次提交后本 Provider 的会话状态直接更新，不等待事件回绕——未建 `DataChangeBus`（第 4 阶段的事），提交后也不发事件。
- `reviewProvider` 是 autoDispose（D-36 结论：页面独占、随页生死，回页重读；离开中途再回来按旧版重挂载行为处理，断点续治靠 SQLite 里的持久化状态恢复，不把未提交的会话状态当成必须跨导航保留的东西）。`build()` 里 `Future.microtask(load)` 首查 + `_disposed` 守门（沿用 Stage 2 模式）；`load()` 只写列表数据字段，不动会话字段（会话结束/暂停回列表时复用同一路重读，不会把正在展示的总结/会话顶掉）。`load()` 原样搬自页面 `_load`（分组、SR-P2-39 未加入过滤、B6 归档排除、SR2-34 错因筛选失效回落、断点校验与陈旧断点回收、SR-P1-12 页数初值守门）。
- 初始入参复用 D-35 的 `wrongbookInitialProvider` 模式：外壳经 `ProviderScope` 注入 `ReviewInitial`，Notifier `build()` 里读它定初始 `subjectFilter`，不在页面 `initState` 里同步改 Provider。
- `repo` 构造参数保留（本阶段不碰 `lib/app.dart`）：页面在 build 里包一层 `ProviderScope(overrides: [repositoryProvider.overrideWithValue(widget.repo), reviewInitialProvider.overrideWithValue(...)])`，页内不再直接调 `repo` 的方法。角标不动，仍走 `badgeVersion`；不建 `DataChangeBus`；不碰 `lib/data/`、`lib/app.dart`、`lib/main.dart`、pubspec；不碰其他页面。
- 细粒度重建：页面拆成 `_ReviewView`（只订阅 `(loading, inSession, showSummary, sessionCauseKey)` 四元组）+ `_ListView`（整份 state，列表）+ `_SessionView`（只订阅 `phase` 与“当前题是否还在”）+ `_SessionMeta` / `_CauseMeta` / `_StepCause` / `_StepRemedy` / `_StepRedo` / `_StepCheck`（各只 `select` 自己要的字段）+ `_SummaryView`（只订阅 `(curedNow, summaryRemaining, changes)`）。自查点选只改 `checks`，只重建自查步，不重建整个会话。跳过时块用新实例（`CauseBlock.copyWith`，不原地改 `causes` 列表），保证 `select` 按实例变化识别出当前块变了。
- 补救输入框控制器是页面本地 UI 状态，不进 Provider：原 `_beginCause` / `_skipCurrent` 里的 `_remedyController.clear()` 改由 `_ReviewView` 按 `ReviewState.sessionCauseKey`（`bi|ci|questionId|块内错因表`，不在会话里为空串）变化、下一帧清一次。新错因开始/跳步后输入框是空的，与原来一致；重做步不清空（原来 `_nextFromRemedy` 走重做分支时也不清）。
- 修掉的两个迁移引入问题（均在自测中发现、已修）：① `_ReviewView` 的模式切换先判了 `inSession` 再判 `showSummary`，会话结束时 `inSession` 仍为真、总结页永远走不到（原代码是会话内先判 `_showSummary`）；② 会话各步的 `select` 选择器在块被跳空的瞬时态里对 `currentBlock` / `currentQuestion!` 抛错（Riverpod 通知时选择器先于父级切总结页的重建被求值，抛错会污染通知）——全部选择器改成空安全，无当前块/题时返回 null、对应步渲染空占位，父级随后切到总结页。
- 行为口径零变：治愈（同一错因同一题自查“已解决”两次，`cureChecks` 走设置）、跳过（第 1 次追加队尾、第 2 次留到下次，`skipLimit` 走设置）、复查通过不加计数（待定1）、“不确定”不算、每会话错因数上限（`causesPerSession` 走设置）、断点续治与范围文案（SR-P2-57）、按组只治该组错因（SR-P2-49）、SR-P1-13 跳过末错因直接进重做、SR2-34 详情删题回列表不断言。
- 测试：既有测试文件 0 删除、0 弱化，复习页构造参数不变（外壳模式与错题本/首页一致），widget 测试无需改包裹/注入方式。新增 `test/review_notifier_test.dart` 16 个 Provider 单测（不启动 widget，`ProviderContainer.test` + `repositoryProvider.overrideWithValue`，`container.listen` 保活——D-36 的 autoDispose 单测教训）：load 分组/元信息/初始筛选/失败重试/筛选分页 5 个，治愈与自查（四步走完、满 2 次治愈、复查不加计数、不确定不算、保存失败、按组进会话）6 个，跳过与断点（跳过两次、SR-P1-13、暂停续治、从头开始、陈旧断点回收）5 个。
- 验收：`flutter analyze` 0 问题；复习页既有测试 39/39（`review_page_test.dart`）+ 相关文件 45/45（`b9_3` / `b9_4` / `b11_6` / `p0b1` / `p0b2` / `b8_1_subject_sweep` / `b11_11`）+ 新增单测 16/16；全量串行 1082 个（基线 1066 + 新增 16），两次全量各 1081/1082（见下条，两次失败不同、都是既有文件里单跑通过的用例，与本次改动零交集）；Linux Release 构建通过；演示库 md5 不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.a3-review-gate`）。
- 未闭合项（需协调员裁决，本次执行员未碰这两个文件、未扩大范围）：两次全量各剩 1 个失败，都是既有测试、单跑通过、与本次改动零交集。① 默认 /tmp 跑：`import_service_p1_fixes_test.dart` 的 SR-P1-14“恰好 50MB PDF 放行进 needBox”。已定位为环境问题：任务失败的 error 是 `导入失败：文件复制不进去（FileSystemException: writeFrom failed, path = '.../imports/task-.../original.pdf' (OS Error: No space left on device, errno = 28)）`；`/tmp` 是 512MB tmpfs，每次 `flutter test` 在其中写两个 105MB 的 .dill（编译输出 + 监听器副本，共 ~210MB），该组测试在自己的临时目录里还要写 21MB + 20MB 源文件 + 20MB 复制 + 50MB 源文件 + 50MB 复制（峰值 ~161MB），空间不够时 50MB 复制失败、任务判 failed。证据：单跑该用例通过；`TMPDIR` 指到磁盘（`~/workspace/.tmp-tmpdir`）后该组 5/5 全过。② `TMPDIR` 指磁盘重跑全量：SR-P1-14 通过，换成 `detail_page_test.dart` 的“重新框选 §1.5.1 SR2-3：事务失败时旧切片字节完好、框与题不动（有旧切片）”失败（断言“重新框选失败：保存失败，请重试”未出现）；该用例依赖 `runAsync` 内真实延时等自愈跑完（30×200ms）再走重框流程，是时序敏感用例，单跑 11s 通过、整文件跑（36/37）失败，详情页文件本阶段未动。两文件都只 import `data` / `models` / `services`，与本次改动的复习页文件零交集；是否再跑全量取干净数由协调员定。
- 整理页（下一页）要注意的事：① 整理页 52 处 `setState`，队列 + 批量条 + 折叠手风琴状态收进 Provider；确认/批量确认后队列推进逻辑进 Controller 单测（方案 §四第 3 阶段第 2 条）。② 复习页的教训直接复用：会话/队列类 Provider 的 `load()` 不要碰进行中的会话字段；`select` 选择器必须空安全（队列被清空的瞬时态里 `currentX!` / 下标会抛错，污染 Riverpod 通知——先判空、返回 null、由父级切空态）；模式切换的分支顺序要先判终态再判进行中（本阶段 `inSession` 先于 `showSummary` 的 bug）；`autoDispose` 单测必须 `container.listen` 保活，不要裸 `read` 轮询等首查。③ 整理页也有输入框/修框类本地 UI 状态（文本控制器、折叠），按本页补救输入框的办法处理：控制器留页面，清空信号用 Provider state 里一个派生 key（本页是 `sessionCauseKey`）驱动，不要把控制器塞进 Notifier。④ 整理页确认整理后队列推进时若也用 `unawaited` 的收尾异步（本页 `_finishSession` 同款），单测里要轮询等终态，不要 `await` 方法返回就断言——收尾是 fire-and-forget，主方法返回时还没跑完。

## D-38 — SR2-3 测试等待策略改按条件轮询（2026-11-16，Stage 3 验收；只改测试等待，不断言、不弱化）

- 背景：全量三次跑，SR2-3（详情页重新框选 §1.5.1，事务失败时旧切片字节完好）在全量负载下两次失败、整文件单跑两次全过；详情页本阶段未动。日志定位失败在 883 行“临时切片已清干净，不留 .tmp-*.png”——失败提示已出、失败后的临时文件异步删除在负载下还没落定，固定 20×200ms 等待就断言了。另有一次失败是 50MB PDF 写 /tmp 报 ENOSPC（/tmp 是 512MB tmpfs，flutter test 每次编两个约 105MB 的 .dill 就占 ~210MB），已改走磁盘 TMPDIR（~/workspace/.tmp-flutter-test）跑全量。
- 改动只在 test/detail_page_test.dart 的 SR2-3 一处，两处固定等待改按条件轮询，断言本身一字不动：① 自愈等待：等到切片宽度变成自愈后的 492 且自愈那次 repo.save 已落袋才继续——注意顺序，自愈先写文件、再调 save 改库里尺寸；第一版只等文件破得太早，后面的 repo.saved.clear() 清不到那次保存，导致末尾“事务失败不存题”断言误报，已修正；② 确认后等待：等到失败提示出现且 .tmp 临时文件清干净才继续。
- 验收：SR2-3 单跑通过、整文件 37/37 通过；全量待重跑（预期 1082/1082）。同文件的其他用例仍用固定等待，未动——如后续再抖，按同一模式改。
- **更正（2026-11-16，D-39 详述）：D-38 对“磁盘 TMPDIR 下三次失败”的诊断是错的——真因不是临时文件清理滞后，而是我取的 TMPDIR 目录名 `~/workspace/.tmp-flutter-test` 本身含 `.tmp-`；SR2-3 断言用完整路径 `f.path.contains('.tmp-')` 过滤，目录名一命中，每个文件都误匹配，`isEmpty` 永远 false。探针证实：断言前目录里只有 tall.png、q1.png，根本没有 .tmp 文件。D-38 的两处轮询改动无害、保留（仍是更稳的等待方式），但真正修复是把 TMPDIR 改名。**

## D-39 — 全量测试磁盘 TMPDIR 改名：`.tmp-flutter-test` → `flutter-test-tmp`（2026-11-16，Stage 3 验收；只改环境，不改代码）

- 根因：`test/detail_page_test.dart` 的 SR2-3 在 893 行（确认后轮询）与 909 行（最终断言）都用 `f.path.contains('.tmp-')` 判断临时切片是否清干净——`f.path` 是完整路径。`_testTmp` 由 `Directory.systemTemp.createTemp('qm2-detail-rework')` 创建，落在 TMPDIR 下；我之前为避开 /tmp 的 512MB tmpfs（ENOSPC）而设的磁盘 TMPDIR `~/workspace/.tmp-flutter-test`，目录名本身就含 `.tmp-`，于是 slices 下每个文件的完整路径都命中过滤，`isEmpty` 恒为 false。这解释了全部三次磁盘-TMPDIR 全量跑 SR2-3 都失败、而默认 /tmp 跑（路径 `/tmp/qm2-detail-rework…` 不含 `.tmp-`）时 SR2-3 通过的现象。
- 改动：`mv ~/workspace/.tmp-flutter-test ~/workspace/flutter-test-tmp`；此后全量测试统一用 `TMPDIR=$HOME/workspace/flutter-test-tmp`（磁盘 141G 空闲，`flutter-test-tmp` 不含 `.tmp-` 子串）。测试代码的过滤写法本身没改——它对正常临时目录名是正确的；教训记下：**TMPDIR 目录名不得含 `.tmp-`**，也不要含测试里用全路径过滤的任何子串。
- 验收：全量重跑中（预期 1082/1082），日志 `~/workspace/a3-full.log`。

## D-40 — 架构 A 第 3 阶段：整理页收进 Provider（2026-11-16，ARCH-PLAN-A §四第 3 阶段第 2 条）

- 新增 `lib/state/organize_notifier.dart`（唯一新增的状态文件）：`organizeProvider`（`NotifierProvider.autoDispose<OrganizeNotifier, OrganizeState>`）。每页 1 个 Provider（本阶段只用 1 个，未建第 2 个）；状态唯一真源仍是 SQLite，Provider 只做响应式读取 + 写回，不另存一份、不改 Schema、不增删功能。
- `OrganizeState`（原 `_OrganizePageState` 的业务字段原样搬移）：队列数据（queue/index/sort/loading/hasAnyQuestion/organizedToday/toReviewCount）+ 元数据（folders/exams/kps/allTags/customTypesAll/subjects）+ 表单值（folderIds/examId/kpIds/errorTypes/customTypes/tags）+ `formResetKey`。派生（`current`/`orderIds`/`subjectOf`/`folderDisplayName`/`formQuestion`）是 `OrganizeState` 上的纯函数/getter。`subjectInitial`（学科首字母 S/Y/Z）从整理页移到本文件公开，排序与队列弹窗共用（SR-P2-35 同款去重）。
- 业务逻辑进 Notifier 的部分：`refresh()`（原 `_refresh` + 末尾 `_loadFolders` + `_loadForm`，含 B11-10 今日小结“队列已空且库里有题时才读”）、`loadFolders()`、`loadForm()`（SR-P2-27 合并原样搬移）、`saveCurrent()`（SR2-6 写回队列，失败返回 false 不抛错）、`goTo()`/`jumpTo()`/`applyQueueSort()`（排序不重读文件夹，原代码同款）、`confirmCurrent()`（保存 + 同步错因记录 + `saveRecentTask` kind '整理' + 重读推进）、内联新建 `submitNewFolder`（SR-P2-36 预检 + StateError 兜底，同名返回 null）/`submitNewExam`/`submitNewTag`/`addCustomType`（固定名进固定项返回 true）、队列批量操作 `deleteQuestion`/`batchTagQuestions`（返回已保存 id 集 + 总数，SR3-15 部分保存口径）/`batchAddFolders`（返回已加入/跳过数）/`submitBatchFolder`/`batchConfirmQuestions`（只确认已选文件夹的题，返回拦下数；不同步错因记录、不记最近任务，与单题确认不同，原代码同款）/`batchDeleteQuestions`。改动口全部是具名方法（D-35：不用泛型 `update(copyWith)`）。
- `organizeProvider` 是 autoDispose（D-36 结论）；`build()` 里 `Future.microtask(refresh)` 首查 + `_disposed` 守门（沿用 Stage 2/3 模式）。整理页没有初始入参（构造器只有 repo 与四个回调），所以**没有** `organizeInitialProvider`——需要初始参数时才按 `wrongbookInitialProvider` 模式加（D-35），本次不需要。
- 页面改动（`lib/modules/organize/organize_page.dart`，仍是一个文件，未拆 part）：外壳 `OrganizePage`（StatefulWidget）只包一层 `ProviderScope(overrides: [repositoryProvider.overrideWithValue(widget.repo)])`；内层 `_OrganizeView` 是 `ConsumerStatefulWidget`，`repo` 构造参数保留（本阶段不碰 `lib/app.dart`）。`setState` 52 处 → 34 处，剩下的全是纯界面状态：手风琴开合、知识点章节展开、内联新建展开态、队列弹窗的勾选/搜索/排序/内联菜单/确认框、表单同步的收框。文本控制器留页面本地；切题/刷新时 Notifier 把 `formResetKey` 加一，页面按它变化、下一帧把控制器文本按当前题重建并收起内联新建框（原 `_loadForm` 里设控制器文本 + 收框的部分，见 `_syncFormFromState`；自定义错因输入框原 `_loadForm` 也不清，不清）。
- 队列弹出层（`_QueuePopup`）：它是 OverlayEntry，build 上下文不在页面嵌套 ProviderScope 之内，拿不到 ref——批量操作走构造器接进来的 `OrganizeNotifier` 实例，元数据（folders/exams/subjects/allTags）是打开时的快照（`_loadMeta` 已删，initState 里同步取快照）；勾选/搜索/排序/内联菜单/确认框仍留本层本地；`_questions` 快照同步（SR2-5/SR3-15）仍在弹出层里，Notifier 的批量方法只返回结果（已保存 id、拦下数等），不同步快照。
- 行为口径零变：SR2-6 保存写回队列、SR2-26 保存失败拦下（开队列/切题/跳转/改排序/进详情）、SR-P1-7 开队列前先落盘再拍快照、SR-P2-27 自定义错因合并、SR-P2-28 `newEntityId`、SR-P2-36 整科同名预检、B11-10 今日小结、B8-6 手风琴一次只开一个、批量确认只确认已选文件夹的题且不同步错因记录、批量打标签部分保存失败提示、批量加文件夹跨科跳过。
- 测试：既有测试文件 0 删除、0 弱化，整理页构造参数不变（外壳模式与复习页一致），widget 测试无需改包裹/注入方式。新增 `test/organize_notifier_test.dart` 22 个 Provider 单测（不启动 widget，`ProviderContainer.test` + `repositoryProvider.overrideWithValue`，`container.listen` 保活——D-36 的 autoDispose 单测教训）：refresh/loadForm 6 个，表单值改动 2 个，保存/切题/确认 6 个，内联新建 3 个，队列批量操作 5 个。
- 验收：`flutter analyze` 0 问题；整理页既有测试 71/71（`organize_page_test`、`b2_win11bug_organize`、`b8_6_accordion`、`b11_10_today_summary`、`b11_11_empty_states`、`b11_4_prev_question`）+ 相关文件 105/105（`b5_p2_collect`、`b8_1_subject_sweep`、`app_shell`、`review_page`、`b9_3`、`b9_1`、`b8_1_subject_refresh_flow`）+ 新增单测 22/22；全量串行 1104/1104（基线 1082 + 新增 22），日志 `~/workspace/a3-organize-full.log`；Linux Release 构建通过；演示库 md5 不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.a3-organize-gate`）。全量 TMPDIR 用 `~/workspace/flutter-test-tmp`（磁盘，D-39）。
- 详情页（下一页）要注意的事：① 整理页的教训直接复用：`loadForm` 类“重建表单”的操作要拆成“Notifier 改业务值 +  bump 一个派生 key，页面按 key 变化、下一帧同步本地控制器”（不要把控制器塞进 Notifier，也不要在页面 `initState` 里调 Notifier 方法）；② 弹出层/Overlay 类子 widget 拿不到页面嵌套 scope 的 ref，业务操作经构造器接 Notifier 实例 + 打开时快照，纯界面状态留本地；③ `applyQueueSort` 式“不重读某份元数据”的旧代码 quirks 要逐处核对、原样保留，不要顺手“修掉”；④ autoDispose 单测必须 `container.listen` 保活，不要裸 `read` 轮询等首查。

## D-41 — 架构 A 第 3 阶段：详情页收进 Provider（2026-11-16，ARCH-PLAN-A §四第 3 阶段第 3 条）

- 新增 `lib/state/detail_notifier.dart`（唯一新增的状态文件）：`detailProvider`（`NotifierProvider.autoDispose<DetailNotifier, DetailState>`）+ `detailInitialProvider`（`DetailInitial`：`questionId` / `orderIds`，带逐项 `==`，外壳每次 build 传等值实例时不触发 override 失效）。每页 1 个 Provider（本阶段只用 1 个，未建第 2 个）；状态唯一真源仍是 SQLite，Provider 只做响应式读取 + 写回，不另存一份、不改 Schema、不增删功能。
- `DetailState`（原 `_QuestionDetailPageState` 的业务字段原样搬移）：当前题（question/currentId/orderIds/loading）+ 错因记录与解决记录（records/history）+ 元数据（exams/folders/allTags/kps/subjects）+ 编辑表单值（editErrorTypes/editCustomTypes/editFolders/editTags/editKps/editExamId/editBase）+ `formResetKey`。派生（`subjectOf`）是 `DetailState` 上的纯函数。
- 业务逻辑进 Notifier 的部分：`load()`（原 `_load`，含 SR3-10 自愈触发）、`_healSliceIfNeeded`（SR3-10 切片自愈原样搬移：尺寸校验 → 按当前第一个 1 层框重裁 → 原子替换 → 尺寸变了改库 → 重读；失败静默）、`enterEdit()`（原 `_enterEdit` 里表单值的部分，SR-P2-27 合并原样）、`saveEdit()`（原 `_saveEdit` 全新构造题的写法原样，P2 §1.2 图片字段从 base 带上）、`goTo()`/`deleteCurrent()`（原 `_goTo`/`_doDelete` 里改下标删库定下一题的部分）、`toggleFavorite()`/`toggleArchive()`/`toggleReviewJoined()`（返回 bool，false 时页面弹“先补错误类型”）、`boxesForPageImage()`/`applyReworkBoxes()`（原 `_reworkBoxes` 里编辑器返回之后的部分，返回 `ReworkOutcome` 六态，页面按值弹对应提示；SR2-3 临时文件 + 单事务 + rename 语义一字未动）、内联新建 `submitNewTag`/`submitNewFolder`（SR-P2-36 预检 + StateError 兜底，返回 null 时页面弹“已经有了”）/`submitNewKnowledgePoint`/`submitNewExam`/`addCustomType`（与整理页同款，固定同名返回 true）。改动口全部是具名方法（D-35：不用泛型 `update(copyWith)`）。
- `detailProvider` 是 autoDispose（D-36 结论）；`build()` 里 `Future.microtask(load)` 首查 + `_disposed` 守门（沿用 Stage 2/3 模式）。初始入参复用 D-35 的 `wrongbookInitialProvider` 模式：外壳经 `ProviderScope` 注入 `DetailInitial`，Notifier `build()` 里读它定初始题与来源列表，不在页面 `initState` 里同步改 Provider。
- 页面改动（`lib/modules/detail/question_detail_page.dart`，仍是一个文件，未拆 part）：外壳 `QuestionDetailPage`（StatefulWidget）只包一层 `ProviderScope(overrides: [repositoryProvider.overrideWithValue(widget.repo), detailInitialProvider.overrideWithValue(...)])` 并持有导出服务；内层 `_DetailView` 是 `ConsumerStatefulWidget`，`repo` 构造参数保留（本阶段不碰 `lib/app.dart`）。`setState` 32 处 → 17 处，剩下的全是纯界面状态：折叠区开合、答案可见、编辑/脏态、取消确认框、弹窗与 SnackBar。文本控制器留页面本地；进编辑时 Notifier 把 `formResetKey` 加一，页面按它变化、下一帧把控制器文本按当前题重建（D-40①，见 `_syncFormFromState`，与整理页同款）。
- D-40 逐条落实：① `enterEdit` 拆成“Notifier 改业务值 + bump `formResetKey`，页面按 key 变化、下一帧同步本地控制器”，控制器不进 Notifier，页面 `initState` 里不调 Notifier 方法；② 本页无 Overlay 弹出层子 widget——重框编辑器弹窗与分享卡片预览弹窗都在页面内开（有 context），确认后的业务经 Notifier 方法交回去，纯界面状态留本地；③ “不重读某份元数据”类 quirks 已逐处核对原样保留：`load()` 读 `folders()` 不带学科过滤（整理页是按学科读，详情页是全部，不要顺手“修掉”）、`_newTag` 重读后才把新建标签选进编辑表单（原 `_load` 前后两次加同一个名的合并）、自愈只在重裁尺寸与库里不同时才 `save` 改库、`saveEdit` 全新构造题时图片字段必须从 base 带上（P2 §1.2）；④ autoDispose 单测 `container.listen` 保活（D-36 教训），不裸 `read` 轮询等首查。
- 行为口径零变：SR2-3 事务失败旧切片字节完好、框与题不动（断言与等待一字未改）、SR3-10 打开页自愈、SR3-11 页图损坏给提示不抛异常、SR-P1-8 源页 ≥2 重框框不丢失、SR-P2-27 自定义错因合并、SR-P2-36 整科同名预检、编辑保存/取消内联确认三按钮、删除模态确认后进下一题、上一题/下一题按来源列表顺序、加入/取消加入复习口径（未整理题无按钮、无错因题提示先补错误类型）、B11-8 导出三动作、B11-11 复习记录空状态“去复习”按钮。
- 自测中修掉的两个迁移引入问题：① 全局替换 `_history` 时误伤 `_historyLabel`（方法名含 `_history` 前缀），改回；② 自愈尾部重读与单测 tearDown 拆容器竞态时 ref 已销毁的报错被记成“自愈失败”日志——catch 里加 `_disposed` 守门，页面已离开时静默放弃（生产侧同理：退出详情页时后台自愈的重读不再打扰日志）。
- 测试：既有测试文件 0 删除、0 弱化，详情页构造参数不变（外壳模式与复习/整理页一致），widget 测试无需改包裹/注入方式。新增 `test/detail_notifier_test.dart` 23 个 Provider 单测（不启动 widget，`ProviderContainer.test` + `repositoryProvider.overrideWithValue`，`container.listen` 保活）：load 3 个，编辑表单 5 个，收藏/归档/加入复习/切题/删除 7 个，内联新建 4 个，重新框选 3 个（成功、SR2-3 事务失败、SR3-11 页图损坏），SR3-10 自愈 1 个。重框/自愈用例用真实 PNG + 磁盘临时目录（与 `detail_page_test.dart` 同款夹具），纯 `test()` 里须先 `TestWidgetsFlutterBinding.ensureInitialized()`（`evictCachedFileImage` 要 PaintingBinding）。
- 验收：`flutter analyze` 0 问题；详情页既有测试 37/37（`detail_page_test.dart`）+ 相关文件 136/136（`detail_notifier`、`b11_8_export_image`、`b8_1_subject_sweep`、`b5_p2_collect`、`b11_11_empty_states`、`app_shell`）+ 新增单测 23/23；全量串行 1127/1127（基线 1104 + 新增 23），日志 `~/workspace/a3-detail-full.log`；Linux Release 构建通过；演示库 md5 不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.a3-detail-gate`）。全量 TMPDIR 用 `~/workspace/flutter-test-tmp`（磁盘，D-39）。代码未推，等 Meng 批准（由协调员统一报）。
- 收集页 + `box_editor`（下一页）要注意的事：① 收集页修框状态（框选、缩放、旋转）是纯 UI 临时状态，留在页面本地 `setState`，不进 Provider——只有“已确认的框/任务进度”这类要跨页用的才进 Provider；本页用 `ConsumerStatefulWidget`（方案 §四第 3 阶段第 4 条）。② 本页的教训直接复用：全局字符串替换要防方法名前缀误伤（如 `_history` → `_historyLabel`），替换后全仓 grep 旧字段名逐项核对；后台自愈/重读类 fire-and-forget 异步的 catch 里要加 `_disposed` 守门，页面已离开时的 ref 销毁报错不要记成业务失败日志。③ 详情页 `DetailState.subjectOf` 与整理页 `subjectInitial` 一样是放进状态文件的纯函数——收集页如有同类纯函数，同样随 Notifier 走，不要留在页面里各写一份。

## D-42 — 架构 A 第 3 阶段：收集页收进 Provider（2026-11-16，ARCH-PLAN-A §四第 3 阶段第 4 条；Stage 3 最后一页）

- 新增 `lib/state/collect_notifier.dart`（唯一新增的状态文件）：`collectProvider`（`NotifierProvider.autoDispose<CollectNotifier, CollectState>`）。每页 1 个 Provider（本阶段只用 1 个，未建第 2 个）；状态唯一真源仍是 SQLite，Provider 只做响应式读取 + 写回，不另存一份、不改 Schema、不增删功能。`box_editor.dart` 未动（修框状态框选/缩放/旋转是纯 UI 临时状态，留编辑器本地 21 处 setState）。
- `CollectState`（原 `_CollectPageState` 的业务字段原样搬移）：任务列表与派生信号（tasks/subjects/unboxedPagesByTask/hasAnyDraftBox/hasSplitSibling）+ 导入状态（selectedSubjectId/pendingImport/batch/stagedPaths/subjectGuessHint）。派生（`subjectOf`/`count`/`shownTasks`）是 `CollectState` 上的纯函数/getter；纯函数 `splitPagesFor`/`pageListText`/`noBoxWarningText`/`taskNote` 随 Notifier 走（D-41③）。`PendingImport` 由原私有 `_PendingImport` 改公开（状态字段类型不能是私有类）。
- 业务逻辑进 Notifier 的部分：`load()`（原 `_load`，含 P1-2 已拆页不算未框、SR-P2-25 两信号、只认 1 层框、B8-2 layer-2 丢弃）、`selectSubject()`（改选 + 清猜测提示）、`pickFiles()`（返回 null = 选择器打不开，页面弹提示）、`handleIncomingPaths()`（原统一入口：目录/类型跳过、SHA-256 同批去重只留第一份、文件名/内容重复进待确认、超限进待确认、按文件名猜学科、仍没学科暂存）、`startStagedImport()`（返回 `needsSubject`，页面出“先选学科”横幅）、`confirmPendingImport`/`discardPendingImport`/`discardStagedImport`/`dismissBatch`、`retryBatchFailures`/`retryBatchPath`、`importFiles()`（原 `_importFiles` 全套：批量队列建/复用、逐个处理、加密/空文件/不存在进失败任务、`enqueue` 进度回调、失败任务落库、选完一批清空已选学科、末尾重读）、`prepareBoxEditor()`（原 `_openBoxEditor` 开弹窗前的部分：页图校验、置 boxing 落盘、读草稿、没草稿才跑 YOLO 检测并按旋转角变换坐标）、`saveDraftBoxes()`、`confirmSplit()`（原 `_confirmSplit` 全套：SR2-62 戳、已拆页跳过、切片先写盘、旋转烘焙、保留任务同事务、SR-P2-22 失败清文件、SR2-25 收尾）、`deleteTask()`。改动口全部是具名方法（D-35：不用泛型 `update(copyWith)`）。
- `collectProvider` 是 autoDispose（D-36 结论）；`build()` 里 `Future.microtask(load)` 首查 + `_disposed` 守门（沿用 Stage 2/3 模式）。收集页没有初始入参（构造器只有 repo 与回调），所以**没有** `collectInitialProvider`（D-40 同款：需要初始参数时才按 `wrongbookInitialProvider` 模式加，本次不需要）。注入的检测 / PDF 渲染服务仍由页面构造器持有，需要时作为方法参数传进 Notifier（`prepareBoxEditor(yoloService:)` / 各导入方法 `pdfRenderService:`）。
- 页面改动（`lib/modules/collect/collect_page.dart`，仍是一个文件，未拆 part）：外壳 `CollectPage`（StatefulWidget）只包一层 `ProviderScope(overrides: [repositoryProvider.overrideWithValue(widget.repo)])`；内层 `_CollectView` 是 `ConsumerStatefulWidget`，`repo` 构造参数保留（本阶段不碰 `lib/app.dart`）。`setState` 33 处 → 17 处，剩下的全是纯界面状态：`_picking` / `_noSubjectWarning` / `_hideErrorBanner` / `_filter` / `_dragOver`。修框编辑器弹窗与“还有 N 页没有框”确认框、删除确认框仍在页面内开（要 `BuildContext`），确认后的业务经 Notifier 方法交回去；`confirmSplit` 的未框页确认拆成两步：Notifier 先返回 `ConfirmSplitOutcome.needsUnboxedConfirm`（不写任何东西），页面弹框、用户确认后再调一次 `confirmSplit(confirmedUnboxed: true)`。
- 两条导入前提示的时机（“只收 PDF / JPG / PNG”与“同批内容重复只导一份”）必须在漫长导入开始前就出现，不能等导入跑完才随返回值带回页面——`handleIncomingPaths` / `startStagedImport` 接一个纯函数回调 `onNotice`，由页面在调用时传 `_snack`；Notifier 本身不碰 `BuildContext`、不弹 Dialog、不调导航。其余提示（页图缺失、拆题结果）都是方法返回后才出的，走返回值（`BoxEditorPrep` 的 error、`ConfirmSplitOutcome`）。`BatchImportState` 本身可变（行状态原地改），每次改完 Notifier 都重新赋值一份 `CollectState` 触发重建（见 `_emitBatch`）；`batch_import.dart` 头注释的“导入循环在 CollectPage._importFiles”已改指 `CollectNotifier.importFiles`。
- D-41 逐条落实：① 修框状态留页面本地 setState，只有已确认的框/任务进度/导入去重结果进 Provider；② 本次无全局字符串替换（字段逐个手写搬移，无 `_history` 式误伤；搬完后 grep 核对旧字段名零残留——`_tasks`/`_subjects`/`_pendingImport`/`_batch`/`_stagedPaths`/`_selectedSubjectId`/`_unboxedPagesByTask`/`_hasAnyDraftBox`/`_hasSplitSibling`/`_subjectGuessHint` 在页面里已无残留）；③ 纯函数随 Notifier 走（见上）；④ autoDispose 单测 `container.listen` 保活（D-36 教训），不裸 `read` 轮询等首查。
- 自测中修掉的迁移引入问题（首轮全量 1147/1150，3 个失败稳定复现、与本次改动直接相关）：`build()` 的 `Future.microtask(load)` 可能在页面已离开、Provider 已销毁后才跑，`load()` 开头的 `ref.read(repositoryProvider)`（`_repo`）直接抛 `UnmountedRefException`（b8_1_subject_refresh_flow 切页快时必现；b9_3 两个角标用例切导航时同因失败）。修法：`load()` 顶部先判 `_disposed` 再碰 ref；长流程方法（`importFiles` / `confirmSplit` / `prepareBoxEditor`）在入口处一次性捕获 repo，之后不再 `ref.read`，中途销毁也不抛错；`_failTask` 改接捕获的 repo 入参（失败任务照写，原代码只守门 setState、不守门写库）；其余 `_repo` 引用只剩方法入口的同步读取（`pickFiles` / `handleIncomingPaths` / `saveDraftBoxes` / `deleteTask`，调用时页面必定在挂载）。修后两文件单跑 31/31，`flutter analyze` 0 问题。
- 行为口径零变：拖放/批量导入/重试失败项、SHA-256 去重、PDF 50MB/20 页与图片 20MB 超限、按文件名猜学科、暂存“开始导入”、待确认横幅两动作、导入进度、失败任务、修框草稿优先/检测失败只提示、确认拆题的未框页保留与 SR-P2-22 清理、SR2-62 两次确认 id 不同、删除确认文案、筛选 chips 与任务统计行。
- 测试：既有测试文件 0 删除、0 弱化，收集页构造参数不变（外壳模式与复习/整理/详情页一致），widget 测试无需改包裹/注入方式。新增 `test/collect_notifier_test.dart` 23 个 Provider 单测（不启动 widget，`ProviderContainer.test` + `repositoryProvider.overrideWithValue`，`container.listen` 保活）：load 3 个，selectSubject 1 个，handleIncomingPaths 6 个（不支持文件、暂存、猜学科进待确认、文件名重复、超限图片、同批内容重复），startStagedImport/discard 3 个，importFiles/confirmPendingImport 2 个（不存在的文件记失败任务），prepareBoxEditor 1 个（页图缺失），confirmSplit 早期分支 3 个（无框、已拆过、未框页确认），deleteTask/saveDraftBoxes 2 个，纯函数 2 个。导入成功路径（真实 enqueue / 修框确认拆题）由既有 widget 测试覆盖，不在单测里重跑。
- 验收：`flutter analyze` 0 问题；收集页既有测试 202/202（`collect_page_test`、`pdf_collect_page_test`、`b5_p2_collect`、`b11_dragdrop`、`b11_batch_import`、`b9_1_collect_done`、`b8_345_box_interaction`、`b11_11_empty_states`、`b8_1_subject_refresh`、`b8_1_subject_sweep`、`app_shell`、`detail_page_test`、`b11_8_export_image`）+ 新增单测 23/23；全量串行 1150/1150（基线 1127 + 新增 23），日志 `~/workspace/a3-collect-full.log`；Linux Release 构建通过；演示库 md5 不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.a3-collect-gate`）。全量 TMPDIR 用 `~/workspace/flutter-test-tmp`（磁盘，D-39）。代码未推，等 Meng 批准（由协调员统一报）。
- Stage 3 收尾（下一阶段，第 4 阶段角标收尾时复用）：① 本次修掉的 `UnmountedRefException` 是 Stage 2/3 各页共有的隐患——`build()` 里 `Future.microtask(load)` + 方法内多次 `ref.read(repositoryProvider)` 的组合，切页快时都可能撞上；第 4 阶段动各页时顺手核对：`load()` 顶部 `_disposed` 守门、长流程方法入口捕获 repo。② `collectProvider` 与其他页面 Provider 一样是 autoDispose、页面独占；跨页实时刷新是第 4 阶段 DataChangeBus 的事，本次不提前做。③ Stage 3 四页全部完成：复习（D-37）→ 整理（D-40）→ 详情（D-41）→ 收集（本条）。

## D-43 — 架构 A 第 4 阶段：角标接管到 DataChangeBus + badgeCountsProvider（2026-11-16，ARCH-PLAN-A §四第 4 阶段；Stage 4，A 的最后一块业务阶段）

- 新增 `lib/data/data_change_events.dart`（纯 Dart，不 import riverpod）：`DataChangeKind`（`badges` / `reviewRecords` / `subjects` / `questions` / `settings`）、`DataChangeEvent { Set<DataChangeKind> kinds; String? questionId; }`、`DataChangeBus` 单例（广播流 + `emit` + 可重入 `scope()`）。`scope` 把作用域内多次 emit 缓冲，退出时合并成一个事件（kind 取并集；只有恰好缓冲了一个事件时保留其 `questionId`）；一个事件都没发则不发；体内抛错后缓冲的事件仍发出，异常继续外传。
- 事件发出点定在 `AppDatabase` 实例方法（与旧 `bumpBadgeVersion()` 调用点 1:1 替换），不是只放 Repository——`ImportService` 直接在 `AppDatabase` 上写 `upsertCollectTask`，绕过了 Repository，只放 Repository 会让导入时收集角标丢刷新。数据层 import 白名单不变（riverpod 只进 `lib/state/`、`lib/modules/`、`lib/app.dart`、`lib/main.dart`）；`lib/data/` import 纯 Dart 的 `data_change_events.dart` 不违规。
- 各写方法的 kind 集（完整表见 `docs/ui-replication/A-READING-GUIDE.md` §六）：`save`/`archive`/`toggleFavorite` → `{badges, questions}`；`delete` → `{badges, questions, reviewRecords}`；`saveRemedy`/`setReviewJoined`/`recordSelfCheck` → `{badges, reviewRecords}`（`setReviewJoined` 仅 `ok` 时、`recordSelfCheck` 仅结果不是 `unsure` 时）；`joinReviewBatch`/`cancelReviewBatch` → 一次合并 `{badges, reviewRecords}`（`scope` 包循环，仍调虚方法 `setReviewJoined`，`b11_6` 的 FakeRepo 覆写不受影响；全跳过不发）；`confirmSplit` → `{badges, questions}`；`replaceQuestionBoxes*` → `{questions}`；`saveCollectTask` → `{badges}`（仅新建/状态变化，节流保留）；`deleteCollectTask`/`deleteSubject`/`deleteFolder` → 含 `{badges, subjects, questions, reviewRecords}` 的超集（可能连带删题/删科）；`upsertFolder`/`insertTag`/`insertExam`/`insertKnowledgePoint`/`renameExam`/`renameKnowledgePoint`/`renameChapter` → `{subjects}`；`renameTag`/`deleteTag`/`deleteExam`/`deleteKnowledgePoint`/`deleteChapter` → `{subjects, questions}`（同时改写题目行）；`saveSettings`/`saveExamEvents`/`saveBackupFailed` → `{settings}`；`importBackupJson`/`importBackupZip`（`importBackupZipFile` 转调，不另发）→ 一次含全部五种 kind。不发事件的方法：`syncCauseRecords`/`deleteCauseRecordsForQuestion`/`deleteCauseRecord`（调用方的 `save` 覆盖角标）、`saveDraftBoxes`、`saveReviewState`/`clearReviewState`、`saveLastRoute`/`saveLastRecheckReminderDate`/`saveRecentTask`/`saveSetting`、`migrateToDirectory`/`setCustomDataDirectory`/`cleanOrphans`。
- 新增 `lib/state/badge_counts_provider.dart`：`BadgeCounts` 值类（collectBadge / organizeBadge / reviewBadge / navRev / navPending / subjects；`==`/`hashCode` 经 `mapEquals`/`listEquals`；`BadgeCounts.zero`；`countPendingBox` 从 `CollectPage` 搬来，状态层不 import `lib/modules/`）+ `BadgeCountsNotifier extends AsyncNotifier<BadgeCounts>`。`build()` 先订阅总线再首读（subscribe-before-first-query，`ref.onDispose` 取消订阅），只在事件含 `badges` 时 `ref.invalidateSelf()` 重读；`_readCounts()` 一次 `Future.wait` 跑原来 `_refreshBadges` 的 5 条查询，口径一字未动（复习角标 = `homeRevCounts` 各科之和、数题不数错因；subjects = 库里原始列表，无 `Subject.all` 回退）。Provider 是 `AsyncNotifierProvider`、**绝不 autoDispose**（根节点常驻，D-36 结论②）。
- `lib/app.dart` 改用 `badgeCountsProvider`：删角标字段、6 处 `_refreshBadges()` 调用、`initState` 监听与整个 `_refreshBadges` 方法；`build` 里 `ref.watch(badgeCountsProvider).value ?? BadgeCounts.zero`（stale-while-reloading）。`lib/data/badge_notifier.dart` 已删除；`lib/modules/settings/settings_page.dart` 的恢复后 `bumpBadgeVersion()` 已删（恢复经 `importBackup*` 发事件）；详情页 `onChanged` 回调已删（唯一用途就是角标刷新）——`QuestionDetailPage`/`_DetailView` + 6 处调用点 + 4 个测试文件的 `onChanged: () {},` 一并去掉。
- D-42 共有隐患按同一模式修完 8 个已迁移页面的 Notifier（`home`/`report`/`subjects`/`review`/`organize`/`wrongbook`/`detail`/`collect`，收集页 D-42 已修，本次复核无改动）：`load()` 顶部先判 `_disposed` 再碰 `ref`；方法入口一次性捕获 `repo`，之后不再 `ref.read`；批量方法（`subjects.addSubject`、整理页 4 个批量方法、错题本 `batchAddTag`/`batchMoveToFolder`/`batchMoveOut`/`batchFavorite`/`batchArchive`/`batchDeleteConfirmed`、错题本 `reorderFolder`）另用 `scope` 包起来只发一个事件。单触点方法（入口同步读库、其后无 await）未动；`settings_notifier` 不属 8 页，不动。
- 行为口径零变，角标数字与原来一致；但有一处刷新时机变化（B9-3 已接受的残留滞后换了形态，见下）。
- **导航刷新删除的后果（须向 Meng 说明）：时间驱动的复查到期（无写入）在旧链路下靠切导航时 `_refreshBadges()` 重读刷新；新链路只订阅数据事件，复查到期后角标在下一次数据事件或应用重启时才刷新，不再随导航刷新。** 这是删除手动刷新链路的直接结果，不是 bug；如需恢复时间驱动刷新，要另加定时/前台恢复时的重读（不在本次任务内）。
- 详情页复习记录订阅 `reviewRecords` 事件是方案的终态，但本次未接线（任务只含 6 项，顺手改别的在计划外）；各页仍自己 `load()`。
- 测试：新增 `test/stage4_badge_test.dart` 24 个——A 组 8 个总线/仓储事件单测（写成功发一个完整 kind 集事件且 `questionId` 只在单题时有；`unsure` 自查与同名文件夹保存失败不发事件；批量两题只发一个合并事件；全跳过不发事件；备份恢复只发一个全 kind 事件；`saveSettings` 发 `{settings}` 而 `saveLastRoute` 不发；`scope` 嵌套合并与抛错后仍 flush），B 组 6 个 Provider 单测（首查读到当前计数；含 `badges` 才重读；无交集 kind 不重读且状态对象不变；初始化期间写入最终计入；dispose 后不再触达；`OrganizeNotifier.batchConfirmQuestions` 三题只发一个事件），C 组 10 个整应用 widget 场景（A v4 清单：删学科、整理完一道、批量整理三道、加入复习、取消加入复习、自查治愈、归档、恢复归档、删除题目、备份恢复——写库后角标在原页面即时刷新，全程不切导航）。自测中修掉两个测试写法问题（非产品问题）：① testWidgets 体跑在 fake async 里，真实 ffi Future 必须经 `tester.runAsync` 等，直接 await 会挂住（S4-1 曾超时 14 分钟）——新增 `_seedWidgetRepo` 帮手，全部种子写入走 `runAsync`；② 广播流投递比 await 慢一拍，`events.clear()` 必须先等在途事件落定再清，否则上一笔写事件迟到污染计数（join/cancel/import 三个 A 组用例曾因此多计一个事件）；③ S4-8 种子里用 `setReviewJoined` 之前的旧对象调 `archive`，全行 upsert 把 `reviewJoined` 写回 false——归档须用库里刚读回的题。
- 验收：`flutter analyze` 0 问题；受影响测试 668/668（新文件 24 + 复习/整理/详情/收集/学科/错题本/首页/报告/设置/外壳等 37 个文件）；全量串行 1174/1174（基线 1150 + 新增 24），日志 `/tmp/stage4_full_suite.log`；演示库 md5 不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.a4-gate`）。全量 TMPDIR 用 `~/workspace/flutter-test-tmp`（磁盘，D-39）。代码未推，等 Meng 批准（由协调员统一报）。
- **未完成项——Linux Release 构建在本机跑不起来（环境问题，非代码问题）：`flutter build linux --release` 在 CMake 生成步失败，缺 `/usr/include/gtk-3.0`（`libgtk-3-dev` 未装）。`apt-get install libgtk-3-dev` 装不上：镜像自带的 `libzstd1` 是 `1.5.5+dfsg2-2build1.1+hatch1`，而 Ubuntu 的 `libzstd-dev` 严格依赖 `libzstd1 (= 1.5.5+dfsg2-2build1.1)`，版本钉死冲突。把 `libzstd1` 降级到 Ubuntu 版才能装，是动系统核心库的决定，不宜单方面做——由协调员定（或在 Meng 的 Win11 真机上验证构建）。本次失败与 Stage 4 代码无关，CMake 在配 runner/插件时就找不到 GTK 头文件，改动前也一样失败。
- **决定（Meng，2026-11-16 16:16，选项 A：接受现状）**：纯时间驱动的复查到期（无写入）不再随切导航刷新角标，只在下一次数据事件或应用重启时才刷新。数据变动仍是实时的（写库成功后角标马上重算，不用切页面）。不实现前台恢复重读，不加定时轮询，不再为此改代码。A 收尾只把本决定记入日志与阅读指引（`A-READING-GUIDE.md` §六、§七）。

## D-44 — 架构 A 收尾：回归 / 文档（2026-11-16，ARCH-PLAN-A §四每阶段验收 + 回归与文档 0.5–1 天；A 的最后一环）

- 回归：`flutter analyze` 0 问题；串行全量测试 **1174/1174**（EXIT=0，约 7 分 50 秒，日志 `~/workspace/a-wrapup-full.log`，末行 `+1174: All tests passed!`）；Linux Release 构建通过（`✓ Built build/linux/x64/release/bundle/quiz_master2`，日志 `~/workspace/a-wrapup-build.log`）。D-43 正文里的“Linux Release 构建跑不起来”已过期：Stage 4 收尾时协调员已把 `libzstd1` 降为 Ubuntu 版（现 `1.5.5+dfsg2-2build1.1`）并装好 `libgtk-3-dev`（`3.24.41-4ubuntu1.3`），本次收尾构建直接通过，未再动系统包。
- 演示库：跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.a-wrapup-gate`；跑后 md5 未变（`eae75818e13b18ea9508068d74986cb3`，与备份一致）。注意：live 库当前 md5 与 v1 标准库（`8f7f9c64405dc6e484ac2bf8e5e1a807`）不一致——live 库是 v2 schema 的空库（0 道题，126976 字节，`user_version=2`），收尾开始前已是如此（16:13 截图核查时即为该 md5；文件 mtime 2026-11-16 08:12 UTC）；v1 标准库仍完好保存在 `quiz-master2.db.a4-gate`（md5 `8f7f9c64…`）。收尾未动 live 库，只做了备份与核对；live 库何时被换成空 v2 库、是否需要恢复 v1，留给 Meng 定，不属于 A 收尾范围。
- 文档：`A-READING-GUIDE.md` 更新到完成态（§一 11 个文件全表；§二、§三 Stage 1 旧描述修正；§四补 D-36 / D-42 单测铁律；§六补 no-emit 的两项测试播种方法 + `bumpOrganizedToday` 说明 + 收尾核对 + D-43 决定；新增 §七收尾状态）；`docs/代码地图.md` 更新（`app.dart` 根组件、新增 `data_change_events.dart` + `lib/state/` 行、`badge_notifier` 标已删除、接线步骤的 `bumpBadgeVersion` 改 DataChangeBus、A 完成提示块；各页旧“`_load` 在 State 里”的描述未逐页重写，以 Notifier 文件与阅读指引为准）。
- §六映射表收尾核对：全仓 30 处 `emit` 逐处核对，与表 1:1 对应，无遗漏、无多余；`flutter_riverpod` 的 import 白名单干净（只 `lib/state/`、`lib/modules/`、`lib/app.dart`、`lib/main.dart`；`lib/data/` 只有 `data_change_events.dart` 注释里提到该词，不是 import）；旧 `_refreshBadges` / `badgeVersion` / `bumpBadgeVersion` 只剩注释提及，无代码残留。另：`badgeCountsProvider` 未另写代次号（方案 §四第 3 条的设计建议），靠 `ref.invalidateSelf()` + Riverpod 自身失效语义处理并发重查，B 组单测“初始化期间写入最终计入”覆盖该场景。
- D-43 决定已记（Meng 2026-11-16 16:16，选项 A 接受现状），见 D-43 末尾；`A-READING-GUIDE.md` §六、§七同步。
- reviewRecords 尾巴结论：**立为单独事项，不在 A 内做**。方案：`DetailNotifier` 在 `build()` 里先订阅后首查，收到含 `reviewRecords` 且 `questionId` 等于当前题的事件时只重读 `records` / `history`（不调全量 `load()`，避免冲掉编辑中的表单值与触发切片自愈）；`ref.onDispose` 取消订阅；补单测（同题事件刷新、异题事件忽略、dispose 后不接收、编辑中事件不冲表单）。不做的理由：当前单页导航下，详情页打开时没有外部写入方会改这道题的复习记录（唯一写入方就是详情页自己，写完已调 `load()`），订阅的实际收益约等于零，却要冒编辑态竞态风险；是否值得为“终态完整”做，由 Meng 定。
- 代码未推，等 Meng 批准（由协调员统一报总账）。B 的任何阶段均未开始；B Stage 2 仍等 Win11 真机验证。

## D-45 — 架构 B 第 1 阶段：驱动切换 sqflite → Drift（2026-11-16，ARCH-PLAN-B §四第 1 阶段）

- 范围：161 处 sqflite 调用点 → Drift `customSelect` / `customInsert` / `customUpdate` / `customStatement`；新增 `lib/data/drift/quiz_database.dart`（`QuizDatabase`，`@DriftDatabase(tables: [])`，回调注入）；测试 helper 收口（`openForTest` / `useDatabaseForTest`）；`drift 2.35.4` / `drift_dev 2.35.3` / `build_runner 2.17.1` / `sqlite3 3.5.2`。不改 SQLite schema、不升级其他依赖、不增删功能；行为口径零变。
- 两处直译偏差（方案稿字面写法在 Drift API 里不存在，按等价语义改写）：① `MigrationStrategy` 没有独立的 `onDowngrade` 槽位——改为 `onUpgrade` 内按 `from` / `to` 分流，升级与降级分支都抛 `StateError`（旧库不迁移、不降级，见 `QuizDatabase` 回调）；② `sqlite3` 没有 `openReadOnly`——只读探针改为 `sqlite3.open(path, mode: OpenMode.readOnly)` + `PRAGMA user_version`。
- 懒打开修补（Drift 与 sqflite 的关键行为差）：Drift 是懒打开——不跑查询就不建文件、不跑 `onCreate`；sqflite 是打开即建。`test/b1_stage1_schema_test.dart` 首跑即因此失败（只读探针 `SQLITE_CANTOPEN`，库文件根本不存在）。修法：`openAtImpl` 在构造 `QuizDatabase.file(...)` 后强制跑一次 `SELECT 1`（3 行 + 注释）；`openForTest` 同样强制 `SELECT 1`（其约定是“不存在则新建”，b5_p2_data SR-P2-11 同根因失败）。理由：Stage 1 要求行为零变，打开失败必须在打开时就暴露（供 B3-P01 的 `_openDb` 回退），不能拖到首次查询。
- 测试写法规则翻转（本次收尾最花时间的部分，sqflite 时代的惯例在 Drift 下反过来了）：旧规则“testWidgets 体跑在 fake async 里，真实 ffi 的 Future 须用 `tester.runAsync` 等”已作废。探针 1–13 定性（临时探针文件已删，日志在 `~/workspace/b1-work/b1-probe*.log`，结论记在 `~/workspace/b1-work/progress.md`）：① setUp 跑在 FakeAsync 区之外，setUp 里打开/播种的库在测试体里 await 仓库方法会挂住（探针 11 复跑 2/2 挂、探针 13 二分确认触发条件就是 setUp 播种）；② 一个 `runAsync` 里多段仓库调用，第二段 `await AppDatabase.instance.db` 挂住（探针 8/10：裸查询本身、重复 await 同一个 Future 本身都没问题，查询之后再 await 单例 getter 才挂）；③ 测试体内联播种 + 直接 await 全通（探针 12：subjects/all/causeRecords/dueToday/runAsync 单次查询均通）。生产代码不受影响（不用 runAsync；普通 `test` 跑在真实异步区，多段查询全过）。
- 按新规则修的 4 个文件（播种从 setUp 移到测试体内、仓库调用 `runAsync` 改直接 await、文件头旧规则改写）：`b9_3_review_badge_test`（B 组 3 个用例曾 10 分钟超时，修后 +7 全过，3 秒）、`b8_1_subject_refresh_flow_test`（曾 8 分钟 + “删除确认弹窗未出现：英语”，修后 +1 全过，4 秒）、`b9_1_collect_done_test` 真实交互组（数据层/回填两组是普通 `test`，未动；修后全文件 +7 全过，8 秒）、`stage4_badge_test` C 组（`_seedWidgetRepo` 去 `runAsync`、`_cureCause` 去 tester 参；A/B 两组是普通 `test`，未动；修后 +24 全过，7 秒）。另 `b5_p2_data_test` 靠 `openForTest` 修法通过（+61）。修的过程中还清掉 5 个多余 `!`（`runAsync` 返回可空、直接 await 返回非空所致）。
- 单跑验证通过、无需改动的：`b11_dragdrop_test`（+7；其 `runAsync` 内含 tester.tap/pump 轮询 + 单次查询，不触发挂起）、`b11_8_export_image_test` + `b5_p2_collect_test`（+44；`runAsync` 只包图片/文件 IO）、`detail_page_test`（+37；同上）、`organize_page_test`（+45；0 个 `runAsync`）。
- 新规则（写进本条，供 B 后续阶段与以后写测试用）：widget 测试里播种必须在测试体内做，仓库方法直接 await；`runAsync` 只用于 `Future.delayed`、真实文件/图片 IO、单次查询；一个 `runAsync` 里不要放多段仓库调用；`setUp` 里不要给 testWidgets 开库播种。普通 `test` 不受影响。
- 验收：串行全量测试 **1175/1175**（基线 1174 + 新增 1 个 schema 测试，EXIT=0，8 分 08 秒，日志 `~/workspace/b1-work/b1-full.log`）；新增 `test/b1_stage1_schema_test.dart`（`openAt` 新建空库：`user_version=2`，17 条 DDL 与 v2 基线逐字一致）；CLI schema diff 零差异（新代码空库 `.schema` 排序后 vs `~/workspace/b1-work/v2-baseline-schema.sql`，81 行，含部分唯一索引 `idx_boxes_one_layer1_per_question` 与全部 `question_boxes` CHECK 约束）；`flutter analyze` 只剩 1 个已知 warning（生成文件 `quiz_database.g.dart` 的 `unused_field`，不手改）；Linux Release 构建通过（`✓ Built build/linux/x64/release/bundle/quiz_master2`，日志 `~/workspace/b1-work/b1-build.log`）；演示库 md5 未变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.b1-stage1-full-rerun`）；备份 zip 往返由全量覆盖（p1/s8b4/p3 用例）。全量 TMPDIR 用 `~/workspace/flutter-test-tmp`（磁盘，D-39）。
- 收尾中的两次中断：① 首轮全量在 +768 -3 处挂住（b9_3 B 用例 10 分钟超时，flutter_tester 零 CPU 阻塞在 epoll_wait），按父任务指令 kill 后单跑定位、修好；② 运行时重启约 19:06 把重跑打断在 +379（0 失败），并清空了已恢复的工具链（`which clang/clang++/ninja` 全空，全量重跑报 `Building native assets failed`），按 17:09 已授权的同一恢复脚本重跑恢复（EXIT=0，自检 clang++ 18.1.3 / gtk 3.24.41 / ImageMagick 6.9.12-98 / xdotool 3.20160805.1，日志 `~/workspace/b1-work/restore-toolchain-2.log`），随后全量一次通过。
- 代码未推，等 Meng 批准（由协调员统一报总账）。B Stage 2 仍等 Win11 真机验证（ReplaceFileW 三种部分失败状态 + 父目录 fsync FFI），不跳过、不启动。

## D-46 — 架构 B 第 2 阶段门禁：Win11 真机验证通过（2026-11-16 21:50，ARCH-PLAN-B §四第 0 阶段第 6 条 + B-NEW-14/16/17）

- 验证方式：Meng 在自己 Win11 电脑上跑验证程序 `~/workspace/win11-verify/verify.dart`（Dart 3.13.7 windows_x64），工作目录 `%TEMP%\qm2-win11-verify-*`，只写临时文件，不碰真实演示库、不联网。结果文件 `~/workspace/win11-verify/win11-verify-result.txt`，汇总 4/6 通过；两项 FAIL 均为预期内的有效验证结论，不是阻塞项。
- [1/6] rename FAIL（有效结论）：Dart `File.rename` 替换已存在目标抛 `PathAccessException (errno 5 拒绝访问)`。结论：**`File.rename` 在 Win11 上绝对不能当原子替换用**。恢复日志原子替换在 Windows 上必须走 FFI 调 `ReplaceFileW`（带备份文件）；Linux 上用同文件系统 `rename(2)`。“先删旧日志、再普通重命名新日志”的两步方式禁止。
- [2/6] replace PASS：`ReplaceFileW` 成功路径——正式日志为完整新版 v2、备份 `restore-journal.json.bak` 为完整旧版 v1、tmp 已消失。
- [3/6] inject PASS（安全属性成立，错误码与预期不符是重要发现）：锁住正式日志后 `ReplaceFileW` 返回错误码 **0**（预期 1175）；锁住临时日志返回 **32**（预期 1176）；预置备份 + 锁临时返回 **32**（1177 未触发，预期内）。三次注入后正式日志均未损坏丢失。结论：**恢复代码不得只凭 Win32 错误码推断文件位置——实测出现过错误码读到 0 但文件根本没动**。失败后一律先实地核查正式日志、备份、临时三处文件的实际状态，再按 B-NEW-17 的逐状态规则处理。
- [4/6] layouts PASS 6/6：L-1175（正式 v1 + 临时 v2 → 重试安装成功）、L-1177（正式缺失 + 备份 v1 + 临时 v2 → 安装临时）、L-1177b（正式缺失 + 备份 v1 + 临时损坏 → 从备份恢复原日志）、L-1175b（正式 v1 + 临时损坏 → 丢弃临时保正式）、L-first（首次创建只有临时 → 同卷 rename 安装）、L-none（三处均无有效日志 → 明确拒绝，不得继续）。三状态布局的恢复动作均按 B-NEW-17 验证通过。
- [5/6] fsyncdir FAIL（预期内，不阻断）：`GENERIC_READ` 打开目录句柄后 `FlushFileBuffers` 报错误 5。实现约束：**改用 `GENERIC_READ|GENERIC_WRITE` 打开目录句柄再试；仍失败则只记录、不阻断本次日志更新**（B-NEW-16：故障保证只覆盖进程强制终止，不承诺断电恢复）。
- [6/6] killtest PASS：循环更新中 `taskkill /F` 强制杀进程，重启后正式日志仍为完整版本 v40（非旧即新，无半截）。
- 门禁结论：B Stage 2 可以启动（Meng 2026-11-16 21:50 发回验证结果；一揽子授权 2026-11-16 09:54 已覆盖本阶段执行，推送仍需另行批准）。实现必须遵守的三条硬约束：① Windows 原子替换走 FFI `ReplaceFileW`（恒带备份，同卷），Linux 走同文件系统 rename；② 失败后先核查三处文件实际状态再分派，绝不只凭错误码；③ 父目录 fsync 用 `GENERIC_READ|GENERIC_WRITE` 重试，失败只记不阻断。另：验证程序本身修过一个 bug——`Utf16` / `toNativeUtf16` / `malloc` 在 `package:ffi` 不在 `dart:ffi`（初版 analyze 25 个错，加 `package:ffi` import + `pubspec.yaml` 的 `ffi: ^2.1.0` 后通过，验证包 v2）。

## D-47 — GPT 关口 P1-01 修正：ReplaceFileW 错误码整体错一位（2026-11-16，B Stage 2 推送后，GPT 复审 FAIL 唯一项）

- GPT 结论：2026-11-16 23:55 出结论 FAIL，唯一阻断项 P1-01。主 agent 已按微软定义与代码 grep 独立核实，GPT 是对的。
- 微软定义（WinError.h）：1175 (0x497) = ERROR_UNABLE_TO_REMOVE_REPLACED；1176 (0x498) = ERROR_UNABLE_TO_MOVE_REPLACEMENT；1177 (0x499) = ERROR_UNABLE_TO_MOVE_REPLACEMENT_2；1178 (0x49A) = ERROR_JOURNAL_DELETE_IN_PROGRESS，与 ReplaceFileW 无关。
- 错位原因：实现写的是 1176/1177/1178，整体错一位；常量、注释、测试、D-46 预期码同错。状态机逻辑本身（按磁盘实际状态分派、不得只凭错误码推断）是对的，只错数字。21:50 门禁实测读到的是 0 和 32，从未读到过 117x，所以错位一直没暴露。
- 修正内容：
  - `lib/data/journal_ffi.dart:125-127` 三个常量改为 1175/1176/1177（名不变），注释 120-122 同步。
  - `lib/data/restore_journal.dart` 注释 5 处（268、415、495、505、548）按正确码重写。核查：分派逻辑 `_handleReplaceFailure` 只按磁盘实际状态（正式/备份/临时存在性）分派，错误码只进异常信息；三处常量定义后无任何按数字分派之处，无需改逻辑。
  - `test/b2_restore_journal_test.dart`：注入码与用例名全部按 1175/1176/1177 重写（布局名同步 L-1175/L-1176/L-1177）。重点：1175（REMOVE_REPLACED）之前完全没覆盖到，本次补上。
  - D-46 的预期码与布局名同步纠正（[3/6] 预期 1175/1176/1177；[4/6] L-1175/L-1177/L-1177b/L-1175b）。
  - 未改：计划草稿 `ARCH-PLAN-B-DRIFT-DRAFT.md`（只用常量名、无数字，本身正确）；`gpt-review-b2.md` 原文不动（材料里的码随代码一起纠正，GPT 复审以修正后代码为准）；Win11 验证包由另一路按正确码重做（`win11-verify-b2-kit.zip`）。
- 验证：目标测试 `b2_restore_journal` + `b2_restore_flow` 42/42；串行全量 **1246/1246**（EXIT=0，9 分 36 秒，日志 `~/workspace/b2-work/b2-p101-fix-full.log`，0 个 `[E]`）；`flutter analyze` No issues found；schema 测试通过（`user_version=2`，17 条 DDL 逐字一致，diff 0）；演示库 md5 未变（`8f7f9c64…`，跑前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.b2-p101-gate`）。
- 残留核查：仓库内（lib/test/decision-log/计划草稿）已无 1178 当 ReplaceFileW 状态；1178 仅存于 `gpt-review-b2.md` 原文（按任务要求不改）与旧验证包 `verify.dart`（另一路重做中）。
- 状态：修正未推，等 Meng 批；B3 暂缓；GPT 复审只审 P1-01 这一个修复点（Meng 2026-11-16 23:57 定）；Win11 真机完整恢复验证明天（2026-11-17）做，验证包已备好，等修正推上去后再跑。

## D-48 — Win11 真机验证 [1/8]：group ⑪ 的 2 个 Linux-only 测试在 Windows 上失败，改为 Windows 跳过（2026-11-17，测试-only 修复）

- 现场：Win11 验证包 PowerShell 版跑完 8 项，[2/8][3/8][4/8][5/8][6/8][7/8][8/8] 全部 PASS；[1/8] 现有恢复测试套件 53 个里 51 通过、2 失败。失败的 2 个都在 `test/b2_restore_journal_test.dart` 的 group '⑪ 日志原子替换中断（Linux，子进程 SIGKILL）'（循环更新中杀掉 / 临时已写、替换尚未完成时杀掉）。
- 根因（已确诊，测试 harness 问题，不是产品 bug）：两个测试都调 `_startWorker` 用 `Process.start` 启动一个临时生成的纯 Dart worker；`_dartExecutable` 按 `FLUTTER_ROOT` 拼出 `D:\flutter_sdk\flutter\bin\dart`。在 Windows 上那是个 Unix shell 脚本（无扩展名），CreateProcess 报 `ProcessException: %1 不是有效的 Win32 应用程序`，worker 根本没启动，产品逻辑完全没被测到。日志见 Win11 的 `b2-existing-suite.log`（UTF-16LE，须转码读）。
- 为什么不是产品问题：同一场景的 Windows 等价覆盖是验证包 [7/8] killtest（真实 `updateStage` 循环 + `taskkill /F`），在 Win11 真机上已 PASS（杀进程后正式日志完整、非旧即新、无半截、tmp 已清、备份为完整旧版）。其余 51 个测试（含全部恢复/导入崩溃用例）在 Windows 上全部通过。
- 修法：group ⑪ 加 `skip: Platform.isWindows ? 'Linux-only：子进程 SIGKILL，Windows 不支持；Windows 等价覆盖见 Win11 验证包 [7/8] killtest（taskkill）' : false`。注意：不要用 `onPlatform`——test_api 0.7.12 的 `group` 虽有 `onPlatform`，但本文件 import 的是 `package:flutter_test`，其 `group` 是 `test_compat.dart` 的精简签名 `group(description, body, {dynamic skip, int? retry})`，没有 `onPlatform` 参数（第一次写 onPlatform 时编译报 `No named parameter with the name 'onPlatform'`，已改成 `skip`；`skip` 为 String 或 `true` 时跳过、为 `false` 时正常跑，见该函数文档）。Windows 上 2 个测试显示为跳过，Linux 上照常跑。不改成 Windows 版：即使把启动路径换成 `dart.exe` 也跑不了——测试用 `ProcessSignal.sigkill` 杀子进程，Windows 不支持 SIGKILL；且 Windows 版会与 [7/8] 重复。
- 格式说明：加了命名参数后 `dart format` 要求 `group(...)` 调用拆成多行，组内两测试整体缩进 +2（纯空白改动，语义只改两处：组头注释 + 组尾 `onPlatform`）。文件改前已确认 `dart format` 干净，改后仍干净。
- 潜在问题（本次不动）：`_dartExecutable` 在 Windows 上会选中 `bin\dart`（Unix 脚本）——有 skip 后 `_startWorker` 不再于 Windows 上被调用，所以本次不动它；以后若有人在 Windows 上用 `_startWorker` 起 worker，需先按平台选 `dart.exe`（如 `<sdk>\bin\cache\dart-sdk\bin\dart.exe` 或 PATH 里的 `dart`）。
- 验证（Linux 本机，2026-11-17）：演示库跑前备份到 `~/workspace/demo-db-backup/quiz-master2.db.b2-1-8-fix-gate`（md5 `8f7f9c64…`）；三文件套件 `flutter test --concurrency=1 test/b2_restore_journal_test.dart test/b2_restore_flow_test.dart test/b2_import_crash_test.dart`（TMPDIR=$HOME/workspace/flutter-test-tmp，LD_LIBRARY_PATH=onnxruntime-1.4.1/linux），结果 **53/53 通过，"All tests passed!"，0 个 `[E]`**（日志 `~/workspace/b2-work/b2-1-8-fix-suite.log`）。注意：Linux 上 `skip` 为 `false`，2 个 ⑪ 测试是正常跑过（不是跳过），证明 skip 没破坏它们；跳过只在 Windows 上生效，Win11 重跑时期望 51 通过 + 2 跳过。`flutter analyze` 改动文件 No issues found；`dart format` 干净；演示库 md5 跑后未变（`8f7f9c64…`）。另：验证中途因 VM 重启丢了 clang/ninja（`pdfium_dart` 的 hook 报 `No compiler configured`），已按既定脚本 `docs/ui-replication/restore-linux-toolchain.sh` 恢复（clang 18.1.3），与本次改动无关。
- 状态：测试-only 修复，未推；等 Meng 批推送后，他在 Win11 上拉取，只重跑 [1/8] 即可确认（期望 51 通过 + 2 跳过）。

## D-49 — 详情页“这道题不存在了”：Riverpod 3.x 传递 override 挂载缺陷，detail/wrongbook/review 三 Provider 补 dependencies（2026-11-17，安装包 bug 修复）

- 现场：Meng 2026-11-17 09:50 报安装包详情页空白（“这道题不存在了”，无左导航），他自己机器和别人全新安装都一样；首页、错题本、目录页 9 道题都正常，只有详情页无论哪种路径都不显示。诊断（Linux Release + 演示库）复现成功，确认是代码问题，不是 Windows / 安装包问题。
- 根因（已确诊，**不是 B2/Drift 回归**，是架构 A 第 3 阶段引入的 Riverpod 状态层缺陷）：`DetailNotifier` 的 `detailProvider`（`lib/state/detail_notifier.dart:58-61`）是手写 `NotifierProvider.autoDispose`，**没有传 `dependencies:`**。Riverpod 3.x 只把 Provider 挂载到覆写了它已声明传递依赖的最深容器；没有声明依赖时挂到根容器。`build()` 里 `ref.read(detailInitialProvider)`（:264）读到的就是根容器的默认值 `DetailInitial(questionId: '', ...)`（:85），而不是详情页嵌套 ProviderScope 里 override 的真实 id。于是 `load()` 调 `questionById('')` 得 null，页面显示“这道题不存在了”。debug 日志证实：`_openDetail: q.id="q-math-1"`、`detailPage.build: widget.questionId="q-math-1"`，但 `load: currentId=""`、`questionById -> NULL`。数据库、`questionById` 全部正常。为什么现有测试一直是绿的：`detail_page_test` 把详情页直接当 home（无根 Scope），没覆盖“根 ProviderScope + Navigator.push”这一触发条件。
- 修复（最小方案，3 个文件，只改 Provider 定义 + 注释）：
  - `lib/state/detail_notifier.dart`：`detailProvider` 加 `dependencies: [detailInitialProvider, repositoryProvider]`。
  - `lib/state/wrongbook_notifier.dart`（:36-39）：`wrongbookProvider` 加 `dependencies: [wrongbookInitialProvider, repositoryProvider]`——同一模式、同样没传 dependencies，初始值目前只承载非关键入口状态所以缺陷不可见，一并消除隐患。
  - `lib/state/review_notifier.dart`（:43-46）：`reviewProvider` 加 `dependencies: [reviewInitialProvider, repositoryProvider]`，同理。
  - 注意：只把 `build()` 里的 `ref.read` 改成 `ref.watch` 不够——挂载决策用的是静态 `dependencies`，不是运行时的 watch。其余页 Provider（home/organize/report/collect/subjects/settings）只读 `repositoryProvider`，其默认值就是单例库（与根组件同一份），生产上无此缺陷；organize/collect 没有 initial provider——本次不动。
- 验证（2026-11-17，全部通过）：
  - 回归测试 `test/detail_push_scope_regression_test.dart`（诊断留好，三组对照）：修复后 **3/3 通过**；关键行 `DIAG mech-push: currentId="q-math-1" question=函数极限 loading=false notExist=false`（修复前仅根 Scope+push 失败，currentId=''）。
  - debug 复现（诊断副本 `~/workspace/qm2-diag-copy/`，3 处 DIAG 插桩保留，修复已同步进去）：日志 `DIAG _openDetail: q.id="q-math-3"` → `DIAG load: currentId="q-math-3"` → `DIAG load: questionById -> q-math-3 | 定积分阴影面积`；详情页正常显示（截图 `/tmp/diag-fix-detail.png`）。注：列表首题是 q-math-3（时间新→旧排序），不是 q-math-1——id 本身无要求，关键是 currentId 不再是空串。
  - Linux Release 复现验证：`flutter build linux --release` 成功（日志 `~/workspace/b2-work/d49-release-build.log`）；Release 包 + 全新 v2 演示库（9 题，md5 `721883c3…`）在 Xvfb :99 上点进详情页，题目正常显示（截图 `/tmp/diag-rel-detail.png`，与 debug 截图逐字节一致）。
  - 串行全量 **`1249/1249`，`All tests passed!`，0 个 `[E]`**（8 分 44 秒，日志 `~/workspace/b2-work/d49-full.log`；1246 + 新增回归测试 3 个）；`flutter analyze` No issues found；演示库跑前备份到 `~/workspace/demo-db-backup/quiz-master2.db.d49-gate`，跑后 md5 未变（`8f7f9c64…`）。
- 深链路（学习报告弱点 → 错题本带筛选）验证：修复后点“数学 · 概念不清”正确落在**数学目录页**（修复前会因 initial 读不到默认值而落在书架）。但进列表后筛选并未生效——这是**修复范围外的既有行为**，不是本次缺陷：`WrongbookNotifier.build()` 里 subjectId 非空 → 目录页（按 D-35 注释“带学科进来 → 目录页”设计如此）；而 `_openList`/`openList` 进列表范围时调 `clearFilters()`（SR-P2-44 规则：进另一科/文件夹清搜索与筛选），把深链路带来的 `filterCauseName` 一并清掉，用户最终看到的是未筛选的列表。产品意图（2026-11-12 决定：“点薄弱点打开按该错因/知识点筛选的错题本”）目前未达成，需 Meng 定：是让深链路直达已筛选的列表，还是保留目录落点但让初始筛选熬过第一次进列表。**本次未改**，留待他决策。
- 附带核查（诊断发现的目录行 xdotool 点击无反应）：逐一复测，**不是产品 bug，不修**。本次 debug 运行中：“全部题目”行两次点击均进列表、试卷文件夹行点击进列表（1 道题）、改名按钮点击后重命名输入框正常打开（截图 `/tmp/diag-fix-rename3.png`）。前两次改名点击无反应是我的坐标偏了约 25px（点在改名/删除两按钮之间的 6px 间隙上，visual grounding 定位后按精确中心 1119,254 重测即生效）；诊断时的无反应同样是合成点击落点问题。建议 Meng 在 Win11 真机上随手点一次目录行确认即可，无需另立项。
- 状态：修复未推，等 Meng 批推送；他重装后需在 Win11 真机上点一次详情页确认（安装包侧）。修完 B2 的“真正完成”条件已全齐（P1-01 修正 + GPT 复审 PASS + Win11 8/8 验证），但 B2 最终邮件与 B3 仍按主 agent 安排，等 Meng 确认修复后再走。

## D-50 — 学习报告薄弱点 → 错题本：深链路直达已筛选列表，跳过目录页（2026-11-17）

- 方向（Meng 2026-11-17 11:22 选定）：**直达已筛选的列表**，不是“先落目录页、进列表时带上筛选”。
- 现状（D-49 修复后已验证）：点报告里的“数学 · 概念不清”能正确落在数学目录页，但进列表后筛选没生效——`build()` 里 subjectId 非空 → 目录页（D-35 设计）；`_openList`/`openList` 进列表范围时调 `clearFilters()`（SR-P2-44），把深链路带来的 `filterCauseName` 一并清掉，最终看到未筛选的列表（实测数学 2 道全列出）。
- 修复（3 处，都在本地工作树 D-49 改动之上；D-49 的三处 dependencies 没动；报告页弱点列表 UI 没动）：
  - `lib/state/wrongbook_notifier.dart` `WrongbookNotifier.build()`：初始落点优先级改成——带错因 / 知识点筛选进来 → **列表页**；只带学科进来 → 目录页；都不带 → 书架。学科仍留在 state 里定列表范围。`filteredAll()` 本来就按 subjectId 划范围、再按 filterCauseName / filterKpIds 筛，所以落点改了就够了，不用另加筛选逻辑。类注释同步改了。
  - `lib/state/wrongbook_notifier.dart` `WrongbookInitial`：补 `==` / `hashCode`（同款见 `DetailInitial` / `ReviewInitial`）。外壳每次 build 都新建一个实例，值语义相等才合理。
  - `lib/app.dart` `_go`：普通导航（含左导航 / 首页进错题本）一律清 `_reportCauseArg` / `_reportKpArg`（原来只在离开 /wrongbook 时清）。只 `_goWrongbookFiltered` 设这两个值；不清的话，下次普通进错题本会在全新挂载时读到残留筛选，落在带筛选的列表而不是书架。
- 返回路径（选定：**回目录**，不用回报告）：列表页头已有的“← 目录”按钮 → `openDirectory(subjectId)`（无学科时回书架）。没选“回学习报告”：本应用没有路由栈（单一 `_route` + 左导航切换，不是 push/pop），“回来源”要把来源参数一路穿过 app.dart → WrongbookPage → 列表头，改动面大，只为这一个入口不值；目录是错题本内一致的回退目标，报告离左导航只有一次点击。`openDirectory` 会清筛选，所以深链路是一次性入口，不会泄漏到后续导航。
- Riverpod 语义（本次实测确诊，写进注释与测试，免得后人误读）：**`dependencies` 只决定 Provider 挂载到哪个容器；`ref.read` 不订阅——挂载后 override 值再变，已挂载的 notifier 不重建，initial 只在挂载时读一次**。证据：临时测试（跑完即删）里 `updateOverrides` 换成空 initial 后 `view` 仍是 `list`、`loading` 仍 false；真机上点当前页的左导航项（错题本）也一样是原地不动——这是应用内各页共有的“当前页导航是 no-op”行为，不是 bug。深链路的正确性依赖两点：全新挂载时 `build()` 的落点判断，以及 `_go` 在普通导航时清残留参数。`==` 的作用是值语义一致（与 DetailInitial / ReviewInitial 同款），本次行为不依赖它。
- 验证（2026-11-17，全部通过）：
  - 回归测试 `test/wrongbook_notifier_test.dart` +5（D-50 组，复用 `_setUp` + `FakeWrongbookNotifierRepo`）：① 学科 + 错因 → 列表、`filterCauseName` 已设、`filteredAll()` == [m1]；② 学科 + 知识点 → 列表、`filterKpIds` 已设、`filteredAll()` == [m1]；③ 正常入口：目录进列表仍清筛选（SR-P2-44 保留）；④ `resetFilters` 仍清空搜索/全部筛选、排序回 'new'；⑤ 挂载后 override 再变（等值 / 变值）不影响当前页——排序/视图/筛选原样保留（initial 只在挂载时读一次）。
  - 回归测试 `test/wrongbook_page_test.dart` +3（D-50 组，复用 `pumpWrongbook`，补了可选 `filterKnowledgePointId` 参数）：① 学科 + 错因直达已筛选列表；② 学科 + 知识点直达已筛选列表；③ 深链路列表点“← 目录”回目录，再点“全部题目”进未筛选列表（筛选已清、一次性入口）。注意：三题首跑 3/3 失败是因为断言了 `q.title`——大卡片默认视图不渲染标题，只渲染切片缩略图文字（`sliceText`）+ 序号，标题只出现在紧凑行/已归档行；改成给每道测试题 distinct `sliceText`（'题：求极限' / '题：求导数' / '题：英语词汇'）后断言通过（临时排查测试已删）。演示库实测数据：数学未筛选列表 2 道（q-math-1、q-math-3；q-math-2 未整理不计入），数学“概念不清”只筛出 q-math-1（1 道）。
  - 串行全量 **`1257/1257`，`All tests passed!`，0 个 `[E]`**（11 分 18 秒，日志 `~/workspace/b2-work/d50-full.log`；1249 + 新增 8 个）。注意：第一遍全量跑到 +1089 时被 runtime 重启打断（日志只到 detail_page_test），且中段出现 1 个 `[E]`：`b11_dragdrop_test.dart`“一次拖两张（同猜数学）”期望的“批量导入 · 已完成 1 / 2 · 1 个失败”没出现——与本次改动无关（拖放批量导入的异步进度文案时序）；单跑该文件 **7/7 通过**，判定为负载下偶发；重跑的全量 1257/1257 里它也通过了。
  - `flutter analyze` No issues found；`dart format` 干净（4 个改动文件）。
  - Linux Release 真机验证：`flutter build linux --release` 成功（日志 `~/workspace/b2-work/d50-release-build.log`）；Release 包 + 全新 v2 演示库（9 题，md5 `721883c3…`）在 Xvfb :99 上：首页正常 → 学习报告（本月：弱点“数学 · 概念不清 / 1 道题”）→ 点它**直达数学错题本列表**，`筛选（已选 1）`、`共 1 道 · 第 1 / 1 页`，卡片为函数极限题（q-math-1），未筛选的数学列表是 2 道（截图 `/tmp/d50-deeplink-list.png`）→ 点“← 目录”回数学目录（全部题目 2 道；截图 `/tmp/d50-back-dir.png`）→ 左导航先去学习报告、再点错题本，落在**书架**（数学/英语/政治三封面，无残留筛选；截图 `/tmp/d50-nav-shelf2.png`）。注：报告默认“本周”窗口内没有薄弱点（演示题不在本周），验证时用的是“本月”——行为与范围无关，只影响弱点是否列出。
  - 演示库跑前备份到 `~/workspace/demo-db-backup/quiz-master2.db.d50-gate`，跑后 md5 未变（`8f7f9c64…`）。
- 环境插曲（与 D-50 改动无关，记在这里免得下次重踩）：验证中途 runtime 重启，/usr 下工具链丢失（clang/ninja 不见）；按 `docs/ui-replication/restore-linux-toolchain.sh` 恢复后，Release 应用启动报 `libEGL fatal: did not find extension DRI_Mesa version 1`。查到恢复脚本的 bug：注释说索引按 noble-updates 优先，但 `pkgs.update()` 是后写覆盖，循环里 updates 在前、noble 在后，结果 noble 24.0.5 胜出——日志证实 24.0.5 的 `libglapi-mesa` 被解到 /，与 25.2.8 的 DRI 驱动不匹配。修复：① 手动把 `libglapi-mesa` 换成 noble-updates 的 24.2.8-1ubuntu1~24.04.1，应用随即正常启动（Impeller OpenGLESSDF）；② 恢复脚本循环顺序改成先 noble、后 noble-updates（`dict.update` 后写者胜），并把原因写进脚本注释；干跑验证：libegl-mesa0 / libegl1-mesa-dev / libgl1-mesa-dri 均解析为 25.2.8，libglapi-mesa 解析为 24.2.8。注意：盘上 `libEGL_mesa.so.0.0.0` 经 md5 核对一直是 25.2.8（没被 24.0.5 覆盖），这次真正被 24.0.5 覆盖的是 `libglapi.so.0.0.0`。
- 状态：修复未推，等 Meng 批推送——D-49 + D-50 一起推（D-49 的推送审批 11:20 已给、11:21 被叫停“先不推”，需重新走邮件先行 + 小卡片确认）；他重装后需在 Win11 真机上确认两处：详情页正常显示、报告弱点直达已筛选列表。

## D-51 — B3：备份恢复走类型化 API；导出保持存储表示原样；非规范 '' 规范化为 '[]' / '{}'（2026-11-17）

- 范围（plan v9 §四第 3 阶段第 3 条 + P1-B3）：`_seed` 的 6 处 customInsert 与备份恢复的 `_backupInsertRow`（手拼 SQL）改走 Drift 类型化 API；`_variables` / `_variable`（仅供这两处用）随之删除。
- 导出不动：`exportBackupJsonFromImpl` 仍用 `customSelect('SELECT * FROM $t')` 读存储表示原样导出——这是 P1-B3 的明文要求（“导出时 JSON 文本原样”），类型化导出会把 '' 读成 [] 再编回 '[]'，改了导出字节，不合要求。导出不是垫片，是有意保留的存储表示读取。
- 恢复映射（`_backupInsertRowTyped`，13 张表逐表 Companion）：JSON 列先经 `AppDatabase.decode*` 解回业务值，再由各列 TypeConverter 编回存储表示。规范值解码-编码互逆、逐字节不变；非规范旧值 ''（DDL DEFAULT 遗留）解码为空集合、编回规范的 '[]' / '{}'。语义等价（`decode('') == decode('[]')`），口径与 p2_json_fields 回归一致（'' 是漂移、'[]' 是规范；`_seedCauseRecordsTyped` 的 remedy_history 显式写 '[]' 同理）。
- 其余列按 JSON 运行时类型严格取值（`_rs` / `_ri` / `_rd` 系列助手）：缺失或类型不对直接抛 `BackupRestoreException`（带行 id 与列名），不静默默认值、不猜测转换；有 DDL 默认值的可选列缺失时走 `Value.absent()`（落库默认值，与旧写法“缺键不写”同口径）。
- 旧 strict 口径保留：类型化映射只认已知列，未知列不会进 Companion，必须先拦——`_backupInsertRowTyped` 开头按 13 张表已知列集校验，多余列直接拒绝恢复（旧 `_backupInsertRow` 是拼 SQL 时由 SQLite 报错，同一口径；测试覆盖）。
- 清表也类型化：`DELETE FROM $t` 改为按表名分流的 `db.delete(...).go()`（`_clearBackupTable`）。
- 新增 `AppDatabase.decodeRotations`（db_codec `decodeRotationsImpl`），与 `RotationsConverter.fromSql` 同逻辑（空串/NULL/非法 JSON -> {}），供恢复映射用；编解码约定源头仍是 db_codec.dart。
- 验收：新测试 `test/b3_backup_interop_test.dart` 10/10 通过（见 D-55）；黄金夹具 `test/fixtures/b3-old-backup.json` / `.zip`（B3 之前代码导出，13 张表全覆盖，含满值 / '[]' / '{}' / 非规范 ''，生成器 `test/b3_fixture_gen_test.dart` 已删）。
- 导出行顺序：`SELECT *` 无 ORDER BY，行顺序不保证；恢复末尾的 schemaVersion 写回（insertOrReplace）会把该行移到 settings 末尾——新旧代码同行为，与内容无关；往返对比测试按主键排序后再比。

## D-52 — B3：计划 v9 第 3 阶段第 3 条“新表定义统一放 lib/data/drift/（新目录：tables.dart、converters.dart、daos/）”与现实的偏差（2026-11-17）

- 现实：B2 已把 13 张表定义放在 `lib/data/drift/tables/`（每表一个文件）+ `converters.dart`，计划里的“新目录”写法是 v1 时期的布局描述，实质要求（表定义统一在 drift/ 下）已满足，不再新建 `tables.dart` 做无行为收益的重组。
- `daos/` 不建：B2 已定偏差（无独立 DAO 类，直接用 Drift 生成的表访问器，GPT 关口已知）；B3 是收尾，不为此补一层 DAO——多一层转发既不改行为也不改验收，只增 churn。
- 结论：本条视为已完成（表定义在 drift/、转换器在 converters.dart、备份/恢复与 _seed 已类型化），偏差记在这里，不另立项。

## D-53 — B3：移除 sqflite_common_ffi 依赖；pubspec.lock 随之变化（2026-11-17）

- `pubspec.yaml` 删 `sqflite_common_ffi: ^2.3.6`；`flutter pub get` 输出只移除了 `sqflite_common 2.5.7` 与 `sqflite_common_ffi 2.4.7`（前者是后者带入的传递依赖），其余包版本零变动；全仓 grep 无任何代码 `import package:sqflite…`（只剩 `package:sqlite3` 的只读探针 import，与本次移除无关）；`flutter analyze` 0 问题。
- 全仓 custom* / raw* 审计结论：(d) 类真正残留垫片 0 处——命中的 `.insert/.update/.delete` 均为 Drift 类型化 API；17 条 DDL `customStatement`、两处 `SELECT 1` 探针、两处 PRAGMA 均为合法使用，不动。
- 仅注释清理：db_codec / db_questions / db_catalog / db_collect / db_settings / database / README / 代码地图里已失实的 sqflite / `_toRow` / `_fromRow` 提及；`db_codec.dart` 的 encode*/decode* Impl 保留（仍被 `AppDatabase` 公开静态方法与测试调用）。
- **注意（给 Meng 的提醒，写进 B3 推送说明）：B3 推送后他拉取时 pubspec.lock 有合法变化（sqflite 两包移除），不要像之前那样 `git checkout -- pubspec.lock` 还原——还原会把已删的依赖带回来。**

## D-54 — B3：build_runner 进工作流；生成的 *.g.dart 必须入库（2026-11-17）

- 命令：仓库根目录 `dart run build_runner build --delete-conflicting-outputs`（Win11 用 `D:\flutter_sdk\flutter\bin\dart`，Linux 用 `~/workspace/flutter-install/flutter/bin/dart`）；改了 `lib/data/drift/tables/` 任一表文件、`quiz_database.dart` 的表注册或 `converters.dart` 后要跑，只改业务代码不用跑。
- 验证：本次跑完 `lib/data/drift/quiz_database.g.dart` md5 与改动前完全一致（`d20ce76c11e711c18618de22e57cd28d`，表定义没改，符合预期）；耗时 81 秒，exit 0。
- 入库核实：同步记录里 `.g.dart` 在 B1（84aa09a）与 B2（16ae2c8）两次推送的 paths 里，之后无推送删它；`.gitignore` 无 `*.g.dart` 忽略规则；结论：已在远程快照里。
- 代码地图 `docs/代码地图.md` 第 3 节“数据流”内新增 `### build_runner 工作流` 一节（命令、触发条件、入库约定、建表不走生成——`createTablesImpl` 的 `customStatement` 原样 DDL 为准）；同文件 §1 依赖块与 §3 一处已失实描述同步修正（sqflite → Drift）。
- drift_dev 的 PRIMARY KEY 列 `NOT NULL` 警告（`customConstraint('PRIMARY KEY')` 未写 `NOT NULL`）是 B2 既有表定义写法，本次未动——表定义变动会触发 schema diff 门禁复核，不属于收尾范围；实际 DDL 由 `createTablesImpl` 的原样 SQL 决定，不受其影响。

## D-55 — B3 验收汇总：收尾完成，B 全部结束（2026-11-17）

- 第 1 项：`sqflite_common_ffi` 移除（见 D-53）；全仓 custom* / raw* 审计：(d) 类真正残留垫片 0 处；17 条 DDL 不动；仅注释清理 9 文件。
- 第 2 项：build_runner 工作流进代码地图（见 D-54）；`quiz_database.g.dart` 两次重生成 md5 均为 `d20ce76c…`，与改动前一致。
- 第 3 项：`_seed` 与备份/恢复走类型化 API（见 D-51）；黄金夹具 `test/fixtures/b3-old-backup.json`（md5 `ac5d969d…`）/ `.zip`（md5 `896f0a2d…`）；新测试 `test/b3_backup_interop_test.dart` 10/10（旧→新 JSON/zip、新→旧复刻 JSON/zip、现场往返、多余列拒绝、非空库恢复）。
- 验收（2026-11-17）：
  - 串行全量 **1267/1267，`All tests passed!`，0 个 `[E]`**（9 分 20 秒，日志 `~/workspace/b3-work/b3-full.log`；1257 + 新增 10 个）；`flutter analyze` No issues found；`dart format`：B3 改动文件干净。
  - schema diff 0：`test/b1_stage1_schema_test.dart` 1/1（17 条 DDL 逐字一致）。
  - 演示库跑前备份到 `~/workspace/demo-db-backup/quiz-master2.db.b3-start`，跑后备份到 `quiz-master2.db.b3-gate`，md5 全程不变（`8f7f9c64…`）。
  - Linux Release 构建通过（日志 `~/workspace/b3-work/b3-release-build.log`），包内含 `libsqlite3.so`（与 `libonnxruntime.so.1.15.1`、`libpdfium.so` 同在）。
  - Win11 待 Meng 做：清单 `~/workspace/b3-work/win11-b3-checklist.md`（核心：安装包里 `sqlite3.dll` 在 + 备份导出/恢复冒烟；这次拉取后不要 `git checkout -- pubspec.lock`，见 D-53）。
- 已知非阻塞项（不拦 B3）：
  - `b11_dragdrop_test.dart`“一次拖两张”：D-50 全量 +1089 时失败过一次、第 1/2 项验收全量与单跑又各失败一次（当时判为稳定复现），本次 B3 全量 1267/1267 里它通过了。结论：与 B3 改动无关（改动是注释 + 删无引用依赖 + 字节一致的 `.g.dart` 再生成 + 备份/种子类型化，不碰拖放导入），是负载/时序敏感的偶发；全量绿了，不再追。
  - 全量日志里 Drift “multiple databases” debug 警告共 18 处，其中 14 处来自既有测试（b2_restore_flow 等），B3 新测试贡献 4 处（同一测试内先后开两个内存库、源库未关）。各内存库自有执行器，无实际共享；既有套件同模式，不另改。
  - 全仓 `dart format --set-exit-if-changed lib/` 显示 37 个文件可被重排（长单行构造展开，例 models.dart 的 Subject.all），均为 B3 未动文件、既往风格漂移；B3 改动文件全部干净。收尾阶段不做全仓重排（只增 diff 噪音），留待以后。
  - drift_dev 的 PRIMARY KEY `NOT NULL` 警告见 D-54，未动。
- 状态：B3 本地实现与验收全部完成，未推代码、未发邮件，等 Meng 批推送；推送后他按 Win11 清单验证（sqlite3.dll + 备份冒烟），通过后 B 正式收尾。

## D-56 — 最终自审启动：只审不修（2026-11-17）

- Meng 批准开始最终自审（架构 A、B 全部跑完之后的闭环）。本次只审、不修：通读代码、核实 6 个已知尾巴、找出新问题，汇总成带编号的分级报告交给 Meng 裁决，他定修哪些之后再开修复批次。
- 自审过程不改产品代码、不推代码、不发邮件。工作日志与报告放 `~/workspace/final-review/`，报告 `FINAL-REVIEW-REPORT.md`。
- 分级口径沿用第二次自审（P0 阻断、P1 应修、P2 可修可留），只报能确认的，不猜。
- 明确不列入修复建议、只记现状的两项：详情页 `reviewRecords` 订阅（A 外单独事项，等 Meng 定）；`retryFromStoredOriginal` 的 UI 接线（Meng 待决事项）。

## D-57 — 最终自审完成：只审不修，45 项（P0 0、P1 7、P2 38），等 Meng 裁决（2026-11-17）

- 7 个工作组（W1 页面层、W2 数据/状态层、W3 尾巴①⑤、W4 尾巴②、W5 尾巴③④、W6 尾巴⑥、W7 基线）全部完成；报告 `~/workspace/final-review/FINAL-REVIEW-REPORT.md`，各组报告 `w1-pages.md` ~ `w7-baseline.md`，基线日志 `baseline-full.log`。
- 基线：全量 1267/1267、analyze 0、schema 测试通过；演示库跑后 md5 曾变（见 FR-45），已从备份恢复。
- 6 个尾巴：①重叠框部分复现 P1（检测问题，先做 UX 小修）；②重框主流程通，2 P1 + 2 P2；③删除未包事务在代码层面已闭合（13 路径全包事务），另 1 P1 + 4 P2 在事务之外；④ zip 主干全过，边界 1 P1 + 5 P2；⑤放大浮层已修且在远程 head 4c1ca1e3 里（协调员亲自核实 `widgets.dart` 含 `_fitFor`/`_centerInitial`），残留 P2（Win11 复核）；⑥纯白胶囊未复现，残留 P2（根因未证实）。
- P1 7 项：FR-01 删学科后 kpSubjectId 残留写孤儿、FR-02 角标事件先于错因同步、FR-03 重叠框、FR-04 重框可画第二框静默丢框、FR-05 重框后旧切片滞留、FR-06 孤儿清理信过期扫描、FR-07 备份 JSON 损坏值静默丢数据。
- 需 Meng 裁决：SR2-29 口径、SR2-40 圆盘、FR-04 修法二选一、FR-37 口径；修哪些按编号定，之后再开修复批次。
- 附带：全量测试会改写真实演示库（FR-45，肇事测试未定位）；v1 演示库启动即删是既定设计（B1 删老库、无迁移），GUI 复现改用 v2 空库或另做 v2 夹具；R11 回归脚本坐标已过期（复习 271→248、首页 100→84）。

## D-58 — 最终自审修复启动：45 项全修，四批顺序做（2026-11-17）

- Meng 2026-11-17 17:25 批准按自审建议全部修：P1 7 项 + P2 38 项，修法按报告建议走；FR-04 选 (a) 重框模式禁画新框，FR-37 加批量删题事务；SR2-29 确认“报告分布扣已掌握”、SR2-40 确认“紧凑行不设行号、大卡片蓝圆盘保留”。
- 四批顺序做、每批验收：批一 P1（FR-01~FR-07）；批二 P2 数据与恢复（FR-20/21/23/24/25/26/27/28/29/40/41/42/43/45，14 项）；批三 P2 页面与文案（FR-08/09/10/11/12/16/17/18/34/35，10 项）；批四 P2 代码卫生与防御（FR-13/14/15/19/22/30/31/32/36/37/38/39，12 项）。可修 P2 共 36 项；FR-33/FR-44 只做 Win11 真机复核、不修代码。合计 45 项。
- 全部本地实现与验收，不推代码、不发邮件；四批合并不久一次推，等 Meng 批准。
- 记一笔：FR-03 的 UX 小修（重叠框标红 + 横幅点名）就是 Meng 17:02 待加功能第 1 项的本体，修完后十二批第 1 项只剩核对、不用另做。
- 风险重点：FR-05 缓存改动、FR-06/07/26 恢复与备份行为改动必须双向测试（合法旧行为仍通过、非法的被拦住）；FR-07 拒绝恢复时先校验、再覆盖，确保原库不被整体覆盖。FR-45（全量测试改写真实演示库）仍是开放缺口：每批全量前后都核对演示库 md5，变了就从备份恢复并记录。

## D-59 — SR2-29 裁决确认：报告分布扣已掌握（2026-11-17，批一）

- 亲手核对代码属实，不改代码。`lib/state/report_provider.dart:225` 的 `questionsInRange` 只收已整理未归档且**未掌握**的题（`!isMastered(q)`），报告分布与弱点 Top 5 均由此派生；`lib/modules/report/report_page.dart:128` 取 `questionsInRange`。文件头注释已写明 SR2-29 口径。
- 裁决（Meng 2026-11-17 17:25，见 D-58）：报告分布扣已掌握。按此口径实现已是现状，旧账闭合。

## D-60 — SR2-40 裁决确认：紧凑行不设行号、大卡片蓝圆盘保留（2026-11-17，批一）

- 亲手核对代码属实，不改代码。大卡片确有蓝色序号圆盘（`lib/modules/wrongbook/wrongbook_list.dart` `_buildLargeCard`，accent 圆角 999 徽标 + 本页位置序号）；紧凑行 `_buildCompactRow` 无序号。
- 裁决（Meng 2026-11-17 17:25，见 D-58）：紧凑行不设行号、大卡片蓝圆盘保留。代码现状即此口径，旧账闭合。

## D-61 — FR-05 缓存修法选择：evict 全清 + ValueKey（2026-11-17，批一）

- 根因（W4-03 已钉死）：`evictCachedFileImage` 用裸 `FileImage.evict()`，与渲染侧 `Image.file(cacheWidth: ...)` 走的 `ResizeImage` 缓存键不一致；且 `Image.didUpdateWidget` 只在 provider 不等时重解码——只清缓存救不了正在显示的旧图。
- 选了组合方案（任务书两选项都用，各补对方的缺口）：
  - `evictCachedFileImage`：裸 `FileImage` evict + `PaintingBinding.instance.imageCache.clear()` + `clearLiveImages()`。不用精确键清理：`ResizeImageKey` 是私有构造、外部构造不出来，且各渲染点的 cacheWidth 随 maxHeight × dpr 变化、无法逐个枚举。`clear()` 本身不清 live 图片——旧切片正显示时旧图仍以 live 条目留在缓存里，重建后旧态卸载、旧图回落 keepAlive，新解析又命中它（回归测试实测证实）；`clearLiveImages()` 只摘掉缓存的追踪回调，不动正在显示的图片本身。副作用是全应用正在显示的图片失去 live 追踪，之后切页回来重新读盘——重框确认 / 切片自愈是偶发操作，可接受。
  - `QuestionSlice._realSliceBody` 与 `CompactSliceThumb` 的 `Image.file` 加 `ValueKey`（文件写盘时间毫秒 + 字节大小，stat 失败回落纯路径）：文件重写后 widget 重建、重新解码。
- 返回值语义不变：仍是裸键是否命中（ResizeImage 加载不填充裸键，返回 false 是正常的；isTrue 语义由 p05 既有测试覆盖）。
- 回归测试 `test/fix_batch1_fr05_slice_cache_test.dart` 2 项：(a) ResizeImage 侧 evict 再读到新图；(b) 同一 QuestionSlice 在同一进程内覆盖写后即时变色（RepaintBoundary 截图读中心像素）。p05 13/13、详情页重框组 5/5 通过。

## D-62 — 最终自审修复批一完成：P1 7 项 + 两项旧账（2026-11-17）

- FR-01（删学科后 kpSubjectId 残留）：`load()`/`deleteSubject` 校验页签、`addChapter`/`addKnowledgePoint` 入口校验学科存在性；回归测试 +4（subjects_notifier_test 14/14）。
- FR-02（角标事件先于错因同步）：三处调用点用 `DataChangeBus.instance.scope()` 包 save + syncCauseRecords（confirmCurrent 再加 saveRecentTask）；新测试 fix_batch1_fr02 3/3，修法前失败探针已做。
- FR-03（重叠框标红 + 横幅点名）：重叠框标红（errInk）+ 横幅按“题级框 N”点名，新文案不含“有框重叠了，”前缀；回归测试并入 collect_page_test 修框编辑器组 1 项。**本项即 Meng 17:02 待加功能第 1 项的本体，十二批第 1 项修完只剩核对。**
- FR-04（重框禁画新框，选 (a)）：`_onDrawStart` + 右键 `onPointerDown` 两道拦，提示改写；回归测试并入 detail_page_test 重框组 1 项，修法前失败探针已做。遗留边角：重框下删掉唯一框后只能点「恢复自动框」或取消（详情页有 `至少保留一个题级框` 兜底）。
- FR-05（重框后旧切片滞留）：选型见 D-61（evict 全清 + ValueKey）；新测试 fix_batch1_fr05 2/2；p05 13/13、详情页重框组 5/5。
- FR-06（孤儿清理信任过期扫描）：删除前重算引用（`skippedReferencedCount`）、恢复成功后置空重扫；新测试 fix_batch1_fr06 3/3；p3/b2 44/44、settings 26/26。
- FR-07（备份 JSON 列损坏值）：校验层加 9 列形状检查，`''`/`null` → 空集合的 D-51 口径不变；新测试 fix_batch1_fr07 8/8；b3/p1 31/31。附带：s8b4 种子 queue 写成字符串数组 `'["q-math-1"]'`（应用从未写过这种形状），改为规范值 `'[{"q":"q-math-1","c":"计算错误"}]'`。
- SR2-29（报告分布扣已掌握，D-59）、SR2-40（紧凑行不设行号、大卡片蓝圆盘保留，D-60）：亲手核对代码属实，只记决策，不改代码。
- 验收：串行全量 **1289/1289**（1267 基线 + 新增 22，9 分 44 秒，日志 `~/workspace/final-review/fix-batch1-full2.log`）；`flutter analyze` No issues found；`dart format` 本批改动文件干净；schema 测试 1/1（17 条 DDL 逐字一致）；演示库 md5 前后不变（`8f7f9c64…`，FR-45 本批未咬人）；Linux Release 构建通过（包内含 `libsqlite3.so`）。
- 批报告 `~/workspace/final-review/FIX-BATCH-1.md`。未推代码、未发邮件；四批合并不久一次推，等 Meng 批准。

## D-63 — FR-23 布尔列口径：按 DDL 实际 5 列，不按报告的 6 列（2026-11-17，批二）

- 报告（W2-06）称 questions 有“6 个布尔列”，但 DDL（`lib/data/db_schema.dart` questions 表）实际只有 5 个：is_organized、is_demo、is_favorite、is_archived、review_joined。`_validateBackupRowDomains` 按实际 5 列做白名单；多出来的第 6 列不存在，无从校验。写进批报告。

## D-64 — FR-28 复核口径：不用 `_referencedRelativePaths`，只查库行直接引用的 4 列（2026-11-17，批二）

- 任务书字面是“复用孤儿扫描口径 `_referencedRelativePaths` + 存在性检查”。但 `_referencedRelativePaths` 除 4 列直接引用外，另有两类派生保护：任务的 `page-normalized.png` 与 `pages/` 下页图（“有行即保护”、文件本身未必存在）。直接做存在性检查会把未渲染过的任务也判为缺失，让每次失败恢复都报“回滚后复核未通过”。
- 改用新 helper `_missingReferencedFiles`，只查库行直接引用的 4 列（questions 的 source_path/page_image_path/slice_path + collect_tasks.source_path），与孤儿扫描的列相同、去掉派生保护。偏差与理由写进批报告。

## D-65 — FR-28 复核范围限定：只在切换已开始时核（2026-11-17，批二）

- `fileRollbackOk == true` 时加 `journal.stage.index >= RestoreStage.filesSwitching.index` 限定。切换前失败（如快照互斥）时文件根本没动过，核它只会用恢复前的旧悬空引用掩盖真正的失败原因。任务书未写此限定，是实现时补的范围收窄，写进批报告。

## D-66 — FR-43 指纹含 mtime：写回相同字节也判已变化（2026-11-17，批二）

- `RestoreFileFingerprint` 按任务书比大小/mtime/哈希三项。重写相同字节会改 mtime，`restoreFileUnchanged` 返回 false——这是按口径的正确行为（宁可误报重选，不可按可能已被换过的文件恢复），不是 bug。指纹测试初版期望“写回相同字节后为 true”，实跑失败后已按此口径修正测试。

## D-67 — FR-45：未定位到肇事测试，加 `test/flutter_test_config.dart` 兜底（2026-11-17，批二）

- 88 个测试文件逐组二分跑完，无一能复现 W7 的演示库 md5 变化；静态上直接碰单例的测试都在 setUp/测试体内先重定向。最可能的肇事是 W7 窗口内并行工作员的 GUI/应用真机运行（应用 `_openDb` 删 v1 演示库重建 v2 的行为与 94,208 → 126,976 字节一致），而非某个测试。
- 加兜底：`test/flutter_test_config.dart` 的 `testExecutable` 在每个测试文件 main() 之前把 `AppDatabase.testDataDirectory` 指到全新临时目录。加之前核对：两处 `setCustomDataDirectory` 测试（b2_leftover_data_test、b5_p2_data_test）都先设 `testMarkerDirectory`；无测试断言 `testDataDirectory` 为 null 或 `dataDirectoryPath()` 等于真实路径；`testDataDirectory = null` 只出现在各文件 `tearDownAll` 收尾。
- 防线只拦测试进程，拦不住 GUI/应用真机运行——跑应用验证仍须用隔离数据目录。最终结论以批末全量 md5 为准，见批报告。

## D-68 — FR-08 共享拼音排序：新文件 `lib/state/subject_sort.dart`（2026-11-17，批三）

- 拼音表（97 条）原在 `wrongbook_notifier.dart`（SR2-32），FR-08 原样移到新文件 `lib/state/subject_sort.dart`，另加三个共享函数：`subjectInitialForName` / `subjectPinyinKeyForName` / `compareSubjectNames`（首字母 → 拼音串 → 原名）。
- 错题本 `subjectInitial` / `subjectPinyinKey` / `subjectKeyCompare` 改为按学科 id 取名后委托；整理页 `_sorted` 改为取学科表（`subjects` 参数，找不到的 id 回退 `Subject.byId`）后调 `compareSubjectNames`，队列弹窗 `_filtered` 同款；整理页旧的顶层 `subjectInitial`（按 id 写死三科）删除。
- 附带发现（不在本批范围，未改）：'学' 不在原表里（SR2-32 的表缺口），'数学' 的拼音串是 'S学'（回退原字），不是 'SX'；但 'W'(0x57) < '学'(0x5B66)，生物仍排在数学前，排序结论不受影响。扩表是另一件事，留待以后。

## D-69 — FR-09 详情页复查间隔：DetailState 带 `recheckIntervalDays`（2026-11-17，批三）

- 未选“页面 watch settingsProvider”：详情页其余文案都不读设置，另起一个订阅不如沿用复习页/报告页“状态里带设置”的做法。`DetailState` 加 `recheckIntervalDays`（默认 7），`load()` 里 `repo.settings()` 一并读库；文案拼 `满 ${_st.recheckIntervalDays} 天自动回来复查`。
- 为让 `load()` 不走真实库，`test/detail_page_test.dart` 与 `test/detail_notifier_test.dart` 的两个 FakeRepo 各加 `settingsValue`（默认 `AppSettings.defaults`）+ `settings()` 桩。

## D-70 — FR-10 复习页元数据行：现拼 `st.subjects`，前 3 科 +“等”（2026-11-17，批三）

- 括号内容由 `st.subjects` 现拼：取前 3 科名用“、”连，超过 3 科加“等”；无学科时不带括号（`列表按学科排，同一科里先加入的先解决`）。未选“去掉括号”（报告给的二选一，选了现拼，信息量不变）。

## D-71 — FR-12 详情页计数：改标“共自查 N 次”（2026-11-17，批三）

- 报告给的二选一（改标“共自查 N 次” / 直接用 `nOk`），选前者：数字仍是 `history.length`（全部自查次数），只改“解决”二字为“自查”，与同行内“自查「已解决」nOk 次”不再自相矛盾。

## D-72 — FR-16 详情页知识点补章节：`学科 › 章节 · 知识点名`，章节为空回落（2026-11-17，批三）

- 与同页编辑芯片同款写法；`chapter` 为空时回落到 `学科 › 知识点名`，不留悬空的“·”（数据损坏时的防御，正常数据章节非空）。

## D-73 — FR-17 错题本已归档标题：无学科时为“已归档 · 错题本”（2026-11-17，批三）

- 报告给的二选一（“已归档 · 错题本” / “错题本”），选前者：与有学科时的“学科 · 错题本”对称，且保留“已归档”信息。注意：书架顶部跨学科已归档视图（`_buildArchived`）标题本来就是硬编码“已归档”，不在 FR-17 范围内，未动。

## D-74 — FR-34 重框确认按钮：重框下为“确认重新框选”（2026-11-17，批三）

- 报告给的二选一（“确认重新框选” / “确认并更新切片”），选前者，与详情页入口文案“重新框选这道题”同词。草稿模式两档文案（“确认修框，去整理”/“拆成 N 个待整理任务”）不动；重框模式的操作说明折叠文本里“确认只点下方「确认修框」按钮”同步改成新按钮名，避免文案与按钮脱节。

## D-75 — FR-35 重叠横幅：已由批一 FR-03 修好，本批只核对验证，不改代码（2026-11-17，批三）

- 核对：`_overlapBannerMessage`（`box_editor.dart`）四种文案均不含“有框重叠了，”前缀（批一 FR-03 写新文案时已去掉，文件内注释亦有“FR-35 到时只剩核对”字样）；标题“框重叠” + 正文“第 N 道题的框叠在一起，请调开再确认。”连读无重复。只加回归测试锁定。

## D-76 — 最终自审修复批三完成：P2 页面与文案 10 项（2026-11-17）

- FR-08/09/10/11/12/16/17/18/34 按报告修法修完，FR-35 核对无重复（不改代码）；每项都有回归测试锁定（见批报告）。
- 新增测试 15 项（fix_batch3 6 项 + organize_notifier 1 + wrongbook_notifier 1 + detail_page 3 + review_page 2 + report_page 1 + wrongbook_page 1），既有测试改断言 3 处（detail_page FR-12、FR-16 各 1 行；organize_page FR-11 1 行）+ 详情页重框确认 5 行（FR-34）。
- 验收：只跑相关测试文件（按 Meng 2026-11-17 19:27 新定，不跑全量、不跑 Linux Release）；`flutter analyze` No issues found；schema 测试 1/1（17 条 DDL 逐字一致）；演示库 md5 前后不变（`8f7f9c64…`）。
- 批报告 `~/workspace/final-review/FIX-BATCH-3.md`。未推代码、未发邮件；四批合并不久一次推，等 Meng 批准。

## D-77 — FR-19：5 个页 Provider 补 `dependencies: [repositoryProvider]`（2026-11-17，批四）

- 报告给的二选一（补 dependencies / 补覆盖测试），两者都做：home/collect/organize/report/subjects 五处补 `dependencies: [repositoryProvider]`（D-49 同款），另按 detail 模式各补一组“根 Scope + Navigator.push + FakeRepo”回归测试（`test/fix_batch4_fr19_push_scope_test.dart` 5 项，判别信号是 FakeRepo 独有的“假学科 / 假题”）。
- 生产行为零变化：默认值与根组件是同一单例库。`settingsProvider` 与 `badgeCountsProvider` 不补（无嵌套 override，见 W2 审计表）。
- 修法前失败探针已做：临时去掉 homeProvider 的 dependencies 后，home 一项失败；还原后 5/5 通过。

## D-78 — FR-22：`freedBytes` 删除成功后再计入（2026-11-17，批四）

- `deleteOrphanFilesImpl`：先 `lengthSync()` 存局部变量，`await f.delete()` 成功后再 `freed += size`；删失败进空 catch 时 freed 不虚高。单文件失败不阻断整批的既定口径不变。
- 删失败活注：当前环境是 root + overlayfs，权限位拦不住删除、`chattr +i` 不被允许（Operation not permitted），无法稳定注入一次真实删失败；回归测试锁两点——成功路径数字准确（删 123 字节文件 → freedBytes 123）+ 源码顺序（`freed += size` 在 `await f.delete()` 之后，旧 `freed += f.lengthSync()` 已不存在）。

## D-79 — FR-30：删三个死方法 + 修正指南对照表（2026-11-17，批四）

- 删 `AppDatabase.addCauseCheckHistory` / `deleteCauseRecordsForQuestion` / `deleteCauseRecord`（全仓零调用；`syncCauseRecordsIntoImpl` 内部删错因直接写 `db.delete`，不经过它们，删除无连锁）。指南 `A-READING-GUIDE.md` §六两行同步修正：`syncCauseRecords` 单列一行；`ensureCauseRecords` 单列一行并注明 FR-30 已删三者。
- 历史文档（旧报告/计划文档，如 `DB-CHANGE-PLAN.md`、`B3-DELETE-CONFIRM.md`、`P0B2-P0-HARDENING-REPORT.md`）里提及三者的文字是当时状态的历史记录，不改。

## D-80 — FR-31：事件 kind 订阅口径只写注释/指南，不改代码（2026-11-17，批四）

- `lib/data/data_change_events.dart` 头注释 + 指南 §六写明：当前唯一订阅方是 `badgeCountsProvider`、只消费 `badges`；其余四种 kind（questions / subjects / reviewRecords / settings）目前无任何订阅方，是为将来订阅方预留的元数据；将来加订阅方时把该页的刷新时序纳入回归（W2-01 角标竞态的教训）。

## D-81 — FR-32：编解码双实现用对照测试锁定，不抽公共函数（2026-11-17，批四）

- 报告给的二选一（抽公共纯函数 / 加对照测试），选后者（推荐②）：`converters.dart` 是 part 库私有、抽公共函数需解除 part 私有性，改动面大；对照测试 `test/fix_batch4_test.dart` FR-32 组 4 项——同一批边界输入（空串、`[]`、非法 JSON、非字符串元素、缺键项、浮点旋转角等）同时过 `decode*` 与 `*Converter.fromSql`，断言结果相等；编码一侧也对照（空列表写 `'[]'`）。

## D-82 — FR-36：整理页批量删除与错题本同款逐题容错（2026-11-17，批四）

- `OrganizeNotifier.batchDeleteQuestions` 返回 `({int ok, int missing, int failed, Set<String> deletedIds})`：每题先 `repo.questionById` 查库（已不在库里计 missing）、删成功计 ok、抛错计 failed 继续下一题；页面 `_batchDelete` 只去掉 `deletedIds` 里的题，并用 `batchResultMessage('删除', ok, missing, failed)` 提示（为此 organize_page import 了 `wrongbook_notifier.dart` 的 `batchResultMessage`，无循环 import）。
- 注意：整理页仍是逐题删除（每题各自一个事务），与错题本 FR-37 的整批事务不同——整理页保留逐题容错语义（中途失败其余题继续删），错题本改成要么全成、要么全不成。两处口径不同是有意的，见 D-83。

## D-83 — FR-37：错题本批量删除整批一个事务（2026-11-17，批四）

- Meng 裁决口径 (b) 数据层加批量删题事务：新增 `deleteQuestionsBatchFromImpl`（先收各题切片路径 → 一次事务内逐题 `_deleteQuestionTxn` → 提交后逐个删独占切片，中途失败整批回滚）+ `AppDatabase.deleteQuestionsBatch`（成功后只发一个合并事件，多题故 questionId 为空；空批直接返回、不发事件）+ `QuestionRepository.deleteQuestions`；`WrongbookNotifier.batchDeleteConfirmed` 改为一次调 `deleteQuestions`，整体成功 okN 全计、整体失败 failed 全计（missing 仍先在 state 里按 `questionById` 分出）。指南 §六补 `deleteQuestions` 一行。
- 旧的逐题 try/catch + scope 包循环不再用于批量删除；单题删除 `repo.delete` 不变。

## D-84 — FR-38/FR-39：考试事件单条改动走原始 JSON 行 + 同一事务（2026-11-17，批四）

- 新增 `mutateExamEventsRawIntoImpl`（`db_settings.dart`）：读原始 JSON 数组 → 改动函数只改目标行（按 id 匹配的 Map）→ 写回，读-改-写回在同一个 `db.transaction` 内（Drift 同一连接上的事务串行执行，并发写不再交错丢改动，FR-38）；未知/坏行原样保留随新数组写回（FR-39，读时跳过是“读时容忍”，写时不再清掉）。整段 JSON 不是数组或非法 JSON 时按空列表起步（与读侧坏 JSON 按空列表口径一致；整段已坏到无法解析时无行可保留）。
- `QuestionRepository.saveExamEvent` / `deleteExamEvent` 改走新入口（经 `AppDatabase.saveExamEventFrom` / `deleteExamEventFrom`，成功后发一次 `{settings}` 事件）；整表替换的 `saveExamEvents` / `saveExamEventsInto` 保留（批量整体替换口径，单条增删改不再走它）。指南 §六对应行同步改口径。
- 修法前失败探针已做：临时探针按旧写法（load → 改 → saveExamEventsInto）并发新增两场，丢一场；新入口同款并发三操作（新增两场 + 删一场）全生效（探针文件已删）。

## D-85 — FR-15 修法修正：弹窗控制器改字段持有，不立即 dispose（2026-11-17，批四）

- 报告建议是“showDialog await 返回后 dispose”，按字面实现后实测失败：showDialog 的 future 在 `didComplete` 时就完成（SDK 源码：`Route.didComplete` 在退出动画之前完成 `_popCompleter`），退出动画仍在重建 TextField，立即 dispose 会抛 “A TextEditingController was used after being disposed”（`_AnimatedState.didUpdateWidget` → `addListener`），且泄漏出的框架异常会毒化后续测试（错题本页测试一度连锁失败 22 项）。
- 改为字段持有：详情页 `_askTextCtrl` / `_newKpNameCtrl`、错题本页 `_batchAddTagCtrl`，下次打开同种弹窗时先释放上一个（此时上一个弹窗早已完全关闭——弹窗是模态的，按钮要等退出动画结束才能再点到），页面 dispose 时释放最后一个。`Route.popped` 同样在动画前完成，不能用来等动画结束，故不用它。
- 附带修（批三遗留，批四验收时发现）：批三 FR-09 让 `DetailNotifier.load()` 多读 `repo.settings()`，但 `test/detail_push_scope_regression_test.dart` 的 `MechFakeRepo` 没补桩，3 项全失败（`loading` 一直 true）；按批三同款给该 FakeRepo 补 `settings()` 返回 `AppSettings.defaults`。这是测试桩补漏，不改产品代码、不动批三的项。

## D-86 — 批四完成（2026-11-17，P2 代码卫生与防御 12 项）

- 12 项全部实现并验收：相关测试 23 个文件 546/546（`--concurrency=1`，约 210 秒），`flutter analyze` 0，schema 测试 1/1，演示库 md5 前后均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`。新增测试 34 项：fix_batch4_test 22、fr19 推送范围测试 5、organize_notifier FR-36 组 3、wrongbook_notifier FR-37 组 3、organize_page FR-36 控件测试 1；另 detail_push 测试文件仅补桩、无新增测试。
- 本批验收中途曾出现 25 项失败（错题本页 22 + detail_push 3），全部定位并修复后复跑全过：① FR-37 改入口后错题本页 FakeRepo 未跟进 `deleteQuestions` 桩；② FR-15 按报告字面“await 后立即 dispose”实测错误（见 D-85）；③ detail_push 的 MechFakeRepo 缺 `settings()` 桩（批三 FR-09 遗留，见 D-85）。
- FR-36 与 FR-37 语义刻意不同：整理页批量删除保留逐题容错（删坏的留下、其余继续、汇总报数），错题本批量删除改整批事务（中途失败整批回滚）。两处入口不同，互不冲突。
- 未推代码、未发邮件。批报告：`~/workspace/final-review/FIX-BATCH-4.md`，测试日志：`~/workspace/final-review/fix-batch4-relevant-tests.log`。

## D-87 — FR-34 定性：重框改名是通用改名，收集页重框测试期望滞后（2026-11-17，门禁失败修复）

- 自审报告 FR-34（W4-01）原文说的是“重框模式确认按钮文案误导”，未限定详情页；D-74 记“重框模式为‘确认重新框选’，草稿模式两档文案不动”——`box_editor.dart:922` 的 `confirmLabel` 本就是按 `mode` 分支，不是按页面分支；批三回归测试已锁“重框 1 框 → 新文案、草稿 1 框 → 旧文案”。故收集页重框模式同样适用新文案，批三改共享编辑器没有改过界。
- 批三漏改的只是测试：`test/b5_p2_collect_test.dart` 的 `_openEditorDialog` / `_tapConfirm` 两个共享 helper 仍按旧文案前缀“确认修框”找按钮（重框新文案“确认重新框选”不含该前缀），4 项重框测试（SR-P2-20 ×2、SR3-13 ×2）因此找不到按钮。本批只改测试：helper 改模式感知（`_confirmFinder(mode)`：重框精确匹配“确认重新框选”，草稿仍按“确认修框”前缀），4 处重框点按 + 1 处草稿点按显式传 mode；草稿模式断言（259/295/511/922 行等）全部保留原样。产品代码不动。
- SR-P2-3 详情页重框用例另含一处同类滞后点按（`find.text('确认修框，去整理')` → “确认重新框选”），随 D-88 的桩修复一并改（该用例门禁失败主因是桩缺失，见 D-88）。

## D-88 — 18 项 pumpAndSettle 超时定性：FakeRepo 缺 `settings()` 桩，非产品回归（2026-11-17，门禁失败修复）

- 根因链：批三 FR-09 让 `DetailNotifier.load()` 多读 `repo.settings()`（`detail_notifier.dart:310`）；`test/b5_p2_collect_test.dart` 的 `_DetailFakeRepo`（5 项）、`test/b11_8_export_image_test.dart` 的 `FakeExportRepo`（12 项）、`test/b8_1_subject_sweep_test.dart` 的 `_SweepDetailRepo`（1 项）均未覆写 `settings()`，落到基类 `QuestionRepository.settings() => _db.loadSettings()`，读真实 Drift 库，在测试 fake async 里永不完成 → `loading` 一直 true → `CircularProgressIndicator` 无限动画拖死 `pumpAndSettle`。三处超时的失败点全在首 pump（b5 `_pumpDetail:1423`、b11_8 `pumpExportDetail:179`、b8_1 `_pumpPage:83`），与 FR-15 无关——FR-15 的字段持有控制器只在弹窗打开后才创建，超时发生时弹窗尚未打开，故 (b) 排除；b8_1 同文件内已补桩的报告/复习 FakeRepo 均通过，是反证。
- 不是产品回归：生产环境 `settings()` 读真实库可完成；`load()` 无 try/catch 是全部 repo 调用共有的既有模式（任一读库抛错都会停在 loading），不在本批修范围；若要给 `load()` 加失败兜底（抛错时退回默认间隔、不一直 loading），另立项由 Meng 定。
- 修法：三处 FakeRepo 各补 `Future<AppSettings> settings() async => AppSettings.defaults;`（与 `detail_page_test` / `detail_push_scope_regression_test` / FR-19 测试同款，D-85 同类先例：批四验收时 `MechFakeRepo` 同样缺桩，同样只补桩）。产品代码不动；未用 `pump(Duration…)` 绕过超时。

## D-89 — GPT 关口审 P1 修复：备份恢复 TOCTOU，校验字节与导入字节同一份（2026-11-17）

- GPT 门禁 FAIL 的唯一阻断项：FR-43 备份恢复里指纹校验与实际恢复是两次独立读文件（`parseRestoreFile` 算指纹 → `restoreFileUnchanged` 重读核对 → `importBackupZipFile` 按路径重读恢复）；校验与恢复之间文件被换，恢复的就是用户没确认过的另一份备份，而恢复会覆盖现有数据库。定性 P1 成立（触发虽窄——个人电脑上需外部换文件，但后果是整库被换）。
- 修法：解析时读到的完整字节一路带到确认恢复，恢复直接用这份字节，不再按路径重读。删 `RestoreFileFingerprint` 类与 `restoreFileUnchanged()`（指纹重查本身就是 TOCTOU 窗口）；删按路径重读的入口 `AppDatabase.importBackupZipFile` 与 `QuestionRepository.importBackupZipFile`（危险 API 不留）；设置页 `_restoreZipPath` / `_restoreFingerprint` 合并为 `_restoreZipBytes` 常驻内存。确认后“文件已变化请重新选择”的提示随之取消——文件被换后恢复照常用解析过的字节。
- 代价：zip 字节在选好到确认期间常驻内存（解析时已读过一次、确认弹窗模态短时持有，可接受）。
- 新增回归测试 3 项（`test/fix_gpt_p1_toctou_test.dart`，A/B 两份真导出备份）：确认前文件被换仍恢复解析过的 A；确认前文件被删仍照常恢复；解析出的题数与备份一致。旧测试同步更新：删“按路径重读失败”与指纹测试，改“解析返回文件本身字节”与“恢复分发走字节”。
- 验收：相关测试 20/20 + 131/131 + 59/59，`flutter analyze` 0，全量串行 **1362/1362**（1360 + 3 − 1，9 分 43 秒，日志 `~/workspace/final-review/fix-gpt-p1-full2.log`），演示库 md5 不变。未推代码、未发邮件。
- 环境插曲：首遍全量跑到 +1183（0 失败）时被 SIGTERM 中断，系 VM 重启清空 /usr 下 clang 与 ninja；恢复脚本两次在拉 Ubuntu 索引时断流（urllib 一次性读大流），变通为 curl 拉三个索引 + 本地闭包脚本恢复（`/tmp/restore-from-local.py`），clang 18.1.3 等均已验证可用。恢复脚本的索引拉取宜改 curl + retry，是否改由 Meng 定。
- 批报告：`~/workspace/final-review/FIX-GPT-P1.md`。

## D-90 — 十二批第 1 项：FR-03 核验全过，功能 1 不再单独实现（2026-11-17）

- GPT 咨询回复 §2.1 的 5 个检查点逐项核验（测试 + 代码检查），全部通过：(1) 拖动/缩放时红色实时刷新——`_moveBox`/`_resizeBox` 都走 `_replaceBox` → `setState` → build 现算 `_overlappingBoxIds`/`_anyOverlap`，无缓存状态；(2) 拖开后红色消失；(3) 三框重叠三道都红；(4) 取消重进后重叠状态重新算出——两个 getter 每次 build 现算，`initState` 从草稿框重建，无残留；(5) 横幅与框状态一致——显隐用 `_anyOverlap`（全部页）、文案用 `_overlappingBoxIds`（当前页）。
- 新增核验测试 4 项（`test/collect_page_test.dart`“修框编辑器”组 + `redOverlapBorders()` helper），产品代码零改动。验收：新 4 项 4/4；`collect_page_test.dart` + `fix_batch3_test.dart` 53/53；`flutter analyze` 0。
- 结论：功能 1（重叠框标红）与 FR-03 基本重复，FR-03 即本体，不再单独实现。十二批第 1 项关闭。
- 测试写法坑（已修正，均非产品问题）：① 框 id 是持久化 id（含随机 uuid8），缩放柄 key 须按前缀找；② 横幅出现会重排画布、页重 fit，后续画框起笔几何须按新布局重算 origin；③ 向上拖画框会与滚动视图抢手势，向下拖可靠。
- 环境：核验中途 VM 重启清 /usr 工具链，恢复脚本 urllib 索引断流老问题复现，用 curl 断点续传拉索引 + 本地闭包脚本恢复（`~/workspace/batch12-work/restore-from-local.py`）；ninja 被覆回 Ubuntu 1.11.1（同款漂移，已验证无影响）。
- 报告：`~/workspace/batch12-work/FR03-VERIFY.md`。

## D-91 — 十二批共享迁移 v2→v3 + 功能 7 重试设计（2026-11-17 深夜）

- 十二批第 2、3 项共用一次 schema 升级，先做迁移再并行两项。`AppDatabase.schemaVersion` 2 → 3：新表 `recently_viewed_questions(question_id TEXT PRIMARY KEY, viewed_at INTEGER NOT NULL)`（功能 4 用）；`collect_tasks` 新增可空列 `source_hash TEXT`（功能 7 重试指纹用，SHA-256）。
- v2 库不再删除：`deleteLegacyDatabaseIfPresent` 只删 `user_version < 2`（v1）；v2 文件走 Drift `onUpgrade` 2→3 迁移，数据全保留；`from > 3` 仍抛“请用新版打开”。迁移后 settings.schemaVersion 写回 3，与 user_version 一致（onUpgrade 内补写——真实 v2 库 settings 本来就有这行）。
- 迁移 DDL 必须与 `createTablesImpl` 的手写字面量一字不差（B1 纪律：迁移后库与全新 v3 库 sqlite_master 逐字一致）。Drift 的 `m.createTable` / `m.addColumn` 生成带引号的 DDL（`"source_hash" TEXT NULL`、`CREATE TABLE "recently_viewed_questions"...`），与手写文本不一致，故 onUpgrade 改走 `m.database.customStatement`，用同一份手写字面量（`CREATE TABLE recently_viewed_questions(...)` + `ALTER TABLE collect_tasks ADD COLUMN source_hash TEXT`）；`Migrator` 本身无 `customStatement`，须经 `m.database`。`_upsertSettingInto` 是 database.dart 库私有，quiz_database.dart 是独立 library 不可见，settings 写回改走 cast 后 `(attachedDatabase as QuizDatabase)` 的 Drift 类型化写入。
- 备份互通：`validateBackupDataImpl` 接受 schemaVersion 2 与 3（v2 备份恢复进 v3：新表缺键视为空、`source_hash` 缺列为 NULL）；< 2 与 > 3 拒绝。必需表检查按版本分流（`backupTablesV2` 13 表 / `backupTables` 14 表）。v2 备份恢复后 settings.schemaVersion 写回 3（`_writeMetaSettingsInto` 用 `AppDatabase.schemaVersion`）。
- 启动恢复 `backfillInterruptedImportsIntoImpl`（`db_collect.dart`，onBeforeOpen 与 B9-1 回填同批跑）：启动时 `importing` 行必是崩溃/杀进程残留 → 置 failed，原因“上次导入被中断，请重试”，progress 0；单条 UPDATE，幂等；其它状态不动。
- `CollectTask` 增可空字段 `sourceHash`（`_collectTaskFromDb` / update+insert companion 全列写回——凡重建 `CollectTask` 处须把 `sourceHash` 带上，否则写回会抹掉哈希）。
- 验收（迁移部分）：`test/b12_schema_v3_migration_test.dart` 新 4 项（v2 库迁移数据全保留、迁移后 DDL 与全新 v3 库逐字一致、v1 仍删、启动恢复幂等）+ `b1_stage1_schema_test.dart`（v3：18 条 DDL 逐字一致）+ `p1_schema_backup_test.dart`（v3 导出 14 表、v2 备份恢复、>3 拒绝、sv=1/非整数拒绝）共 27/27；`flutter analyze` 0。
- 功能 7 重试设计（实现待做）：同一任务身份原地重试——`retryFromStoredOriginal` 改为复用同一任务行/id（B2 旧语义“建新任务行、旧失败行保留”与 GPT“同一任务身份”要求冲突，故改）；校验：状态须 failed（否则 StateError 拒绝）；in-flight 幂等用 `Map<String, Future<CollectTask>> _retryInFlight`（二次并发调用 await 同一 future，管线只跑一次）；原文件 0 个/多个 → 按现行 `_failAndClean` 文案失败；指纹：重算库内原文件 SHA-256 与存的 `task.sourceHash` 比对，不一致 → “原文件已被替换或改动，请重新提供原文件再导入”并清 sourcePath；NULL 存哈希（v2 旧行）跳过比对。重置行（同 id、progress 0、error 清空，createdAt/name/fileName/subjectId/sourcePath/sourceHash 保留）→ 防御性清 stale 派生文件（`pages/`、`page-normalized.png`）→ 按扩展名分发进现有管线（PDF 走已按 id 参数化的 `_importPdf`；图片分支从 `enqueue` 抽 `_importImage` 纯重构）。`enqueue` 改：原文件拷进任务目录后算哈希存行。Notifier 加 `CollectNotifier.retryFailedTask(task)`（单任务重试中标志、按钮禁用、StateError 走现有 snack）；收集页失败行加“重试”按钮。回归测试覆盖 GPT 8 点：同 id 保留、原文件删、原文件换、多个原文件、并发双重试只跑一次、非法重试拒绝、再失败仍可重试、崩溃恢复、成功后重试拒绝。
- 功能 4 首页历史设计（实现待做）：新 part 文件 `lib/data/db_recently_viewed.dart`（`recordQuestionViewedIntoImpl` upsert + 剪到最新 30 条；`recentlyViewedQuestionsIntoImpl` 联表跳过已删题、最新在前、上限 30）；记录点 `DetailNotifier.load()` 成功后（try/catch 包住，绝不拖垮详情加载）；首页学科行下方“最近查看”区，最多 30 行（标题、学科名、最后查看时间：今天/昨天 HH:mm、其余 MM-dd HH:mm），点进详情；空时整区隐藏。

## D-93 — 十二批功能 4 首页历史实现（2026-11-17 深夜）

- 按 D-91 设计实现，未改迁移（schemaVersion 3、新表已建好，直接用）。口径 Meng 2026-11-17 22:44 定：最近查看的题、最近 30 道、每条带最后一次浏览时间+日期。
- 数据层：新 part 文件 `lib/data/db_recently_viewed.dart`；`recordQuestionViewedIntoImpl` upsert + 同一事务内剪到最新 30 条（常量 `recentlyViewedMaxEntries = 30`）；`recentlyViewedQuestionsIntoImpl` 内联 questions（已删题跳过）、最新在前、上限 30；`AppDatabase` 静态转发 + extension 包装；仓库新增 `recordQuestionViewed` / `recentlyViewedQuestions`（返回 `List<({Question question, DateTime viewedAt})>`）。
- 记录点：`DetailNotifier.load()` 成功后（try/catch 包住，记录失败不拖垮详情加载；题不存在不记）；同题防重 `_lastViewRecordedId`（收藏/编辑保存后的重读、首查与显式 load 的重合不重复记；标志位在 await 前先置，防两路 load 并发各记一次；失败清标志、下次再试）。
- 首页：`HomeState.history`（`load()` 第 8 路）；学科行下方“最近查看”区，最多 30 行紧凑行（标题、学科名、最后查看时间）；时间格式 `formatRecentlyViewedTime`（纯函数，不引 intl）：今天/昨天 HH:mm、同年 MM-dd HH:mm、跨年 yyyy-MM-dd HH:mm；空时整区隐藏；已归档/已掌握照常显示；点行经 `onOpenDetail` 进详情（app.dart 接 `_openDetail`，sourceLabel '首页'，orderIds 为历史列表顺序，上一题/下一题按它走）。
- FakeRepo 补桩 13 处（D-88）：新 repo 方法须给全部走到首页/详情加载的 FakeRepo 补桩，否则基类读真实库、fake async 永不完成。
- 验收：新测试 20/20（`b12_history_data_test` 8、`b12_history_home_test` 8、`b12_history_detail_test` 4）；受影响既有测试 13 个文件 194/194；`flutter analyze` 0。统筹复核：新 3 文件 20/20 重跑通过，analyze 0。
- 已知局限（另立项，不在本批修）：详情页是 Navigator 压栈，首页仍挂载、homeProvider（autoDispose）不重建，从详情返回首页时刚看过的题不会立刻顶到首位，要等下次回页才刷新。修法是 homeProvider 订阅 DataChangeBus + 记录成功后发变更事件（Stage 4 模式），属跨页刷新机制。

## D-94 — 首页历史返回刷新小尾巴：十二批最后顺便修（Meng 2026-11-18 00:20 定）

- 问题（D-93 已知局限）：详情页是 Navigator 压栈，首页仍挂载、homeProvider（autoDispose）不重建，从详情返回首页时刚看过的题不会立刻顶到“最近查看”首位，要等下次回页才刷新。
- Meng 拍板：十二批四项全部做完之后顺便修，放在全量测试之前做，不另立项、不拖到十三批。
- 修法（STATUS.md 已写明，沿用 Stage 4 模式）：homeProvider 订阅 DataChangeBus，记录一次查看成功后发变更事件，首页收到事件重读历史。
- 回归测试：记录一次查看 → 返回首页 → 历史刷新（刚看的题顶到首位）。测试基线随修完后的新增测试数更新。
- 本项与第 2–4 项一起进 GPT 关口审（`gpt-review-batch12.md`）与推送。

## D-92 — 十二批功能 7 失败任务重试入口实现（2026-11-17 深夜）

- `retryFromStoredOriginal` 改为同一任务行/id 原地重试，B2 旧语义“建新任务行、旧失败行保留”废弃（与 GPT“同一任务身份”要求冲突）；状态须 failed，否则 `StateError`（“只有导入失败的任务可以重试”）。
- in-flight 幂等：`Map<String, Future<CollectTask>> _retryInFlight`，二次并发调用 await 同一 future，管线只跑一次，完成后摘掉（不只靠 UI 禁用）。
- 原文件定位沿用 `locateStoredOriginals`：0 个/多个按现行 `_failAndClean` 文案失败。恰好 1 个时算 SHA-256 与 `task.sourceHash` 比对：不一致 → “原文件已被替换或改动，请重新提供原文件再导入”并清 `sourcePath`；`sourceHash` 为 NULL（v2 旧行）或算不出哈希时跳过比对。
- 比对通过后重置行（同 id、progress 0、error 清空，其余保留）→ 防御性清 stale 派生文件（抽成 `_deleteDerivedFiles`，与 `_failAndClean` 共用）→ 按扩展名分发（PDF 走 `_importPdf`，图片走从 `enqueue` 原样抽出的 `_importImage` 纯重构）。
- `enqueue`：原文件拷进任务目录后算哈希存进持久化行。`_failed`、`_updateProgress`、`_importPdf`/`_importImage` 成功行、立即持久化行全部带上 `sourceHash`（全列写回，缺一个就会抹哈希——尤其是 `_updateProgress`，渲染中途多次写库）。`_failAndClean` 加可选 `sourcePath` 覆盖参数（指纹不一致时传 `''` 清引用）。
- Notifier：`CollectState.retryingTaskIds` + `retryFailedTask(task)`（返回 `({CollectTask? task, String? error})`；非法重试与异常走 error 文案，成功/再失败都重读）；另补 `importFiles` 进度回调与 `confirmSplit` 保留任务重建点的 `sourceHash`。
- UI：收集页失败行加“重试”按钮（重试中禁用；成功后随状态消失；再失败行上显示新原因、仍可重试）。
- 验收：新 `test/b12_retry_failed_task_test.dart` 17 项（enqueue 存哈希 PDF/图片、同 id 保留、原文件删/换/多、并发双重试只跑一次、非法重试拒绝、再失败仍可重试、成功后重试拒绝、图片重试、NULL 跳过、Notifier 三项、收集页两项）+ 回归 6 文件 102 项，全过；`flutter analyze` 0。统筹复核：新 17 + 回归 102 共 119/119 重跑通过，analyze 0。旧语义测试“旧失败行保留”按 D-91 改为同 id 原地。
- 教训（测试期发现）：① `Future.whenComplete` 派生的 future 同样带原错误——`StateError` 已被调用方 await 到并处理，派生 future 无人接会变成未处理异步错误、测试多报一个错；已用 `.then(onError: (_) {})` + `unawaited` 显式吃掉。② widget 测试真库限制：testWidgets 的 fake 异步区里 Drift 查询不完成（Notifier 的 `load()` 读真库会让页面一直空列表、`pumpAndSettle` 可能 hang）；仓库先例是一律 FakeRepo 泵页面，真库操作包进 `tester.runAsync`；二次 `pumpWidget` 同型复用元素树、不重建 ProviderScope/notifier，重进页面验证需先泵占位 widget 卸掉旧 scope。

## D-95 — 十二批功能 8 Stage A 离线验证通过，第 1 轮即过（2026-11-18 凌晨）

- 验证集 37 页（单栏 5 / 双栏 12 / 三栏 11 / 拼版 5 / 边界 4；原 39 页，collage-04/07 是答案页，Meng 2026-11-18 00:55 定剔除）。检测：生产 YOLO 第 1 层（`tool/stage_a_detect.dart`），39 页 0 fallback，共 333 框（验证集 319 框）。标注：统筹逐页视觉判断，37 个 truth JSON（order 只含题内容框；纯标题/指令行/公式表误检框排除；延续框紧跟题干）。
- 计数口径：题序指标只在“框齐全页”（detection_complete=true 且 ≥2 题框）上算，共 30 页；检测问题（漏检/误检/重叠）单列统计，不混进题序率。检测问题：漏检 10 道（collage-02 3、collage-03 1、collage-06 3、edge-03 2、triple-08 1）、误检 13 框（框齐全页 8 + 检测不全页 5）、重叠 6 对、合并框 ≥11。edge-03 漏检数 discrepancy 待 Meng 确认（他说 1 道，图上 Q2/Q3 两道未框）。
- 跨栏题定义（Meng 2026-11-18 01:02 纠正、01:04 确认）：不是横占两栏，是题的组成部分分在两栏（题干左/选项右、AB 左/CD 右、整题左/配图右，另有大题小问分栏、材料左/问题右、题干断开续写、题干右/配图左、表格与问题分栏、选项两列按行读；跨页题另算）；位置按题干开头定，其他部分不单独占排序位置。三栏实测唯一跨栏现象是“整题左/配图右”3 例（triple-01 Q8、triple-04 Q9、triple-06 Q10，题干与配图是分开的两个框，配图框紧跟题干）。第 4 类（题干右、配图左）0 例，纯几何处理不了，记为 Stage B 已知局限。
- 算法（独立脚本 `stage-a/xy_cut.py`，不进应用）：栏检测（x 投影 + 区间链接交叉校验）→ 栏内递归 XY-cut → 低置信度退化人工。校准：第一版回退一律低置信度 + 中心聚类校验，转人工 16/30（53%）；诊断后修正两处（区间链接替代中心聚类；回退仅在上缘近 tie <0.008 且 x 重叠 >50% 时才标低置信度；最小切分间隙 0.002→0.0005）→ 转人工 0/30，exact 保持 30/30。参数灵敏度：MIN_GAP_W 0.002–0.004、MAX_COVER 0.05 时稳定 30/30。
- 指标（30 页）：全页完全正确率 30/30 = 100%（≥90% 通过），相邻顺序准确率 1.000，错误自动排序率 0%，转人工率 0%。基线：朴素 y-then-x（当前生产顺序）8/30；栏检测 + 栏内 y 排序 30/30——与 XY-cut 并列。真正修掉触发 bug 的是栏检测；XY-cut 的价值在栏内不规则排布（本样本零实例）与置信度机制。Stage B 仍用 XY-cut 混合。
- 局限：样本全是规则版式，栏内并排/交错零实例，0% 转人工率不推广；第 4 类跨栏零实例；跨页题不在本批；检测问题独立于题序但真实使用时会叠加；含糊阈值 0.008 贴近样本边界（最小上缘差 0.010，阈值 0.012 时转人工 2/30）。
- 按 Meng 2026-11-17 23:27 循环规则：第 1 轮即过，直接做 Stage B，不咨询 GPT。报告 `~/workspace/batch12-work/STAGE-A-REPORT.md`。

## D-96 — 十二批功能 8 Stage B 接入设计：题序动态计算 + XY-cut 混合进生产（2026-11-18 凌晨）

- 目标：把 Stage A 验证过的 XY-cut 混合算法接入应用，替换 `YoloOnnxService._detect` 里朴素的 y-then-x 框顺序。检测仍用现有 YOLO 第 1 层服务，不改检测。
- 新服务 `lib/services/question_order.dart`（纯函数，无 IO）：`QuestionOrder.orderBoxes(List<QuestionBox>)` → `QuestionOrderResult{boxes（阅读顺序）, confidence（high/low）, reasons}`。Stage A 脚本 `stage-a/xy_cut.py` 的 Dart 移植，常量与语义一字不差（MIN_GAP_W 0.004、MAX_COVER 0.05、MIN_CUT_GAP 0.0005、CHAIN_TOL 0.003、AMBIG_TOP 0.008、AMBIG_XOVERLAP 0.5、SPAN_TOL 0.005、BINS 1000；栏检测 x 投影 + 区间链接交叉校验 → 栏内递归 XY-cut → 低置信度退化人工；跨栏块按上缘并回全局 y 排序）。
- §7 五个待定设计问题，逐项定：
  - (1) 题序是持久化字段还是动态计算 → **动态计算，不加字段、不升 schema**（v3 刚落地）。顺序是框几何的纯函数，计算点：检测输出（服务内）、编辑器接检测结果时、编辑器加载草稿时、框集合/几何提交变化时（画完、拖完、缩放完、删框、整页旋转）。冻结边界是确认拆题：confirmSplit 按当时列表顺序生成题（标题“第 N 题”+ 整理队列），题一旦生成，顺序即题的创建顺序，重检测碰不到已确认的题。
  - (2) 人工调序后永不被重检测覆盖 → **本应用没有独立的“人工顺序”状态；人工调序 = 改框几何（画/移/缩放/删），顺序始终跟着几何现算。**重检测（“恢复自动框”）替换的是本页框集合，不是顺序；手动框已有确认弹窗守着（有 manual 框先弹确认），替换后顺序按新框几何重算。重框模式（单题）IoU 认领只换目标框原位，其余框与顺序不动。备选（持久化人工顺序 + 重检测 IoU 合并保留）不做：本批没有手动调序 UI 来表达“人工顺序”这个意图，改动面大；若 Meng 以后要显式调序 UI，另立项。
  - (3) “自动排序过期”与“用户已确认排序” → **没有“过期”状态。**自动排序不缓存，每次用时现算，不存在过期；“已确认”只发生在确认拆题那一刻，之后顺序冻成题的创建顺序。
  - (4) 题序与重试/重检测 → **重试不碰顺序。**重试（功能 7）只重跑导入，检测在修框时才跑；失败任务重试时还没有草稿框，顺序在修框检测时现算。重检测：草稿模式替换本页框 + 顺序重算（手动框有确认弹窗）；重框模式 IoU 认领单题、顺序不动。
  - (5) 低置信度页在收集页的呈现 → **修框编辑器顶部横幅“题序不太确定”，不伪装确定。**置信度按页记在编辑器内存态；低置信度时出警告横幅，框仍按算法顺序编号展示（最优猜测），请用户按题号核对。草稿重进的页置信度同样现算（同一纯函数），不持久化。
- 必须补的一点（否则 Stage B 修复会被重进洗掉）：草稿重读目前按 (page, id) 排序，持久 id 是随机 uuid8——重进编辑器会把检测顺序洗成随机顺序。所以编辑器 init 时必须按几何重排草稿框。
- 旋转注意：检测在原页坐标上跑，`prepareBoxEditor` / `_autoDetectIfEmpty` / `_restoreAutoBoxes` 都在进编辑器前把框转到已旋转的页坐标；服务排的是未旋转页的顺序，编辑器 `_ingestDetected` 必须按旋转后的几何重排一次（同一纯函数），否则转过 90° 的页顺序仍是错的。
- 拖动/缩放过程中只改坐标、不重排（逐帧重排会抖）；松手（onPanEnd/onPanCancel）后按新几何一次排好。
- 诚实说明（Stage A §5.3）：Stage B 仍用 XY-cut 混合（不是只做栏 + y 排序），理由同报告：规则版式等价，不规则版式更一般，置信度机制同一套。0% 转人工率是“本样本 + 0.008 阈值”的结果，不推广；代码注释与 UI 文案都不宣称算法 100% 准确。
- 已知局限（代码注释 + GPT 材料里写明）：第 4 类跨栏（题干右、配图左）本样本 0 例，纯几何发现不了，算法会把配图排到题干前面；遇上只能靠用户在编辑器里手动调框。检测问题（漏检 10 道、误检 13 框、重叠 6 对、合并框 ≥11）是检测的事，不进本题序工作；edge-03 漏检数 discrepancy（Meng 说 1 道、图上 2 道）不动，等 Meng 一句话。
- 实现与验收（待做）：服务内替换排序 + 编辑器五处接线（init / ingest / 画完 / 手势结束 / 删框 / 旋转）+ 低置信度横幅；测试用 Stage A 30 页框 JSON + 真值做夹具（全页顺序逐页比对）+ 低置信度合成用例；D-94 小修由 worker 并行做（见 STATUS.md §5）。

## D-97 — 十二批 D-94 小修：详情返回首页，“最近查看”立刻刷新（2026-11-18 凌晨）

- 修法（Meng 2026-11-18 00:20 定，D-94；Stage 4 模式）：`homeProvider` 订阅 `DataChangeBus`，记录一次查看成功后发变更事件，首页收到事件重读历史。
- 新 kind `DataChangeKind.recentlyViewed`（`lib/data/data_change_events.dart`，专用于“最近查看”写入）：订阅方现为两个——`badgeCountsProvider` 只消费 `badges`，`homeProvider` 只消费 `recentlyViewed`；其余四种 kind（questions / subjects / reviewRecords / settings）仍无订阅方，头注释已同步改准确（原来“唯一订阅方是 badgeCountsProvider”的说法已过期）。
- 发事件点：`AppDatabaseRecentlyViewed.recordQuestionViewed` 扩展方法（`lib/data/db_recently_viewed.dart`），写库成功后发一次 `{recentlyViewed}` + questionId（写后发，不是写前；写库抛错不发）；可单测版 `recordQuestionViewedIntoImpl` 保持纯写库、不发。调用方 `DetailNotifier.load()` 已有 try/catch 包住记录调用，`emit` 本身不抛，订阅回调调 `load()`、`load()` 自己有 try/catch，订阅侧异常不反噬到写库侧。
- 订阅点：`HomeNotifier.build()`（`lib/state/home_provider.dart`），照抄 `badge_counts_provider.dart` 的“先订阅、后首查 + ref.onDispose 取消订阅”模式；收到事件后直接调 `load()` 重读（不用 `ref.invalidateSelf`——那会把 state 重置回 loading、首页闪一下加载卡）；只响应含 `recentlyViewed` 的事件，其余忽略。
- 顺带补齐（新 kind 加入的直接后果，不是扩范围）：备份恢复发的“全部 kind”事件两处（`importBackupJson` / `importBackupZip`，`lib/data/db_backup.dart`）的 kind 集由五类补到六类——恢复覆盖 `recently_viewed_questions` 表，历史也在内，不补则恢复后历史仍不刷新；两处注释“全部五种”→“全部六种”。`docs/ui-replication/A-READING-GUIDE.md` §六同步：FR-31 段改成两个订阅方、对照表加 `recordQuestionViewed` 行（`{recentlyViewed}` + 题 id，仅写库成功后发）、收尾核对段补 D-94 注（`emit` 处现为 34 处，D-94 只新增 1 处，其余是此前批次所加）。
- 验收：新 `test/b12_history_refresh_test.dart` 7/7（数据层 3：写成功发一次含新 kind + questionId、纯写库版不发、写库失败不发；Provider 层 3：收到事件后重读、首位变 B 且不闪 loading、无关 kind 不重读、首查进行中发来的事件不丢失；页面层 1：首页打开 → 真实 `DetailNotifier.load()` 打开题 B 详情 → 返回首页不重进，题 B 顶到首位）。受影响既有测试 8 文件 113/113（b12_history 三文件、home_provider、home_page、stage4_badge、detail_notifier、p1_schema_backup）；`flutter analyze`：本项文件 0 问题，全仓仅剩 1 条既有 warning（`tool/stage_a_detect.dart` 的 `detectTimeoutForTest`，Stage A 工具文件，与本项无关）。
- 测试写法教训（已修正，非产品问题）：Provider 测试须先配好 FakeRepo 再建 container——build 的 microtask 首查可能在 setUp 与测试体之间的 microtask 间隙里跑完，建完容器再配 historyList 的话首查读到空列表；时序测试的卡住点（Completer）同样须在建容器前置好，否则“首查进行中”的场景实际没卡住。
- 测试基线：1407 + 7 = 1414（待统筹全量复核）。

## D-98 — 十二批全量门禁首遍 5 项失败：v3 迁移后旧断言滞后，零产品回归（2026-11-18 凌晨）

- 首遍全量 1424/1429（10 分 01 秒），失败 5 项，全部在 v3 迁移前写死的旧断言上，产品代码零改动（除 2 处注释）：
  1. `s8b4_backup_migration_test.dart`“backupTables 共 13 张”：Expected 13、Actual 14——v3 新表 `recently_viewed_questions` 是第 14 张。修测试：14 张 + containsAll 加新表名。
  2. 同文件“导出的 JSON 含 4 张表的数据 + _meta”：`meta['schemaVersion']` Expected 2、Actual 3——导出盖当前版本戳。修测试：改断言为 `AppDatabase.schemaVersion`（用常量跟踪，不再写死）。
  3. `b3_backup_interop_test.dart`“重导出与黄金夹具对比”：`_meta.schemaVersion` Expected 2（黄金夹具 v2）、Actual 3（重导出盖当前版本）；diff 循环里 v2 黄金夹具缺 `recently_viewed_questions` 键（`null as List` 会抛，失败停在上一行没走到）。修测试：_meta 断言改当前版本；diff 循环缺键按空表算；期望 diff 从 7 处改为 8 处——第 8 处是 `settings/schemaVersion/value: 2 → 3`，即恢复把 settings.schemaVersion 写回当前版本（§2.3 既定行为），黄金夹具（v2）里它是 '2'。
  4. 同文件“现场往返：两次导出除 _meta 外一致”：唯一差异是 settings.schemaVersion（首次导出 '2'、恢复后再导出 '3'）。根因是 `seedRichDb` 把 settings.schemaVersion 写死 '2'（B3 时代的遗留，当时当前版本就是 2），而恢复末尾按 §2.3 写回当前版本。修测试：种子改写 `'${AppDatabase.schemaVersion}'`（模拟当前版本库，永不再滞后）；“新备份 → 旧代码库”组里旧逻辑复刻的写死 '2' 不动（那是旧代码行为的复刻）。
  5. `fix_batch4_test.dart` FR-31 头注释测试：期望含“当前唯一订阅方是 `badgeCountsProvider`”，D-94 后头注释已改写为“订阅方共两个”。修测试：断言改为“订阅方共两个”+ 两订阅方各自消费的 kind；“其余四种 kind 仍无订阅方”与“为将来订阅方预留”两断言仍成立，未动。
- 顺带修的两处产品注释（只改注释，代码不动）：`lib/data/db_backup.dart` 两处“恢复后 settings.schemaVersion 写回 2”已与代码不符（代码写的是 `AppDatabase.schemaVersion`），改为“写回当前版本”。另有一处历史注释（`lib/data/database.dart:248` openForTest 的“B1-Drift：schemaVersion 为 2”）仍是 B1 时代的表述，未动（历史记录，非行为口径）。
- 探针：一次性临时测试确认往返差异只在 settings.schemaVersion 一行（逐表比对，其余 13 张表逐字节一致），探针已删；另确认新鲜内存库 settings 表为空、user_version=3，排除“新库种子错”的可能。
- 修复后 3 个文件复跑全过；`flutter analyze` 本批文件 0 问题；全仓 analyze 剩 1 条 warning（`tool/stage_a_detect.dart` 用 `detectTimeoutForTest`，Stage A 离线工具既有问题）——加 `// ignore: invalid_use_of_visible_for_testing_member` 恢复 0（离线工具故意用测试钩子放宽超时，不进应用、不进全量）。
- 第二遍全量重跑中（日志 `~/workspace/batch12-work/full-suite-b12-2.log`）。
- 第二遍全量（2026-11-18 02:15–02:26，10 分 51 秒）：**1429/1429，All tests passed!**（日志 `full-suite-b12-2.log`；`flutter analyze` 同一命令先跑，No issues found）；演示库 md5 跑后不变；Linux Release 通过。十二批门禁全绿。

## D-99 — GPT 关口审 P1-01 修复：NULL hash / 算不出哈希时拒绝重试（2026-11-18 凌晨）

- GPT 首审 FAIL 的唯一 P1（P1-01）：v2 迁移过来的失败任务 `sourceHash` 为 NULL，重试时旧逻辑跳过 SHA-256 比对直接跑——原文件在任务失败后被替换/改动，用户点重试会用错文件拆题，且看起来是正常成功。GPT 建议：NULL hash 时拒绝原地重试，提示“旧任务缺少原文件校验信息，请重新导入原文件”。
- 修法（只改 `lib/services/import_service.dart` `_retryFromStoredOriginal` 的比对分支，`retryFromStoredOriginal` 的 doc 注释同步改）：
  - `task.sourceHash == null`（v2 旧行，无比对基线）→ 走 `_failAndClean` 拒绝重试，文案一字不改用 GPT 建议原句：“旧任务缺少原文件校验信息，请重新导入原文件”。任务保持 failed 状态，仍在收集页可见，再点重试仍得同一拒绝（有回归测试锁定）。
  - `currentHash == null`（算不出哈希：定位到 1 个候选、但读盘失败）与 NULL hash 是同一类洞——“无法验证”不等于“验证通过”，一并按拒绝处理。文案另写：“原文件暂时读不出来，请重新提供原文件再导入”（基线不是缺的，是现文件读不出来，用 NULL hash 的文案会说错原因）。该分支无确定性测试手段：触发条件是定位与读盘之间的竞态/读盘错误，测试以 root 运行、权限手段无效；未单独立测试——与 NULL hash 分支共用 `_failAndClean` 拒绝通道，仅文案不同，拒绝行为由 NULL hash 的 3 项测试覆盖同款通道。
  - 其余分支不动：hash 不一致仍拒绝 + 清 sourcePath（原句不变）；hash 一致仍正常重试。
- sourcePath 处理（NULL hash / 算不出哈希两种拒绝）：**不清**。理由：两种都是“无法验证”，不是“已证伪”——引用本身没被证明不可信（与指纹不一致不同，那是已证伪才清）。`_failAndClean` 不传 `sourcePath` 覆盖时，文件在就保留引用（`_sourcePathIfFileExists` 校验）；v2 旧行的 sourcePath 指向库内原图（真实存在），拒绝后保留，用户仍能看到原文件来源、重新导入时可凭它找回。原文件本身不动（`_failAndClean` 只清派生文件）。
- Notifier/UI 不用改：service 返回 failed 行带 error，`CollectNotifier.retryFailedTask` 原样返回 `(task: failed行, error: 文案)`，收集页弹 snack 显示该文案、重试按钮仍在（有 Notifier 层测试锁定）。
- 测试变化（`test/b12_retry_failed_task_test.dart` 17→19 项）：
  - 原“NULL hash 跳过比对、重试成功”测试改写为“NULL hash 拒绝重试”：返回 failed、同 id、error 精确等于 GPT 原句；原文件不动、sourcePath 保留；库里行仍 failed、sourceHash 仍 NULL、error 为原句。
  - 新增“NULL hash 拒绝后再次点击仍拒绝”：用库里拒绝后的行再 retry 一次，同样 failed + 同文案、同 id、sourcePath 保留。
  - 新增 Notifier 层“NULL hash 拒绝经 Notifier 返回原句文案、行仍 failed、仍可再点”。
  - hash 正常仍比对通过、hash 不一致仍拒绝已有测试覆盖（同 id 保留 / 原文件被替换），未重复造。
  - 回归时另发现 1 项旧测试撞新语义（`test/b2_import_source_path_test.dart`“恰好一个候选：重试成功”，B2 时代种子行无 sourceHash）：种子行补与库内原图一致的哈希基线（`sha256HexOfFile`，加 `import_guess.dart` 导入），断言不动；该文件其余两项（无文件/多候选）走候选数分支、不受影响。测试数不变。
- 验收：重试相关 13 文件 202/202（b12_retry 19/19 + 12 回归文件 183/183）；`flutter analyze` No issues found；全量一次（日志 `~/workspace/batch12-work/full-suite-b12-p1.log`，10 分 04 秒）：**1432/1432，All tests passed!**，exit 0；演示库 md5 跑后不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前备份 `~/workspace/demo-db-backup/quiz-master2.db.b12-p1-start`）；Linux Release 通过。
- 计数说明：本次全量 1432 = 上一遍日志实测 1430（`full-suite-b12-2.log` 末行 +1430）+ 本次净增 2（b12_retry 17→19）。STATUS.md 与 gpt-review-batch12.md 里写的 1429 是逐项加总时漏计 1 项，与本次改动无关。
- 其余 GPT 未定为 P0/P1 的事项一律未动（Stage A 口径、30 页泛化、动态题序、DDL 手写、事件刷新、并发重试、D-88/B1/zip 遗留）。

## D-100 — 十二批推送 + edge-03 漏检数确认（2026-11-18 上午）

- Meng 08:45 批准推送（批准邮件先发，id `1a1ec1d068eb49f5`）。推送执行员推 164 个文件（3 批：`0d25ebd0` 22 个 lib、`5adcd7e9` 27 个 test、`dea6061d` 115 个文件含决策日志 D-90~D-99、Stage A 离线工具、112 个题序夹具 JSON；修改 41、新增 123），新 head `dea6061dbd7d7b60a277e3840b4ec9f91d719876`（短 `dea6061d`），`git ls-remote` 核对，同步记录 23→26 条。未推：`b3-old-backup.zip`（已知）、662 张截图、3 份架构草稿、14 个 `.sh` 纯权限改动（644→755，内容 0 行）。
- 完成邮件已发（任务汇报，id `1a1ec22ecdf0662c`）；tracked item `goal_471baecf41ff` 已关；30 分钟汇报与 5 分钟看门狗两个定时任务已删。
- edge-03 漏检数 Meng 08:56 确认：**2 道**（Q2 平行板电容器、Q3 电磁感应）。`STAGE-A-REPORT.md` 三处待确认标记已改成已确认；D-95 原文不动（历史记录），以本条为准。
- Win11 复核清单：`~/workspace/batch12-work/WIN11-CHECKLIST-BATCH12.md`（12 项），等 Meng 拉取后验证。
- OCR 尖峰进行中：SimpleTex 接口调研已派调研员；Drive 查核：`test pictures/images/` 50 张 xt_p041–p090 抽查 3 张全是数学（专升本数学严选 800 题），Drive 上无以英语/政治命名的真题照片，英语和政治的尖峰照片仍需 Meng 提供（或先用演示库的题测）。

## D-101 — 十二批 Win11 复核：备份恢复校验器认错主键（2026-11-18）

- 现象：Meng 在 Win11 上备份后立即恢复，报错“这份备份文件已损坏：recently_viewed_questions 表里有行缺少主键 id”。他那份备份本身没坏（schemaVersion 3，含 4 条浏览历史，文件已核查）。
- 根因：`lib/data/db_backup.dart` 的 `_validateBackupRow` 默认所有非整数主键表的主键都叫 `id`；但 `recently_viewed_questions` 的主键是 `question_id`（`db_schema.dart`：`question_id TEXT PRIMARY KEY`），根本没有 `id` 列，导出也是 `{question_id, viewed_at}`。十二批 D-91 加表时只补了导出/必填列/插库分流，没补校验口径；备份里历史为空时无行可校验，所以十二批测试没抓到。
- 修法（只改 `_validateBackupRow` 附近）：新增 `_backupPkColumn`（settings→key，recently_viewed_questions→question_id，其余默认 id）；校验按每张表的真实主键列查，整数表（cause_records、review_history、review_state、recent_tasks）认 id 且缺失允许的原有行为不动；SR2-16 空串拒绝口径落在真实主键列上。报错文案仍是“这份备份文件已损坏：$table 表里有行缺少主键 $pkColumn”（settings 的 key、其余表的 id 文案与原来一字不差）。
- 测试（新增 `test/b12fix_d101_backup_pk_test.dart`，5 项）：(a) 4 条浏览历史的备份往返恢复成功（question_id/viewed_at 全对）；(b) 缺 question_id 的行被拒绝且原库不动；(c) question_id 空串/非字符串被拒绝；(d) 只有 id、没有 question_id 的行仍被拒绝；(e) 空历史备份仍能恢复（修前唯一能过的情形）。另用 Meng 的真实备份文件 `~/workspace/user/files/quiz-master2-backup.qm2backup` 做过一次性验证（临时测试，跑完已删；原文件只读，操作的是 /tmp 下的副本，走 `importBackupZipInto` 整条 zip 恢复链路，4 条历史全数入库）——该文件修好后可直接恢复，不用重备。
- 验收：备份相关 11 个文件 242/242（D-101 新 5 项 + FR-07 8 项 + p1_schema_backup、b3_backup_interop、s8b4/p3 迁移、b2 恢复流/日志、b3_p01、b5_p2_data、settings_controller）。Drift“一个测试里开了两个内存库”的 debug 警告与 FR-07 原文件相同，是既有模式，非本次引入。

## D-102 — 十二批 Win11 复核：重叠横幅挤压画布（2026-11-18）

- 现象：Meng 在 Win11 修框时反馈，重叠框功能本身没问题，但红色“框重叠”提示一弹出来，整个框题部分就缩小，非常影响操作。
- 根因：`lib/modules/collect/box_editor.dart` 里“框重叠”横幅插在画布上方的 Column 流式布局里；横幅出现即挤占画布高度，画布按新可用区重算 fit 缩放，整页看起来缩了一圈，拖框中途反复跳变。
- 修法（只动“框重叠”横幅，其他横幅不动）：
  - 画布 `Expanded` 外包一层 `Stack`，画布本体用 `Positioned.fill` 包 `LayoutBuilder`（拿满 Expanded 的紧约束，和原来一致）；“框重叠”横幅改成 `Positioned(top: 0, left: 0, right: 0)` 悬浮在画布顶部、`margin: EdgeInsets.zero`，不占布局高度，出现/消失时画布尺寸和缩放纹丝不动。
  - 横幅加 ×（`overlap-banner-close`）：点 × 收起成右上角一个 16px 小红点（`overlap-banner-dot`，红底白边圆点，点红点再展开）；重叠消除后经 `addPostFrameCallback` 复位收起状态，下次再重叠默认重新展开。
  - 横幅本体包 `IgnorePointer`，× 是独立的可点按钮：横幅盖在画布顶部只做提示，画布顶部的框仍能正常点/拖。第一轮测试曾因横幅挡住左上角框的拖动导致 B3“左键在框上拖动”失败 1 项，改成 IgnorePointer + 独立 × 后全过。
  - 其他横幅（重新框选、检测不可用、页图损坏、没框到题、题序不太确定）保持原样，仍在上方 Column 流式布局里——它们只在进页时出现，不会在拖框中途冒出来。横幅文案（点名哪几道框重叠）与确认拦截逻辑（重叠时确认仍被拦下）未动。
- 测试（`test/collect_page_test.dart` 新增 1 项 widget 测试）：以 `box-editor-canvas` 的 `tester.getSize` 为基线，依次断言不重叠、拖进重叠、点 × 收起、点红点展开、拖开消除、再拖进重叠时画布尺寸始终等于基线；同时断言横幅点名“第 1、2 道题”、标红 2 框、重叠消除后横幅默认重新展开、确认仍被拦下。`collect_page_test.dart` 52/52。
- 验收：全量一次（日志 `~/workspace/batch12-fix-work/full-suite-b12fix.log`，10 分 26 秒）：**1438/1438**（1432 基线 + D-101 5 项 + 本项 1 项），exit 0；`flutter analyze` 0 issue；演示库 md5 跑后不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，跑前备份 `~/workspace/demo-db-backup/quiz-master2.db.b12fix-start`）。
