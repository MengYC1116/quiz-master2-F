# Batch 7 总结 — 第三次自审 35 项修复

- 任务：修完第三次自审（SELF-REVIEW-3.md / SELF-REVIEW-3-SUMMARY.md）的全部 35 项（P0 0、P1 2、P2 33），按汇总“建议修的顺序”分六阶段做。
- 日期：2026-11-15。协调员：第七批修复协调员。
- 基线：Batch 6 完成（`flutter analyze` 0 问题；全量测试 852/852；Linux Release 构建通过；演示库 md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`）。
- 原则：只修第三次自审列出的问题；Meng 已定的 4 项口径按推荐的 (a) 执行；不提交、不推送（推送须 Meng 另外批准）。

## 例外（已定，不修）

- **SR3-25**（B2 旧遗留，错题本紧凑行深色下用亮色存色）：作后续项，这批不回炉。
- **SR3-8**（50MB PDF 用例间歇失败）：只观察、不改代码。本次全量里“恰好 50MB PDF”用例通过，未复现；根因仍未证实。

## Meng 已定的 4 项口径落实情况

1. **SR3-21 金角兜底（a）**：36 步耗尽后改 1° 细粒度扫描取最优色。实测第 15 科取 110°（`0xFF63D94C`，最小距约 25.3°，仍 ≥25°）、第 16 科取 307°（`0xFFD94CC8`，约 23.2°，15 色下最优）。用例钉住 13–16 科字面值。
2. **SR3-16 离页守卫（a）**：只在 `B6-P1-QUEUE.md` 的“拦住”论证后补适用边界句（“拦住”只保页内动作，不保离页）；产品级离页守卫（`PopScope` + 离页前保存/确认）另立项，这批不做。
3. **SR3-24 YOLO 串行队列超时（a）**：单次推理加 60 秒超时（`detectTimeout` 常量），超时按推理异常走 fallback 并放行队列，不取消原生推理。新增 `@visibleForTesting` 的 `detectTimeoutForTest` 及用例（1ms 超时 → fallback，下一次检测仍能跑）。
4. **SR2-19 备份峰值口径**：维持现状，按峰值算（最终 < 2GB 但峰值 > 2GB 的备份继续拒绝）。数据组核对：`peakBytes = usedBytes + incomingBytes`，既有用例随文件跑通；未改代码。

## 最终验证（协调员亲自跑）

- `flutter analyze`：**0 问题**（`No issues found!`）。
- 全量测试：串行 `--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，**879/879 通过**（约 6 分 25 秒；第三次全量 852 → **879，净增 27**）。
- Linux Release 构建：通过（`✓ Built build/linux/x64/release/bundle/quiz_master2`）。**中途工具链故障**：首次构建 CMake 报错 `/usr/include/gtk-3.0` 不存在——VM 换后 GTK 开发头文件又被清空（复发问题）；已跑 `docs/ui-replication/restore-linux-toolchain.sh` 恢复（GTK 3.24.41、clang 18.1.3），重建通过。
- 演示库：跑全量前已备份到工作区（`~/workspace/demo-db-backup/quiz-master2.db.b7-start`），跑完恢复并核对 md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1、9 道题、3 学科），不变。
- 计数演进：852（Batch 6）→ **879（Batch 7，净增 27）**：P1 +4、数据层 +7、收集/整理/详情 +9、错题本/复习/报告 +3、服务层/主题 +4、文档 +0。

## 阶段一：P1 两项（`B7-P1.md`）

### SR3-1 — `readZip` 判重前归一化

- `lib/services/zip_archive.dart`：新增共用归一化函数 `normalizeZipEntryName`（`\`→`/`、折叠连续 `/`、消解 `.` 段，`..` 保留）；`validateZipEntryName` 改用它（绝对路径/盘符在归一化前判，`..` 在归一化后判，归一化为空按空名拒绝）；`readZip` 判重键改为归一化 + 小写折叠（仅用于比较，不改存名与落盘路径）。staging/进位路径未改用归一化键——判重已在进 staging 前拒掉一切撞车变体。
- 用例：`//`、`/.`、反斜杠、大小写四种变体均判重拒绝；端到端 `//` 变体重名备份恢复断言含“已损坏”且不含“文件写不进去”。
- 验证：`b5_p2_data_test` 62/62；`b7_p1_sr3_2_test` 2/2；备份/服务/报告四文件合跑 78/78。

### SR3-2 — 报告 `_isMastered` 改用记录口径

