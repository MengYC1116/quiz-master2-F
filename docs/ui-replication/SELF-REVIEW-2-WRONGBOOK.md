# 第二次自审报告：错题本 / 复习 / 学习报告 / 首页（+ 学科管理 / 设置相关页）

- 审查员：错题本/复习/报告/首页审阅组（只审、不改）
- 日期：2026-11-15
- 工作树：`~/workspace/quiz-master2-UI`，分支 `ui-replication`（Batch 1～5 改动均未提交、未推；`git diff` 相对 HEAD `bca8586` 是五批总量，本次以 B5 报告指出的位置定位改动）
- 范围：`lib/modules/wrongbook/`（6 个文件）、`lib/modules/review/review_page.dart`、`lib/modules/report/report_page.dart`、`lib/modules/home/home_page.dart`、`lib/modules/subjects/subjects_page.dart`、`lib/modules/settings/settings_page.dart`；另按需对照 `lib/data/repository.dart`、`lib/models/models.dart`、`lib/widgets/widgets.dart`、`lib/widgets/uikit.dart`、`lib/theme/design_tokens.dart`、`lib/app.dart` 核对口径
- 对照基线：`docs/ui-replication/SELF-REVIEW-WRONGBOOK.md`（第一次自审，本组 30 条）、`B5-P0-2-sort.md`、`B5-P1-1.md`、`B5-P1-COUNTS.md`、`B5-P1-9-12-13.md`、`B5-P1-10-11.md`、`B5-P1-15.md`、`B5-P2-WRONGBOOK.md`、`B5-SUMMARY.md`
- 本报告只写此文件，未改任何代码、未 commit/push、未动其他文件。

## 方法与验证

- 以读代码为主，逐条对照第一次自审的原文与修法，不只信 B5 报告自述。
- 测试（`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，机器空闲时串行跑）：
  - `test/wrongbook_page_test.dart`：**68/68 通过**（含 B5 新增 21 项）。
  - `test/review_page_test.dart` + `test/report_page_test.dart`：**61/61 通过**。
  - `test/home_page_test.dart` + `test/subjects_page_test.dart` + `test/b5_p1_1_subject_counts_test.dart` + `test/b3_p11_layer2_downgrade_test.dart`：**56/56 通过**。
  - `test/settings_page_test.dart`：**未能跑**。本次审查中途服务/VM 重启后 `/usr/bin/clang` 丢失，`flutter test` 在 native assets 构建处失败（`Building native assets failed`，`which clang` 无结果），之后连已通过的文件也同样失败——是环境问题，不是代码问题。未尝试恢复工具链。因此 B5 报告里“未跑通”的 SR-P2-50 widget 测试至今仍无一次 live widget 运行记录；本报告对 SR-P2-50 的核查改用纯 Dart 探针（把 `_scanCacheSync` 的 `walk`/`add` 逻辑原样复制到独立脚本跑夹具树，见 SR2-WRONGBOOK-4），探针跑完已删。
- 演示库核对：审查前后 `~/.local/share/quiz-master2/quiz-master2.db` md5 均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 题）；跑测试前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.selfreview2-wrongbook-pre`。
- 行号均为当前工作树行号。

## 问题清单

共 **8 条：P1 × 1，P2 × 7**。

### P1

#### SR2-WRONGBOOK-1（P1）目录“移动文件夹”目标下拉用陈旧值，换科或删目标文件夹后触发 DropdownButton 断言——与 SR-P0-2 同类问题在另一处复活

- 位置：`lib/modules/wrongbook/wrongbook_directory.dart:176`（`value: _moveTargetId`）→ `lib/modules/wrongbook/wrongbook_page.dart:1501-1536`（`_styledDropdown` 是真的 `DropdownButton`）；状态字段 `lib/modules/wrongbook/wrongbook_page.dart:202`（`String _moveTargetId = '__top__'`）；赋值只在 `wrongbook_directory.dart:186`（下拉 `onChanged`）。
- 现象/后果：`_moveTargetId` 在任何导航/刷新/删除路径上都不复位：`_openDirectory`（`wrongbook_page.dart`，只清 `_selectingMove/_moveSelection/_renamingId/_draggingId` 等，不碰 `_moveTargetId`）、`_openShelf`、`_load`、`_deleteFolderConfirmed` 均不重置它。于是：
  1. 换科复现（无需删除，三步即达）：A 科目录打开“选择文件夹”，目标下拉选某顶层文件夹 X；回书架进 B 科目录，再点“选择文件夹”→ 移动条重建时 `_moveTargetId` 仍是 A 科 X 的 id，不在 B 科的下拉选项（`'__top__'` + B 科顶层文件夹）里，debug 下抛 `There should be exactly one item with [DropdownButton]'s value`，release 下拉显示异常——与 SR-P0-2 的崩溃是同一契约、同一后果。
  2. 删目标复现：移动条开着、目标已选 X 时，直接点 X 行的“删除”（改名/删除按钮在选择模式下仍显示，`wrongbook_directory.dart` 行按钮区无模式门控）并确认删除 → `_load` 后 `_selectingMove` 仍为 true，移动条带着已删的 id 重建，同样断言。把 X 拖进别的文件夹（不再是顶层）后也有同样效果。
  3. 二次伤害：即使下拉被绕过，点“移动”时 `_moveOneFolder`（`wrongbook_page.dart:894`）用无 `orElse` 的 `_folders.firstWhere((x) => x.id == targetParentId)` 查目标，目标不存在即抛 `StateError`；`_moveSelected` 与 `_applyDrop` 两处调用方都没有 try/catch，属 SR-P2-41 在批量操作里刚修掉的同款 `firstWhere` 隐患，在移动路径上还活着。
