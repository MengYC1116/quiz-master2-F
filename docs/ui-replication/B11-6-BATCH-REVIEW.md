# B11-6 错题本批量加入复习（拓展版）

- 分支：`ui-replication`（共享树，未 commit、未 push）
- 范围：只做第 6 项，不动 collect / organize / detail / home / settings 的主文件，未改 `docs/decision-log.md`（规则落地细节见下面“决策”一节，由协调员统一记 D-25+）
- 状态：已完成；`flutter analyze` 改动文件 0 问题；新测试 16/16 通过；既有错题本测试 86/86 通过

## 改了什么文件

| 文件 | 改动 |
|---|---|
| `lib/data/repository.dart` | 新增 `hasJoinableCause`（纯判定）、`joinReviewBatch`、`cancelReviewBatch`（均在 `setReviewJoined` 之后） |
| `lib/modules/wrongbook/wrongbook_page.dart` | `_snack` 增加可选 `actionLabel` / `onAction`；新增 `_batchJoinReviewSelected`、`_batchJoinReviewAll`、`_batchCancelReviewSelected`、`_snackJoinReviewResult`、`_snackCancelReviewResult`（放在 `_batchArchive` 之后） |
| `lib/modules/wrongbook/wrongbook_list.dart` | `_buildBatchBar` 增加三个按钮（放在“批量归档”后、“批量删除”前），复用现有 `Wrap` + `QmButtonVariant.plain` + `small` 结构，未改筛选 / 排序 / 分页逻辑 |
| `test/b11_6_batch_review_test.dart` | 新增：单元测试 + widget 测试（16 个） |

未改动：列表本身的筛选、排序、分页；`docs/decision-log.md`；演示库（全程未跑应用，未碰 `~/.local/share/quiz-master2/quiz-master2.db`）。

## 行为

批量条（列表页 → “批量操作”）新增三个按钮：

- **加入复习**：对勾选的题执行加入复习。无勾选时禁用（与其他批量按钮同一规则）。
- **全部加入复习**：对当前筛选出的全部题执行加入复习，不用先勾选。作用域 = `_filteredAll()` 的结果，与“全选当前结果”同口径：是当前筛选结果，不是全库，也不限当前页。
- **取消加入复习**：对勾选的题执行取消加入。无勾选时禁用。

反馈（Snackbar，一次说清）：

- 加入：`已加入复习 N 道`；有跳过时追加 `M 道已无未解决错因，跳过`；另有“已不在列表里，跳过”（勾选题在两次加载间被删/移出范围）、“保存失败，请重试”分段。加入成功（N > 0）时 SnackBar 带 **“开始复习”** 动作，点它调 `widget.onGoReview()` 跳复习页 `/review`（不限学科）；N = 0 时不给入口。
- 取消：`已取消加入复习 N 道`；未加入的题追加 `M 道未加入复习，跳过`；同样有“已不在列表里 / 保存失败”分段。无“开始复习”入口。
- 批量操作后勾选清空、列表重载（与其他批量操作一致）；批量模式保持打开。

## 跳过规则的落地方式

判定在 `QuestionRepository.hasJoinableCause(Question q, List<CauseRecord> records)`（纯函数，不读库）：

- 错因是空的 → 不可加（`setReviewJoined` 本来也会返回 false）；
- 某个错因还没有解决记录 → 可加（还没治过）；
- 某条记录未解决（待解决 / 解决中）→ 可加；
- 某条记录已解决但到了复查时间 → 可加（仍要复查）；
- 全部错因已解决且未到复查时间 → 不可加，计入跳过。

`joinReviewBatch` 先读一次 `causeRecords()` 按题分组，逐题判定；可加的调 `setReviewJoined(q, true)`。已治愈错因不重复加入是靠底层保证的：`setReviewJoined` 的播种用 `ConflictAlgorithm.ignore`，已在库里的已解决记录（状态 / `solvedCount` / 复查日）原样不动，只给尚无记录的错因补一条待解决记录。单题保存失败计入 `failed`，不中断整批。

`cancelReviewBatch` 与详情页单个取消同语义：只把 `review_joined` 置回 false，错因记录保留，重加入可恢复；本来就没加入的题计入跳过。

“按错因加”不另做新 UI：用现有错因筛选（筛选面板“错误类型”/“错因”）+ “全部加入复习”实现（测试覆盖：筛“方法不会”后全部加入只加了那 1 道）。

## 测试结果

