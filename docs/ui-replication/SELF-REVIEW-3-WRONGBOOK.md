# 第三次自审 · 错题本 / 复习 / 报告 / 首页（WRONGBOOK）

- 日期：2026-11-15
- 范围：只审第六批改动（B6），文件见任务清单；只审、不改代码；未提交、未推送。
- 基线：第六批已推送，远端 head `38cbc4b`；最终验证 analyze 0、测试 852/852、Linux Release 通过、演示库 md5 不变。
- 审法：先读 `B6-P1-DROPDOWN.md`、`B6-P2-WRONGBOOK.md`、`B6-P2-GAPS.md`、`B6-SUMMARY.md` 相关小节，再逐项对照源码核实；两处关键怀疑（WRONGBOOK-1、WRONGBOOK-2）写了临时探针 `test/zz_probe_sr3_test.dart`，但本次 `flutter test` 在共享 CPU 上 13 分钟无输出、编译进程 CPU 几乎不动（疑似与其他并发任务争抢），已按确切 PID 停掉并删除探针文件——这两条的结论以代码级证据为准，探针未完成实跑，特此说明。
- 结论：**共 5 条：P0 0、P1 1、P2 4。**

---

## WRONGBOOK-1（P1）— SR2-29：报告 `_isMastered` 与错题本 `_isMastered` 不同义，陈旧记录下“分布数 = 该科封面总数”不成立

- 位置：`lib/modules/report/report_page.dart:193-205`（`_isMastered`）vs `lib/modules/wrongbook/wrongbook_page.dart:443-448`（`_isMastered`）；另涉 `lib/data/db_questions.dart:60-62`（`syncCauseRecordsIntoImpl`）、`lib/data/db_questions.dart:49`（`setReviewJoinedIntoImpl` 的 `_seedCauseRecordsFor`，`ConflictAlgorithm.ignore`）、`lib/data/repository.dart:30-38`（`reviewBucketOf`）。
- 现象：B6 报告称报告页新增的 `_isMastered`“与错题本同义”，不对。错题本版只看该题现存的全部 `CauseRecord`（全部已解决且无一到复查即已掌握，与 `reviewBucketOf(...) == solved` 等价，首页/封面/目录都走这条口径）；报告版则按 `q.allCauses` 逐个错因查记录（每个当前错因都必须有一条已解决且未到复查的记录）。两者只在“记录与当前错因一一对应”时才等价，而这个前提会被正常操作打破：
  - 退出复习后改错因会留下陈旧记录：`syncCauseRecordsIntoImpl` 开头即 `if (!q.reviewJoined) return;`，未加入复习的题改错因（详情页编辑可改错因，保存时调 `syncCauseRecords`，见 `question_detail_page.dart:290`）不删旧记录、不给新错因补记录。
  - 再加入也不清陈旧记录：`_seedCauseRecordsFor` 是 `ConflictAlgorithm.ignore`、“已有记录不动”，只补缺失的。
- 证据（可复现的两条路径，均为普通 UI 操作，无需改库）：
  1. 报告多算：某题错因 `[计算错误]` 已治愈（已解决、复查日未到）→ 取消加入复习（记录保留）→ 详情页加错因 `概念不清`（无记录）→ 错题本按记录口径判已掌握（列表/封面不含它），报告按错因口径判未掌握（分布含它）→ **分布数 = 封面数 + 1**。
  2. 报告少算：某题 `[计算错误 已解决，概念不清 待解决]` → 取消加入复习 → 详情页删掉 `概念不清`（待解决记录残留）→ 错题本判未掌握（列表/封面含它），报告只看剩下的 `计算错误` 判已掌握（分布不含它）→ **分布数 = 封面数 − 1**。
