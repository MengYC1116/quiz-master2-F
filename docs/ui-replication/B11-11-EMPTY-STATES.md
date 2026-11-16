# B11-11 空状态接线（最小版）

- 批次：Batch 11 第 11 项
- 结论先行：**全应用审计完成；所有空状态动作按钮在审计时已全部接线，没有发现死按钮，本项未改任何业务代码**（`lib/` 零改动）。新增 8 个点按验证测试，全部通过。
- 新增测试：`test/b11_11_empty_states_test.dart`（8 个用例）
- 本报告路径：`docs/ui-replication/B11-11-EMPTY-STATES.md`

## 1. 审计方法

- 扫出全应用全部 `QmEmptyState` / `EmptyState` 调用点（共 10 处，见表），逐处读 `onAction` 是否为空；
- 扫全部含“去收集 / 去整理 / 去复习 / 去学科管理 / 选择文件导入”字样的按钮与文案，逐处确认回调；
- 顺着回调读到 `lib/app.dart` 的 `_buildPage` / `_go` / `_goReview`，确认回调最终改的是真实路由；
- 全应用 grep `onPressed: null` / `onAction: null`：除设置页两个有意的禁用态（忙时备份/恢复、通知关闭时选时间）外，无死按钮；
- 核对了任务点名的三处“去复习”：整理页空状态、学习报告空状态均已接线；复习页空状态的动作是“去错题本选题”（按设计应去错题本选题，而非去复习），同样已接线。

路由映射（`lib/app.dart`，代码核对，见 §4 说明为何未做应用级测试）：

| 页回调 | 目标路由 |
|---|---|
| `onGoReview` → `_goReview()` | `/review` |
| `onGoCollect` → `_go('/collect')` | `/collect` |
| `onGoWrongbook` → `_go('/wrongbook')` | `/wrongbook` |
| `onGoSubjects` → `_go('/subjects')` | `/subjects` |
| `onOpenOrganize` → `_go('/organize')` | `/organize` |

## 2. 全应用审计表

“接线前状态”指本次审计开始时该动作是否已接通真实导航；“本次是否接好”指本项内是否由我接好（已接通的记“已接通（无需改动）”）。

