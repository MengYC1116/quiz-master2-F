# Batch 5 Stage 5 P2 — 错题本 / 复习 / 报告 / 首页（B5-P2-WRONGBOOK）

- 范围：SR-P2-37～SR-P2-55、SR-P2-57、SR-P2-58（SR-P2-56 跳过，已裁决残留）；SR-P2-36 为数据层工人转交（B5-P2-DATA.md“需转交”第 3 条），并入本阶段一并完成。
- 分支 `ui-replication`，未 commit、未 push。演示库 `~/.local/share/quiz-master2/quiz-master2.db` 未动（94208 字节，2026-11-14 13:48）。
- 既有测试改动 2 处：`test/wrongbook_page_test.dart` 书架/目录计数随 SR-P2-38 改口径；`test/review_page_test.dart`“按组开始解决”按 SR-P2-49 决定 (b) 重写。

## 逐项结果

| 项 | 修复 | 测试 |
|---|---|---|
| SR-P2-36 文件夹整科判重（转交） | `wrongbook_page.dart` 三处预检改调 `repo.folderNameExistsInSubject`：`_addFolder`（新建，不传 `excludeId`）、`_saveRename`（改名，传自身 id）、`_moveOneFolder`（移入/移回，传自身 id，替代原来只查目标层/顶层的两处判断，返回文案改为“同一学科下已经有同名文件夹「X」了”）；三处 `saveFolder` 均捕获 `StateError` 转提示“已经有了”，不报未知错误。另给 `_reorderFolder` 加了同款防线（调顺序不改名，正常不触发；见“额外改动”）。 | 新增 5 项（目录页 `B5 SR-P2-36` 组）：新建拦跨层同名、别科同名放行、改名拦跨层同名、移入目标层为空但别层有同名时拦下、saveFolder 抛 StateError 只提示。Fake 侧补 `folderNameExistsInSubject`（按 folderList 实扫）与 `saveFolderError` 注入点。 |
| SR-P2-37 学科首字母写死三档 | `_subjectInitial()` + `_subjectKeyCompare()`：常用汉字首字母映射表（数 S、英 Y、政 Z、化 H、物 W……），拉丁首字母大写，未映射汉字回退本身；排序平局按学科名、再按时间新→旧。 | 新增 2 项：五科同错因，升序首张为化学（最旧，证明排序压过时间），降序首张为政治。 |
| SR-P2-38 目录/书架题数含已掌握 | 决定 (a)：`_folderCount`、书架封面总数、目录“全部题目”行均扣掉已掌握；“已解决 X 道不显示”提示改为当前文件夹口径（文件夹内按子孙树计，否则按整科计）。 | 新增 2 项：f1 列表标题“数学 · 试卷”+ 提示“这个文件夹里错因已全部解决 1 道默认不显示”；f2 列表无提示。 |
| SR-P2-39 未加入盒列入未整理/无错因题 | `notJoined` 加条件：已整理、未归档、有错因才列入。 | 新增 1 项：盒里有 q8 与 q4“马原”，无 q6（未整理）、q7（无错因）。 |
| SR-P2-40 批量加标签绕过 §6 第 4 条 | `_batchAddTag` 新建标签名先过 `hasBannedNameSeparator`，命中提示“不能含逗号或竖线”并中止，不入库。 | 新增 1 项：输入“新标,签”→ 提示，标签未入库、无题目被保存。 |
| SR-P2-41 批量操作 firstWhere/无事务/无反馈 | 六个批量操作改安全查找（`_questionById`/`_folderById`，查不到返回 null）+ 逐项 try/catch + `_snackBatchResult` 汇总提示；跨学科列表批量条加提示“跨学科列表不能批量移文件夹：先打开一本书，再批量移”。真事务仍需数据层批量方法（见“转交”）。 | 新增 2 项：先全选再删首题后批量收藏→“已收藏 2 道；1 道已不在列表里，跳过”；跨学科列表批量模式显示提示。 |
| SR-P2-42 拖拽往下多移一位 | `_reorderFolder` 记录 `fromIndex`，`idx > fromIndex` 时先减 1 再插入。 | 新增 1 项（手柄起拖，见下）：拖“试卷”到与“平时作业”之间的缝隙顺序不变，拖到末尾缝隙变为 [平时作业，试卷]。 |
| SR-P2-43 `_applyDrop` 注释与实现不符 | 只改注释：缝隙只接受同层拖拽，子文件夹回顶层请拖到“全部题目”行。无代码行为改动。 | 无（注释项）。 |
| SR-P2-44 换科/换文件夹不清搜索筛选 | `_openList`/`_openDirectory`/`_openShelf` 均调 `_clearFilters()`（清搜索与全部筛选、回第 1 页、清勾选；不碰文件夹/学科归属）。 | 新增 1 项：数学列表搜“函数极限”→ 目录 → 书架 → 英语列表，两道英语题全可见。 |
| SR-P2-45 “最近一周”实为 8 天 | 决定：周筛选 `age < 7`（7 天含今天）；搜索 haystack 同时收 `yyyy-MM-dd` 与 `yyyy-M-d` 两种写法。月筛选 `age <= 30` 未动（无决定，见“遗留”）。 | 新增 2 项：6 天前在内、7 天前在外；日期两种写法都搜到 2026-11-05 的题。 |
| SR-P2-46 跨学科已归档无分页无搜索 | 书架顶部已归档视图接同一分页器（默认 10 条）。搜索按 SELF-REVIEW 暂缓。 | 新增 1 项：12 道归档 →“共 12 道 · 第 1 / 2 页”、10 个“恢复到错题本”；下一页 2 个。 |
| SR-P2-47 已解决区/未加入盒不分页 | 已解决区按 `_pageSize` 分页（独立 `_curedPage`，筛选变化归零）；未加入盒按学科分行，默认前 10 道 +“展开全部（共 N 道）”/“收起”。 | 新增 2 项：5 组已解决每页 2 条共 3 页，翻页到第 2 页；13 道未加入默认只列前 10，展开后全见。 |
| SR-P2-48 `_load()` 无 try/catch | 首页、错题本、复习页 `_load()` 包 try/catch：首次失败出错误页（横幅 + 重试），已有内容时横幅 + 保留旧内容；复习页另有“重新加载”按钮。 | 新增 3 项（三页各一）：抛错出横幅、重试失败仍在、重试成功恢复（首页恢复后见“3 道要复习”）。三页 fake 各补 `throwOnLoad`。 |
| SR-P2-49 会话忽略错因筛选 | 决定 (b)：`_buildBlocks` 只取已过滤分组内的待治错因，再按 `onlyCause` 收窄；按组开始只治该组错因。 | 新增 1 项：错因筛“计算错误”后开始解决→“第 1 / 1 道题 · 错因「计算错误」”“本题错因 1 / 1”。既有“按组开始解决”测试已按 (b) 重写。 |
| SR-P2-50 缓存预览只扫顶层 | `_scanCacheSync()` 的 `walk()` 递归进普通子目录，cache/thumb/tmp 目录与 `.tmp`/`.cache` 文件在深层也被发现并计数。 | 新增 1 项（已写，未跑通，见“未验证”）：临时目录 `work/thumb-cache/a.png` + `work/deep/x.tmp` → 预览“临时文件 1 个、缩略图缓存 1 张”。扫描逻辑另用纯 Dart 脚本照搬验证通过（temp=1、thumb=1，`/tmp/b5_p2_50_check.dart`）。 |
| SR-P2-51 第 8 科起颜色回落第一色 | `_newSubjectColors` 7 → 12 色（加青绿 0xFF14B8A6、草绿 0xFF84CC16、琥珀、靛蓝、玫红）；12 色用完按金角 137.5° 轮转生成（撞色再步进 37°，最多 12 次），不再回落数学蓝。 | 新增 1 项：连加 10 科共 13 科，第 8 科青绿、第 9 科草绿，13 色全不同，第 13 科为金角生成色（非数学蓝）。Fake 补 `saveSubjectCalls` 计数（供 SR-P2-55 用）。 |
| SR-P2-52 封面字号不跟全局缩放 | **与 SELF-REVIEW 字面方向有偏差（有探针证据）**：实测 `TextScaler 1.3` 下 `fontSize` 已被全局缩放（52→67.6），只有 `letterSpacing` 不缩放。故只把两处 `letterSpacing` 乘 `scale`（学科名 3.12、副标题 13.6），`fontSize` 不乘——否则双重缩放，违反 D4 约定（`uikit.dart` 头注 + `app.dart:240-254`：字号全局缩放一次，布局尺寸乘 `qmScaleOf`）。 | 新增 1 项：1.3 倍下“错 题 本”宽度 > 185（修复前 172，1.0 倍时 148）。 |
| SR-P2-53 列表标题文件夹名不显示 | 文件夹分支标题改为 `'${subject.name} · ${folder.name}'`。 | 与 SR-P2-38 同一测试断言“数学 · 试卷”。 |
| SR-P2-54 跨学科列表书框回退数学色 | `_openBookFrame` 增加 `neutral` 参数；跨学科列表（`_subjectId == null`）用灰 `0xFF64748F`，不再用数学封面色。 | 新增 1 项：错因筛选进列表含灰色书框；数学列表无灰色书框。 |
| SR-P2-55 封面选择器两套点按 | **最终做法与 SELF-REVIEW 建议相反（有测试证据）**：保留外层 `GestureDetector(onTap: _setCover)` 为唯一处理，`QmCoverMini` 不传 `onTap`（为 null 时只返回装饰容器，无点按识别器）。因既有测试点样式名签（`find.text('圆点')`）触发选择，改只留内层会使名签点按失效——第一次尝试即因此失败 1 项，已改回。 | 新增 1 项：点数学“圆点”小图（第 3 个 `QmCoverMini`）→ `coverStyle` 变 `dots`，且 `saveSubject` 恰好调用 1 次。 |
| SR-P2-57 恢复条文案写死 | 新增 `_scopeLabelForFilters()`（按当前学科/错因筛选）与 `_scopeLabelForBlocks()`（按保存队列实际学科/错因）；恢复走后者。 | 新增 1 项：数学筛选开始→暂停→继续解决，会话元信息为“第 1 / 2 道题 · 数学这一科”，全页无“全部待解决错因”。 |
| SR-P2-58 “重置”回设置默认值 | 决定 (a)：“重置”固定回时间新→旧（`'new'`）。**另修一个回归测试挖出的真 bug**：原实现把 `_sort = 'new'` 放进共用的 `_clearFilters()`，导致进书导航也抹掉设置默认排序（探针证实：设置 `wrongbookSort: 'old'` 时进书仍显示“新 → 旧”，设置项形同虚设）。现 `_clearFilters()` 只清搜索/筛选/页码/勾选、不动排序；`_resetFilters()` 在此之外另置 `_sort = 'new'`。导航保留当前排序（首次 `_load` 应用的设置默认值或页内改过的值）。 | 新增 1 项：设置默认旧→新时进书仍显示“排序：时间 旧 → 新”，点“重置”后变“排序：时间 新 → 旧”。 |

