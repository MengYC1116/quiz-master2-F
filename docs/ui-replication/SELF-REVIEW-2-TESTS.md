# 第二次自审 · 测试质量与全量验证组报告（SELF-REVIEW-2-TESTS）

- 时间：2026-11-15（全量跑约 4 分 43 秒；其余核查随后进行）
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 范围：Batch 5 全部新增测试的质量审计 + 全量验证（analyze / 全量测试 / Linux Release 构建 / 演示库）
- 状态：**只审不改**。未改任何产品代码，未提交、未推代码，未动 git 状态。

## 验证结果

| 项 | 结果 |
|---|---|
| `flutter analyze` | **0 问题**（`No issues found!`，10.4s，Flutter 3.47.9，`~/workspace/flutter-install/flutter/bin/flutter`） |
| 全量测试 | **778/778 通过，0 失败**（`All tests passed!`，exit 0，约 4 分 43 秒；命令 `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux flutter test`，日志 `~/workspace/demo-db-backup/full-test-20261115.log`；`[E]` 0 行、跳过 0 项） |
| Linux Release 构建 | **未跑——环境阻断**（见下“阻断：clang 丢失”） |
| 演示库 | **md5 不变**：跑前备份 `8f7f9c64405dc6e484ac2bf8e5e1a807`；全量跑后核对仍为同一值；已从备份恢复并再核对一次，仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`；只读查询确认 `user_version=1`、questions 9 道（全为演示题）、subjects 3 个 |

### 阻断：clang 丢失（环境问题，非产品问题）

- 任务开始时 `which clang` = `/usr/bin/clang`，18.1.3，analyze 与全量测试均在其上跑通。
- 其后运行环境发生一次重启；重启后 `/usr/bin/clang*` 已不存在，`which clang` 无结果，`gcc`/`cc` 仍在，但 Flutter 原生工具链只认 clang（日志：`Running 'which clang'` 后 `No compiler configured on host 'linux_x64'`，`pdfium_dart` hook 构建失败 exit 255）。此后连单个最小测试文件也无法启动。
- 按任务要求（clang 缺失先确认再报、不自行改系统），**未重装、未改系统**。`~/workspace` 与 `~/.pub-cache` 下无 clang 可用副本，apt 缓存中亦无 clang 包。
- 影响：(1) Linux Release 构建本次未能执行；(2) 针对全量日志逐文件归属的定向复跑未能执行（见“核查口径说明”）。
- 后续：恢复 clang（注意 `/usr` 下的安装不随重启保留，建议装入持久位置或每次重启后重装）后，再跑 `flutter build linux --release`，并对下面 10 个文件做一次定向复跑以补齐逐文件归属证据。

### 核查口径说明（全量日志逐文件归属不完整）

- 全量日志为 `--reporter expanded` 输出：计数器走到 `+778` 且以 `All tests passed!` 收尾，静态用例声明数（773 个 `test(`/`testWidgets(` 声明 + 循环生成的额外用例，见下）与 778 量级一致，佐证整套测试确实跑了。
- 但日志里有 10 个文件的路径行完全缺失：`b5_p2_data_test.dart`、`pdf_render_service_test.dart`、`b5_p0_1_orphan_test.dart`、`b5_p1_256_test.dart`、`b5_p1_3_delete_exam_test.dart`、`b5_p1_1_subject_counts_test.dart`、`import_service_p1_fixes_test.dart`、`import_service_pdf_fallback_test.dart`、`b2_leftover_data_test.dart`、`b3_overlay_layer2_test.dart`、`b3_p01_path_safety_test.dart`。
- 同一份日志里另有明显异常：`runAsync` 反复 pump 的用例会重复打印同一行（如 `b3_p11` 的 1 个用例打印 29 行），说明该 reporter 在并发 + FakeAsync 下的输出行不可逐行采信。**因此 778/778 的总数结论可信，但“PDF 组 13 项本次一次通过”等逐文件结论只能以总数佐证，缺逐文件日志行**；待 clang 恢复后定向复跑补证。
- 静态计数：全仓 53 个测试文件共 773 个用例声明；循环生成额外用例（review 页亮/深×三档 1 个声明变 6 个，+5；report 页同类循环亦有额外生成），合计与 778 吻合。

### 抽查覆盖率

- Batch 5 新增测试共约 154 项（净增 628→778 为 150，另有少量旧测试删除/合并，见 `B5-P2.md`）。
  - 8 个全新测试文件，105 项：`b5_p0_1_orphan_test` 3、`b5_p1_256_test` 10、`import_service_p1_fixes_test` 8、`b5_p1_3_delete_exam_test` 3、`b5_p1_1_subject_counts_test` 4、`b5_p2_data_test` 36、`b5_p2_collect_test` 27、`b5_p2_services_test` 14。
  - 已有文件内新增约 49 项（按 SR 编号定位）：错题本 23（P0-2 2 项 + P2 21 项）、复习 10（P1 3 项 + P2 7 项）、设置 3、学科管理 2、首页 1、整理 3（P1-7）、详情 1（P1-8）、报告 2（P1-10/11）、收集 1（P2-25；P1-2 为既有用例内补断言）、`b3_p11` 2（P1-15）、YOLO 1（P1-16）。
- **本次逐个读过上述全部约 154 项新增测试（8 个新文件通读 + 已有文件内全部 SR 标记用例逐条读过），覆盖率约 100%。** 另读了 `B5-SUMMARY.md`、`B5-P0.md`、`B5-P1-DATA.md`、`B5-P1-COUNTS.md`、`B5-P2.md`、`B5-P2-WRONGBOOK.md`、`B5-P2-SERVICES.md` 及 `SELF-REVIEW.md` 相关条目。
- 未做变异/反向验证（那需要临时改产品代码，不属本次“只审”范围；B5 报告中声称做过反向验证的见“已核实干净”末条）。

## 问题清单

### P1（3 项）

#### SR2-TESTS-1 P1-2 确认拆题只测成功路径，未测事务中途失败回滚

- 位置：`test/b5_p1_256_test.dart`（`SR-P1-2 确认拆题` 组，2 个用例）；`test/collect_page_test.dart`（保留任务同次提交断言）。
- 现象：SR-P1-2 的原 bug 是“保留任务重建在事务外，崩溃窗口丢任务 + 丢未框页草稿”。DB 层测试只断言一次成功调用同时建出拆分题 + 拆分任务 + 保留任务 + 未框页草稿（含旋转角）；收集页测试只断言保留任务与拆题是同一次 `confirmSplit` 调用提交。**没有任何用例在事务中途注入失败**——若事务实现退化为多步写库（或某一步静默吞错），测试仍全绿。
- 证据：同批的 P1-3（`b5_p1_3_delete_exam_test.dart`）与 P1-4（`import_service_p1_fixes_test.dart`）都用了 `BEFORE UPDATE/INSERT` 触发器做失败注入并断言整体回滚；P1-2 组内无触发器、无 `throwsA`。
- 修的方向：在 `confirmSplitInto` 的后半段写操作上立触发器（如 `BEFORE INSERT ON question_boxes` 抛错），断言：调用抛错，且 questions / collect_tasks / question_boxes / 保留任务均保持调用前状态，原任务行仍在。

#### SR2-TESTS-2 SR-P2-60 导入任务 id 只断言两次 id 不同，未断言 6 位随机段格式

- 位置：`test/b5_p2_services_test.dart`（`SR-P2-60 任务 id 加随机段` 组第 1 个用例）。
- 现象：用例只做两次顺序 `enqueue` 并断言 `first.first.id != second.first.id`。每次 `enqueue` 都含文件复制 + 解码，耗时远超 1ms，两次调用几乎必然落在不同毫秒——**旧的“毫秒 + 序号”方案同样能通过**，钉不住“同一毫秒两次导入不撞 id”这一回归点。实现是 `task-<毫秒>-<序号>-<6 位随机>`（`lib/services/import_service.dart:198`）；用例未对格式做任何断言。
- 证据：同一修复的另一半（收集页确认拆题 id）在 `test/b5_p2_collect_test.dart`（SR-P2-22 成功确认用例）里用了正则 `^task-\d{13}-\d{6}-\d+-\d+$` 钉格式；导入侧没有对等断言。
- 修的方向：断言导入任务 id 匹配 `^task-\d+-\d+-\d{6}$`（或直接断言含 6 位随机段）；如能安排同一毫秒内两次调用，再断言 id 不同。

#### SR2-TESTS-3 SR-P2-75 放大对话框只断言对话框还在，未断言缩放真的变了

- 位置：`test/b5_p2_services_test.dart`（`SR-P2-75：放大对话框点 ＋/－ 仍可用`）。
- 现象：用例点 ＋ 再点 －，最后只断言标题 `整题图 · 放大查看` 还在。原 bug 是“缩放因子在 build 里赋值”——带 bug 时点 ＋ 会触发重建、缩放被重置回初始值，但对话框本身不会消失，**该用例带 bug 也能通过**。对话框实际有可观测的缩放状态：`_ZoomDialogState` 用 `_scale` 渲染 `'${(_scale * 100).round()}%'` 徽标（`lib/widgets/widgets.dart:833` 起、`_onTransform` 更新徽标）。
- 证据：用例内无任何对 `%` 徽标、`_scale` 或 `TransformationController` 矩阵的读取。
- 修的方向：点 ＋ 前后读徽标文本，断言百分比变大；点 － 后断言变小（或读 `InteractiveViewer` 的 `TransformationController` 矩阵缩放分量）。

### P2（14 项）

#### SR2-TESTS-4 SR-P2-21 只测了“点空白退出”，未测“点框上不退出”

- 位置：`test/b5_p2_collect_test.dart`（`SR-P2-21` 组，`鼠标左键点画布空白处退出内框模式，点框上不退出`）。
- 现象：用例只在画布中心（空白处）点了一次左键并断言退出内框模式；**从未在框上点按**。用例名后半句“点框上不退出”无对应操作与断言——若修复过度（点哪都退出，含框上拖动起点），测试仍全绿。
- 修的方向：在进入内框模式后先点一次框体，断言仍在内框模式，再点空白处断言退出。

#### SR2-TESTS-5 SR-P2-44 只设了搜索文本，未设任何筛选

- 位置：`test/wrongbook_page_test.dart`（`SR-P2-44 换科/换文件夹时搜索与筛选清零`）。
- 现象：用例换科前只在搜索框输入了 `函数极限`；`_clearFilters()`（`lib/modules/wrongbook/wrongbook_page.dart:670`）实际清的是搜索 + 7 个筛选字段（试卷、错因类型、时间范围、错因状态、错因名、收藏、逾期）+ 标签/知识点 + 页码/勾选。**筛选字段的清零完全没有用例覆盖**，用例名“搜索与筛选清零”只兑现了一半。
- 修的方向：换科前先设一个筛选（如错因类型或时间范围），换科后断言该筛选回到默认值（如下拉显示“全部”）。

#### SR2-TESTS-6 SR-P2-40 只测逗号，未测竖线

- 位置：`test/wrongbook_page_test.dart`（`SR-P2-40 批量加标签：含逗号的新标签拦下，不入库不保存`）。
- 现象：实现禁令是“不能含逗号**或竖线**”（`lib/modules/wrongbook/wrongbook_page.dart:1163`），用例只输入了 `新标,签`；`|` 分支无用例。
- 修的方向：补一个输入 `新标|签` 的用例，断言同样拦截、不入库、不保存。

#### SR2-TESTS-7 SR-P2-59 只测放行侧，未测新估算的拒绝侧

- 位置：`test/b5_p2_services_test.dart`（`SR-P2-59` 组）。
- 现象：用例用稀疏文件把占用顶到 2GB−5MB，2MB 的 PDF 放行进 `needBox`，钉住了“旧算法误拒、新算法放行”。但**新算法的拒绝边界没有任何用例**：占用 2GB−1MB 时 2MB 的 PDF 应被拒，若估算公式写错导致超限仍放行，测试发现不了；全仓亦无其他用例覆盖导入存储估算的拒绝路径。
- 修的方向：补占用 2GB−1MB + 2MB PDF 的用例，断言任务失败且错误含存储上限提示。

#### SR2-TESTS-8 SR-P2-66 期望色用与实现相同的公式算出，只用一个输入色

- 位置：`test/b5_p2_services_test.dart`（`SR-P2-66：新学科存色深色下雾化……`）。
- 现象：实现是 `_darkStoredMist = Color.lerp(stored, 0xFFDCE3EC, 0.45)`（`lib/theme/design_tokens.dart:365`），用例期望值同样写 `Color.lerp(stored, const Color(0xFFDCE3EC), 0.45)`。因常量是字面写在用例里的，改常量仍会失败（不属于严格的“改实现不改测试也能过”），但期望值不是独立字面量，且只用了一个输入色 `0xFF2E7CF6`。
- 修的方向：期望值改写为算好的字面色值，并补第二个输入色（如一饱和暖色）断言雾化结果。

#### SR2-TESTS-9 SR-P2-51 第 13 科的金角生成色只断言“不相同且不是数学蓝”

- 位置：`test/subjects_page_test.dart`（`SR-P2-51 第 8 科起仍有新色……`）。
- 现象：第 8 科（青绿 `0xFF14B8A6`）、第 9 科（草绿 `0xFF84CC16`）都断言了字面色；第 13 科（金角生成）只断言 13 色互不相同且不是数学蓝。**金角步进算错仍能通过**（只要颜色互不相同）。
- 修的方向：断言第 13 科颜色的字面值。

#### SR2-TESTS-10 SR-P2-11 Windows 文件锁定防线在 Linux 上未被直接测到

- 位置：`test/b5_p2_data_test.dart`（`SR-P2-11 删老库先清附属` 组）。
- 现象：用例对 `-wal` 是目录的情形只锁定了“只读探针打不开即拒绝删除、文件保留”，并在注释中说明“附属删失败不抛错的分支是防 Windows 文件锁定的防御代码，Linux 单测无法直接模拟”。即 SR-P2-11 的核心修复分支（附属删失败时不抛错、继续删主库）在 Linux 测试里**没有可执行的覆盖**，只留了注释。
- 修的方向：无 Linux 侧直接修法时，记为 Win11 真机手动核查项（删老库时模拟文件被占用）；若后续把删除逻辑抽象出可注入的文件操作层，再补单测。

#### SR2-TESTS-11 SR-P2-5 2GB 边界恰好等于上限的情形未测

- 位置：`test/b5_p2_data_test.dart`（`SR-P2-5 备份恢复 2GB 上限` 组）。
- 现象：拒绝侧用 2GB+1 字节（稀疏文件），放行侧用 1GB；**恰好 2GB 时是拒是放（`>` 还是 `>=`）没有用例**。
- 修的方向：补占用恰为 2GB 的用例，断言与实现口径一致的行为。

#### SR2-TESTS-12 SR-P2-2 用例名与断言矛盾（名说“不动”，断言是“被改写”）

- 位置：`test/b5_p2_data_test.dart`（`SR-P2-2 清演示数据走删题事务` 组，`演示题的框清掉、任务指向置空；recent_tasks 与复习断点不动`）。
- 现象：用例名说“复习断点不动”，实际断言 `review_state.queue == '[]'`——含演示题的断点队列被改写（演示条目被清掉），行还在、内容变了。断言本身正确，名字误导。
- 修的方向：改名，如“演示题的框清掉、任务指向置空；断点队列去掉演示条目、其余不动”。

#### SR2-TESTS-13 P1-4 未测 `_failAndClean` 本身也失败的分支

- 位置：`test/import_service_p1_fixes_test.dart`（`SR-P1-4` 组）。
- 现象：文件头注释写明修复含“`_failAndClean` 再失败也只返回内存里的 failed 任务”；用例的触发器只让“写 needBox 的 UPDATE”失败，`_failAndClean` 的 failed 写库仍能成功。**第二层失败路径无用例**。
- 修的方向：补触发器让全部 `collect_tasks` 写操作失败的用例，断言 `enqueue` 不抛、仍返回 2 个内存 failed 任务。

#### SR2-TESTS-14 P1-1 首页焦点卡用例用手填的 FakeRepo 数据，未覆盖真实仓储到首页的接线

- 位置：`test/b5_p1_1_subject_counts_test.dart`（`首页焦点卡拆分与封面三数一致` widget 用例）。
- 现象：该用例把 `due`/`rev` 手填进 `FakeRepo` 再断言焦点卡文案，钉的是渲染；封面三数与首页数的互斥拆分一致性由同文件的仓储层单测钉住。**真实仓储 → 首页这一段接线没有 widget 用例**。属合理分层、轻微缺口。
- 修的方向：如需补，写一个用真实 `QuestionRepository`（内存库 + 种子题与错因记录）泵首页的用例，断言焦点卡文案；或明确记为分层测试的已知边界。

#### SR2-TESTS-15 SR-P2-22 成功确认用例未跑“两次确认撞同一毫秒”的真实碰撞场景

- 位置：`test/b5_p2_collect_test.dart`（`成功确认：拆出的题与拆分任务 id 带 6 位随机段（SR-P2-60 同款）`）。
- 现象：用例断言一次确认内两题的随机段相同、id 符合 `^import-\d{13}-\d{6}-\d+-\d+$` 格式；注释自认“两次确认的随机段大概率不同（格式即防线）”。格式正则能拦住回退到“毫秒+序号”旧格式，但**两次确认落在同一毫秒时 id 是否仍不同，未被实际跑过**。
- 修的方向：同一用例内连续确认两次（如两个单页任务），断言两次的随机段不同；或在 id 生成层对“同一毫秒连续调用”做确定性单测。

#### SR2-TESTS-16 SR-P2-74 只测 dpr=3.0，无 dpr=1.0 对照

- 位置：`test/b5_p2_services_test.dart`（`SR-P2-74：cacheWidth 乘 devicePixelRatio`）。
- 现象：只在 `devicePixelRatio: 3.0` 下断言 384 / 960 两个字面值；dpr=1.0 时的基准值（128 / 320）无对照，`cacheWidth` 与 dpr 的乘法关系只在一个点上被钉住。
- 修的方向：补 dpr=1.0 的对照断言。

#### SR2-TESTS-17 P1-1 未测复查日恰好是今天的边界

- 位置：`test/b5_p1_1_subject_counts_test.dart`（`reviewBucketOf` 与场景用例）。
- 现象：场景只用“昨天到期”与“7 天后到期”；`isReviewDue` 对 `recheckDate == 今天` 是否算到期，没有用例。复查日当天是“待复查”还是“已解决”的分界点。
- 修的方向：在 `reviewBucketOf`/`isReviewDue` 用例中补 `recheckDate` 为今天（零点与当前时刻各一）的情形。

## 已核实干净

- **P0-2 旧值/未知值均已覆盖**（任务示例担忧不成立）：错题本 `test/wrongbook_page_test.dart` 有“旧值 `wrongbookSort='subject'` 进列表不断言，按学科首字母排”与“未知值回落到时间新→旧，不断言”两个用例（以前者断言首个打开的是数学题、后者断言排序文案）；设置页 `test/settings_page_test.dart` 有 `AppSettings` 归一单测（旧值→`subj-asc`、未知值→`new`、`copyWith('subject')`→`subj-asc`）。
- **SR-P2-24 多框优先级已覆盖**（任务示例担忧不成立）：`test/b5_p2_collect_test.dart` 有“同区域多框取面积最大者，与列表顺序无关”（大小框两种顺序各跑一次）与“同区域同面积取第一个”两个用例，均为精确数值断言；SR-P2-23 亦有“挂在第 2 个框下的内框按第 2 个框换算”与“`parentBoxId` 为空回退第一个 1 层框”两个用例。
- **SR-P2-52 阈值有探针依据**：`B5-P2-WRONGBOOK.md` 记录修复前 1.3 倍下宽度 172、1.0 倍下 148，修复后 >185；用例断言 `>185` 能区分修复前后，非随意魔数。
- **SR-P2-55 单点按已钉住**：点一次封面小图断言 `coverStyle` 变 `dots` 且 `saveSubject` 恰好调用 1 次；B5 报告记录了“只留内层会使名签点按失效、第一次尝试失败 1 项”的取舍过程。
- **SR-P2-77 只动测试侧，产品代码未动**：`lib/` 下无任何 `P2-77` 引用；改动只在两个测试文件——`test/pdf_render_service_test.dart` 13 处、`test/yolo_onnx_service_test.dart` 冒烟组 4 处，各加 `Timeout(Duration(minutes: 5))`；与 `B5-P2-SERVICES.md` 表述一致。本次全量跑（并行）一次通过、未复现抖动；但逐文件归属见“核查口径说明”（PDF 组缺日志行，需 clang 恢复后定向复跑补证）。
- **SR-P2-91 已修正**：`B4-WRONGBOOK.md` 与 `B4-SUMMARY.md` 均已改为 1147 行 / 共 3746 行，并附 SR-P2-91 修正注（注明行数为 B4 完成时口径、Batch 5 后行数已变）；本次 `wc -l` 现状为 1551/514/606/1178/272/82、合计 4203 行，与 Batch 5 改动一致，无需再改报告数字。
- **SR-P2-92 已修正**：`dart format --output=none --set-exit-if-changed` 对 6 个拆分文件（`box_editor.dart` + wrongbook 5 个文件）检查结果为 `Formatted 6 files (0 changed)`。
- **测试隔离三处干净**：`p0_hardening_test.dart` §4.1——`setUp` 把 `testDataDirectory` 指到全新临时目录，`_openDb` 在临时目录建全新 v2 库，`tearDown` 调 `resetForTest()` 并删临时目录，不碰真实库；`s8b3_startup_test.dart`、`s8b6b7_leftover_test.dart`——同款临时目录 + `openForTest()` 内存库 + `resetForTest()` 复位。演示库 md5 在全量跑后不变亦为旁证。
- **B5 新测试整体质量高**：8 个新文件普遍使用触发器失败注入（P1-3、P1-4、P1-9、P2-8、P2-62）、精确状态断言（P1-2 四产物 + 旋转角、P2-16 快照 +2、P2-36 跨层/跨科/改名/移动/防线五连）、边界对照（P2-5 的 2GB+1 与 1GB、P1-14 的 21MB 与 20MB 内、P2-45 的 6 天在内与 7 天在外、P2-46 的 12 道两页），以及失败对照组（P1-15 有效切片对照、P2-15 目录保留对照、P2-19 纯 YOLO 对照）。B5 报告中声称的反向验证（P1-256、P1-7 整理页、P1-15 的初版误断言纠正）有文字记录，本次未独立重做（需临时改产品代码）。
- **其余抽查无问题**：P1-5/P1-6 归一化 5 个单测 + 3 个 widget 用例（含拖动 >10px、删除后确认结果无残留）；P1-7 整理页 3 个用例（改动先落盘再开队列）；P1-8 详情重框（源页 ≥2 无缩略图条、确认后框不丢失）；P1-9/P1-12/P1-13 复习（最新自查、页数保留、跳过末因直接进重做）；P1-10/P1-11 报告（同名不同题各算 1 道、未整理/已归档不进 Top5）；P1-16 YOLO（缺失模型 fallback、换回真实路径恢复、会话缓存复用，模型文件在仓内 38MB）；P2-18/19/20/21/30/31/32 修框编辑器组（计数桩、取消/替换双路径、内框跟随钳制、切页/取消保存抛错不困住）；P2-25/P2-26/P2-27/P2-29/P2-35/P2-36 收集·详情·整理组（三任务对照、取消三路径、同名合并、缺图占位学科名、日期补零、整科判重）；P2-37/38/41/42/45/46/48/49/54/57/58 错题本·复习组（首字母升/降序、已掌握提示、批量收藏跳过已删题、拖拽缝隙、7 天含今天、已归档分页、读库失败重试、会话只取筛选错因、断点范围文案、重置固定回新→旧）；P2-59/61/62/64/65/69/70/74 服务层组（稀疏文件顶存储、坏图进 failed、进度节流触发器计数、双区点按各一次、主题 token 字面值、20 次裁剪/旋转、七向钳制、cacheWidth 字面值）。

## 汇总

- 验证：analyze 0 问题；全量测试 **778/778**；Linux Release 构建**未跑（clang 丢失阻断）**；演示库 md5 不变（`8f7f9c64405dc6e484ac2bf8e5e1a807`，v1、9 题、3 学科）。
- 测试质量问题：**共 17 项——P1 3 项（SR2-TESTS-1/2/3），P2 14 项（SR2-TESTS-4～17）**。无 P0。
- 最值得修的三项（均为 P1）：P1-2 缺事务失败注入、SR-P2-60 导入 id 缺格式断言、SR-P2-75 缩放未断言变化。
- 待跟进（非测试质量问题）：恢复 clang 后补跑 Linux Release 构建，并对 10 个日志缺行的文件做定向复跑以补齐逐文件归属证据；SR-P2-11 的 Windows 文件锁定分支记为 Win11 真机手动核查项。