- 修的方向：报告 `_isMastered` 改用与错题本/首页同一的记录口径，例如按该题现存记录算 `QuestionRepository.reviewBucketOf(records) == ReviewBucket.solved`，不再按 `allCauses` 逐因查记录；同时修正 `B6-P2-WRONGBOOK.md` 的“与错题本同义”说法与 `report_page.dart:28-35` 文件头口径注释（“分布数 = 该科封面总数”在陈旧记录下不成立）。补一个用例：同一道题带一条已删错因的陈旧记录时，分布数与封面数一致。
- 备注：报告页其他数字不受影响已核实——分布与弱点 Top5 都走 `_questionsInRange`（唯一题数口径点，`report_page.dart:182-191,493`），三个核心数按 `_records` 直接算（处方内口径，与 SR2-29 无关）；`_causeGroups` 与 `_kpGroups` 对复查到期题的处理一致（已解决记录都不进弱点组）。

## WRONGBOOK-2（P2）— SR2-33：按组进会话的文案“学科名 · 错因”与实际作用域不一致

- 位置：`lib/modules/review/review_page.dart:496-520`（`_startSession` 的 `fromGroup` 分支）与 `:430-460`（`_buildBlocks`）；对照 `:542-559`（`_scopeLabelForBlocks`）。
- 现象：B6 把按组进会话的范围文案改成 `'${学科名} · ${错因}'`，注释称“按组进会话只治该组一个错因”。但实际会话块是 `_buildBlocks(_filtered, onlyCause: fromGroup.cause)`——`_filtered` 是当前筛选下的全部分组，`_buildBlocks` 会把其中**每一个**含该错因的分组里的题都建成块，`bi` 只是跳到该组的首个块。于是会话作用域是（当前筛选 × 该错因），从该组开始、随后继续治其他学科同错因的题；文案却全程写着该组的“学科名 · 错因”。按 `_scopeLabelForBlocks` 对实际块集算，跨学科单错因时应得 `错因「计算错误」`，而不是 `数学 · 计算错误`。例：无筛选时数学、英语各有一道 `计算错误` 待治题，点数学组的“开始解决”，会话共 2 道题（`第 1 / 2 道题`），第二道是英语题，但元信息行全程写“数学 · 计算错误”。
- 证据：`_buildBlocks` 里 `allowed` 由 `_filtered` 的全部分组建成，`onlyCause` 只过滤错因、不限制学科；`bi` 的循环只定起始块。既有用例 `test/review_page_test.dart:713` 抓不住这一点——该库里只有 q2 一道题带 `计算错误`，会话恒为 1 块。
- 修的方向（二选一）：(a) 文案按实际块集算，即按组进会话也用 `_scopeLabelForBlocks(blocks)`（跨学科时自动退为 `错因「…」`）；或 (b) 把块集真正收窄到该组（`_buildBlocks` 只传该组），让文案与行为都按组来。另给既有用例加一道英语同错因题，断言会话题数与文案。
- 备注：`causesPerSession` 上限截断是同一类文案失真（截断后会话可能不含该组任何题，文案仍写该组），修 (a) 时一并覆盖；断点恢复分支仍用 `_scopeLabelForBlocks`，不受影响。

## WRONGBOOK-3（P2）— SR2-28：搜索态缝隙拖拽拒收全程无任何提示

- 位置：`lib/modules/wrongbook/wrongbook_directory.dart:271-279`（`_buildGapTarget` 的 `onWillAcceptWithDetails`）。
- 现象：文件夹搜索有关键词时缝隙一律 `return false`，状态正确（不调序、不保存，`test/wrongbook_page_test.dart:1902` 已钉住），但用户侧零反馈：拖动时缝隙不高亮、不提示，松手后什么都不发生。搜索态是用户正在主动操作的状态，拖拽平时又可用，静默拒收容易被当成“拖拽坏了”。
- 修的方向：在搜索框附近或目录顶加一句静态提示（例如搜索有关键词时显示“搜索时不能调顺序，先清空搜索”），或在缝隙拒收时给一个轻提示；`DragTarget` 本身没有“被拒”回调，提示要放在搜索态的文案上，不要为此改拖拽结构。
- 备注：静默拒收是本文件既有风格（跨层缝隙拒收 SR-P2-43 同款），本条只要求补一句可感知的说明，不改拒收行为。

## WRONGBOOK-4（P2）— SR2-30：B6 报告“preview.items 里不再有目录本身”不严谨；failed 目录仍以目录形式进 items，清理计数按 1 项算