- 证据：全树 `grep _moveTargetId` 只有 4 处（定义、移动条 value、移动条 onChanged、`_moveSelected` 取值），无任何一处复位或校验；对照同一页的批量条 `_buildBatchBar`（`wrongbook_list.dart:535-538`）已有显式防线——“下拉的当前值必须在选项里：存量值失效（文件夹被删）时回落到首项，不在 build 里写回状态”——同类修复只做了一处，另一处漏了。
- 修的方向：与批量条同款：在 `_buildMoveSelBar` 里把 `_moveTargetId` 先对当前科顶层文件夹校验，无效（不在选项里）时回落到 `'__top__'`；同时 `_moveOneFolder` 的目标查找改 `firstWhereOrNull`（或 `orElse` 抛可提示的错），`_moveSelected` 汇总提示；另在 `_openDirectory`/`_openShelf`/`_deleteFolderConfirmed` 里把 `_moveTargetId` 复位为 `'__top__'`。修后加一测：A 科选目标 → 进 B 科开移动条不断言；选定目标后删掉它 → 移动条不断言且回落到“移到顶层”。

### P2

#### SR2-WRONGBOOK-2（P2）目录拖拽调序时文件夹搜索开着会移错位置：缝隙下标按过滤后的可见列表算，`_reorderFolder` 却按全量列表解释

- 位置：`lib/modules/wrongbook/wrongbook_directory.dart:12-16, 56-61`（顶层缝隙按 `visibleTops` 建，`visibleTops` 是搜索过滤后的子集）、`:317-320`（子文件夹缝隙按 `kw` 过滤后的 `kids` 建）→ `lib/modules/wrongbook/wrongbook_page.dart` `_reorderFolder`（`siblings` 取全量 `_topFolders(subjectId)` / `_subFolders(parentId)`，`fromIndex`/`toIndex` 都按全量算；SR-P2-42 的 `idx > fromIndex` 减 1 修正也建立在“同一张表”前提上）。
- 现象/后果：搜文件夹时拖拽，缝隙下标与全量下标错位，落点与所见不符。例：顶层 A、B、C、D，搜到 B、D（可见 `[B, D]`）；把 D 拖到 B 与 D 之间的缝隙（过滤视图里的 gap 1，用户预期不动）→ `_reorderFolder` 得 `toIndex=1`、`fromIndex=3`（全量），`1 > 3` 不成立不减 1，插到 1 得 `[A, D, B, C]`——D 跳到了 B 前面。子文件夹同理。
- 证据：代码链即证据；B5 的 SR-P2-42 测试只在无搜索时拖拽，未覆盖搜索态。
- 修的方向：二选一：(a) 搜索有关键词时禁用缝隙拖拽（`_buildGapTarget` 的 `onWillAcceptWithDetails` 在 `kw.isNotEmpty` 时返回 false）；(b) 把可见下标换算成全量下标再调 `_reorderFolder`。修后加一测：搜索过滤后拖拽，顺序与所见一致（或缝隙拒收）。

#### SR2-WRONGBOOK-3（P2）学习报告学科分布仍把已掌握题算进去，与封面/目录/列表的“扣已掌握”口径不一致——SR-P1-11 声称的“口径一致”没闭合

- 位置：`lib/modules/report/report_page.dart:171-176`（`_questionsInRange` 只滤 `isOrganized && !q.isArchived`）、`:423-429`（分布行 `qsIn.where(subject).length`）vs `lib/modules/wrongbook/wrongbook_shelf.dart:168-176`（封面总数扣 `_isMastered`）、`lib/modules/wrongbook/wrongbook_directory.dart:217-224`（“全部题目”行扣已掌握）、`lib/modules/wrongbook/wrongbook_page.dart:370-379`（`_folderCount` 扣已掌握）、`:551-560`（`_filteredAll` 默认藏已掌握）。
- 现象/后果：同一科同一时段，报告“数学 · N 道错题”会大于错题本封面总数与目录总数，差额正好是该范围内已掌握的题数——正是 SR-P1-3 当初投诉的症状（“报告分布数会大于错题本题数”），只不过 B5 修掉了未整理/已归档两个来源，留下了已掌握这个来源。弱点 Top5 两处（`_causeGroups` 跳过已解决记录、`_kpGroups` 跳过全解决的题）已经不含已掌握题，分布是唯一还含的口径。
- 证据：`_distRow` 的计数源 `qsIn` 与 `_causeGroups`/`_kpGroups` 是同一份，但后两者各自另有“已解决排除”逻辑，分布没有；B5-P1-10-11.md 称分布“与错题本 `_filteredAll` / `_folderCount` 的收录口径一致”，与代码不符——`_filteredAll` 默认视图与 `_folderCount` 都扣已掌握。
- 修的方向：由 Meng 裁决：(a) 分布也扣已掌握（与封面/目录同口径，分布数 = 该科封面总数）；(b) 维持分布按历史错题数（含已掌握），把该口径写进报告页头注释，并修正 B5-P1-10-11.md 里“口径一致”的说法。注意 (a) 会改变“错在哪个学科”的语义：已掌握的科会显示 0 道，需要他确认。