- `lib/modules/report/report_page.dart`：`_isMastered` 改用与错题本/首页同一的记录口径（`QuestionRepository.reviewBucketOf(records) == ReviewBucket.solved`），不再按 `allCauses` 逐因查记录；文件头口径注释与 `_questionsInRange` 注释同步改写；`B6-P2-WRONGBOOK.md` 的“与错题本同义”说法修正为 SR3-2 勘误。
- 用例（新文件 `test/b7_p1_sr3_2_test.dart`，2 个，**实跑验证**——上次探针没跑通的缺口已补）：同一份 FakeRepo 同时泵报告页与错题本页对照数字；路径 1（报告多算）分布 0 道、封面 0 道；路径 2（报告少算）分布 1 道、封面 1 道。两用例在旧口径下都会在分布断言上失败。
- 遗留：路径 2 的题修后计入分布（未掌握）但不进弱点 Top5（当前错因已全部解决，无未解决错因可分组）——记录口径的直接后果，不是分布/封面口径问题；弱点组如需同改，另立项。

## 阶段二：P2 数据层（`B7-P2-DATA.md`）

- **SR3-3**：`db_collect.dart` 的 `boxesForQuestionFromImpl` 与 `boxesForTaskPageFromImpl` 各补 `orderBy: 'page ASC, id ASC'`；修正 `b5_p2_data_test.dart:722` 注释的夸大说法；新增排序用例 1 项（同题多框用 layer=2 框——layer=1 有“每题一框”部分唯一索引）。
- **SR3-4**：选修法 (a)——`upsertCauseRecord` 改名 `updateCauseRemedy`（`db_questions.dart`），`saveRemedy` 调用点同步改；`repository.saveCauseRecord` 保留为公开入口并加注释写明契约（行已存在时 status 等改动按设计丢弃）。不选 (b) 的理由：恢复全量 upsert 会重新引入 SR2-14 刚堵住的旧快照覆盖自查结果的危害。用例钉住：已存在行 status 改动被丢弃、remedy 写入；不存在行整行 INSERT。
- **SR3-5**：`_dedupKey` 按平台分流——可解析分支保留小写折叠，回退分支不再折叠；`[大写不存在, 真实]` 顺序下真实文件仍进 needBox，不再被遮蔽；既有用例按新口径改期望（`[真实, 大写]` 现为 2 个任务）。
- **SR3-6**：`enqueue` 入口把 `onProgress` 包成永不抛错的 `safeOnProgress`，五处调用点全部受益；新增图片/PDF 各 1 个用例，回调抛错时任务仍进 needBox。
- **SR3-9**：`seenBoxIds` 提到 `confirmSplitIntoImpl` 的事务级，一个集合覆盖全部题 + 保留分支，跨题/跨页重复也跳过（保留第一个）；新增跨题、跨页各 1 个用例。
- 验证：`b5_p2_data_test` 62/62；`import_service_p1_fixes_test` 19/19；另 6 文件合跑全过。

## 阶段三：P2 收集 / 整理 / 详情（`B7-P2-COLLECT.md`）

- **SR3-10**（选修法 a，自愈）：详情页 `_load()` 后新增 `_healSliceIfNeeded`——切片实际尺寸（新增 `pngDimensions`，只解析 PNG IHDR，不解码）与库里不符时，按当前第一个 1 层框重裁、临时文件 + rename 原子替换；重裁尺寸与库里不同时再改库；失败静默重试。新增用例 1 项。**基线变化（不是回归）**：既有 SR2-3 用例的夹具（库记 200×100、磁盘 560×700 旧图）正是自愈要修的状态，测试已改成先跑完自愈、再以自愈后切片为基线断言，意图不变。
- **SR3-11**：`_reworkBoxes` 的读页图 + `cropBoxPng` 包进 try/catch，失败报“重新框选失败：页图读不出来/切片裁不出来，请重试”并 return；新增用例 1 项。
- **SR3-12**：`_nearestLayer1Box` 改三态——距离上限 0.25（归一化坐标）、平局取相交面积最大者、仍平局判歧义；确认后随成功提示报“同时落在两道题里 / 离所有题太远”，未归属内框本次不入库。新增用例 3 项。
- **SR3-13**（a+b 并用）：IoU 阈值 0.05→0.3（提示写明阈值），候选池排除中心落在邻题只读框内的检测框；修法 (c) 位移校验未做——(a)+(b) 已堵住触发路径。新增用例 2 项。
- **SR3-14**：恢复时中心落在旧目标框内的独立内框做与有父框内框相同的相对位置换算 + `_clampInner`，框外的不动。新增用例 1 项。
- **SR3-15**：`_batchTagRedo` 逐题记已保存 id，同步放 `finally` 保证执行（只同步已保存子集），失败不抛、报“部分保存失败”。新增用例 1 项（桩 repo 第二题 `save` 抛错 → 第一题标签在快照里、后续批量加文件夹后不丢）。
- 验证：`detail_page_test` 30/30；`collect_page_test` 48/48；`b5_p2_collect_test` 34/34；`organize_page_test` 39/39。
- **探针发现（未修，待定）**：调试 SR3-15 时发现队列弹出层里文件夹下拉的菜单项点按在测试里不生效——菜单能打开，但点菜单项后菜单不关、`_addingBatchFolder` 不置起（疑似弹出层屏障吞掉了菜单路由上的点按）。未在真机核实是产品问题还是测试环境问题，建议 Win11 真机复核时顺手点一次批量加文件夹的下拉新建。

