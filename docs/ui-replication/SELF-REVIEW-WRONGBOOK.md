# 自审报告：错题本 / 复习 / 学习报告 / 首页（+ 学科管理 / 设置相关页）

- 审查员：错题本/复习/报告/首页审查员（只审、不改）
- 日期：2026-11-14
- 工作树：`~/workspace/quiz-master2-UI`，分支 `ui-replication`（Batch 1/2/3/4 已完成、未提交、未推）
- 通读文件：`lib/modules/wrongbook/wrongbook_page.dart`、`wrongbook_shelf.dart`、`wrongbook_directory.dart`、`wrongbook_list.dart`、`wrongbook_cover.dart`、`wrongbook_widgets.dart`；`lib/modules/review/review_page.dart`；`lib/modules/report/report_page.dart`；`lib/modules/home/home_page.dart`；`lib/modules/subjects/subjects_page.dart`；`lib/modules/settings/settings_page.dart`；另读 `docs/ui-replication/B4-WRONGBOOK.md`、`B2-WRONGBOOK-COVER.md`、`B2-WIN11BUG-SPINE.md`，并按需对照 `lib/data/repository.dart`、`lib/data/db_catalog.dart`、`lib/data/db_questions.dart`、`lib/models/models.dart` 核对口径。
- 本报告只写此文件，未改任何代码、未 commit/push、未动其他文件。

## 方法与基线

- `flutter analyze`（本次审查范围 6 项：`lib/modules/wrongbook/` + review/report/home/subjects/settings 各页）：**No issues found**。即以下问题均为 analyzer 看不出的逻辑/口径/决定不一致问题。
- 演示库核对：审查前后 `~/.local/share/quiz-master2/quiz-master2.db` md5 均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题）；跑测试前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.selfreview-wrongbook-pre`。
- P0-1 曾尝试写临时 widget 测试复现（`test/zz_selfreview_tmp_test.dart`，用后已删除，`git status` 已确认无残留）。该测试 8 分钟以上无输出：经 `ps` 核查，同期另一名工人在同一树里跑 17 个测试文件的大批量测试，占住了构建缓存，本探针被饿死（CPU 仅 0:02）。为避免争用已主动停掉探针、删掉临时文件。P0-1 的定论因此只建立在代码证据 + Flutter `DropdownButton` 契约上（见该条“证据”），未拿到 live 复现，修后应用单测复核。
- 行号均为当前工作树行号。

## 问题清单

共 **30 条：P0 × 1，P1 × 6，P2 × 23**。

### P0

#### P0-1 设置里选“学科首字母”排序，进错题本列表即触发 DropdownButton 断言（debug 抛错；release 下拉异常），且排序本身也未生效

- 位置：`lib/modules/settings/settings_page.dart:1004-1006`（选项）→ `lib/modules/wrongbook/wrongbook_page.dart:179-180`（`_load`）→ `lib/modules/wrongbook/wrongbook_list.dart:133-153`（下拉）→ `lib/modules/wrongbook/wrongbook_page.dart:446-473`（`_filteredAll` 的 `switch (_sort)`）。
- 现象/后果：设置页“默认排序”提供 `QmSegmentOption(value: 'subject', label: '学科首字母')`（模型注释 `lib/models/models.dart:552` 亦写 `wrongbookSort = 'new' // new / old / subject`）。用户选定后，错题本 `_load()` 把 `_sort = settings.wrongbookSort` 置为 `'subject'`；但列表页排序下拉的 items 只有 `new / old / subj-asc / subj-desc / status-asc / status-desc` 六项，没有 `'subject'`；`_filteredAll` 的 switch 也没有 `case 'subject'`，会落入 `default`（时间新→旧）。Flutter `DropdownButton` 要求 value 必须恰好对应一个 item，debug 下抛 `There should be exactly one item with [DropdownButton]'s value: subject`；release 下选中项查找失败，下拉显示异常。等于设置里一个公开选项一点就坏，且即使不崩、排序也静默回落到默认。
- 复现/证据：上述四处代码链即证据。`grep wrongbookSort lib/ test/` 显示全项目除设置页与模型外，只有 `wrongbook_page.dart:179-180` 两处引用，无任何消费 `'subject'` 的分支。另见 P2-2：即使用户在列表页手动选 `subj-asc/subj-desc`，那也不是设置项 `'subject'` 的语义。
- 修的方向：二选一并由 Meng 定：(a) 设置项改名/改值，与列表页一致（`'subject'` 改为 `subj-asc` 或拆成两项 A→Z / Z→A），并在 `_filteredAll` 补对应 case；(b) 列表下拉补一个 `value: 'subject'` 的 item 并映射到 `subj-asc`。同时给 `_sort` 加兜底：未知值回落到 `_defaultSort` 或 `'new'`，不再把非法值直接喂给下拉。修后加一测：`wrongbookSort='subject'` 的 FakeRepo 进列表不断言。

### P1

#### P1-1 复习会话“上次自查”显示的是最早一次自查，不是最近一次

- 位置：`lib/modules/review/review_page.dart:1482`；数据源 `lib/data/db_questions.dart:140-144`。
- 现象/后果：`_buildStepCause` 取 `history.last` 当“上次自查”。但 `reviewHistory()` 的 SQL 是 `orderBy: 'reviewed_at DESC'`（新→旧），`.last` 是最旧一条。用户在第 ① 步看到的“上次自查 · 日期·结果”会是第一次自查的记录，越练越错；补救文案、复查判断本身不受影响（只影响这一行展示）。
- 复现/证据：`review_page.dart:1482` 的 `history.last` 对 `db_questions.dart:144` 的 `DESC`。同一数据源在别处无此误用（报告页只计数/过滤，与顺序无关）。
- 修的方向：改为 `history.first`（DESC 下首条即最新），或让 `_loadHistoryForSession` 明确按时间倒序取首条；加一测：同一题两条自查记录（旧“未解决”、新“已解决”），第 ① 步应显示新的那条。