#### SR2-WRONGBOOK-4（P2）SR-P2-50 修得不完整：`insideCacheDir` 是死参，目录按 1 个计，预览个数仍偏小

- 位置：`lib/modules/settings/settings_page.dart:555-600`（`_scanCacheSync` 的 `walk`/`add`）；预览文案 `:1140`（`'临时文件 ${preview.tempCount} 个、缩略图缓存 ${preview.thumbCount} 张，共约 ${preview.mb} MB'`）。
- 现象/后果：
  1. `insideCacheDir` 从未为 true：`walk` 递归进普通子目录时原样透传（`walk(e, insideCacheDir: insideCacheDir)`），而遇到名字含 cache/thumb/tmp 的目录时是 `add()` 后 `continue`，从不以 `insideCacheDir: true` 递归进去。于是 `else if (insideCacheDir) add(e, 'temp')` 分支不可达，是死代码。
  2. 目录按 1 个计：`add()` 对目录只 `tempCount++/thumbCount++` 一次、字节数递归累加，目录里的文件不逐个计数。纯 Dart 探针（把 `walk`/`add` 原样复制到独立脚本，夹具树：`work/thumb-cache/a.png + b.png`、`work/deep/x.tmp`、`work/cache/f1~f3.txt`、`work/sub/inner-cache/z.bin + y.bin`，每文件 10 字节）实测：`temp=3 thumb=1 bytes=80 items=4`——8 个文件只算出 4 项（thumb-cache 2 张图算 1 张、cache 目录 3 个文件算 1 个、inner-cache 2 个文件算 1 个），字节数是对的（80），个数是错的。B5 报告“深层也被发现并计数”只在“项被发现、能清理”层面成立（`items` 里确实有这些目录，`_clearCache` 会递归删掉），不在“个数”层面成立；预览文案说的是“X 个/张”，用户看到的个数仍偏小。
  3. 验证缺口未补上：B5 报告明说该 widget 测试“已写，未跑通”，本次审查同样没能跑 `test/settings_page_test.dart`（见“方法与验证”：clang 丢失，`flutter test` 无法构建）。该测试至今无一次 live widget 运行记录。
- 证据：探针输出与代码链（`settings_page.dart:574-600`）一致；`grep insideCacheDir` 全项目只有定义处与透传处，无一处传 `true`。
- 修的方向：二选一：(a) 让 `walk` 对 cache/thumb/tmp 目录也递归进入（`insideCacheDir: true`），目录里的文件逐个按类计数，目录本身不再单独计 1（避免重复计）；(b) 维持目录按项计，改预览文案为“X 项”并删掉死参。无论选哪种，修后要在机器空闲时单跑 `flutter test test/settings_page_test.dart` 把 SR-P2-50 测试真正跑通一次。

#### SR2-WRONGBOOK-5（P2）SR-P2-51 金角轮转的生成色与既有色 hue 只差 2°～7°，第 13/14/16/17 科肉眼近乎撞色（裁决复核见后，附带问题）

- 位置：`lib/modules/subjects/subjects_page.dart:307-324`（`orElse`：`hue = (usedColors.length * 137.5) % 360`，撞色避让只在 `usedColors.contains(candidate)` 精确相等时步进 37°）；色表 `:36-53`（12 色）。
- 现象/后果：金角序列从 `n = usedColors.length = 12` 起算，而不是从 0 起算的经典分散序列，生成 hue 恰好落在既有色旁边。实测 hue（`colorsys` 算出）：
  - 第 13 科（n=12）：210.0°，距数学蓝 216.6° 仅 **6.6°**；
  - 第 14 科（n=13）：347.5°，距玫红 349.7° 仅 **2.2°**；
  - 第 16 科（n=15→实际第 16 科 n=15）：40.0°，距琥珀 37.7° 仅 **2.3°**；
  - 第 17 科（n=16）：177.5°，距青绿 173.4° 仅 **4.1°**。
  饱和度/明度也被固定为 0.65/0.85，与既有色的 0.59～1.00/0.66～0.99 同档，区分度主要只剩 hue——2° 的 hue 差在圆点/标题色上基本看不出。`while` 循环只防精确 `Color` 相等，防不住近色。
- 证据：上述 hue 均为实算；既有测试（`test/subjects_page_test.dart:654`，13 科“色全不同”）只断言精确不等，近色照样通过——这正是“只测 happy path”的例子（见“新测试质量”）。
- 修的方向：生成色与全部已用色算 hue 距离（环形），小于阈值（如 25°）时继续步进金角/37° 直到拉开；或把 12 色表扩到 16 色以上再轮转。由 Meng 定阈值与做法。

#### SR2-WRONGBOOK-6（P2）SR-P2-37 首字母排序修得不彻底：同首字母按 Unicode 码点排（不是拼音），未映射汉字回退为原字、排在所有已映射字母之后