## 阶段四：P2 错题本 / 复习 / 报告 / 首页（`B7-P2-WRONGBOOK.md`）

- **SR3-17**（选修法 a）：按组进会话的文案改为按实际块集算（`_scopeLabelForBlocks(blocks)`）。跨学科同错因时自动退为 `错因「…」`，单科单错因时仍是 `学科名 · 错因`；`causesPerSession` 截断后的块集也被如实描述。**实跑验证**（上次探针没跑通的缺口已补）：新增 `crossSubjectRepo()` 与用例，断言会话共 2 道题、文案为 `错因「计算错误」`、第二道确为英语题。`review_page_test` 39/39。
- **SR3-18**：目录页搜索有关键词时在工具条下显示静态提示“搜索时不能调顺序，先清空搜索”，清空后消失；拖拽结构与拒收行为未动。`wrongbook_page_test` 80/80。
- **SR3-19**：`settings_page.dart` 的 failed 分支与 cache 分支同款——目录递归进、文件逐个计，`preview.items` 里不再有目录。新增用例：断言“其中含导入失败的残留文件 2 个”且“已清理 2 项缓存”（旧实现均为 1）。`settings_page_test` 28/28。
- **SR3-20**：SR2-61 用例的 `addTearDown` 移到播种之前；补断言分科行文案（数学“要复习 3 道 · 待整理 1 道”、英语“要复习 1 道 · 待整理 0 道”、政治 0 道）。`b5_p1_1_subject_counts_test` 5/5。
- 遗留：SR3-17 选的是修法 (a)，会话行为不变（按组进会话仍跨学科治同错因题，只是文案如实写）；若要只治该组须另改修法 (b)。SR3-19 的 `_cacheCleanedMb` 个别文件删失败时虚高的小口径差未动（先于 B6 存在）。

## 阶段五：P2 服务层 / 主题 / 组件（`B7-P2-SERVICES.md`）

- **SR3-21**：见“4 项口径”第 1 条。`subjects_page_test` 27/27。
- **SR3-22**：`QmChip` 双区 `Row` 外包 `IntrinsicHeight` + `stretch`，两识别器精确撑满行高，芯片总尺寸不变（实测仍 26px 高）。两处与任务书字面修法的偏差均经探针实测：裸 `stretch` 在松约束下会把芯片撑到 600px 高，不能用；算出的 23.6px 定高不够（Text 行高向上取整，标签区实为 24px）。用例点 × 区 `top + 1` 与 `bottom - 2`（`bottom - 1` 恰是 1px 边框线，命中测试排他边界，任何识别器都点不到）。`uikit_test` 31/31。
- **SR3-23**：`await gate.future` 移进 `try` 块内，gate 报错走加载失败同一路径，下次检测重试。新增用例：gate `completeError` 后第一次 fallback、计数 1，第二次检测重试、计数 2。
- **SR3-24**：见“4 项口径”第 3 条。`yolo_onnx_service_test` 29/29（含真模型实跑）。
- **SR3-34**：删除测试内本地 `hueDistance` 与逐色 `>= 25` 循环，只断言字面值；25° 阈值覆盖由字面值 + SR3-21 的 14–16 科字面值钉住。
- 附注：该组曾对 6 个文件跑整文件 `dart format`，仓库本身不执行 format（HEAD 已非 format-clean），引入了与 B7 无关的重排噪声；已用脚本把保护范围外的纯格式 hunk 逐一还原（53 处），与 B6 改动混在同一 hunk 内的少量重排无法分离、予以保留。
- 遗留：SR3-22 的 1px 边框线仍为全区排他边界；SR3-24 超时后原生推理仍在后台跑，与下一次推理短暂重叠是“不取消原生推理”的固有代价。

## 阶段六：P2 文档（`B7-P2-DOCS.md`）

