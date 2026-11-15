# B8-1 删学科后残留刷新 + 左导航顺序调整

- 任务：第 8 批第 1 项（Meng Win11 真机验收 image-89 / 90 / 98）。
- 分支：`ui-replication`；未提交、未推送。
- 报告文件：`docs/ui-replication/B8-1-SUBJECT-REFRESH.md`（本文件）。

## 根因

不是缓存、不是通知丢失、不是陈旧快照——是**空表回退预设**，同一行模式在 8 处复制粘贴：

```dart
_subjects = subjects.isEmpty ? Subject.all : subjects;
```

- 新库建表时 `_seed`（`lib/data/db_schema.dart`）已把 `Subject.all`
  （数学/英语/政治）写进 subjects 表并配好每科预置文件夹，所以
  **subjects 表为空只发生在用户删光学科后**。空表是合法状态，
  但这行回退把它当成“库还没建好”，在每个读学科的地方把删掉的三科
  又摆了回来：
  - 左导航速览：`lib/app.dart` `_refreshBadges`
    （`_navSubjects = subjects.isEmpty ? Subject.all : subjects`），
    外加首帧初始值 `_navSubjects = Subject.all`；
  - 收集中心导入学科下拉：`lib/modules/collect/collect_page.dart` `_load`；
  - 错题本书架：`lib/modules/wrongbook/wrongbook_page.dart` `_load`；
  - 首页学科格：`lib/modules/home/home_page.dart` `_load`；
  - 导航组件本身：`lib/widgets/app_shell.dart`
    `(subjects ?? Subject.all).take(5)`（null 也回退）。
- 刷新通道本身没坏，可以排除另外两个嫌疑：
  - `deleteSubject`（`lib/data/db_catalog.dart`）删完会
    `bumpBadgeVersion()`，外壳 `badgeVersion` 监听驱动
    `_refreshBadges`，删科后导航会即时重读——重读回来的是被回退
    污染过的列表，所以界面上三科“删不掉”；
  - 书架/收集/首页每次进页都重新 `_load()` 读库，没有跨页缓存的
    学科列表；读到的也是被回退污染过的列表。
- 删学科的库内动作本身是对的（`deleteSubjectFromImpl` 同事务删该科
  的题、任务、草稿框、文件夹等），数据库里三科确实没了——
  验收截图里学科管理页自己也显示“还没有学科，先添加一个吧。”
  （image-89），只有其他四处还在摆幽灵行。这正是“三轮自审没发现”
  的原因（Meng 2026-11-15 14:51 复盘：第 1 项是真漏——
  “没顺着删后跨页刷新链查”）。

## 改了哪些文件

修法：空表就是空，各处直接用库里的列表；删空后各处给空状态，
不再摆预设三科充数。

| 文件 | 改动 |
|---|---|
| `lib/app.dart` | `_refreshBadges`：`_navSubjects = subjects`（去掉回退）；初始值 `Subject.all` → `const []`（首帧不先摆三科幽灵行）；`CollectPage` / `WrongbookPage` 接入 `onGoSubjects: () => _go('/subjects')` |
| `lib/widgets/app_shell.dart` | `(subjects ?? Subject.all)` → `(subjects ?? const <Subject>[])`；注释同步。`subjects` 为空时速览只剩标题、无行；**另按 B8-1 纠正改了速览块锚定（见下节）** |
| `lib/modules/collect/collect_page.dart` | `_load` 去掉回退；初始 `_subjects` 改 `const []`；学科删空时下拉提示变“还没有学科”并禁用（`onChanged: null`，点不开空菜单），下方文案变“还没有学科：先去「学科管理」添加一个，再回来导入。”，并给“去学科管理”按钮（新增可选参数 `onGoSubjects`，不传时只显示文字） |
| `lib/modules/wrongbook/wrongbook_page.dart` | `_load` 去掉回退；初始 `_subjects` 改 `const []`；新增可选参数 `onGoSubjects` |
| `lib/modules/wrongbook/wrongbook_shelf.dart` | 学科删空时书架不再摆三本 0 道题的幽灵书、不显示分页器，改显示 `QmEmptyState`（标题“还没有学科”，文案“先去学科管理添加一个吧。”，有回调时给“去学科管理”按钮；文案与学科管理页空态同款） |
| `lib/modules/home/home_page.dart` | `_load` 去掉回退；初始 `_subjects` 改 `const []`；`_BottomGrid` 注释同步（空时只显示快速收集格）。焦点卡空态（“今天没有要复习的”）不含学科名，无需改 |
| `test/app_shell_test.dart` | `pumpNav` 加 `subjects` 参数；“每科一行”用例显式传 `Subject.all`（`AppNavBar` 不传 subjects 时不再回退预设三科） |
| `test/s8b2_subject_sync_test.dart` | “未传 subjects 时沿用预设三科”改写为“未传 subjects 时不显示任何学科行” |
| `test/b8_1_subject_refresh_test.dart`（新增） | 见“测试覆盖” |
| `test/b8_1_subject_refresh_flow_test.dart`（新增） | 见“测试覆盖：真实交互用例” |