#### P1-2 学习报告薄弱 Top5 的计数按题名去重，同名不同题只算 1 道

- 位置：`lib/modules/report/report_page.dart:194`（`_causeGroups`）与 `:226`（`_kpGroups`）；`count` 定义见 `:173-175`（`titles.length`）。
- 现象/后果：两处都用 `if (!g.titles.contains(q.title)) g.titles.add(q.title)` 去重，`count` 是去重后题名数，不是题数。题名并不唯一（如多道题都叫“第 1 题/选择题”），同名题会被合并计数，Top5 排序与“X 道题”文案都算错；`detail` 行用题名拼接，同名题也只显示一次。
- 复现/证据：代码即证据。`_WeakGroup.titles` 是 `List<String>` 题名，未存题 id。
- 修的方向：`_WeakGroup` 改存题 id 集合（或 `List<String> questionIds`）做去重计数，`titles` 仅作展示；排序与 `countText` 以题 id 数为准。

#### P1-3 学习报告的弱点 Top5 与学科分布把未整理题、已归档题也算进去了，与错题本口径不一致

- 位置：`lib/modules/report/report_page.dart:132`（`_load` 用 `repo.all(includeArchived: true)`）、`:169-172`（`_questionsInRange` 只按 `createdAt` 过滤）、`:179-238`（`_causeGroups` / `_kpGroups`）、`:303-306` 与文末 `_distRow` 循环。
- 现象/后果：报告的弱点分组与“错在哪个学科 · X 道错题”分布统计的是“所选范围内收集的全部题”，含未整理（还在整理工作台排队、未进错题本）与已归档的题。错题本只收已整理未归档题（`wrongbook_page.dart` `_filteredAll`），封面题数、目录计数亦同口径。于是同一科同一时段，报告分布数会大于错题本题数；弱点 Top5 可能由尚未整理、甚至已归档的题顶上去，点行进错题本后列表里找不到这些题。
- 复现/证据：`_questionsInRange` 无 `isOrganized / !isArchived` 过滤；`_causeGroups`、`_kpGroups`、`_distRow` 均直接消费 `qsIn`。
- 修的方向：`_questionsInRange` 增加 `q.isOrganized && !q.isArchived` 过滤（与错题本收录口径一致）；若 HTML `qsIn` 原意确含未整理题，需 Meng 裁决并把该口径写进报告页注释，而不是现状无注释。

#### P1-4 封面三徽标“要复习/待复查”与首页焦点卡、各科概览、左导航速览的口径不一致

- 位置：`lib/data/repository.dart:106-141`（`subjectCounts`，封面用） vs `lib/data/repository.dart:63-99`（`dueToday` / `homeRevCounts`，首页与导航用）；`lib/modules/home/home_page.dart:130-145`（焦点卡拆分）；`lib/modules/wrongbook/wrongbook_shelf.dart` 封面 `_bookStat('要复习', counts.$1)` / `_bookStat('待复查', counts.$2)`。
- 现象/后果：两套口径对同一道题的归类不同。`subjectCounts`：`toReview` = 任一错因未解决的题，`toRecheck` = 任一错因到复查时间的题——一道题可同时计入两项（`repository.dart:97-99` 注释亦明说“一道题可同时计入要复习与待复查”）。首页焦点卡拆分是互斥的：有未解决错因计待解决，只有复查到期才计复查，两者之和 = 要复习总数（`home_page.dart:130-145`）；`homeRevCounts`（导航速览与首页各科格共用）按 `dueToday` 数题，含纯复查题。于是同一科：封面“要复习”不含纯复查题（比首页各科格的“要复习”少），封面“待复查”含混有未解决错因的题（比首页焦点卡“复查”多），两处数字对不上；封面两徽标之和还可能大于该科要复习题数。
- 复现/证据：`subjectCounts`（`repository.dart:130-136`）与首页拆分循环（`home_page.dart:138-145`）逐行对照即见：前者两个 `if` 独立计数，后者 `if/else` 互斥。
- 修的方向：由 Meng 定唯一口径后统一：建议封面沿用首页互斥拆分（要复习 = 待解决数、待复查 = 仅复查数，两者之和 = `homeRevCounts` 该科数），或反之首页改双计；不要两处各自定义。`subjectCounts` 的返回三元组语义（第三项 `solved` 未在封面显示，见“干净的地方”）也应随之在注释里写清。