- 位置：`lib/modules/wrongbook/wrongbook_page.dart:163-180`（`_subjectInitial`、`_subjectKeyCompare`）。
- 现象/后果：
  1. 平局比较用学科名全串 `compareTo`（Unicode 码点序）：同首字母 S 的“数学”与“生物”，码点上 数（U+6570）< 生（U+751F），排“数学”在前；按拼音应是 sheng（生物）< shu（数学），“生物”在前。排序结果与下拉文案“学科首字母 A → Z”不符。
  2. 未映射汉字回退为该字本身（`:171` 的 `?? first`）：与已映射的拉丁字母比较时，汉字码点（U+4E00+）恒大于拉丁字母，未映射学科一律排在所有已映射学科之后，且两个未映射学科之间仍按码点排、不是拼音。
  3. 空名回退 `''`，排在最前面（`''` 小于一切），未知学科反而置顶。
- 证据：代码链即证据；B5 的两项测试（`test/wrongbook_page_test.dart:1568/1581`）只用化学/数学/物理/英语/政治五个已映射学科，未覆盖平局与未映射。
- 修的方向：平局比较改按“首字母 + 全名拼音”排（或至少用映射表把全名逐字转首字母串再比）；未映射汉字给一个确定性的回退（仍用原字比较、但注释写明不是拼音序），或扩映射表覆盖常见学科首字；空名回退到 `'{'`（排最后）或与未知学科同档处理。

#### SR2-WRONGBOOK-7（P2）按组“开始解决”进会话时，范围文案仍写筛选口径，实际只治该组一个错因——SR-P2-57 的同类文案错换了个入口

- 位置：`lib/modules/review/review_page.dart:476-517`（`_startSession`：`fromGroup != null` 时 `blocks = _buildBlocks(_filtered, onlyCause: fromGroup?.cause)`，但 `scopeLabel` 一律取 `_scopeLabelForFilters()`，不看 `fromGroup`）。
- 现象/后果：无任何筛选时，点某组（如数学“计算错误”）的“开始解决”，会话只含该组错因（SR-P2-49 决定 (b)，`_buildBlocks` 的 `onlyCause` 正确），但会话元信息行（`:1566`，`'第 ${_bi + 1} / ${_blocks.length} 道题 · $_scopeLabel'`）却显示“全部待解决错因”；有学科筛选时则显示“数学这一科”，同样夸大了范围（只治其中一个错因）。用户按文案理解会以为本轮治完该科/全部，实际只治了一个错因。SR-P2-57 修的是断点恢复条与 `_scopeLabelForBlocks`，这个新建会话入口的文案没同步。
- 证据：代码链即证据；B5 的 SR-P2-49 测试（`test/review_page_test.dart:939`）走的是错因筛选 + 顶栏“开始解决”，文案恰好吻合，没覆盖按组入口的文案；“按组开始解决”测试（`:702`）只断言块数，不看文案。
- 修的方向：`fromGroup != null` 时 `scopeLabel` 用该组写，如 `'${学科名} · ${错因}'`（与 `_scopeLabelForBlocks` 的单科单错因分支同款）；修后在“按组开始解决”测试里加文案断言。

#### SR2-WRONGBOOK-8（P2）复习错因筛选与错题本错误类型筛选的下拉也没有旧值兜底，详情页删题回来可能断言——与 SR-P0-2 / SR2-WRONGBOOK-1 同类

- 位置：
  - `lib/modules/review/review_page.dart:1037-1050`（错因下拉 `value: _causeFilter`，选项来自 `_allCauses`，即当前待解决 + 已解决分组里的错因）；`_causeFilter` 在 `_load` 里从不校验。
  - `lib/modules/wrongbook/wrongbook_list.dart:238-246` 附近（错误类型下拉 `value: _filterErrorType`，选项 = 固定错因 + `_questions` 里全部题的 `allCauses`）；`_filterErrorType` 在 `_load`/详情返回后从不校验。
- 现象/后果：同一页生命周期内（详情页是压在上面的路由，原页 State 活着，回来后调 `_load`，见 `wrongbook_list.dart:751/834/997` 的 `await widget.onOpenDetail(...); await _load();` 与 `review_page.dart:1580-1581` 的同款调用），筛选值指向的错因可能已消失：
  - 复习页：筛“计算错误”→ 进会话 → 在详情页归档/删除唯一带该错因的题 → 暂停回列表 → `_allCauses` 里已无“计算错误”，`_causeFilter` 仍是它 → DropdownButton 断言（归档会把题移出 `_groups`/`_curedGroups`；治愈不会触发，因为已解决组仍进 `_allCauses`）。
  - 错题本：筛选面板开着、错误类型筛了 X → 在详情页删除唯一带 X 的题 → 回来 `_load` 后选项里无 X，`_filterErrorType` 仍是 X → 同样断言（归档不触发，因为 `_questions` 是 `includeArchived: true` 全量；只有删除触发）。