- 位置：`lib/modules/settings/settings_page.dart:556-562`（`walk` 的 failed 分支）与 `:528-539`（`add`）、`:624-644`（`_clearCache`）。
- 现象：B6 只改了 cache/thumb/tmp 目录分支（递归进目录逐个计数），但 `walk` 开头的 failed 分支是 `if (lower.contains('failed') || lower.contains('import-error')) { add(e, 'failed'); continue; }`——`e` 可以是目录，`add` 会把它整个塞进 `preview.items`（字节数按递归合计），`_clearCache` 再递归删掉它、只计 1 项。于是“已清理 N 项缓存”与实际删掉的文件数在该分支上仍不一致；`_cacheCleanedMb = preview.mb` 在个别文件删失败时也会虚高（先于 B6 存在的小口径差）。
- 证据：代码走读。实际情况是当前代码里没有已知的 failed 目录生产者（`import_service.dart` 的 failed 是任务状态，不是目录名；`collect_page.dart` 亦然），所以这条目前大概率走不到目录分支，影响面限于用户自放的同名目录。
- 修的方向：failed 分支也与 B6 的 cache 分支同款处理——目录递归进、文件逐个计；或至少在注释里写明 `preview.items` 仍可含 failed 目录、与“不再有目录本身”的说法对齐。低优先级。

## WRONGBOOK-5（P2）— SR2-61：真实仓储首页用例只断言焦点卡总数，未断言分科行；tearDown 注册在播种之后

- 位置：`test/b5_p1_1_subject_counts_test.dart:222-271`（SR2-61 用例）；`test/home_page_test.dart:105-110`（`pumpHome` 的 `repo` 参数放宽与 `settle` 参数）。
- 现象（次要测试缺口）：用例本身是真接线——真实 `QuestionRepository` + 内存库、经仓库写方法播种、先断言仓储层数（`dueToday` = `{q1,q2,q3,q8}`、`homeRevCounts` = `{math:3, english:1, politics:0}`）再泵首页断言 `4 道要复习` / `待解决 2 道 · 复查 2 道`——`pumpHome` 放宽参数只是配套改动，这点已确认无问题。但 widget 侧只断言了焦点卡两行总数，分科行（数学/英语各自的今日到期、复习中、已掌握）仍只由 FakeRepo 用例覆盖；另外 `addTearDown(AppDatabase.resetForTest)` 注册在 `runAsync` 播种之后，若播种抛错，测试库单例会残留（目前无害：该用例是本文件最后一个用例，且各测试文件分进程跑）。
- 修的方向：补断言分科行文案（与 FakeRepo 的同名用例对齐）；把 `addTearDown` 移到播种之前。低优先级。

---

## 已确认无问题