#### P1-5 错题本的排序与每页条数、复习的每页条数，在每次 `_load()` 后都被重置回设置默认值

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:171`（`_pageSize = settings.pageSize`）、`:179`（`_sort = settings.wrongbookSort`）；`lib/modules/review/review_page.dart:283`（`_pageSize = settings.pageSize`）。
- 现象/后果：用户在列表页把排序改成“时间旧→新”或把每页改成 20 后，只要进一次详情再回来、点一次星、做一次批量操作（错题本 `_load()` 有 19 处调用，见 B2-LEFTOVER-WRONGBOOK-VIEW.md 的枚举），排序/页数就跳回设置默认值。视图模式（大卡片/紧凑列表）已在 B2 用 `_viewModeInitialized` 标志修掉同类问题，但 `_sort` / `_pageSize` 被该文档明确写为“仍每次跟随设置（不在本次范围，未动）”，问题至今活着。复习页更甚：字段注释（`review_page.dart:147-149`）写着“只在打开时从设置默认值读一次初值”，代码却在每次 `_load()` 无条件覆盖，与注释直接矛盾；会话结束、暂停回列表都会重置页数。
- 复现/证据：代码即证据；`_load()` 内 `_viewMode` 有 `if (!_viewModeInitialized)` 保护（`wrongbook_page.dart:174-177`），而 `_pageSize` / `_sort` 两行在其外、无保护。
- 修的方向：与 `_viewModeInitialized` 同款：排序与页数也只在首次 `_load()` 取设置默认值，之后保留页内选择；或把“页内改动是否写回设置”由 Meng 定（现复习页注释称“下拉改动不写库、不改设置默认值”，与“每次 `_load` 覆盖”合起来等于页内改动随时丢失）。修后补测：改排序/页数 → 进详情返回 → 仍保留。

#### P1-6 复习会话里跳过一题的最后一个错因，会把上一个已写完补救的错因重新呈现一遍

- 位置：`lib/modules/review/review_page.dart:571-603`（`_skipCurrent`）。
- 现象/后果：设一题有错因 A、B、C，用户已依次写完 A、B 的补救，`_ci = 2`（C）时点“跳过”：`removeAt(2)` 后块剩 [A, B]，`_ci >= length` 触发 `_ci = length - 1 = 1`，`_phase` 回到 `recall`，于是 B 被重新呈现（补救输入框已清空——内容已存库，未丢，但用户须多点一次“下一步”才能进重做）。按模型，A、B 既已走完，第 ①② 步应结束、直接进第 ③ 步重做；跳过 C 不应倒退。
- 复现/证据：`review_page.dart:592-599` 的分支逻辑；`_nextFromRemedy`（`:605-620`）是 `_ci < length - 1` 才前进、否则进 `redo`，`_skipCurrent` 未复用该收尾判断。
- 修的方向：跳过后若 `_ci` 已越过块尾（即剩余错因全部已走完 ①② 步），直接进 `_Phase.redo` 而不是把 `_ci` 钳回 `length - 1`；只有块中部跳过时才停在当前 `_ci`（下一个未走完的错因自动顶上来）。加一测：三错因题，前两个走完、跳过第三个，应直接出现重做步。

### P2

#### P2-1 文件夹同名判重只查同层兄弟，不查整科

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:563-580`（`_addFolder`，`siblings` 为同父文件夹）、`:593-608`（`_saveRename` 同理）、`:685-730`（`_moveOneFolder` 只查目标同层）。
- 现象/后果：已定决定是“同一学科不能有两个同名文件夹”（见任务清单与 `subjects_page.dart` 的学科判重口径）。现顶层已有“试卷”时，仍可在另一顶层文件夹下新建同名子文件夹“试卷”，或把文件夹移入含同名子的目标下（`_moveOneFolder` 的目标同名检查在 `:705-707` 也只查 `_subFolders(targetParentId)`）。同名文件夹跨层并存后，目录行靠“父名 / 子名”区分尚可辨认，但判重提示“已经有了”失去整科一致性。
- 修的方向：新建/改名/移入三处把判重范围改为整科（`_subjectFolders(subjectId)` 内按名判重，排除自身）；或由 Meng 改决定为“只同层判重”，并把该口径写进目录页注释。注意数据层 `upsertFolder`（`db_catalog.dart:378-388`）无唯一约束，判重只能靠页内逻辑。

#### P2-2 错题本“学科首字母”排序写死数学/英语/其他三档，新学科排不准

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:435-440`（`subjectRank`：`'math' => 0, 'english' => 1, _ => 2`）。
- 现象/后果：已定排序是“学科首字母 A→Z”。新学科（如化学、物理）一律 rank 2，与政治并列、只按创建时间倒序排，既不是首字母序，也不是入库序；三科以上时排序结果与下拉文案“学科首字母 A → Z”不符。注释（`:433-434`）自称“数学 S / 英语 Y / 政治 Z”，但代码并未按首字母算，而是按 id 硬编码。
- 修的方向：按学科名首字母（或库内学科顺序 + 名称）算 rank；未知学科不再统一落到 2。顺带与 P0-1 一并修（`'subject'` 设置值与 `subj-asc/subj-desc` 的映射）。

#### P2-3 目录页/书架的题数含已掌握题，但列表默认隐藏已掌握；“已解决 X 道不显示”提示的计数是整科口径，不是当前文件夹口径

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:212-222`（`_folderCount`：只排除未整理与已归档，不排除已掌握）、`lib/modules/wrongbook/wrongbook_shelf.dart` 封面 `total`（同口径）；`lib/modules/wrongbook/wrongbook_list.dart:455-474`（`_buildMasteredNote`）。
- 现象/后果：目录行写着“5 道题”，点进去列表默认只显示未掌握的 3 道（另 2 道已掌握被 `_filteredAll` 的已掌握默认隐藏滤掉），用户会以为丢题；`_buildMasteredNote` 的 `hidden` 按整科算（`:458-467` 的 `where` 只限定 `_subjectId`，不限 `_folderId`），在某文件夹列表里却写“这科错因已全部解决 X 道”，X 与当前文件夹无关。
- 修的方向：二选一：(a) 目录/封面计数与列表默认视图同口径（扣掉已掌握，另在行上或提示里说明）；(b) 保持计数含已掌握，但 `_buildMasteredNote` 的 hidden 改为当前文件夹子树口径，并在目录行加“含已掌握”说明。由 Meng 定。

#### P2-4 复习页“还没加入复习的题”把未整理题、无错因题也列进去了，而这些题根本加不进复习