- 证据：代码链即证据；`grep` 确认 `_causeFilter`/`_filterErrorType` 在 `_load` 与各导航方法里均无复位/校验（`_clearFilters` 只在换科/换文件夹/重置时调，不在详情返回时调）。页面切换会重建 State（`lib/app.dart` `_buildPage` 按路由新建页面，无 IndexedStack 保活），所以跨页删除不构成此问题，只有上述“详情页删题/归档后回本页”路径构成。
- 修的方向：与批量条同款防线：在 `_load` 的 `setState` 里（或下拉 `value` 处就地）校验——值不在当前选项里时回落到 `'全部'`/null；或在 build 里用就地计算的 `effectiveValue`（不写回状态）。修后加一测：筛某错因 → 删掉唯一带该错因的题 → 回列表不断言、筛选回到“全部”。

## 三项协调员裁决复核（结论单独一节）

### 裁决 (a) SR-P2-51 第 8 科颜色：扩到 12 色 + 金角轮转、不再回落数学蓝——结论：成立（字面），但附带 P2 级近色缺陷（SR2-WRONGBOOK-5）

- 核对结果：
  - 12 色表完整（`lib/modules/subjects/subjects_page.dart:36-53`）：新蓝、新绿、新红、紫、橙、青、粉、青绿 `0xFF14B8A6`、草绿 `0xFF84CC16`、琥珀、靛蓝、玫红，共 12 个 distinct 值；第 8 科青绿、第 9 科草绿，与 B5 报告一致。
  - 轮转逻辑正确（`:307-324`）：`firstWhere(未用色，orElse: 金角生成）`，12 色用完后不再回落 `_newSubjectColors.first`；撞色步进 37°、最多 12 次，有上界，不会死循环。
  - 旧测试按新行为更新合理（`test/subjects_page_test.dart:654`）：连加 10 科共 13 科，断言 13 色全不同、第 13 科为金角生成色——与“不再回落第一色”的新行为一致，不是把旧期望硬改成新实现。
  - 别的颜色回落点：新学科主色（`Subject.color`）无其他回落点。另有两处与学科色有关的回落，但不属于本项：`DesignTokens.subjectInk/subjectSoft`（`lib/theme/design_tokens.dart:372-430`）对预设三科以外的学科无 `stored` 时回落数学色——那是“找不到学科/未传存色”的兜底，不是第 8 科起的回落；`CoverTokens.of`（`:921`）未知 key 回落蓝色——那是封面底色系统（7 色 key），与学科主色无关。
  - 缺陷（SR2-WRONGBOOK-5）：金角起点取 `usedColors.length`（12 起），生成 hue 与既有色只差 2.2°～6.6°（第 13 科 210° vs 数学蓝 216.6°；第 14 科 347.5° vs 玫红 349.7°），`while` 只防精确相等。字面“不再回落数学蓝”成立，视觉可区分的目的未达成。

### 裁决 (b) SR-P2-52 封面字号不跟全局缩放（只乘字距）：结论：成立

- 自审原要求：学科名 `fontSize: 52` 与副标题 `fontSize: 16` 是固定值，不跟三档字号缩放，要求“两处字号与字距同乘 `scale`”。
- 工人实际做法：只把两处 `letterSpacing` 乘 `scale`（学科名 3.12、`错 题 本` 13.6，`lib/modules/wrongbook/wrongbook_shelf.dart:322, 351`），`fontSize` 不乘，并写明理由（D4 约定：字号由 `app.dart:267` 的 `MediaQuery TextScaler` 全局乘一次，`qmScaleOf` 取的就是同一因子；`letterSpacing` 不被 `TextScaler` 缩放）。
- 理由成立的证据：D4 约定在 `lib/theme/design_tokens.dart:19, 160-161, 461, 517, 544, 569-570` 六处一致表述（“字号只写基准值，由 app.dart 的 MediaQuery TextScaler 全局缩放一次；布局尺寸由调用方按 qmScaleOf 的同一因子乘一次”）；B5 报告的探针数据（1.3 倍下 52 → 67.6）与 Flutter 的 `TextScaler` 语义一致（只缩放 `fontSize`，不缩放 `letterSpacing`）。若按自审字面把 `fontSize` 也乘 `scale`，特大档会是 52 × 1.3（TextScaler）× 1.3（手动）= 双重缩放，确实错。反向做法正确。
- 测试佐证：`test/wrongbook_page_test.dart:1811`（1.3 倍下“错 题 本”宽度 > 185，修复前 172、1.0 倍时 148）钉住了字距缩放的效果。
- 附带观察（不另计问题）：字距乘 `scale` 后，大字号下学科名与副标题的总宽会超过标准档的书宽占比，B2 报告的 74.4px 纵向排布只在标准字号下实测过；三档字号下的封面排布仍建议 Meng 在 Win11 真机上顺手看一眼。

### 裁决 (c) SR-P2-55 学科管理封面选择器两套点按（保留外层、去掉内层）：结论：成立