- **SR2-7（移动目标下拉）**：三个使用点全覆盖——目录移动条 build 内 `effectiveTargetId` 兜底（`wrongbook_directory.dart:158-165,185`，只认 `__top__` 与当前科顶层文件夹）；`_moveSelected` 按同一口径重算目标再执行（`wrongbook_page.dart:1001-1008`）；`_moveOneFolder` 用 `_folderById` 安全查找 + 跨科校验、找不到返回可提示文案不再抛 `StateError`（`:914-921`）。复位点齐全：`_openDirectory`（`:761`）、`_openShelf`（`:777`）、`_deleteFolderConfirmed`（`:867`）；进目录的唯一入口是 `_openDirectory`，`initState` 默认值即 `__top__`。拖动使目标变子文件夹、改名、删目标等路径都被“只认当前科顶层”的 build 守卫兜住。`_moveSelected` 成功后不复位是合理的（目标仍合法，下次开条沿用上次选择）。
- **SR2-34（错因/错误类型下拉）**：复习 `_causeFilter` 与错题本 `_filterErrorType` 均为 `_load` 复位 + build 内 `effectiveValue` 双防线，且 `_load` 的校验集合与下拉选项集合是同一来源（复习 `_allCauses` 来自分组，`review_page.dart:312-317,393-402,1050-1054`；错题本 `固定错因 + 现存题全部错因`，`wrongbook_page.dart:326-334`、`wrongbook_list.dart:197-205,264`）。遗留的两处已逐一核实，报告说法成立：`_filterExamId` 与复习 `_subjectFilter` 确实没有页内删除路径——试卷/学科只能在学科管理页删（`subjects_page.dart:290,301`），而应用是路由切换式导航（`app.dart:301,329-344`：`child: _buildPage()`，非 IndexedStack），离页即 dispose State、回页是全新 State；详情页是 Navigator 压栈、State 存活，但详情页没有删试卷/删学科的操作（`deleteExamFromImpl` 还在同一事务里把题上的 `exam_id` 置空，`db_catalog.dart:281-292`）。注：这道防线依赖“离页即 dispose”这一导航结构，若将来改成常驻页（如 IndexedStack），这两处要补 `effectiveValue` 兜底——B6 报告已留此话。
- **月筛选 age < 30**：唯一口径点 `_filteredAll()`（`wrongbook_page.dart:606-621`），周/月统一 `age >= 0 && age < limit`，列表/目录/搜索/分页都走它；`lib/` 与 `test/` 内无 `age <= 30` 残留（只剩注释里“不是 age <= 30”的说明句）；文案“最近 30 天”在 `wrongbook_list.dart:286`；报告页“本月”自然月未动。目录计数不走时间筛选是既有设计（目录是文件夹索引），不在此口径内。
- **SR2-32（拼音排序）**：三级比较（首字母 → 全名拼音首字母串 → 全名）与空名回落 `'{''`/`''` 一致（`wrongbook_page.dart:163-201`）：空名首字母 `'{'`（> Z）且 key `''`，稳定排最后；表外汉字回退原字比较、码点恒大于拉丁字母，排在已映射字母之后，注释已写明不是拼音序；映射表覆盖数学/英语/政治/生物/化学等常见首字。`SR2-74` 三组用例（同首字母平局、未映射汉字、空名）与实现一致，全量已通过。
- **SR2-28 状态面**：搜索态缝隙拒收本身正确（见 WRONGBOOK-3，问题只在无提示）；拖到行上移进去、拖到“全部题目”移回顶层不受影响（`wrongbook_directory.dart:271-279` 只拦缝隙）。
- **SR2-30 计数与清理一致性**：递归后 cache/thumb/tmp 目录内的文件逐个按类计数、目录本身不再计 1（`settings_page.dart:574-598`）；`_clearCache` 只删 `preview.items` 里的文件（`:624-644`），留下的空目录下次扫描为 0、无偏差——B6-SUMMARY 的“留空目录无害”已确认；`test/settings_page_test.dart` 在门禁跑里已有真实运行记录（SR-P2-50 用例通过，B6-SUMMARY“协调员收尾修复”一节），不再是“已写未跑”。
- **SR2-76（页码回落）**：列表与已归档视图的渲染层都对 `_page` 做 `clamp`（`wrongbook_list.dart:8-9,1145-1146`），分页器上下页也用回落后的 `page`；`_page` 状态本身不重置是既有设计（只显示回落），用例已钉住。
- **SR2-61 接线本身**：见 WRONGBOOK-5，真实仓储→首页的接线是真覆盖，不是只换参数类型。
- **B6-SUMMARY“遗留”里已列的项**：逐项确认，不重复编号——`_clearCache` 留空目录无害（见上）；SR2-29 打破旧用例已由协调员修（`report_page_test.dart` 分布用例已改为英语 1 道并加 SR2-29 专用用例，全量通过）；其余遗留（`_confirmCurrent` 无 try、SR2-3 重命名失败分支未测、失败行卡 `importing`、SR2-62 同毫秒未确定性覆盖等）均不在本次范围文件内，未动。

## 探针说明

- 临时探针 `test/zz_probe_sr3_test.dart`（SR2-29 陈旧记录双页对照、SR2-33 跨科同错因会话）已写但未跑通：本次 `flutter test --concurrency=1` 在共享 CPU 上 13 分钟无输出，编译进程 CPU 几乎不动，已按确切 PID 停掉并删除探针文件（工作树无残留）。WRONGBOOK-1 与 WRONGBOOK-2 的结论以代码级证据为准，建议修完后由执行员在对应文件里补用例并实跑验证。