没有改数据库、Schema、pubspec、删除语义、计数口径。

## 左导航顺序：学科管理、学科速览、设置

> **本节已按 Meng 2026-11-15 15:45 的纠正重写；旧结论（“顺序已对、
> 不用改”）作废。**

纠正：Meng 要的是**学科速览固定在设置正上方、两者紧挨着，中间没有
空隙**。问题不是顺序（顺序本来就是 学科管理 → 学科速览 → 设置），
而是**贴合度**：旧结构里速览区是 `Expanded` 撑满导航剩余空间，
科少时行贴在区顶部、设置固定在底部，中间留一大段空。

改法（`lib/widgets/app_shell.dart` 展开态）：

- 速览块改为**底部锚定、直接贴在设置按钮上方**：外层 `Expanded`
  的 `Column` 用 `mainAxisAlignment: MainAxisAlignment.end` 把整块
  （分隔线 + 标题 + 行）推到底；设置外层 `Padding` 的顶边距由 8
  改为 **0**，最后一行底边与设置按钮顶边重合、无空隙。
- 行区仍是 `SingleChildScrollView`（key `qm-nav-subject-scroll`
  不变），行多 / 窗口矮时在区内滚动：`Flexible` 给松约束，
  `SingleChildScrollView` 按子内容定高（`size = 约束内
  constrain(child.size)`，行少时只占内容高、行多时顶到上限并滚动；
  它本身没有 `shrinkWrap` 参数——首版误写后 analyze 报错
  `undefined_named_parameter`，查 SDK 源码确认后去掉）。
- 设置仍固定在导航最底部、不进滚动区；折叠态无速览区，不受影响。
- image-89 里设置按钮不可见，是因为截图底部被裁切（图高 876px，
  是裁过的窗口截图，政治行下方即裁切边），不是顺序问题。

回归用例（`test/b8_1_subject_refresh_test.dart` 新增 2 项）：

- “B8-1 纠正：速览块底部锚定，最后一行底边紧贴设置按钮顶边
  （无空隙）”——3 科时，行区（`qm-nav-subject-scroll`）底边与
  `QmButton`（设置）顶边之差 `closeTo(0, 1.0)`；另断言速览标题
  与“学科管理”行之间确有空段（空在块上方，不在块与设置之间）。
- “B8-1 纠正：学科删空时速览标题也紧贴设置按钮”——0 科时同样
  相邻（行区高为 0，标题底边贴设置顶边）。
- 原有顺序断言（`学科管理 < 学科速览 < 设置` 纵坐标 + 设置不在
  滚动区子树内）仍在；`test/p0b2_nav_palette_test.dart` 的
  “设置固定底部、行多时区内滚动”（6 学科、720/600 高、1.3 特大字号）
  在新结构下仍全过（见“验证结果”）。

## 测试覆盖

### 真实交互用例（父任务补充要求）