- 自审原要求：只留一处，建议留 `QmCoverMini.onTap`、删外层 `GestureDetector` 的 `onTap`。
- 工人实际做法：相反——留外层 `GestureDetector(onTap: _setCover)` 为唯一处理，`QmCoverMini` 不传 `onTap`（`lib/modules/subjects/subjects_page.dart:733-760`，注释写明理由）。
- 另一套真无害的证据：`QmCoverMini.build`（`lib/widgets/uikit.dart:941-945`）`onTap == null` 时直接返回装饰容器，不包 `_QmPressable`、不装任何手势识别器，与外层不存在手势竞争；外层 `GestureDetector` 包裹的是小图 + 下方样式名签整个格子，名签点按是既有交互（既有测试点 `find.text('圆点')` 触发选择），改只留内层会使名签点按失效——B5 报告称第一次尝试即因此失败 1 项，有测试证据。
- 测试佐证：`test/subjects_page_test.dart:688`（点数学“圆点”小图 → `coverStyle` 变 `dots`，且 `saveSubject` 恰好调用 1 次）钉住了“单次保存”。
- 附带观察（不另计问题）：改留外层后，点按失去了内层 `_QmPressable` 的按压态视觉反馈（外层是裸 `GestureDetector`，无涟漪/缩放）；功能正确，只是手感上轻微退化，如在意可给外层包一层按压态。

## 遗留项确认

### (i) 报告页月筛选仍为 `age <= 30`——位置与现状

- 位置不在报告页，在错题本列表的时间筛选：`lib/modules/wrongbook/wrongbook_page.dart:581-592`（`_filteredAll`）：`limit = _filterTimeRange == 'week' ? 7 : 30`，周用 `age < limit`（7 天含今天，SR-P2-45 已定），月用 `age <= limit`（即 31 天含今天）。现状确认：未动，与 B5-P2-WRONGBOOK.md“月筛选未定”一致。
- 若按“30 天含今天”改（`age < 30`）：与周口径一致（都是“滚动 N 天含今天”），改动只是一行（月分支改 `age < limit` 或把月分支并入周分支的 `<` 判断），无数据风险；B5 的周测试（6 天前在内、7 天前在外）可照搬成月测试（29 天前在内、30 天前在外）。
- 别的月口径：学习报告页“本月”是另一套算法——自然月（`lib/modules/report/report_page.dart:111`：`_rangeStart` 的 `'month' => DateTime(now.year, now.month, 1)`，即本月 1 日到今天），与错题本的滚动月不同。这是两个功能的各自口径（报告是“本周/本月/全部”的范围条，错题本是“最近一周/最近一月”的筛选），不冲突；把错题本月改成 `age < 30` 后两者仍不同（滚动 30 天 vs 自然月），无需统一，但建议在错题本筛选文案或注释里写明是“最近 30 天”而非“本月”，避免用户按报告的“本月”理解。

### (ii) `reviewCount` 只存库、无页面渲染——确认

- 写入：`lib/data/db_questions.dart:155`（`recordSelfCheckTxn` 内，`UPDATE questions SET review_count = review_count + 1`，与写 `review_history` 同一事务）；模型字段 `lib/models/models.dart:288, 326`；编解码 `lib/data/db_codec.dart:72, 105`；详情页编辑保存时原样带回（`lib/modules/detail/question_detail_page.dart:268`，不重置）。
- 渲染：全项目 `grep reviewCount` 只有上述 4 处，无任何页面读它。**但数字本身并非无处显示**：详情页“复习记录”区的“解决次数”行（`question_detail_page.dart:1720`）显示 `'共解决错因 ${_history.length} 次 · …'`，`_history` 是 `reviewHistory()` 的全部记录；正常流程里每次 `recordSelfCheck` 都在同一事务里既插一条 `review_history` 又给 `review_count + 1`，两者数值相等（备份恢复/旧库迁移等极端路径可能偏离，未核）。所以 `reviewCount` 字段是 `review_history` 行数的冗余镜像，不是独有信息。
- 显示它是否只是渲染改动：是渲染改动，但先要定口径——`reviewCount` 的语义是**按错因计的自查次数**，不是按轮次/按题计的“复习次数”：一轮会话里一道题 3 个错因各查一次就 +3；复查通过也 +1（`recordSelfCheckTxn` 不分是否复查）。若在错题本列表行或复习列表行直接显示为“复习 N 次”，会误导（用户以为练了 N 轮）。若要显示，应标为“自查 N 次”或只在详情页把“解决次数”行改成读该字段（与现文案等价，无新增信息）。是否显示、标什么，需 Meng 另立产品决定；不建议把它当作“缺失的显示”直接补。

## 新测试质量（只测 happy path 的测试）

以下新增/改写测试只钉住了主路径，未覆盖负向或边界值（其余 B5 新增测试见“已核实干净”）：