- 位置：`lib/modules/review/review_page.dart:198-199`（`_load`：`if (!q.reviewJoined && !q.isArchived) notJoined.add(q)`），展示见 `:1298-1330`（`_buildNotJoinedBox`）。
- 现象/后果：`notJoined` 只排除已归档，未排除未整理与无错因。详情页规则是“未整理的题不能加入复习”（`question_detail_page.dart:1652`），且 `setReviewJoined` 在错因为空时返回 false（`repository.dart:36-40`）。于是复习页会列出一批点“加入复习”也加不进去的题名，并配文“到这些题的题目详情「复习记录」里点「加入复习」才会进来”，用户照做后发现无此按钮。
- 修的方向：`notJoined` 改为 `!reviewJoined && isOrganized && !isArchived && allCauses.isNotEmpty`；或分两行写清“未整理的题先去整理工作台”。

#### P2-5 错题本批量加标签可新建含 `,` 或 `|` 的标签，绕过了 §6 第 4 条的禁令

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:845-885`（`_batchAddTag`，新建标签直接 `repo.addTag(newCtrl.text.trim())`，无校验）；对照 `lib/modules/subjects/subjects_page.dart:215` 与 `:396`（两处均调 `hasBannedNameSeparator` 拦截，模型见 `lib/models/models.dart:214`）。
- 现象/后果：学科管理页新建/改名标签都禁 `,` 与 `|`，但错题本批量加标签的新建输入框不禁；数据层 `insertTag`（`db_catalog.dart:401-407`）亦无校验（`ConflictAlgorithm.ignore`）。虽多值字段已改 JSON、逗号不再切坏解析，但禁令本身被绕过，且该标签回到学科管理页后无法改名（改名校验会拦）。
- 修的方向：在 `_batchAddTag` 新建分支加同一校验（`hasBannedNameSeparator` → snack“不能含逗号或竖线”），与学科管理页文案一致。

#### P2-6 批量操作用 `firstWhere` 查题、无事务、无失败反馈；跨学科勾选批量移文件夹时静默跳过

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:845-1000`（`_batchAddTag` / `_batchMoveToFolder` / `_batchMoveOut` / `_batchFavorite` / `_batchArchive` / `_batchDeleteConfirmed`）。
- 现象/后果：(a) 六处循环均用 `_questions.firstWhere((x) => x.id == id)`，若勾选题在两次 `_load()` 间已被别处删掉/归档过滤掉，会抛 `StateError`，整个批量操作中断在中断处，之前已执行的留下、之后的不执行，且无提示；(b) `_batchMoveToFolder`（`:928-944`）对 `q.subjectId != target.subjectId` 的题直接 `continue`，但从“全部学科”入口（`filterCause` / 知识点筛选进列表，`_subjectId == null`）勾选跨科题时，这些题被静默跳过，选后清空、无任何说明；(c) 批量删除/归档逐条 `await`，中途失败即半截状态（“多个删除操作未包事务”亦是 MEMORY 记的已知尾巴）。
- 修的方向：循环内用 `firstWhereOrNull` 跳过已不存在的题并汇总提示；`_batchMoveToFolder` 在跨科跳过时 snack 告知跳过 N 道；批量删除/归档按 §4.2 模式包事务或至少失败回滚并报错。注意 `_batchFolderOptions`（`:911-917`）只返回当前学科文件夹，跨科场景下应在进入批量模式时就说明。

#### P2-7 目录页文件夹拖拽调顺序：往下拖会多移一位

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:765-790`（`_reorderFolder`）；缝隙渲染见 `lib/modules/wrongbook/wrongbook_directory.dart`（`_buildGapTarget(null, i)`，i 为 0..行数，行 i 之前）。
- 现象/后果：`_reorderFolder` 先 `removeWhere` 删掉被拖行，再 `insert(toIndex)`。缝隙下标是“删除前”的位置：把 A（第 0 行）拖到 A 与 B 之间的缝隙（index 1，期望不动）→ 删 A 得 [B, C…] 再插到 1 → [B, A, C…]，A 被移到 B 之后；往下拖一律多移一位，往上拖才正确。
- 复现/证据：三行 [A, B, C]，拖 A 到缝隙 1，期望 [A, B, C] 不变，实际得 [B, A, C]。
- 修的方向：插入前按被拖行原下标修正目标下标（`if (toIndex > fromIndex) toIndex -= 1`，`fromIndex` 为删除前下标），或把缝隙下标定义为“删除后”的位置并改渲染侧。加一测覆盖上/下两个方向。

#### P2-8 `_applyDrop` 的注释称“子文件夹拖到顶层行之间 = 移进该顶层”，但该路径实际走不通

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:795-800`（注释） vs `lib/modules/wrongbook/wrongbook_directory.dart` `_buildGapTarget` 的 `onWillAcceptWithDetails`（`if (dragged.parentId != parentId) return false`）。
- 现象/后果：顶层缝隙只接受 `parentId == null` 的拖拽，子文件夹拖过去直接被拒；`_applyDrop` 的第三条注释与 `_buildGapTarget` 的实现矛盾，读代码会误判行为。实际把子文件夹移回顶层只能拖到「全部题目」行（`_DropKind.promote`），该路径本身是对的。
- 修的方向：删掉或修正 `_applyDrop` 的第三条注释，以 `_buildGapTarget` 的实现为准。