`test/b8_1_subject_refresh_flow_test.dart`：**一个测试、真实走完全程**，
不是只验逻辑：

- 真实库：`AppDatabase.openForTest()` 内存库（只建表不播种，
  不碰真实演示库、无文件 IO），`useDatabaseForTest` 设为单例，
  种预设三科（与新库首次启动一致），其余表全空。
- 真实整应用：直接 pump `QuizMasterApp`（不用 FakeRepo），
  按 Meng 的操作顺序真实点按：
  1. 首页确认导航速览里三科都在（删前基线，证明用例真的看到了它们）；
  2. 点左导航“学科管理”→ 点开折叠的“学科”分区（默认全折叠，
     截图 image-89 里也是展开态）→ 逐科点行内的“删除”按钮（按“与学科名
     同处一个 Row”的规则定位，不会误点导航速览行）→ 模态确认弹窗
     点“确认删除这一科和全部 0 道题”→ 每次删完都等到导航速览里
     该科消失再继续（`badgeVersion` 监听驱动的 `_refreshBadges`
     已落地）；
  3. 三科删光后，学科管理页自己显示“还没有学科，先添加一个吧。”；
  4. 点“收集中心”：下拉提示“还没有学科”，点开下拉确认数学/英语/
     政治都不出现；
  5. 点“错题本”：书架空状态“还没有学科 / 先去学科管理添加一个吧。”，
     无三本书、无“共 3 本”；
  6. 点“首页”：只有快速收集格，无三科格。
- 断言只看界面（`find.text`、下拉提示、空状态、导航栏内 scoped
  查找），库里空了只是最后一行辅助 sanity，主断言不靠它。
- 整应用 `pumpAndSettle` 永不静止（见 `s8b3_startup_test.dart`
  文件头），用例用有界手动 pump（`_pumpUntil`，每 100ms pump
  一次、最多 60 次）等界面稳定，不睡真实时间。

### FakeRepo widget 用例

`test/b8_1_subject_refresh_test.dart`（12 项，学科表空 / 非空对照；
原 10 项 + B8-1 纠正新增 2 项相邻断言）：

- 导航：空表 → 速览无任何学科行（标题与设置仍在）；只删一科 →
  速览只剩其余两科；顺序 `学科管理 < 学科速览 < 设置` + 设置不在
  滚动区子树内；**相邻：3 科时行区底边紧贴设置按钮顶边
  （差值 0，容差 1px），0 科时标题也紧贴设置按钮**（见上一节）。
  滚动区子树内。
- 收集：空表 → 下拉提示“还没有学科”、点不开幽灵项、“去学科管理”
  按钮可用；非空 → 下拉仍能选到学科。
- 错题本：空表 → 书架无书、空状态 + 按钮可用、无“共 3 本”；
  非空 → 三本书仍在。
- 首页：空表 → 只有快速收集格；非空 → 三科格仍在。

两份用例都不用异步文件 IO。

## 验证结果

### 基线（本项开始前，2026-11-15 14:49 CST）

- `flutter analyze`：0 问题。
- 演示库已备份到 `~/workspace/demo-db-backup/quiz-master2.db`
  （md5 `8f7f9c64405dc6e484ac2bf8e5e1a807` = Batch 7 的 v1）。
- 全量测试基线重跑：启动后 16 分钟未结束，且并行工人（第 2 项）
  在 14:55–14:56 CST 开始同树清扫 layer-2 代码，树在中途变化、
  结果无法解读，遂按确切 PID 停掉；基线数以 Batch 7 自身的
  879/879（见 MEMORY.md）为准，不再重复跑基线。

### 本项改动后（含 B8-1 纠正）

- `flutter analyze`（改动的 10 个文件：6 个 lib + 4 个 test）：
  **0 问题**。全仓 analyze 在并行工人扫尾完成后也回到 **0 问题**
  （15:40 CST 实测；中途一度 85 个报错，全在第 2 项清扫 layer-2
  时的过期测试引用里，已由该项工人修掉，与本项无关）。
  纠正改动后 `flutter analyze lib/widgets/app_shell.dart
  test/b8_1_subject_refresh_test.dart` 仍 **0 问题**（中途首版误写
  `shrinkWrap` 报 1 个错，查 SDK 源码后修正，见上一节）。
