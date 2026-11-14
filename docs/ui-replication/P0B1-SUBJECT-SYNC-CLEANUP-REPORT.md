# P0B1 学科同步扫尾（第一批第 2 项）报告

- 分支：`ui-replication`（未提交、未推送）
- 基线：改前 `flutter analyze` 0 问题；全量 `flutter test` 390 通过 + 1 跳过（= 391 项，与任务预期一致）
- 改后：`flutter analyze` 0 问题；全量 `flutter test` **397 通过 + 1 跳过（= 398 项）**，新增 7 项全部通过
- 验证库：演示库（深色、标准字号）验证后已恢复为 9 道题 / 3 学科原状

## 1. 改了什么

一律按收集页 / 报告页 / 复习页 / 错题本已有的写法：页面 state 持有一份读库的 `_subjects`（空库回退预设三科），再用 `_subjectOf(id)`（`firstWhere` + `orElse: () => Subject.byId(id)`）找学科；直接 `Subject.byId(...)` 显示学科名/色的位置全部改掉，只剩 `_subjectOf` 里的预设兜底。

| 文件 | 改动 |
|---|---|
| `lib/modules/detail/question_detail_page.dart` | 新增 `_subjects` + `_subjectOf`，`_load()` 里调 `repo.subjects()`；替换 5 处：标题行（L602）、副标题（L835）、题目信息学科字段（L1075）、编辑态学科字段（L1148）、新建知识点提示（L1265）；两个 `QuestionSlice` 调用处传 `subject: _subjectOf(q.subjectId)` |
| `lib/modules/organize/organize_page.dart` | 主态新增 `_subjects` + `_subjectOf`，`_refresh()` 里调 `repo.subjects()`；替换 3 处：顶栏“当前整理”（L584）、文件夹区（L1119）、知识点树（L1529）；`_paperImage` 的 `QuestionSlice` 传 subject。队列弹窗态（`_QueuePopupState`）同样新增 `_subjects` + `_subjectOf`，`_loadMeta()` 里调 `repo.subjects()`；替换 3 处：搜索 haystack（L1985）、详情行（L2029）、删除确认（L2380） |
| `lib/modules/home/home_page.dart` | `_HomePageState` 新增 `_subjectOf`（`_subjects` 本来已读库）；副标题“上次停在”改走 `_subjectOf`。`_FocusCard` 新增 `subjects` 参数（父页传 `_subjects`），“继续上次”里的学科名改走库里查找 |
| `lib/modules/review/review_page.dart` | 两个 `QuestionSlice` 调用处传 `subject: _subjectOf(q.subjectId)`（该页已有 `_subjectOf`；此处 `failed` 默认为 false，属一致性补齐） |
| `lib/widgets/widgets.dart` | `QuestionSlice` 与 `CompactSliceThumb` 新增可选 `subject` 参数（`SubjectLabel` 同款做法）：传了用库里学科的名 / 图标 / 存色，不传才回退 `Subject.byId`；失败占位里的 `subjectLabelColor` 改传 `subject.color`（亮/深两态新学科都不再落到数学色）。`subjectLabelColor` 本体（L491 的 `Subject.byId(...).color`）与 `SubjectLabel`（L511）未动——它们是“调用方没传存色时”的兜底，没有库里数据时无从知道新学科的颜色，真正的修法在调用方传参 |
| `test/detail_page_test.dart`、`test/organize_page_test.dart` | `FakeDetailRepo` / `FakeOrganizeRepo` 新增可配的 `subjects()` 覆盖（默认 `Subject.all`，与收集/复习/报告页的 fake 同款）；否则详情/整理页新增的 `repo.subjects()` 调用会落到真实数据库 |
| `test/p0b1_subject_sync_test.dart`（新增） | 回归测试，见 §3 |

未动：`wrongbook_page.dart`、`test/wrongbook_page_test.dart`（任务要求）；数据库 Schema、依赖、`pubspec.lock`；无 commit / push / pull / reset / checkout / clean。

## 2. 漏查结果

改后全树复查 `Subject.byId`（除 `lib/models/models.dart` 的定义本身）：

- `lib/` 内剩余的全部是各页 `_subjectOf` 的 `orElse` 兜底或注释（收集/详情/首页/整理主态+弹窗/报告/复习/错题本、`widgets.dart` 的 `QuestionSlice` / `CompactSliceThumb` / `subjectLabelColor` / `SubjectLabel`），已无直接拿 `Subject.byId(...)` 显示学科名/色的调用点。
- 其余 `Subject.all` 出现处均为“空库回退预设三科”的既有写法（各页 `_subjects` 初值 / `isEmpty` 回退、`database.dart` 种子、`app.dart` 导航初值），不是漏网。
- 整理页文件夹重名检查（任务要求只记录不修）：两处都在已按学科过滤的 `_folders` 上查——主态 L394（`_loadFolders()` 按当前题 `subjectId` 取），队列弹窗 L2078（`_loadMeta()` 按 `_currentSubjectId` 取）。**未发现未限定 `subjectId` 的问题**，无需另立项。
- 另见（未改，非 byId 漏网）：队列弹窗的 `_subjectInitial` 只认 `english → Y`、`politics → Z`，其余一律 `S`——新学科与数学同按 `S` 排，只影响按学科排序时的相对次序，不显示错名；不在本次范围内。