#### P2-9 进错题本另一科/另一文件夹时，搜索与筛选条件不清零，旧条件带到新范围

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:518-545`（`_openList` 只清 `_page/_selected/_batchMode`）、`:546-562`（`_openDirectory` 只清目录侧状态）、`:564-574`（`_openShelf`）。
- 现象/后果：数学书里搜“三角函数”、筛“仅收藏”后，返回书架打开英语书、进其目录/列表，搜索框与筛选仍是数学那套条件，列表可能为空，用户须手动点“重置”。`_resetFilters`（`:497-516`）存在但三处导航均未调用。
- 修的方向：`_openList` / `_openDirectory` 在切换学科时调用 `_resetFilters`（保留文件夹/学科归属本身）；或由 Meng 定为“筛选跨书保留”，并把该口径写进注释。

#### P2-10 “最近一周”实际是 8 天；搜索日期须写无前导零格式才命中

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:405-419`（`_filterTimeRange`：`limit = 7`，`age >= 0 && age <= limit`）；`:334`（`_searchHaystack` 的日期串）。
- 现象/后果：(a) `week` 取 `age <= 7`，含今天共 8 个自然日，与“最近一周”通常理解（7 天）差一天；(b) 搜索日期拼成 `2026-11-5`（月/日无前导零），搜 `2026-11-05` 命中不了，搜 `2026-11-5` 才能命中。
- 修的方向：(a) `age < 7` 或 `age <= 6`（由 Meng 定 7 天是否含今天）；(b) 日期串补零到 `yyyy-MM-dd`，或同时收两种写法。两者均为展示/过滤口径小偏差，无数据风险。

#### P2-11 书架顶部入口的跨学科已归档视图无分页、无搜索

- 位置：`lib/modules/wrongbook/wrongbook_list.dart:1102-1140`（`_buildArchived`：`archived` 全量排序后直接 `_buildArchivedRows`，无 `_buildPagination`、无工具条）。
- 现象/后果：归档题一多，整页一次渲染全部行；且与书内已归档视图（走 `_buildList`，有分页）不一致。归档是只增不减的冷数据，量上来后首屏与滚动成本都高。
- 修的方向：复用 `_buildList` 的分页（或给 `_buildArchived` 加与书内一致的分页器，默认 10 条）；搜索可暂缓，先补分页。

#### P2-12 复习页“已解决的错因”区与“还没加入复习的题”盒不分页

- 位置：`lib/modules/review/review_page.dart`：已解决区 `_buildCuredSection` / `_buildCuredRow`（渲染 `_filteredCured` 全部，分组无分页）；未加入盒 `_buildNotJoinedBox`（`:1298-1330`，全部题名拼进一个 `Text`）。
- 现象/后果：待解决列表有分页（默认 10），已解决区与未加入盒却全量渲染；题多时页尾很长，且未加入盒的长字符串无换行分行以外的结构。量级尚小时无感，是扩展性缺口。
- 修的方向：已解决区复用同一分页或折叠默认收起；未加入盒按学科分行、超出 N 道折叠。低优先级。

#### P2-13 首页、错题本、复习页的 `_load()` 没有 try/catch，读库失败会一直转圈

- 位置：`lib/modules/home/home_page.dart:117-155`、`lib/modules/wrongbook/wrongbook_page.dart:147-186`、`lib/modules/review/review_page.dart:184-290` 的 `_load()` 均无 try/catch；对照 `lib/modules/report/report_page.dart:129-157` 与 `lib/modules/subjects/subjects_page.dart:126-158` 均有 try/catch + 错误横幅（`_loadError`）。
- 现象/后果：`repo` 任一调用抛错时，`_loading` 恒为 true，页面永远是 `CircularProgressIndicator`，无横幅、无重试入口。报告/学科页已证明项目内有现成错误态模式可复用。
- 修的方向：三处 `_load()` 包 try/catch，失败置 `_loadError` 并出与报告页同款横幅（留住旧内容或给重试按钮）。

#### P2-14 复习会话建块时忽略错因筛选：一题带全部待治错因进会话

- 位置：`lib/modules/review/review_page.dart:340-380`（`_buildBlocks`：按分组顺序取题后，`causes = _pendingByQ[qid]` 全部待治错因），调用方 `_startSession`（`:386-440`，含 `fromGroup` 跳转）。
- 现象/后果：列表按错因筛出“计算错误”后点某组“开始解决”，会话里该题的其他待治错因（如“审题失误”）也被带进来一并解决。代码注释（`:340-342`）明说“每题带它全部待治错因”是刻意设计（与列表头“ 一道题有多个错因时在列表里只出现一次，一道题里挨着解决完”一致），但与“按错因筛选”的用户预期冲突：筛出的错因之外的错因会被无意治愈。
- 修的方向：由 Meng 裁决：(a) 维持现状，把“会话按题走、筛选只定起点”写进列表页说明；(b) 会话建块只取筛选命中的错因（`fromGroup` 或 `_causeFilter`），其余错因留待下次。

#### P2-15 设置页缓存清理预览只扫数据目录顶层，嵌套的缓存目录会被漏计

- 位置：`lib/modules/settings/settings_page.dart:540-600`（`_scanCacheSync` 的 `walk`）。
- 现象/后果：`walk(Directory d, {bool insideCacheDir = false})` 只 `listSync()` 当前目录一层，从不递归进普通子目录（`insideCacheDir: true` 的调用点不存在），顶层缓存目录虽在 `add()` 里递归计字节，但藏在某子目录下的 `cache/thumb/tmp` 目录不会被发现；预览数字“临时文件 X 个、缩略图 X 张、共约 X MB”可能偏小，清理也删不到它们。
- 修的方向：`walk` 对非缓存目录递归进入（`insideCacheDir` 透传），或改为整树递归扫描后按名归类。

#### P2-16 第 8 科及以后的新学科颜色回落到第一色（与数学同蓝）

