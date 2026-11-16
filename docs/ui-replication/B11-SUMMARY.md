# B11-SUMMARY — 第十一批：8 个小功能（2026-11-15）

范围（Meng 2026-11-15 23:17 定，23:19 更正第 9 项）：1 拖放导入（最小版）、2 批量导入（拓展版）、4 整理返回上一道（最小版）、6 错题本批量加入复习（拓展版）、8 详情页导出本题图片（拓展版）、9 考试倒计时（独立事件，与试卷零关联）、10 今日小结（最小版）、11 空状态接线（最小版）。未做：CI、大文件拆分、配色/主题、其他功能。未 commit、未 push。

## 一、逐项结果

### 1. 拖放导入（最小版）——完成（报告 B11-1-DRAGDROP.md）
- 插件 `desktop_drop 0.8.4`（0.9.x 要求 `cross_file ^0.4.0`，与 file_picker 8.x 的 `^0.3.x` 冲突，升级 file_picker 超范围）。只接收集中心落点，拖入走与点选导入同一条 `_handleIncomingPaths`（选学科、PDF 50MB / 图片 20MB、重复提示“已经导入过”）；悬停标题变“松开就导入”；文件夹与不支持类型跳过并提示；“拖放导入还没接好”占位文案已删。不做全窗口落点、不做微信/QQ 窗口拖入。
- 测试：新 `b11_dragdrop_test.dart` 7/7（通道模拟真实拖放）；`collect_page_test.dart` 42/42。

### 2. 批量导入（拓展版）——完成（报告 B11-2-BATCH-IMPORT.md）
- 一次多选图片/PDF；>1 文件建 `BatchImportState` 队列卡片（总进度、每行状态/进度/失败原因、单行重试、“重试失败项”）；逐个处理、单张失败不中断整批、重试只重导失败项（沿用本批学科）；单文件导入不建队列，行为不变。
- 去重：内容哈希 = 全文件 SHA-256（`crypto` 3.0.8，纯 Dart）；不改 Schema，哈希按任务 `sourcePath` 现算已入库原文件，缺失跳过不误判；文件名命中或内容命中都进同一条“已经导入过”横幅，用户确认才重导；同批内相同内容只留第一份。
- 猜测只建议、不静默指定：学科按关键词猜（最长命中胜出，等长按数学/英语/政治），全批一致才预填下拉框 + 提示行；试卷名只在队列行显示“建议试卷：X”，不写库。**前置行为变化**：以前没选学科不能点选择文件，现在可先选文件再选学科（“没选学科不能导入”口径不变）；`collect_page_test.dart` 相应 1 个旧测试已按新行为更新。
- 测试：新 29 个（`b11_import_guess_test` 21 + `b11_batch_import_test` 8）；`flutter analyze` 0 问题。

### 4. 整理返回上一道（最小版）——完成，无 lib 改动（报告 B11-4-PREV.md）
- 核查发现「上一道」按钮自 R5 已存在（`organize_page.dart` 的 `_workActs`，与「下一道」并排）：第一道时 `onPressed` 为 null（禁用）；`_goTo(_index - 1)` 只改下标不动队列顺序；切题经 `_trySaveCurrent()` 自动保存、失败拦下，已填内容原样。四条验收逐条满足，故 lib 未改，只补了此前缺失的显式测试（`b11_4_prev_question_test.dart` 2/2）。

### 6. 错题本批量加入复习（拓展版）——完成（报告 B11-6-BATCH-REVIEW.md）
- 批量条新增三个按钮（复用既有 Wrap + QmButton 结构，筛选/排序/分页未动）：**加入复习**（勾选题，无勾选时禁用）；**全部加入复习**（作用域 = 当前筛选出的全部题，与 Batch 9“全选当前结果”同口径，不限当前页、不用先勾选）；**取消加入复习**（勾选题，只翻 `review_joined` 标志，记录保留、重加入可恢复，与详情页单个取消同语义）。
- 跳过规则（`QuestionRepository.hasJoinableCause`）：只加未解决的错因——无记录/待解决/解决中/已解决但到复查时间的错因可加；全部已解决且复查未到的题跳过。反馈一次说清，如 `已加入复习 2 道；1 道已无未解决错因，跳过`；加入成功时 Snackbar 带 **“开始复习”** 动作跳 `/review`（不限学科），0 道加入时不给入口。
- 测试：新 `b11_6_batch_review_test.dart` 16/16（判定 8 例 + 加入/取消 + widget 全覆盖）；回归 `wrongbook_page_test.dart` 86/86。过程：回归文件曾挂起 75 分钟 CPU 0%（协调员按 PID 杀掉后重跑全过，判断为既有测试在共享树被并发改动时的挂起，与改动无可证关系）；首次跑测试时 VM 工具链丢失，按仓库既有脚本恢复成功（clang 18.1.3、GTK 3.24.41）。