| # | 页面 | 空状态 | 动作文字 | 接线前状态 | 本次是否接好 | 未接好归属 |
|---|---|---|---|---|---|---|
| 1 | 收集中心 `collect_page.dart:916` | 还没有收集任务 | 选择文件导入 | 已接通 → `_pickFiles`（导入，非导航） | 已接通（无需改动） | — |
| 2 | 收集中心 `collect_page.dart:1061` | 学科为空 | 去学科管理 | 已接通 → `onGoSubjects` → `/subjects` | 已接通（无需改动）；本次补点按测试 | — |
| 3 | 收集中心 `collect_page.dart:1386/1401/1410` | 任务行待整理 | 去整理 | 已接通 → `onOpenOrganize` → `/organize` | 已接通（无需改动） | — |
| 4 | 收集中心 `collect_page.dart:867`（修框确认） | —（非空状态） | 确认修框，去整理 | 已接通（确认拆题后进整理） | 已接通（无需改动） | — |
| 5 | 整理工作台 `organize_page.dart:695` | 从未有题 | 先去收集题目 | 已接通 → `onGoCollect` → `/collect` | 已接通（无需改动）；本次补点按测试 | — |
| 6 | 整理工作台 `organize_page.dart:678` | 队列已空 | 去复习 | 已接通 → `onGoReview` → `/review` | 已接通（无需改动）；本次补点按测试 | — |
| 7 | 错题本·书架 `wrongbook_shelf.dart:25` | 还没有学科 | 去学科管理 | 已接通 → `onGoSubjects` → `/subjects` | 已接通（无需改动） | — |
| 8 | 错题本·列表 `wrongbook_list.dart:209` | 文件夹为空 | 返回目录 | 已接通（页内导航回目录） | 已接通（无需改动） | — |
| 9 | 错题本·列表 `wrongbook_list.dart:209` | 这科里还没有错题 | 返回目录 | 已接通（页内导航回目录） | 已接通（无需改动） | — |
| 10 | 错题本·列表 `wrongbook_list.dart:209` | 错题本里还没有题 | 返回书架 | 已接通（页内导航回书架） | 已接通（无需改动）；本次补点按测试 | — |
| 11 | 错题本·列表 `wrongbook_list.dart:209` | 这里的题错因都已解决 | 看看已解决的题 | 已接通（错因状态筛成“已解决”） | 已接通（无需改动）；本次补点按测试 | — |
| 12 | 错题本·列表 `wrongbook_list.dart:209` | 没找到这道题 | 清除全部筛选 | 已接通 → `_resetFilters` | 已接通（无需改动）；本次补点按测试 | — |
| 13 | 错题本·列表 `wrongbook_list.dart:209` | 这一本里还没有归档的题 | 返回题目列表 | 已接通（页内退出已归档视图） | 已接通（无需改动）；本次补点按测试 | — |
| 14 | 错题本·列表 `wrongbook_list.dart:1261` | 还没有归档的题（跨学科） | （无按钮，纯文字） | 无动作文字 | 不适用 | — |
| 15 | 错题本·目录 `wrongbook_directory.dart:85` | 还没有文件夹 | （无按钮；文案“新建一个吧”，同页工具栏“加文件夹”按钮可用） | 无动作文字 | 不适用 | — |
| 16 | 复习 `review_page.dart:905` | 复习列表还是空的 | 去错题本选题 | 已接通 → `onGoWrongbook` → `/wrongbook` | 已接通（无需改动）；本次补点按测试 | — |
| 17 | 学习报告 `report_page.dart:297` | 还没有复习记录 | 去复习 | 已接通 → `onGoReview` → `/review` | 已接通（无需改动） | — |
| 18 | 首页 `home_page.dart:537` | 无最近任务（继续条） | 去收集 | 已接通 → `onGoCollect` → `/collect` | 已接通（无需改动） | — |
| 19 | 首页 `home_page.dart:631` | 快速收集格 | 去收集中心 | 已接通 → `onGoCollect` → `/collect` | 已接通（无需改动） | — |
| 20 | 首页 `home_page.dart:657/660` | 学科格 | 错题本 / 去复习 | 已接通 → `onGoWrongbook` / `onGoReview` | 已接通（无需改动） | — |
| 21 | 首页 `home_page.dart:279` | 焦点卡（有要复习时） | 整卡可点 | 已接通 → `onGoReview` → `/review` | 已接通（无需改动） | — |
| 22 | 首页 | 0 道要复习 | （中性文案，不可点） | 设计如此：无焦点卡、无可点动作（`home_page_test` 已断言点按不触发去复习） | 不适用 | — |
| 23 | 题目详情 `question_detail_page.dart:904` | 这道题不存在了 | （无按钮，纯文字） | 无动作文字 | 不适用 | — |
| 24 | 题目详情 `question_detail_page.dart:2016` | 暂无复习记录 | 文案提及“去复习页”，无按钮 | 文案非按钮，未接线 | 未接好 | W4 或后续处理（见 §3 第 2 条） |
| 25 | 学科管理 `subjects_page.dart` | 还没有学科 / 章节 / 知识点 / 试卷 | （无按钮；文案提示，同页有添加按钮） | 无动作文字 | 不适用 | — |
| 26 | 设置 `settings_page.dart` | — | 无空状态 | 不适用 | 不适用 | — |
| 27 | 应用内提醒 `app.dart:194` | 复查提醒弹窗（非空状态） | 去复习 | 已接通 → `_goReview()` | 已接通（无需改动） | — |

另注：错题本列表范围为空的三处文案（#8/#9/#10 的 `desc`）含有“去收集中心拍一道题，或去整理工作台……”的引导文字，但那是说明文案而非按钮；唯一动作按钮是“返回目录 / 返回书架”（已接通）。是否要把文案里的去收集/去整理也变成可点入口，见 §3 第 1 条。

## 3. 待其他 worker 或后续处理

| # | 文件 / 位置 | 发现 | 建议接线 | 归属 |
|---|---|---|---|---|
| 1 | `lib/modules/wrongbook/wrongbook_list.dart:167/175/182`（`_emptyCopy` 范围为空分支） | 文案写“去收集中心拍一道题，或去整理工作台把待整理的题归到这个文件夹”，但只是说明文字，不可点；按钮是“返回目录 / 返回书架”。`QmEmptyState` 只有一个动作位，放不下第二个按钮。 | 需产品决策，二选一：(a) 保持现状（文案引导 + 返回按钮，B8-9 已定稿的形态）；(b) 把动作按钮改成“去收集”（或“去整理”），需新增回调从 `app.dart` 接入。不要悄悄改——这是已定稿的空状态文案三分法的一部分。 | W3（错题本）或协调员决策 |
| 2 | `lib/modules/detail/question_detail_page.dart:2016`（复习记录区） | “暂无复习记录，去复习页练一次会出现在这里”是纯文字，无按钮。 | 如要接线，需给 `QuestionDetailPage` 新增 `onGoReview` 回调并在 `app.dart` 接 `_goReview()`；是否加按钮由 W4 / 协调员定（详情页按决定本无“开始复习”按钮，加“去复习”入口是新增行为）。 | W4（详情页）或后续处理 |