## 改动文件

lib（只改本阶段文件范围内）：

- `lib/modules/wrongbook/wrongbook_page.dart` — SR-P2-36（三处预检 + 防线 + `_reorderFolder` 防线）、SR-P2-37（首字母排序）、SR-P2-38（扣已掌握）、SR-P2-40/41（批量加标签禁令、安全查找、汇总提示）、SR-P2-42（拖拽减 1）、SR-P2-43（注释）、SR-P2-44/58（`_clearFilters` 抽取与拆分，见上）、SR-P2-45（周 7 天 + 日期双写法）、SR-P2-48（`_load` try/catch）、SR-P2-49（会话只取筛选错因）。
- `lib/modules/wrongbook/wrongbook_list.dart` — SR-P2-38（已掌握提示当前文件夹口径）、SR-P2-41（跨学科提示）、SR-P2-46（已归档分页）、SR-P2-53（文件夹标题）、SR-P2-54（`neutral` 传参）。
- `lib/modules/wrongbook/wrongbook_shelf.dart` — SR-P2-38（封面总数扣已掌握）、SR-P2-46（已归档入口点后回第 1 页）、SR-P2-52（`letterSpacing` 乘 scale）。
- `lib/modules/wrongbook/wrongbook_directory.dart` — SR-P2-38（“全部题目”行扣已掌握）。
- `lib/modules/review/review_page.dart` — SR-P2-39（未加入过滤）、SR-P2-47（已解决分页 + 未加入展开）、SR-P2-48（`_load` try/catch）、SR-P2-49（`_buildBlocks` 的 `onlyCause`）、SR-P2-57（范围文案）。
- `lib/modules/home/home_page.dart` — SR-P2-48（`_load` try/catch；另 `_loadErrorDismissed` 与备份横幅分开）。
- `lib/modules/subjects/subjects_page.dart` — SR-P2-51（12 色 + 金角轮转）、SR-P2-55（外层单点按）。
- `lib/modules/settings/settings_page.dart` — SR-P2-50（缓存扫描递归进子目录）。
- `lib/modules/report/*` 未动（SR-P2-56 跳过）。