### 8. 详情页导出本题图片（拓展版）——完成（报告 B11-8-EXPORT-IMAGE.md）
- 详情页底部操作区新增三个动作，与收藏/归档/删除并列：(a) **复制图片到剪贴板**——Windows 下可行，方案 `super_clipboard ^0.9.1`（见 D-30）；(b) **保存图片为文件**——另存为对话框，PNG；(c) **导出带答案版**——分享卡片（题目图在上、答案/解析在下，带学科/文件夹/错因小字），先弹预览框、用户确认后再另存为，不静默落盘；答案为空时卡片显示“待补充”。
- 另顺手闭了 B11-11 的遗留：详情页复习记录空状态接了「去复习」按钮，`app.dart` 已接 `_goReview`。
- 测试：新 `b11_8_export_image_test.dart` 17/17；既有 `detail_page_test.dart` 37/37；`flutter build linux --debug` 通过；分享卡片留样 3 张在 `shots/b11-detail/`。
- 验证边界：Linux 测试环境下没有调真实剪贴板写（带真实写的探针让 `flutter_tester` 空转挂起，无显示服务时原生写调用阻塞）；Win11 真机粘贴必须另验。

### 9. 考试倒计时（按 23:19 更正：与试卷零关联）——完成（报告 B11-9-EXAM-COUNTDOWN.md）
- 设置页新增“考试”组（自定义名称 + 考试日期，不选试卷、不关联试卷、不读任何试卷数据）；列表支持改名、改日期、删除。首页焦点卡上方显示最近一场倒计时“距离 XX 考试还有 N 天”（当天“今天考试”，过期“已考完”）；临近 7 天内（0 ≤ N ≤ 7）标红；点倒计时进设置页考试管理。不做的三项（关联试卷、进试卷题表、考前冲刺）均未做。
- 存储：复用 settings 表 `examEvents` 键（JSON 数组），不新建表、不并入试卷表（见 D-31）；倒计时口径 N = 考试日期 − 今天（日历日），最近一场取未过期里 N 最小，全部过期取最近过期那场。
- 测试：新 `b11_9_exam_countdown_test.dart` 23/23；回归逐文件全过（home 18/18、settings 26/26 等）。测试中修掉两个真 bug：空列表返回 `const []` 导致 repository `sort()` 抛错；改名弹窗控制器在关闭动画期间被 dispose。
- 注意：首页 `_load` 新增 `repo.examEvents()` 调用后，三个直接 pump 首页的旧 Fake 已补覆盖；整应用测试用内存库单例，不受影响。今后新增 repo 调用进首页/设置页时须同步检查这些 Fake。

### 10. 今日小结（最小版）——完成（报告 B11-10-TODAY-SUMMARY.md）
- 整理队列为空且库里有题时，空状态卡下方新增一行居中 muted 文字：`今天整理了 N 道、待复习 M 道`（13.5px，不新增颜色）；从未有题的空状态不显示。只这一行，不加本周累计与连续天数。
- 口径写死：N1 = 今天已整理的题数，用 settings 表 `organizedToday` 键（值 `yyyy-MM-dd|N`），只计未整理→已整理的跃迁（见 D-28，不用 `organized_at` 列）；N2 = 待复习题数，复用 `repo.dueToday().length`，与首页焦点卡 / 复习角标同一数字。
- 测试：新 `b11_10_today_summary_test.dart` 10/10（口径纯函数 3、真库跃迁计数 3、widget 4）。