- **SR3-7**：三处数字更正并 grep/实跑核实——`b5_p2_data_test` 36→56；`_failAndClean` 调用点 13 处（grep：14 命中 − 1 定义）；`b5_p2_services_test` 15/15→25/25（实跑确认）。另顺带修正 `import_service.dart:578-580` 的同款错误注释（纯注释）。
- **SR3-16**：见“4 项口径”第 2 条。
- **SR3-26**：两处“原 30 + 新增 9”→“原 29 + 新增 9 = 38”（基线 29 经 git 计数核实）。
- **SR3-27 + SR3-35**：`docs/代码地图.md`、`docs/CODEBUDDY.md`、`docs/四方分工.md` 同步为推送后状态（Batch 6 已推，远端 head `38cbc4b`，`git ls-remote` 与 `git log origin/ui-replication` 双重核实）；“不要 push”改为针对第七批。复核时发现 `四方分工.md:8` 头注还有一处同类过期表述，顺带同步。
- **SR3-28**：7 条阶段报告级遗留补进 B6-SUMMARY 末尾“遗留”小节，逐条与源报告原文对过。
- **SR3-29**：SR2-16 一条改为“第三次全量 852/852 已确认，无回归（原待办已过时，移出待办、仅留此注）”；SR2-15 改述为“并发用例依赖串行化语义，换库后端时需复核（已知脆弱性，非待办）”。
- **SR3-30**：核实工作树无 `test/zz_probe_*.dart` 残留（`ls` 与 `git status` 均无），无需删除。
- **SR3-31**：`/tmp/b6-files.txt` 首行补 `2026-11-15 01:40 UTC README.md`；清单现 63 条，与 `git diff 6448c45..38cbc4b --name-only` 逐项比对完全一致。
- **SR3-32**：`B6-P1-DOCS.md` 改为“3 处（D-04、README、代码地图 :118；README 一处因换行断开，字面 grep 命中 2 处）”。
- **SR3-33**：B6-SUMMARY 正文 `db_collect.dart:325`→实测 `:338`，并注明其余漂移行号不逐条改旧报告、后续引用以 grep/符号为准。
- 验证：`flutter analyze` 0 问题；grep 逐项复核旧数字/旧措辞零残留；`b5_p2_services_test` 25/25 实跑。

## 遗留（未修 / 需另定，详见各阶段报告）

- **SR3-25**（B2 遗留）：错题本紧凑行深色下用亮色存色画学科名，这批未做，作后续项。
- **SR3-16 产品级离页守卫**：另立项，待 Meng 定。
- **SR3-8**：50MB PDF 用例间歇失败本次未复现，根因仍未证实；门禁重跑时留意，如再现保留完整失败输出再定性。
- **SR3-17 修法 (b)**：如 Meng 希望按组进会话只治该组，须另改块集收窄。
- **SR3-2 弱点 Top5**：修后计入分布的题不进弱点 Top5（当前错因已全部解决），弱点组如需同改，另立项。
- **SR3-15 探针发现**：队列弹出层文件夹下拉菜单项点按在测试里不生效，待 Win11 真机复核确认是否产品问题。
- **SR3-10**：自愈只覆盖“切片文件存在但尺寸不符”；切片文件缺失时不重建，仍走原有的图加载失败占位（设计取舍）。
- **SR3-24**：超时后原生推理仍在后台跑，与下一次推理短暂重叠的固有代价。
- **SR3-22**：1px 边框线仍为全区排他边界。
- **服务层组 `dart format` 残留**：与 B6 改动混在同一 hunk 内的少量纯格式重排无法分离、予以保留（不影响行为）。
- **SR3-28 补收的 7 条遗留本身未修**（只补进总结遗留），其中金角第 14、15…科问题（SR3-21）已按 Meng 已定口径修完。
- SR3-4 的 `repository.saveCauseRecord` 名字仍是“全量保存”口吻（契约已用注释 + 用例钉死），彻底改名可另立项。
- SR3-5 的 Linux 取舍仍在：同目录仅大小写不同的两个真实文件仍会被折叠去重（病态构造，产品跑在 Windows 上）。
- SR3-3 的两处框查询补 orderBy 后，`boxesForQuestionFrom` / `boxesForTaskPageFrom` 仍只有测试在用（无生产调用方）。
- SR3-13 的修法 (c)（认领后位移校验）未做——(a)+(b) 已堵住触发路径。
- SR3-12 的“真重叠 + 面积平局”分支经 UI 不可达（编辑器拦重叠确认、`groupInners` 预分组），用例覆盖的是同一判据的等距间隙构造；分支本身作为纵深防御留在代码里。
- `double` 封面折角：Meng 自己与 CodeBuddy 协调，Muse 不做（原决定不变）。
- SR2-57：P2-11 的 Windows 文件锁分支（Linux 测不了），待 Win11 真机复核；其余沿用 2026-11-14 09:15 的验收清单。
- 测试夹具 zip 链接 2026-11-16T00:41:08Z 过期（本地副本 `~/workspace/qm2-test-fixtures.zip` 可重传）。

## 下一步

1. **Meng 决定是否推送**：推送前需他明确批准；当前全部改动未提交、未推。
2. 推送后他拉取并做 Win11 真机验收；复核清单见 B6-SUMMARY（含 SR2-57 文件锁分支、SR-P0-2 真机列表行为、libpdfium 打包等）+ 本总结遗留的 SR3-15 下拉点按复核。
3. 完成后关闭跟踪项并删除看门与进度汇报两个 cron。