test（只改本阶段文件）：

- `test/wrongbook_page_test.dart` — Fake 补 `folderNameExistsInSubject`、`saveFolderError`、`throwOnLoad`；新增 21 项（SR-P2-36 组 5 项 + B5-P2 组 16 项）。
- `test/review_page_test.dart` — Fake 补 `throwOnLoad`；新增 6 项（B5-P2 组）。
- `test/home_page_test.dart` — Fake 补 `throwOnLoad`；新增 1 项。
- `test/subjects_page_test.dart` — Fake 补 `saveSubjectCalls`；新增 2 项。
- `test/settings_page_test.dart` — 新增 1 项（SR-P2-50），加 `dart:io` 导入。

## 测试结果

单文件逐个跑（多文件并行会互相挤住，见“环境问题”）：

| 文件 | 结果 |
|---|---|
| `test/wrongbook_page_test.dart` | **68/68 通过**（原 47；+5 SR-P2-36，+16 B5-P2；SR-P2-42 拖拽与 SR-P2-58 曾各失败 1 次，修测试/修实现后全过） |
| `test/review_page_test.dart` | **36/36 通过**（原 30；+6；SR-P2-47 已解决分页曾失败 1 次，改点第 2 个“下一页”后通过） |
| `test/home_page_test.dart` | **18/18 通过**（原 17；+1） |
| `test/subjects_page_test.dart` | **26/26 通过**（原 24；+2；SR-P2-55 修复验证：第一次尝试改只留内层点按曾失败 1 项，改回外层单点按后通过） |
| `test/settings_page_test.dart` | **未跑通**（1 项新测试已写；见“未验证”） |
| `test/report_page_test.dart` | 未动、未跑（报告页本身未改；同受环境问题影响，见下） |