## 3. 回归测试（新增 7 项，`test/p0b1_subject_sync_test.dart`）

新建学科化学（`subject-chem` / “化学” / 紫 `0xFF7C5CFC` / 图标“化”，与 S8 系列同值）+ 一道化学题，验证：

1. 整理页顶部：当前整理显示“化学 · 化学平衡”，且页内无“数学”。
2. 队列搜索：搜“化学”只找到化学题（搜到 1 道）；搜“数学”找不到化学题（“没找到这道题，换个词试试”）。
3. 详情页：标题“化学 · 极限题｜化学平衡”、副标题学科名“化学”，页内无“数学”。
4. 首页“上次停在”：副标题与焦点卡均为“整理工作台 · 化学「化学平衡」”。
5. 切片失败占位：`QuestionSlice(failed: true, subject: 化学)` 显示“化”+“化学 · 极限题”，无“数学”。
6. 紧凑缩略图失败占位：`CompactSliceThumb(failed: true, subject: 化学)` 显示“化”+“加载失败”，无“数学”。
7. 未传 `subject` 时仍回退旧行为（显示数学、不崩）——把兜底契约钉住，见 §5 残留。

## 4. 真机验证（Xvfb，1280×720，深色标准字号，`build/linux/x64/release/bundle`）

验证库：从 `/tmp/qm2-p0b1-orig.db` 恢复后，插入化学学科 + 化学题 `q-chem-1`“化学平衡”（未整理、最新），并把 `recent_tasks` 指向它。截图在 `docs/ui-replication/shots/p0b1-subject/`：

| 截图 | 内容 | 结论 |
|---|---|---|
| `01-home.png` | 首页 | “上次停在：整理工作台 · 化学「化学平衡」”、焦点卡“继续上次：整理工作台 · 化学「化学平衡」”；左导航与底部均出现化学（紫点，待整理 1 道）✓ |
| `02-organize-topbar.png` | 整理工作台 | “当前整理：化学 · 化学平衡”，队列“还剩 5 道”✓ |
| `03-queue.png` | 队列弹窗 | 首行“化学平衡”，详情行“化学 · 极限题 · 2026-11-13 · 试卷（来源）：未知试卷 · 待补充 1 项：文件夹（归类）”✓ |
| `04-queue-search-chem.png` | 搜“化学” | 搜到 1 道：化学平衡✓（注：xdotool 在 POSIX locale 下打不出中文，改用 `LC_ALL=C.UTF-8` 后输入正常） |
| `05-queue-search-math.png` | 搜“数学” | 搜到 1 道：导数应用综合——只有数学题命中，化学题不在结果里✓（改前化学题的搜索串会含回退的“数学”，会被误搜到） |
| `06-detail.png` | 题目详情 | 标题“化学 · 极限题｜化学平衡”、副标题“学科：化学（只显示，不能改……”✓ |
| `07-detail-info.png` | 题目信息展开 | “学科（不能改）”字段显示“化学”✓ |

未在真机上验证：切片失败占位。真实应用里 `imageFailed` 默认为 false，演示题渲染的是手绘切片而非图片加载失败态，该路径没有可点的 UI 入口；由 §3 的第 5、6 项 widget 测试覆盖。

**演示库恢复**：验证完用 `pkill -x quiz_master2` 杀应用，`cp /tmp/qm2-p0b1-orig.db` 恢复。核查：9 道题、3 学科、`recent_tasks` 回到 `整理 / math / 函数极限`，`q-chem-1` 与 `subject-chem` 均已不在库里。

## 5. 偏离与残留

1. **顺带修了一个无关但由新测试发现的旧布局 bug**（`lib/widgets/widgets.dart` 的 `CompactSliceThumb` 失败占位）：图标 17px +“加载失败”两行共 44px，超出 64×48 容器内高 38px、底部溢出 6px。数学题同样溢出（用数学题单独复现确认，与学科无关、与本次改动无关）。修为图标 14px + 两行显式行高（`height: 1.0 / 1.2`），现无溢出。若只想要学科同步改动，可单独回退这一处——回归测试第 6 项会随之失败（溢出即测试失败）。
2. **错题本三处切片调用点未改**（任务要求不动 `wrongbook_page.dart`）：`QuestionSlice`（L2850）与 `CompactSliceThumb`（L2970、L3113）仍未传 `subject`，新学科在错题本大卡片 / 紧凑行的失败占位里仍会显示成“数学”（兜底）。错题本其余位置（目录标题、封面等）B2 已修好。后续改错题本时，把这三处改成传 `_subjectOf(q.subjectId)` 即可，widget 侧参数已就绪；§3 第 7 项测试钉住了“未传时回退”的当前行为，改完后应把该项改为断言化学。
3. 队列按学科排序时新学科与数学同按 `S` 排（见 §2），未改。
4. 执行中一个小插曲：恢复库那条命令里 `pkill -f "Xvfb :99"` 匹配到了命令自身的 shell，导致命令被 SIGTERM、恢复没跑到；发现后单独重跑了恢复并核查通过（9 题 / 3 学科 / recent 回到数学）。应用是用 `pkill -x quiz_master2` 杀的，未用带路径的 `-f`。