- `test/subjects_page_test.dart` —— “SR-P2-51 第 8 科起仍有新色”（:654）：只断言 13 色精确不等。未断言生成色与既有色的 hue 距离，SR2-WRONGBOOK-5 的近色（347.5° vs 玫红 349.7°）照样通过。
- `test/wrongbook_page_test.dart` —— “SR-P2-37 学科首字母升序/降序”（:1568/:1581）：只用五个已映射首字母的学科。未覆盖同首字母平局（数学/生物）、未映射汉字、空名。
- `test/settings_page_test.dart` —— “SR-P2-50 缓存预览递归扫子目录”（:344）：夹具只有 `work/thumb-cache/a.png` + `work/deep/x.tmp` 两项，断言 temp=1/thumb=1。未覆盖 cache 目录里的多个普通文件（探针证实它们不逐个计数），且该测试在 B5 与本次均未跑通（见“方法与验证”）。
- `test/review_page_test.dart` —— “SR-P2-49 错因筛选进会话”（:939）与“按组开始解决：只治该组的错因”（:702）：前者只走顶栏“开始解决”+ 错因筛选，后者只断言块数不看文案。均未覆盖断点恢复后是否仍只含筛选错因（恢复走保存队列，理论上已过滤，但无测试钉住），也未覆盖按组入口的范围文案（SR2-WRONGBOOK-7）。
- `test/review_page_test.dart` —— “SR-P2-47 未加入盒”（:905）：只断言 13 道默认列 10 道、展开后全见。未覆盖未加入盒按学科分行的顺序（`ordered` 按 `_subjects` 顺序，未测新学科/未知学科排最后的分支）。
- `test/wrongbook_page_test.dart` —— “SR-P2-42 拖拽调顺序”（:1664）：只测无搜索时往下拖一格不动、拖到末尾换位。未覆盖搜索过滤态拖拽（SR2-WRONGBOOK-2）、子文件夹层内拖拽。
- `test/wrongbook_page_test.dart` —— “SR-P2-46 已归档分页”（:1765）：只测 12 道两页、翻页。未覆盖归档后 `_page` 越界回落（第 2 页删到只剩 1 页时是否回到合法页）与每页条数切换后已归档页码的复位。

## 已核实干净（逐项一句话）