`flutter analyze`（最终）：**我手上文件 0 问题**。全树 10 条均为他人文件：`test/b5_p2_collect_test.dart` 8 条、`test/b5_p2_services_test.dart` 2 条（`unnecessary_import`、`avoid_print`、`unused_element_parameter`、`invalid_null_aware_operator`，本次工作前后均存在）。

另：`wrongbook_list.dart:484` 的 `prefer_interpolation_to_compose_strings` / `unnecessary_brace_in_string_interps` 两 lint 曾互相冲突（拼接触发前者、`${scope}` 插值触发后者）；探针证实 `$scope错因` 解析正确且无需大括号，现用 `'$scope错因已全部解决 $hidden 道…'`，两 lint 均清。

## 未验证（需协调员安排重跑）

1. **SR-P2-50 widget 测试未跑通**。新测试已写（`test/settings_page_test.dart`，`SR-P2-50 缓存预览递归扫子目录`）。三次尝试均被环境问题拦下（见下）：第一次后台运行 158 秒后被未知方 SIGTERM；第二次 clang 缺失导致 pdfium 原生构建失败；恢复 clang 后两次运行分别卡 8 分钟 / 6 分 46 秒（前端编译器冻结）。扫描逻辑本身已用纯 Dart 脚本照搬验证通过（`tempCount=1 thumbCount=1`，`/tmp/b5_p2_50_check.dart`）。重跑命令：`flutter test test/settings_page_test.dart`（机器空闲时单跑）。
2. **`test/report_page_test.dart` 未做 sanity 跑**（报告页未改动；同受环境问题影响）。