## 4. 测试结果

新增 `test/b11_11_empty_states_test.dart`，8 个用例，补上此前只有“出现”断言、没有“点按”断言的空状态动作：

| # | 用例 | 验证 |
|---|---|---|
| 1 | 复习页空态：点“去错题本选题”走 onGoWrongbook | 回调触发 1 次（→ `/wrongbook`） |
| 2 | 整理页从未有题：点“先去收集题目”走 onGoCollect | 回调触发 1 次（→ `/collect`） |
| 3 | 整理页队列已空：点“去复习”走 onGoReview | 回调触发 1 次（→ `/review`） |
| 4 | 错题本：全已解决时点“看看已解决的题”出现该题 | 切紧凑列表后题名出现 |
| 5 | 错题本：搜不到时点“清除全部筛选”恢复列表 | 切紧凑列表后题名出现，空文案消失 |
| 6 | 错题本：范围本身空时点“返回书架”回书架 | 空文案消失，书架出现“数学” |
| 7 | 错题本：本学科已归档空时点“返回题目列表”回列表 | 切紧凑列表后题名出现，归档空文案消失 |
| 8 | 收集页学科为空：点“去学科管理”走 onGoSubjects | 回调触发 1 次（→ `/subjects`） |

运行（串行，默认 `/tmp`，未改 `TMPDIR`）：

```sh
LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux \
  flutter test --concurrency=1 test/b11_11_empty_states_test.dart
```

- 结果：**8/8 通过**，exit 0（日志 `/tmp/b11-11-test2.log`）。
- `flutter analyze test/b11_11_empty_states_test.dart`：**0 问题**。
- 其余已接通的空状态动作已有既有测试覆盖点按：学习报告“去复习”（`report_page_test.dart` 空态组）、收集“去整理”（`collect_page_test.dart:644`）、错题本书架“去学科管理”（`b8_1_subject_refresh_test.dart:220/262`）、首页“去收集 / 去收集中心 / 去复习 / 焦点卡”（`home_page_test.dart`）、错题本文件夹空“返回目录”（`wrongbook_page_test.dart` B8-9 组）、收集“选择文件导入”（`collect_page_test.dart:594`）。
- 未跑全量（按任务要求，全量由协调员最后统一验收）。未跑应用：本项无任何 UI 改动，无需截图验证；且跑应用会删 v1 演示库并与其他 worker 争用 live DB，故 `docs/ui-replication/shots/b11-empty/` 未放截图。

说明：页级 widget 测试验证的是“点按 → 页回调触发（= 要求跳往的路由）”；`app.dart` 内回调到路由的映射（§1 表）是代码核对，未做应用级测试——`QuizMasterApp` 在内部用 `AppDatabase.instance` 建库，泵起整应用会打开真实演示库，不符合测试隔离要求。

测试中遇到的问题：

1. 首轮 3 个错题本用例失败：断言题名 `函数极限` 出现时找到 0 个。原因不是接线问题——错题本默认是大卡片视图，大卡片只显示整题切片，**不显示题名**（既有测试 `wrongbook_page_test.dart`“大卡片：一题一行整题切片，无题名”已定稿）。修复：用例内先点“紧凑列表”再断言题名；同时这也说明此前 `expect(find.text('函数极限'), findsNothing)` 这类断言在大卡片下是恒真的，写用例时须注意。修复后 8/8 通过。
2. 首次跑测试时 `pdfium_dart` 原生构建报 `/usr/lib/llvm-18/bin/clang` 加载 `libclang-cpp.so.18.1` 失败；直接重跑即通过，`clang --version` 正常（18.1.3），属偶发环境抖动，未改任何配置。

## 5. 改动清单

- 新增：`test/b11_11_empty_states_test.dart`（8 个用例）
- 修改：`lib/` **零改动**；未碰 W1–W5 的文件；未改 `docs/decision-log.md`；未 commit、未 push。
- 报告：本文档 `docs/ui-replication/B11-11-EMPTY-STATES.md`