- SR-P0-2：设置页已无 `'subject'` 选项（`settings_page.dart:1004-1011` 为 subj-asc/subj-desc 两项）；`normalizeWrongbookSort`（`models.dart:602-609`）在 `fromMap`/`copyWith`/错题本 `_load`（`wrongbook_page.dart:310-318`）三处归一，旧值 → subj-asc、未知值 → new；`_filteredAll` 有防御性 `case 'subject'`（`:612-615`），`default` 回时间新→旧；两项回归测试分别覆盖旧值与未知值进列表不断言（`wrongbook_page_test.dart:944` 起；本次 68/68 通过）。
- SR-P1-1：`ReviewBucket` + `reviewBucketOf`/`isReviewDue`（`repository.dart:18-44`）为唯一共享分类；`subjectCounts`（`:154-163`）、`dueToday`（`:99`）、首页焦点卡拆分（`home_page.dart:145-153`）三处同走它，混合题只计一桶、要复习 + 待复查 = `homeRevCounts` 该科数；`b5_p1_1_subject_counts_test.dart` 4/4（本次随组通过）。
- SR-P1-9：`history.first`（`review_page.dart:1678`），数据源 `reviewHistory()` 是 `reviewed_at DESC`（`db_questions.dart:269`），首条即最新；回归测试两条记录新旧对照（`review_page_test.dart:742`）。
- SR-P1-10 + SR-P1-11：`_WeakGroup.questionIds`（`report_page.dart:71-75`），`_causeGroups`/`_kpGroups` 两处按题 id 去重；`_questionsInRange`（`:171-176`）加 `isOrganized && !isArchived`，弱点与分布同源 `qsIn`；两项回归测试（`report_page_test.dart:422-444`）。分布含已掌握的残留见 SR2-WRONGBOOK-3。
- SR-P1-12：`_sortInitialized`/`_pageSizeInitialized`（错题本 `wrongbook_page.dart:233-234`）与复习 `_pageSizeInitialized`（`review_page.dart:157`）只首次 `_load` 读设置；`_defaultSort` 字段已随 B5-P2-58 的拆分删除，“重置”固定 `'new'`（见下）；回归测试覆盖进详情返回后排序/页数保留（本次通过）。
- SR-P1-13：`_skipCurrent`（`review_page.dart:658-703`）跳过块内最后一个错因直接进 `_Phase.redo`，`_ci` 钳回末位但不再回 `recall`；自查步按 `block.causes`（已剔跳过的错因）逐个自查，不会把跳过的错因重新计入；回归测试双错因题跳过末因进重做（`review_page_test.dart:756`）。
- SR-P1-15：`CompactSliceThumb` 的 `Image.file` 已补 `errorBuilder`（`lib/widgets/widgets.dart:652`，与 `failed`/`missingRealImage` 分支共用 `failedPlaceholder`）；回归测试损坏切片显示“加载失败”+ 学科图标、有效切片正常（`test/b3_p11_layer2_downgrade_test.dart`，本次 8/8 随组通过）。
- SR-P2-36：新建/改名/移入三处预检都调 `folderNameExistsInSubject`（`wrongbook_page.dart` `_addFolder`/`_saveRename`/`_moveOneFolder`），`saveFolder` 捕获 `StateError` 转“已经有了”；数据层预检按 `subject_id + name`（`db_catalog.dart:162-180`）；5 项回归测试（`wrongbook_page_test.dart:708`）。
- SR-P2-38：`_folderCount`、封面总数、目录“全部题目”行都扣 `_isMastered`（三处同谓词：已整理、未归档、错因不全解决或有复查到期）；已掌握提示改当前文件夹子树口径（`wrongbook_list.dart:465-491`，跨学科列表时按整科计，文案 scope 相应为空/“这科”/“这个文件夹里”）。
- SR-P2-39：`notJoined` 只列已整理、未归档、有错因的题（`review_page.dart:210-220`）；回归测试盒里无未整理/无错因题（`review_page_test.dart:825`）。
- SR-P2-40：`_batchAddTag` 新建分支先过 `hasBannedNameSeparator`，命中提示“不能含逗号或竖线”并中止（`wrongbook_page.dart:1162`）；回归测试输入含逗号标签不入库、无题目被保存（`wrongbook_page_test.dart:1611`）。
- SR-P2-41：六个批量操作改 `_questionById`/`_folderById` 安全查找 + 逐项 try/catch + `_snackBatchResult` 汇总（`wrongbook_page.dart:1071-1100, 1188-1351`）；跨学科批量移文件夹有提示（`wrongbook_list.dart:581`）与跳过计数；批量条 `_batchFolderId` 有旧值回落首项的防线（`:535-538`）——但移动条同款防线漏了，见 SR2-WRONGBOOK-1。
- SR-P2-42：`_reorderFolder` 记 `fromIndex`，`idx > fromIndex` 时减 1（`wrongbook_page.dart`）；无搜索时两方向测试通过（`wrongbook_page_test.dart:1664`）。搜索态见 SR2-WRONGBOOK-2。
- SR-P2-43：`_applyDrop` 注释已改成“缝隙只接受同层拖拽，子文件夹回顶层请拖到「全部题目」行”，与 `_buildGapTarget` 的 `parentId` 校验一致。
- SR-P2-44：`_openList`/`_openDirectory`/`_openShelf` 都调 `_clearFilters`（清搜索与全部筛选、回第 1 页、清勾选，不动排序与学科/文件夹归属）；回归测试数学搜“函数极限”后进英语列表全可见（`wrongbook_page_test.dart:1681`）。
- SR-P2-45：周 `age < 7`（7 天含今天），搜索日期双写法（`datePadded` + `datePlain`，`wrongbook_page.dart:498-510, 581-592`）；两项回归测试（`:1700/:1733`）。月仍为 `age <= 30`，见“遗留项 (i)”。
- SR-P2-46：跨学科已归档视图接同一分页器（`wrongbook_list.dart:1130-1172`），入口 `_page = 0`（`wrongbook_shelf.dart:63-66`）；回归测试 12 道两页（`wrongbook_page_test.dart:1765`）。
- SR-P2-47：已解决区按 `_pageSize` 分页（独立 `_curedPage`，筛选变化归零，`review_page.dart:1260-1345`，`_resetPage` 同步清零）；未加入盒按学科分行、默认前 10 道 + 展开（`:1460-1510`）；两项回归测试（`review_page_test.dart:842/905`）。
- SR-P2-48：首页、错题本、复习页 `_load()` 均包 try/catch，失败出横幅 + 重试、已有内容留住（`home_page.dart:121-178`、`wrongbook_page.dart:274-334`、`review_page.dart:196-330`）；三页各一回归测试（抛错出横幅、重试失败仍在、重试成功恢复）。
- SR-P2-49：`_buildBlocks` 只取传入分组内的错因再按 `onlyCause` 收窄（`review_page.dart:423-465`）；按组开始（`:702` 改写）与错因筛选进会话（`:939`）两项测试；断点恢复走保存队列（已过滤的子集，不会扩回全部），`_load` 的断点校验只按待治键过滤、不扩大范围（`:272-302`）。
- SR-P2-52：见裁决 (b)，成立。
- SR-P2-53：文件夹分支标题改为 `'${subject.name} · ${folder.name}'`（`wrongbook_list.dart:21-27`），与 SR-P2-38 同一测试断言“数学 · 试卷”。
- SR-P2-54：`_openBookFrame` 加 `neutral` 参数，跨学科列表用灰 `CoverTokens.of('grey')`（`0xFF64748F`），不再用数学封面色（`wrongbook_page.dart:1447-1457`、`wrongbook_list.dart:59-62`）；回归测试（`wrongbook_page_test.dart:1818`）。
- SR-P2-55：见裁决 (c)，成立。
- SR-P2-57：`_scopeLabelForFilters`（按当前学科/错因）与 `_scopeLabelForBlocks`（按保存队列实际学科/错因）分开，恢复走后者（`review_page.dart:527-558`）；回归测试数学筛选开始→暂停→继续，会话元信息为“数学这一科”、全页无“全部待解决错因”（`review_page_test.dart:950`）。按组入口文案见 SR2-WRONGBOOK-7。
- SR-P2-58：“重置”固定回 `'new'`（`wrongbook_page.dart:688-694`），`_clearFilters` 不动排序（导航保留设置默认或页内改过的值）；回归测试设置默认旧→新时进书仍旧→新、点“重置”变新→旧（`wrongbook_page_test.dart:1831`）。
- SR-P2-36 之外的文件夹判重死角：`_moveOneFolder` 的循环移动拦截（“不能移到自己下面”、子文件夹只能一层、带子文件夹的一级不能再放进别的文件夹）与 `_reorderFolder` 的 `StateError` 防线均在原处，未发现回归。
- 报告页两处已裁决近似口径（SR-P2-56 的 (a)(b)，不修）：`lastCheck == null` 视为在范围内、`复查通过率`以全部已判定记录为近似，页头注释（`report_page.dart:24-33`）与代码一致，未动。
- 封面 52px 学科名 / 16px“错 题 本”的 `fontSize` 不乘 `scale` 是 D4 约定下的正确做法（见裁决 (b)），不是漏修。
