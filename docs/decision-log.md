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