### 11. 空状态接线（最小版）——完成，lib 零改动（报告 B11-11-EMPTY-STATES.md）
- 全应用审计 27 处空状态：所有动作按钮在审计时已全部接线，没有发现死按钮，本项未改任何业务代码。三处任务点名的“去复习”已核实接通（整理页、学习报告 → `/review`；复习页动作是“去错题本选题” → `/wrongbook`）。
- 测试：新 `test/b11_11_empty_states_test.dart` 8/8（补此前只有“出现”断言、没有“点按”断言的动作）。
- 遗留（见 §五第 1 条）：错题本列表空状态文案提到“去收集/去整理”但只是说明文字、不可点，需产品决策。

## 二、验收（协调员亲自跑，最终树）

- `flutter analyze`：**0 问题**（`No issues found!`，23.8s）。
- 全量测试串行（`--concurrency=1`，`LD_LIBRARY_PATH=…/onnxruntime-1.4.1/linux`，默认 /tmp）：**1007/1007 通过**，`[E]` 0。基线 895 + 本批新增 112（W1 36 + W2 12 + W3 16 + W4 17 + W5 23 + W6 8）。日志 `/tmp/b11-gate-full.log`。
- Linux Release 构建：**通过**（`✓ Built build/linux/x64/release/bundle/quiz_master2`），日志 `/tmp/b11-gate-build.log`。
- 演示库：备份 `~/workspace/demo-db-backup/quiz-master2.db.b11-gate`；跑完 live 库仍是 v1，md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，无需恢复。
- 新增依赖（pubspec.yaml/lock）：`desktop_drop ^0.8.4`、`crypto ^3.0.8`、`super_clipboard ^0.9.1`，三者共存无冲突。

## 三、决策（已记入 docs/decision-log.md，D-25~D-31）

- D-25：拖放插件 `desktop_drop 0.8.4`；落点只收集中心；拖入与点选同流程。
- D-26：批量导入 SHA-256 内容去重、不改 Schema、队列语义、文件名猜学科/试卷规则、“没选学科也能先选文件”前置。
- D-27：整理“上一道”不新增代码（自 R5 已存在，只补测试）。
- D-28：今日小结 N1 用 settings 计数不用 `organized_at` 列；小结行只在队列已空时显示；N2 复用 `dueToday()`。
- D-29：批量加入复习只加未解决错因（已解决但到复查时间算可加）；“全部加入”作用域 = 当前筛选结果；反馈文案；“开始复习”入口为 Snackbar 动作；取消不二次确认。
- D-30：剪贴板图片用 `super_clipboard ^0.9.1`（Windows 可行）；分享卡片先预览再保存。
- D-31：考试事件独立存储（settings 表 `examEvents` 键），与试卷实体无任何关联；倒计时口径；标红 0 ≤ N ≤ 7；考试组位置；懒加载。

## 四、改动文件

- 新增 lib：`lib/services/import_guess.dart`、`lib/modules/collect/batch_import.dart`、`lib/modules/collect/batch_import_card.dart`、`lib/services/question_export_service.dart`、`lib/widgets/question_share_card.dart`、`lib/models/exam_event.dart`。
- 修改 lib：`lib/modules/collect/collect_page.dart`、`lib/services/import_service.dart`、`lib/modules/organize/organize_page.dart`、`lib/data/database.dart`、`lib/data/db_settings.dart`、`lib/data/db_questions.dart`、`lib/data/repository.dart`、`lib/modules/wrongbook/wrongbook_page.dart`、`lib/modules/wrongbook/wrongbook_list.dart`、`lib/modules/detail/question_detail_page.dart`、`lib/modules/home/home_page.dart`、`lib/modules/settings/settings_page.dart`、`lib/app.dart`、`pubspec.yaml`、`pubspec.lock`。
- 新增测试（9 个文件，112 个用例）：`test/b11_dragdrop_test.dart`、`test/b11_import_guess_test.dart`、`test/b11_batch_import_test.dart`、`test/b11_4_prev_question_test.dart`、`test/b11_10_today_summary_test.dart`、`test/b11_6_batch_review_test.dart`、`test/b11_8_export_image_test.dart`、`test/b11_9_exam_countdown_test.dart`、`test/b11_11_empty_states_test.dart`；另 `test/collect_page_test.dart`（1 个旧测试按 B11-2 新行为更新 + `_FakeFilePicker`）、`test/organize_page_test.dart`、`test/home_page_test.dart`、`test/s8b2_subject_sync_test.dart`、`test/b8_1_subject_refresh_test.dart`、`test/b11_11_empty_states_test.dart`（Fake 覆盖补齐）。
- 报告：`docs/ui-replication/B11-1-DRAGDROP.md`、`B11-2-BATCH-IMPORT.md`、`B11-4-PREV.md`、`B11-10-TODAY-SUMMARY.md`、`B11-6-BATCH-REVIEW.md`、`B11-8-EXPORT-IMAGE.md`、`B11-9-EXAM-COUNTDOWN.md`、`B11-11-EMPTY-STATES.md`、本文件；`docs/decision-log.md`（D-25~D-31）。截图：`docs/ui-replication/shots/b11-detail/`（3 张分享卡片留样；其余项 widget 测试覆盖，未跑应用截图）。