- 目标测试（串行 `--concurrency=1`，含 `LD_LIBRARY_PATH`）：
  `test/b8_1_subject_refresh_test.dart`（12 项，含 2 项新相邻断言）、
  `test/b8_1_subject_refresh_flow_test.dart`（真实交互 1 项）、
  `test/app_shell_test.dart`、`test/s8b2_subject_sync_test.dart`、
  `test/p0b2_nav_palette_test.dart`（设置固定底部 + 区内滚动）、
  `test/nav_hover_regression_test.dart`——**48/48 全部通过**（27 秒）。
  （纠正前同一口径为 39/39，系 b8_1 为 10 项且未含 p0b2/nav_hover。）
- 直接受影响的页面测试（串行）：`test/collect_page_test.dart`、
  `test/wrongbook_page_test.dart`、`test/home_page_test.dart`、
  `test/subjects_page_test.dart`——纠正后重跑 **173/173 全部通过**
  （约 2 分钟；纠正前同一批也是 173/173）。
- 全量测试：849/849 全部通过（见下“全量测试（本项改动后）”）。

### 真实交互用例调试记录（值得后人注意的两坑）

1. testWidgets 体跑在 fake async 里，真实 ffi 数据库的 Future
   等不到完成：首版用例用纯 `pump(Duration)` 等启动，12 轮后仍卡
   在加载圈；改成每轮 `tester.runAsync(() => Future.delayed(...))`
   切回真实异步等数据库完成、再 `pump` 渲染后，一轮即加载成功。
   同理用例末尾的 `await repo.subjects()` 也必须包在 `runAsync`
   里——直接 await 会永远卡死（首版因此空转 8 分钟）。
2. 用例收尾须等在途的 `_refreshBadges` / `saveLastRoute` 落定
   （3 轮 runAsync + pump）再结束，否则 tearDown 关库时在途查询
   报 database closed（未加收尾前 5 次里出现过 1 次偶发失败，
   加收尾后连跑 3 次全过；目标测试 39/39 的那次即含收尾版）。
3. 学科管理页各分区默认全折叠，折叠时行内按钮不在树里——用例须先
   点开“学科”分区（截图 image-89 里也是展开态）。

### 全量测试（本项改动后）

- 第 2 次重跑（~15:40 CST 启动）：跑到约 667 项（+667 -1）时
  **/tmp 写满（512M tmpfs 100%）**，`import_service_p1_fixes_test`
  写盘报 `No space left on device` 后全军覆没。/tmp 被 6 个
  `/tmp/flutter_tools.*`（并行多工人的 flutter 进程产物，共约
  507M）占满；根盘无碍（6.9G 空闲）。已删本项已死运行的两个目录
  （GRIBXT 147M、WQTCKU 22M），其余 4 个属其他工人的活运行，未动。
- 第 3 次重跑（~16:05 CST 启动，/tmp 已清空、clang 已恢复后）：
  **849/849 全部通过**（10 分 38 秒，EXIT:0，`/tmp/b8_full3.log`）。
  总数较 Batch 7 的 879 少 30 项：系第 2 项工人在清扫 layer-2 时
  删了相关测试（本项新增 2 项相邻断言已包含在内，b8_1 真实交互
  用例在全量中跑在 +848 位通过），0 失败是关键结论。
  若协调方需要与 Batch 7 逐项对数，可按 `git diff 622b6b6
  -- test/` 核对被删的测试文件。

#### 环境事故：clang 丢失与重装（2026-11-15 ~16:00 CST）