## 环境问题（本次亲历，需协调员知会各工人）

1. **clang 再次丢失**：任务中途 `which clang` 查不到（ninja 还在），`flutter test` 在 pdfium 原生构建 hook（`pdfium_dart-0.4.2/hook/build.dart`）处失败。按 `docs/ui-replication/restore-linux-toolchain.sh` 恢复时，`archive.ubuntu.com` 多次下载中断（`IncompleteRead`，1.8MB 索引下到约 1.5MB 即断、19MB 索引下到 13.8MB 即断）。改用阿里云镜像的 /tmp 副本（`sed` 换 `BASE`，仓库内脚本未动）一次成功：clang++ 18.1.3、GTK 3.24.41、ImageMagick、xdotool 均恢复。建议：该脚本后续直接换可靠镜像或加下载重试。
2. **多 worker 并行跑 `flutter test` 会互相卡死**：3 个以上并发时，各 `dartvm` 在 `futex_do_wait`、前端编译器 CPU 几乎不动（一次观测：编译器 6 分 43 秒只累计 5 秒 CPU），`.dart_tool/hooks_runner/*/​.lock`（pdfium_dart/sqlite3）被多个进程同时打开；`build/test_cache` 的共享 dill 也被多方争用。单文件串行跑在机器空闲时 20–40 秒跑完。建议：各工人错峰跑测试，或协调员统一在阶段末跑全量。
3. **一次后台运行被未知方 SIGTERM**：第一次设置测试后台运行（`proc_36f350be6dc7`，158 秒）以 `exitSignal 15` 结束，不是我杀的（我只杀过自己启动的四个会话：`proc_2f0aceef82ef` 学科重跑、`proc_ea4ae9987dfb`、`proc_f5f744c4d613`、`proc_0cccb02e874c` 设置测试）。请协调员确认是否有别的 worker 在按模糊名字杀进程。

## 遗留问题与转交

1. **转交数据层工人**：批量操作真事务——`QuestionRepository` 现无批量方法，批量删除/归档仍逐条保存，中途失败会部分生效（页内已做逐项捕获 + 汇总提示）。如需真事务，请数据层提供批量方法（或在 `save` 层支持事务），页内调用方再接。
2. **月筛选未定**：SR-P2-45 只定了周（`age < 7`）；月仍是 `age <= 30`（即 31 天），未改——需 Meng 或协调员裁决月口径（30 天含今天即 `age < 30`，还是保持）。
3. **SR-P2-41 跨学科跳过分支几乎走不到 UI**：跨学科列表里批量移文件夹按钮本身禁用，提示文案是用户可见的防线；`_batchMoveToFolder` 里的跨学科跳过计数是防御性代码。
4. **SR-P2-52 偏差**：只乘 `letterSpacing`、不乘 `fontSize`（探针证据见上表）。如 Meng 坚持字面“字号跟缩放”，需先确认 D4 约定的改动。
5. **SR-P2-55 定案**：保留外层 `GestureDetector` 单点按（名签点按是既有交互）；`QmCoverMini` 不传 `onTap`。
6. **SR-P2-58 附加修正**：导航不再重置排序（见上表），设置默认排序恢复生效；“重置”仍固定回新→旧。
7. **`_reorderFolder` 的 StateError 防线**（转交任务三处之外加的）：调顺序不改名，正常不触发；只防库里已有遗留重名时 `upsertFolder` 防线抛错导致页崩。
8. **SR-P2-42 拖拽测试写法**：须从行右侧拖拽手柄（`Draggable<Folder>`）起拖，从文件夹名处起拖不会启动拖拽；缝隙下标按 `DragTarget<Folder>` 顺序计（0 全部题目行、1 gap0、2 f1 行、3 gap1、4 f2 行、5 gap2）。