- 位置：`lib/modules/subjects/subjects_page.dart:295-303`（`_addSubject`：`_newSubjectColors.firstWhere((c) => !usedColors.contains(c), orElse: () => _newSubjectColors.first)`）；色表见 `:36-53`（7 色）。
- 现象/后果：7 色用完后第 8 科起一律拿 `_newSubjectColors.first`（蓝 `0xFF2E7CF6`，与数学同色），学科圆点、标题色、封面以外的学科色全部撞车。注释只写到“第 6、7 科不再回落数学蓝”，未覆盖第 8 科起。
- 修的方向：色表扩到 10 色以上，或用完后按色相轮转生成新色；低优先级（当前仅 3 科）。

#### P2-17 封面学科名与“错 题 本”用固定字号，不跟全局字号缩放

- 位置：`lib/modules/wrongbook/wrongbook_shelf.dart` `_buildBook` 内：学科名 `TextStyle(fontSize: 52, letterSpacing: 3.12)`（固定值）、副标题 `fontSize: 16, letterSpacing: 13.6`（固定值）；对照同函数内其余尺寸均乘 `scale`（如 `SizedBox(height: 40.4 * scale)`、书高 `bookMinHeight * scale`）。
- 现象/后果：三档字号（标准/大/特大）下书体、计数条、按钮都放大，唯学科名与副标题不动；大字号时封面留白比例失衡（B2 报告的 74.4px 纵向排布只在标准字号下实测过）。
- 修的方向：两处字号与字距同乘 `scale`（并重测 B2 的 74.4px 占位在三档字号下的效果）；或由 Meng 定封面字不跟缩放并写进注释。

#### P2-18 错题本列表页标题里文件夹分支与学科分支写出同一字符串，文件夹名从不显示

- 位置：`lib/modules/wrongbook/wrongbook_list.dart:21-27`（`title` 三元：`folder != null && folder.name.isNotEmpty` 分支与 `subject != null` 分支均为 `'${subject?.name ?? ''} · 错题本'`）。
- 现象/后果：进某文件夹的列表与进该科“全部题目”的标题完全相同，用户无法从标题分辨当前在哪个文件夹；`folder` 变量只用于该判断，其余无用。属死分支（非功能 bug）。
- 修的方向：文件夹分支标题改为 `'${subject?.name} · ${folder.name}'` 或删掉该分支（若刻意不显示文件夹名，删分支并留注释）。

#### P2-19 从报告弱点行（无学科）或错因筛选进错题本列表时，打开的书外框 fallback 成数学封面色

- 位置：`lib/modules/wrongbook/wrongbook_list.dart:58`（`_openBookFrame(subjectId: _subjectId ?? 'math', ...)`）。
- 现象/后果：`WrongbookPage` 以 `filterCause` / `filterKnowledgePointId` 进列表时（`wrongbook_page.dart:128-133`，`_subjectId` 为 null），列表外框用数学蓝，与“跨学科列表”身份不符。报告点弱点行时带 `subjectId`，不走此分支；走此分支的是无学科的错因/知识点筛选入口。
- 修的方向：`_subjectId == null` 时外框用中性色或按列表首题学科色；低优先级。

#### P2-20 学科管理封面选择器接了两套点按处理（外层 GestureDetector + QmCoverMini.onTap）

- 位置：`lib/modules/subjects/subjects_page.dart` `_buildCoverPicker` 内样式小图：外层 `GestureDetector(onTap: () => _setCover(s, style: style))` 包裹 `QmCoverMini(..., onTap: () => _setCover(s, style: style))`（`QmCoverMini` 内为 `_QmPressable`，见 `lib/widgets/uikit.dart:817-920`）。
- 现象/后果：同一动作接了两处回调，依赖手势竞技场只胜出一个才不致双写；当前实测未见双写（`_setCover` 本身幂等：同值 `saveSubject` + `_load`），但属于冗余接线，后续改任一处都易漏另一处。
- 修的方向：只留一处（建议留 `QmCoverMini.onTap`，删外层 `GestureDetector` 的 `onTap`，外层只保留布局）。

#### P2-21 学习报告两处“近似口径”属实，属已裁决的残留而非新 bug（列出备查）

- 位置：`lib/modules/report/report_page.dart:281-300`。
- 现象：(a) 已解决/待解决按 `lastCheck` 过滤，`lastCheck == null` 视为在范围内、计入所有范围（`report_page.dart:284-295` 的 `(r.lastCheck == null || _inRange(...))`），从未自查的待解决错因在“本周”里也被计入；(b) “复查通过率”分母是范围内全部已判定自查记录（`judged`），并非仅复查记录（`review_history` 无复查备注字段，页头注释 `:30-33` 已明说“以全部已判定记录为近似”）。(a) 是 S8 B1 经 Meng 2026-11-13 裁决的口径，页头注释 `:24-29` 亦有说明；(b) 同为文档化近似。
- 修的方向：不修（除非 Meng 改裁决）。若将来 `CauseRecord` 补“治愈日期”与 `review_history` 补“是否复查”字段，两处可分别精确化；届时先改模型再改此页。

#### P2-22 复习断点恢复条的范围文案写死“全部待解决错因”

- 位置：`lib/modules/review/review_page.dart:396-401`（`_startSession(resume: true)` 的 `scopeLabel = '全部待解决错因'`）。
- 现象/后果：断点本身是按当时筛选/分组建的队列，恢复时文案却一律称“全部”，与按学科筛选后暂停再恢复的实际范围不符（队列内容是对的，只有文案错）。
- 修的方向：恢复时按保存队列的学科范围生成文案，或把断点保存时连同范围标签一起存。