- 纠正改动后首次跑目标测试时，`flutter test` 在 2.7 秒内失败：
  `Building native assets failed`——pdfium_dart 钩子找不到编译器
  （`No compiler configured on host 'linux_x64'`）。
  查得 `/usr/bin/clang*` 与 `/usr/lib/llvm*` 全都不见了（MEMORY.md
  记 clang 18.1.3 曾在 VM 更换后重装过，疑似又一次环境丢失；
  gcc 13.3 还在，但该钩子解析不到可用编译器）。
- 试图 `sudo apt-get install -y clang-18` 时撞上 dpkg 锁（PID 3342
  的 apt-get，另一工人也在装）；等其完成后 `which clang-18` /
  `clang` 均已存在，遂未重复安装。之后目标测试 48/48 正常跑通。
  注意：本机 clang 曾两次丢失，属环境不稳定因素，全量若再报
  编译器缺失先查 `which clang-18` 再决定是否重装。

## 遗留

1. 同一回退模式还剩 5 处，不在本项文件内，未动（分属其他批次项的
   文件，并行工人正在改其中几处，避免冲突）：
   `lib/modules/detail/question_detail_page.dart:176`、
   `lib/modules/organize/organize_page.dart:207、2163`、
   `lib/modules/report/report_page.dart:157`、
   `lib/modules/review/review_page.dart:200`。
   删光学科后这些页仍会显示预设三科（详情页学科栏、整理页学科筛
   选、学习报告学科分布、复习页学科筛选）。建议下一批同一模式扫掉。
2. `_subjectOf` / `_subjectName` 里的 `Subject.byId(id)` 数学兜底
   还在：只在“题的 subject_id 在学科表里找不到”的数据不一致时触发，
   删学科会连同该科的题一起删，不会走到这条路，未动。
3. Win11 真机复核清单（widget 测试覆盖不到的）：
   - [ ] 真机删光三科后，左导航速览、收集下拉、错题本书架、首页
     四处目视确认无幽灵三科；再新建一科，确认四处即时出现新科。
   - [ ] 真机目视：科少时速览块（分隔线 + 标题 + 行）紧贴设置按钮、
     中间无空隙；科多 / 矮窗口时行区在内部滚动、设置仍固定在底部。
     （B8-1 纠正改了这块布局，widget 测试已断言相邻与滚动，
     真机看实际观感。）
   - [ ] 学科删空后点收集下拉：空菜单不出现、不闪退；“去学科管理”
     跳转正常。
4. 演示库：全量测试会改写真实演示库（本项开始后 md5 已从 v1
   `8f7f9c64` 变为 v2 `78b8661e`，与协调方 15:36 备忘一致）。
   本项结束时已从 `~/workspace/demo-db-backup/quiz-master2.db`
   恢复为 v1 并核对：md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`、
   user_version 1、9 道题、3 学科（数学/英语/政治），与备份一致。
5. 基线与并行说明：本地 HEAD 停在 `bca8586`、工作树内容等于
   远端 Batch 7 head `622b6b6`（见“基线核对”）；第 2 项工人在本项
   进行中同树清扫 layer-2 代码并一度改动本项文件
   `lib/modules/collect/collect_page.dart`（06:56 UTC），经核查
   本项改动未被覆盖；全仓 analyze 中途的 85 报错已由该项扫尾修掉。
   第 7、9 项工人仍在改 detail / wrongbook_list（07:37–07:38 UTC
   仍有写盘），全量测试若在其改动中途跑，可能夹带其中间态。

## 基线核对（本项开始时）

- 远端 head `622b6b6`（Batch 7 已推，879/879、analyze 0、演示库
  md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`）；本地分支 `ui-replication`
  的 HEAD 停在较早的 `bca8586`，但工作树内容经逐文件哈希比对与
  `622b6b6` 一致（仅 3 个中文名 docs 文件因引号转义误报缺失，
  实为同名文件存在；其余多余文件是 `.dart_tool` 构建产物）。
  即：基线按内容算就是 Batch 7，git 状态的“42 文件已改”只是
  HEAD 滞后造成的表观脏树。
- 开始前：`flutter analyze` 0 问题；演示库已备份到
  `~/workspace/demo-db-backup/quiz-master2.db`
  （md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`）。