## 五、待 Meng 定夺 / Win11 真机待验

1. **错题本列表空状态文案（需产品决策，不宜悄悄改）**：范围为空的文案写“去收集中心拍一道题，或去整理工作台……”，但只是说明文字、不可点，按钮是“返回目录 / 返回书架”；`QmEmptyState` 只有一个动作位。改文案还是改按钮，等 Meng 定。
2. **Win11 真机清单（Linux 测不了）**：拖放真实手感与悬停、Windows 原生构建编过、文件夹拖入、虚拟文件（OneDrive 占位 / Outlook 附件）拖入、中文/长路径文件名、10~20 文件批量耗时与近 50MB 大 PDF 的哈希+复制耗时；复制图片后分别粘贴到微信/Word/画图、保存与带答案版另存为走一遍、首次 `flutter build windows` 确认 super_clipboard 预编译二进制能下载（需联网）、详情页「去复习」按钮跳转、深色主题下分享卡片是深色底（是否固定浅色纸面再定）；考试倒计时首页显示与设置页管理走一遍；v1 演示库 9 道题都没有切片文件，导出三个按钮在演示库上都是“这道题没有图片可导出”（符合预期），须用真实导入的题验收。
3. **观察项**：`b5_p2_collect_test.dart` 的 SR2-62 有一次时间敏感随机段断言抖动失败、重跑通过，与本次改动无关；`super_clipboard` 上游仍标 experimental，首次 Windows 构建需联网。
4. **环境记录**：本批两次丢工具链（VM 替换后 `/usr` 后装工具链丢失），均按仓库既有脚本 `docs/ui-replication/restore-linux-toolchain.sh` 恢复（clang 18.1.3、GTK 3.24.41）；多 worker 并发跑测试时 /tmp（512M tmpfs）曾写满，全量验收已改串行跑、无问题。

## 附注（2026-11-16，推送前补记，D-32）

- §五第 1 条已定：Meng 2026-11-16 09:42 定“改成按钮”（不是改文案）。错题本列表范围为空的三种情形（文件夹空 / 学科空 / 整本空），动作位由单按钮“返回目录 / 返回书架”改成“去收集”（主按钮，进 `/collect`）+“去整理”（次按钮，进 `/organize`）；文案本身不动；其余空状态不动。实现：`QmEmptyState` 增加可选第二动作位；`WrongbookPage` 增加可空回调 `onGoCollect` / `onGoOrganize`，`app.dart` 接成 `_go('/collect')` / `_go('/organize')`；任一回调未接通时回落旧单按钮（页头已有“← 目录 / 合上 ✕”，返回入口不丢）。决策记为 D-32（`docs/decision-log.md`）。
- 随 B11 一次推送。测试数变化：全量 **1010/1010**（1007 + D-32 新增 3：错题本双按钮回调 1、`QmEmptyState` 双动作 2）；`flutter analyze` 0 问题；演示库跑完仍是 v1，md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`（备份 `~/workspace/demo-db-backup/quiz-master2.db.b11-d32`，无需恢复）。