测试一律用临时目录 / FakeRepo 内存模拟，绝不打开真实 `AppDatabase.instance`；串行跑（`flutter test --concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，默认 `/tmp`）。

- 新文件 `test/b11_6_batch_review_test.dart`：**16/16 通过**。
  - 单元测试（`_BatchFakeRepo` 覆盖 `causeRecords` / `setReviewJoined`，与真实 `setReviewJoinedInto` 同语义的内存模拟；判定与计数走真实的 `joinReviewBatch` / `cancelReviewBatch`）：
    - `hasJoinableCause` 8 例：无错因 / 无记录 / 待解决 / 解决中 / 全部已解决复查未到 / 全部已解决到复查时间 / 混合一已解决一待解决 / 混合一已解决一无记录 / 混合全部已解决；
    - `joinReviewBatch`：加入 4 道、跳过 2 道；断言已治愈错因记录不动（`solvedCount` / 复查日原值）、只给未解决错因补待解决记录、复查到期的已解决记录不动、无错因题无新增记录、重加入不重复建记录；
    - `cancelReviewBatch`：取消 1 道、跳过 1 道；断言记录保留。
  - Widget 测试（`_B116Repo extends FakeWrongbookRepo`，只覆盖 `setReviewJoined`；批量判定与计数走真实仓库方法）：
    - 未勾选时加入/取消禁用、全部加入可用；
    - 勾选加入：`已加入复习 2 道；1 道已无未解决错因，跳过` + “开始复习”入口，点后 `onGoReview` 被调 1 次，库态正确；
    - 只勾无错因的题：`1 道已无未解决错因，跳过`，且无“开始复习”入口；
    - 全部加入：12 道题、每页 10 道，不勾选直接加，`已加入复习 12 道`（证明作用域不限当前页）；
    - 全部加入 + 错因筛选：筛“方法不会”后只加 1 道，另一题未加入；
    - 批量取消：`已取消加入复习 1 道；1 道未加入复习，跳过`，记录保留。
- 回归 `test/wrongbook_page_test.dart`：**86/86 通过**（重跑后，见下面“过程记录”）。
- `flutter analyze lib/data/repository.dart lib/modules/wrongbook/wrongbook_page.dart lib/modules/wrongbook/wrongbook_list.dart test/b11_6_batch_review_test.dart`：**No issues found**。
- 未跑全量测试（按任务要求，留给协调员统一验收）。

## 决策（供协调员记 D-25+，未写 decision-log.md）

1. **跳过口径**：一道题没有任何未解决错因时跳过；其中“已解决但到了复查时间”的错因算仍需复习（可加），因为复查题仍在复习队列口径（`reviewBucketOf` 的 `recheck` 桶、`dueToday` 含复查题）里。全部已解决且复查未到的题才跳过。
2. **“全部加入”作用域**：当前筛选结果（`_filteredAll()`），与 Batch 9 “全选当前结果”同口径；不限当前页，不含已掌握默认隐藏的题（筛选状态为“已解决”时才可见并可加）。
3. **反馈文案**：加入 `已加入复习 N 道；M 道已无未解决错因，跳过`；取消 `已取消加入复习 N 道；M 道未加入复习，跳过`；另有“已不在列表里，跳过”与“保存失败，请重试”分段（沿用 `_snackBatchResult` 的口径）。
4. **“开始复习”入口形式**：加入结果 Snackbar 的动作按钮（`SnackBarAction`），只在加入成功时出现；点后跳 `/review` 且不限学科（批量可能是跨学科筛选结果）。未另加常驻按钮。
5. **分层**：判定 + 计数在 `QuestionRepository`（纯判定可单测、批量方法可 Fake 覆盖）；页内只做勾选解析、缺失计数与反馈。`_snack` 的动作参数为可选命名参数，现有调用不受影响。
6. **取消不二次确认**：与详情页单个取消一致（无确认框）；记录保留、重加入恢复。

## 过程记录（环境与并行干扰）

- **工具链丢失与恢复**：首次跑测试时 `flutter test` 构建失败——`pdfium_dart` 的 native hook 报 `No compiler configured`，`which clang` 为空（VM 替换后 `/usr` 下后装的工具链又丢了，`ninja` / `clang` / GTK 开发包 / `xdotool` / ImageMagick 全无）。按仓库既有脚本 `docs/ui-replication/restore-linux-toolchain.sh` 恢复，成功：clang 18.1.3、GTK 3.24.41。此后测试可跑。
- **回归文件两次异常、一次重跑通过**：
  - 第一次跑 `wrongbook_page_test.dart` 时编译失败：`database.dart:583` 报 `bumpOrganizedTodayIntoImpl` 找不到；当时 `db_settings.dart`（另一 worker 的 B11-10 今日小结拆分文件，untracked）正在被并行改动（mtime 与运行时间重合），`flutter analyze` 稍后即恢复 0 问题，判定为并行写文件中的瞬时快照，非本人改动所致（本人未碰 `database.dart` / `db_settings.dart`）。
  - 第二次运行挂起 75 分钟、CPU 0%，协调员已按精确 PID 杀掉；与本人改动的关系：同一次运行里本人新文件 16/16 正常通过，且该回归文件随后重跑 86/86 全过，挂起时树上正有其他 worker 在改共享文件——疑似既有测试在共享树被并发改动时的挂起，非本人三处改动（仓库纯新增方法、批量条三按钮、页内 handler）可解释；但无法 100% 排除与当时树状态的交互，已如实记录。
  - 第三次（重跑）：`exit=0`，**86/86 通过**，日志 `/tmp/b116-wrongbook-regress.log`（尾行 `All tests passed!`）。按协调员要求不再死磕。
- **截图**：未跑应用（无 UI 改动需真机验证的环节；批量条是既有结构内加按钮，widget 测试覆盖），故 `docs/ui-replication/shots/b11-wrongbook/` 下无新增截图。