#### P2-23 “重置”后排序回到设置默认值，而非既定“时间新→旧”

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:497-516`（`_resetFilters`：`_sort = _defaultSort`，注释称“排序回到设置里的错题本默认排序”）。
- 现象/后果：MEMORY 记的既定决定是“「重置」 beside filter clears search, all filters, sort back to time new→old”。若用户把设置默认排序改成“旧→新”或“学科首字母”，点“重置”后排序停在该默认值，而非新→旧，与决定字面不符。`_defaultSort` 本身取自设置（`:180`），链路自洽，只是与旧决定冲突。
- 修的方向：由 Meng 定：(a) 重置固定回 `'new'`（改 `_resetFilters` 与注释）；(b) 维持“回设置默认”，更新 MEMORY/决定记录。注意若选 (a)，P0-1 修掉 `'subject'` 之前，重置到 `'new'` 反而能绕开 P0-1 的崩溃路径。

### 死代码 / 过时注释（不另计入 30 条）

- `lib/modules/wrongbook/wrongbook_page.dart:1097-1115` 的 `_styledDropdown` 有 `Key? key` 可选参数，全项目无任何调用方传 `key`（`grep "key:"` 0 处）：删掉该参数或留作备用并注释。
- `lib/modules/wrongbook/wrongbook_page.dart:795-800` 的 `_applyDrop` 第三条注释（见 P2-8）与实现矛盾，属过时注释。
- `test/wrongbook_page_test.dart:1027-1029` 的注释仍写“`_load` 会把视图重置为设置里的默认视图（大卡片）……切回紧凑列表再断言”：B2 修复后该行为已不存在，测试里多点一次「紧凑列表」是无操作（B2-LEFTOVER-WRONGBOOK-VIEW.md“遗留”节已 flag，本次核实属实——注释与多余点击仍在原处）。测试文件不在本次审查范围，列出备查，不改。
- `lib/modules/wrongbook/wrongbook_page.dart:209-211` 的 `_folderCount` 注释称“基线 `_folderCount` 只排除已归档，这里补上 `isOrganized`”——注释本身属实（现代码确含 `isOrganized`），但与 P2-3 的“已掌握仍计入”一并读时易误导，修 P2-3 时顺手更新该注释。

## B4 拆分完整性核查

- 接线：主文件 `wrongbook_page.dart:9-13` 声明 5 个 `part`；5 个拆出文件各含 1 行 `part of 'wrongbook_page.dart'`；3 个视图 extension（`_WrongbookShelfBuild` / `_WrongbookDirectoryBuild` / `_WrongbookListBuild`）各 1 个；封面绘制器与叶部件无 extension，逐字搬移。
- `_update` 转发：主文件 `:1006` 定义 `void _update(VoidCallback fn) => setState(fn);`；拆出文件内 `_update(` 出现次数 shelf 6、directory 20、list 28，合计 **54 处**，与 `B4-WRONGBOOK.md` 的数字逐项一致；拆出文件内 `setState(` 为 0，主文件保留 17 处 `setState(`（业务逻辑本体）。与 B4 文档“54 处机械替换、无 tear-off”的说法一致。
- `flutter analyze lib/modules/wrongbook/`（本次随范围分析跑过）：0 问题。
- 未发现拆分引入的行为变化：状态字段、业务方法、导航方法全部留在主文件；视图方法只换了调用 `setState` 的壳（语义等价）；`_buildBook` 的书脊负偏移、左暗带外移（B2-WIN11BUG-SPINE 的修法）在 `wrongbook_shelf.dart` 外层 Stack 中完整保留（`left/top/bottom: -bookPadding* * scale`，书脊宽 `bookSpineWidth * scale`）；封面 6 样式 × 7 色的 `CoverStyles` / `CoverColors`（`models.dart:50-84`）与 `CoverTokens` 的取值未动；`_CoverFoldPainter` 的三角/渐变/圆角、`_DashedBorderPainter` 的不对称圆角（4/9/9/4）均在 `wrongbook_cover.dart` 中原样存在。
- 一处提醒（非问题）：`wrongbook_list.dart` 仍有 1142 行，是拆分后最大的文件，B4 文档亦已注明“后续可再拆筛选面板/卡片/分页，需传参重构、另立任务”。

## B3 汇总遗留点核查（只核与本页有关的）

- “视图模式在 `_load()` 后弹回默认”（B2-LEFTOVER-WRONGBOOK-VIEW.md）：**已修、属实**。`_viewModeInitialized` 标志在 `wrongbook_page.dart:100-106` 与 `:174-177`，逻辑与文档一致。但同函数的 `_sort` / `_pageSize` 仍每次跟随设置，文档明确写“不在本次范围、未动”——本次核实该遗留仍活着，见 P1-5。
- “删除确认统一模态弹窗”（B3-DELETE-CONFIRM.md / B3-SUMMARY.md §7）：**属实**。本页范围内的删除确认——文件夹删除（`wrongbook_page.dart` `_askDeleteFolder`，13B 后果文案：只在该文件夹的题数 / 多文件夹题数 / 子文件夹数 + “只删这一科”）、批量删除（`_askBatchDelete`，“删了就没了，确定吗”）、学科删除（`subjects_page.dart` `_askDelete`，含题数与文件夹后果）、章节/知识点/标签/试卷删除、设置清空演示数据/孤儿清理/恢复——核查均走 `AlertDialog` 模态弹窗，未见残留行内确认条。失败任务的删除确认不在本页范围，未核。
- “`double`（双线框）样式仍显示折角”（B2-WRONGBOOK-COVER.md §7 第 1 条）：**属实、未动**。`wrongbook_shelf.dart` 的折角 `Positioned` 不分样式绘制，`_CoverPatternPainter` 的 `'double'` 分支（`wrongbook_cover.dart`）只画双线框、不藏折角。按任务交代，`double` 折角是否藏由 Meng 与 CodeBuddy 协调，Muse 不做，本次只记录。
- 边界文档相关问题（文档组负责）：不在本次核查范围，未核。

## 审过且干净的地方（抽查结论）

- 封面顶部无任何英文：`wrongbook_shelf.dart` 的 `_buildBook` 无英文行，只有 40.4px 占位 + 学科名 + “错 题 本”；`grep MATHEMATICS/ENGLISH/POLITICS/enName` 在错题本模块 0 命中（B2 报告同结论）。
- 书脊贴左边缘、通顶通底：外层 Stack 负偏移写法完整（见 B4 核查节）；左暗带随书脊外移、`_CoverInsetShadowPainter` 的 `drawLeft/drawRight` 开关两处分用正确，无旧位置残留暗带。
- 封面样式与颜色两套独立系统：6 样式（`CoverStyles.all`）× 7 颜色（`CoverColors.all`，含 grey）只叠纹样/只换底色；学科管理页 `_setCover`（`subjects_page.dart`）样式与颜色分开保存、点即生效；新学科封面默认灰色（`_addSubject` 显式传 `coverColor: 'grey'`，模型默认蓝未被误用）。
- 封面三徽标始终显示：`_bookStat('道题'/'要复习'/'待复查')` 无条件渲染（0 值也显示）；题数口径为已整理未归档（与列表收录口径一致），唯口径细节见 P1-4 / P2-3。
- 错题本默认大卡片、可切紧凑列表；已掌握默认隐藏（`_filteredAll`，错因状态筛到“已解决”时才显示）、已归档默认隐藏（书架顶部入口与书内归档视图分离）；收藏不优先（排序 switch 无收藏因子）；删除确认走模态弹窗（见 B3 核查节）。
- 目录页文件夹按学科隔离（`_subjectFolders` / `_topFolders` 均按 `subjectId` 过滤）、子文件夹一层（`_moveOneFolder` 的“子文件夹只能有一层 / 带子文件夹的一级不能再放进别的文件夹 / 不能移到自己下面”三禁则完整，含循环移动拦截）；删除文件夹 13B 后果文案完整（只在该文件夹的题数、多文件夹题数、子文件夹数、只删这一科）。
- 复习是错因治疗模型，无翻卡/间隔重复残留：手动“加入复习”才进列表（`review_page.dart` `_load` 的 `reviewJoined` 门控 + 详情页“未整理不能加入”）；治愈判定走 `repository.recordSelfCheck`（同一错因同一题自查“已解决”满 `cureChecks` 次，默认 2，可设 1/2/3；复查通过不加计数）；治愈后复查日 = 今天 + `recheckIntervalDays`（默认 7，可设 3/7/14）；跳过按题×错因计次，第 1 次追加队尾、第 2 次留到下次（默认 2，可设 1/2；`_skipCurrent` 的计数键与阈值判断正确）；每批错因数默认不限（`causesPerSession = 0`，`_buildBlocks` 的 limit 截断正确）；自查“不确定”不算（`recordSelfCheck` 原样返回 + 会话内不改记录）；复查不过清零打回解决中。
- 学习报告结构：只答三个问题，无统计墙、无趋势线、无导出；时间范围默认本周、本周 = 周一到今天（`_rangeStart` 的 `today.subtract(weekday - 1)`）；薄弱 Top5 按关联题数降序、设“看更多”展开全部；“接下来练什么”一句话、无按钮；空态为“还没有复习记录，先去复习吧”+ 去复习按钮。
- 设置默认值与 `AppSettings.defaults`（`models.dart:537-572`）逐项一致：主题跟随系统、字体标准、问候“今天也要加油呀”、每页 10 条、错题本默认大卡片、复习默认按加入时间、提醒默认 20:00；设置页各分段改动均走 `_apply` → `onSettingsChanged` 保存，未见双写（问候语留空保存不生效、恢复默认均有处理）。
- 学科删除删全部题目与文件夹：数据层 `deleteSubjectFromImpl`（`db_catalog.dart:17-61`）同事务删该科题目（含框/解决记录/自查历史）、收集任务、recent_tasks、文件夹、知识点、学科行；学科管理页删除文案与之相符；文件夹同名判重在同层内工作（跨层见 P2-1）。
- 首页焦点卡与导航速览同口径：焦点卡总数 = `dueToday` 题数（`home_page.dart` 的待解决/复查互斥拆分之和），各科格与左导航速览均用 `homeRevCounts`（`app.dart` `_refreshBadges` 同源）；继续上次优先级（复习 > 整理 > 收集）与中英文 kind 双认（种子写中文“整理/收集”的兼容处理）完整；快速收集只有文件导入入口，无手动录入。
- 复习列表断点：暂停保存扁平队列 + 位置（`_flatQueue` / `saveReviewState`），恢复时校验队列是否仍有待治项、无效清掉；`_finishSession` 的剩余数口径与主列表一致（已归档不计）。
- 错题本批量操作的作用域与文案：“移入/加入文件夹”按是否在文件夹内进来的区分正确；“批量移出当前文件夹”只在文件夹内出现；全选按“当前结果”全选且筛选变化后只保留仍在结果内的勾选（`_applyFilterChange`）。
- 学科管理页其余段：知识点树按学科页签、章节默认折起、加章节须同时给第一个知识点；标签/试卷段的增删改名与判重完整；封面样式块每科独立、6 样式 × 7 色点即生效。
