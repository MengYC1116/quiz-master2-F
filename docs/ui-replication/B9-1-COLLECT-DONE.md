# B9-1：整理完所有题后，收集中心仍显示“待整理 13”

- 批次：第九批第 1 项（Win11 真机验收第 2 轮，截图 image-99 收集中心 / image-100 整理工作台）
- 现象：整理完所有题后，收集中心仍显示“待整理 13”，整理工作台却显示“都整理完了”，左导航学科速览待整理也是 0。三处数字对不上。
- 结论：已修复。缺的是“题变已整理 → 收集任务变 done”的状态流转，数据层集中补上 + 开库回填卡住行。UI 一行未动（已整理态的 UI 早就备好了）。
- 状态：完成，未 commit，未推（按任务要求）。不写 B9-SUMMARY.md，不发完成邮件（本批保持开放）。

## 1. 改了哪些文件

| 文件 | 改动 |
|---|---|
| `lib/data/db_questions.dart` | `upsertQuestionIntoImpl`（:183）末尾加流转：题存为已整理时，同句柄把指向它的 `pendingOrganize` 任务置 `done`（:210） |
| `lib/data/db_collect.dart` | 新增 `backfillCollectDoneIntoImpl`（:49）：单条 UPDATE 回填卡住行，返回治好的行数 |
| `lib/data/db_schema.dart` | `openAtImpl`（:45）加 `onOpen`：每次开库扫一遍回填 |
| `lib/data/database.dart` | 静态转发 `AppDatabase.backfillCollectDoneFrom`（供测试与调用方） |
| `lib/modules/collect/collect_page.dart` | 只改 SR-P2-33 注释（:145-152）：done 现在有生产入口，不再是死分支；其余 UI、计数口径一字未动 |
| `test/b9_1_collect_done_test.dart` | 新增，7 项用例（见 §5） |
| `docs/ui-replication/B9-1-COLLECT-DONE.md` | 本报告 |

**没有动的**：`lib/modules/organize/organize_page.dart` —— 第 2 项工人同时在改它的 `_QueuePopup` 与批量条区域；我的修复不需要动它，`git diff` 核对该文件 0 处 B9-1，无冲突（见 §7）。也没有整文件 `dart format`。

## 2. 根因复现过程

按任务书给出的线索逐条复现验证，全部属实（行号为修后当前值；`_batchConfirm` 从任务书的 2190 行移到 2508 行，是第 2 项工人在其上方加代码所致，不是我改的）：

1. **生产侧**：确认切分时每道题生成一个 `CollectTask`，`status=pendingOrganize`，`question_id` 指向题（`lib/modules/collect/collect_page.dart:626`）。
2. **整理侧只动题**：单题确认 `_confirmCurrent`（`lib/modules/organize/organize_page.dart:349`）只把题存为 `organized:true`（`repo.save`）；批量整理 `_batchConfirm`（`:2508`）同样只对每道题 `repo.save(q.copyWith(isOrganized: true))`。两处都不动任务。
3. **全仓没有任何生产代码给任务赋 `CollectStatus.done`**：`grep CollectStatus.done lib/` 只有一处赋值语义之外的读取——`lib/models/models.dart:437` 的 label（`done => '已整理'`）与 `collect_page.dart:732/1321/1352/1427` 的 UI 读取。`collect_page.dart:145-150` 的 SR-P2-33 注释原文明写“已整理任务仍以 pendingOrganize 呈现”。
4. **两处计数读两个数据源**：收集中心 `_count` / `_shownTasks` 是裸查询，只读任务的持久化 `status`；整理队列与导航角标（`pendingOrganizeCount` / `pendingOrganizeBySubject`，`lib/data/repository.dart:261/268`）读题的 `is_organized`。所以整理完题后导航 0、整理页空、收集中心仍 13。
5. **已整理态 UI 早就备好**：done 行只留“删除”（`collect_page.dart:1427`），状态 pill 是“已整理”（`:1352`），缺的只是状态流转。任务与题的关联在 `collect_tasks.question_id`。

## 3. 全部 `organized:true` 调用点（逐一核对）

`grep -rn "copyWith(isOrganized\|isOrganized:" lib/` + 全部 `repo.save(Question)` 调用点，结论：**只有两处能把题从未整理翻为已整理**，其余调用点都只是“保持原值”：

| 调用点 | 行为 | 是否翻转 |
|---|---|---|
| `organize_page.dart:349` `_confirmCurrent` | `_formQuestion(q, organized: true)` → `repo.save` | ✅ 翻转为已整理 |
| `organize_page.dart:2508` `_batchConfirm` | `q.copyWith(isOrganized: true)` → `repo.save` | ✅ 翻转为已整理 |
| `organize_page.dart:298` `_saveCurrent`（切题自动保存） | `_formQuestion(q)`，`isOrganized: organized ? true : q.isOrganized`，保持原值 | ❌ 不翻转 |
| `organize_page.dart:2082` 批量打标签 / `:2127` 批量加文件夹 | 只改 `tags` / `folderIds` | ❌ 不翻转 |
| `detail_page.dart:246` 切片自愈 / `:374` 编辑保存 | 只改切片尺寸 / `isOrganized: base.isOrganized` 显式保持 | ❌ 不翻转 |
| `wrongbook_page.dart:1245` 批量标签 / `:1303` 移文件夹 / `:1332` 移除文件夹 | 只改 `tags` / `folderIds` | ❌ 不翻转 |
| `repository.dart:258` `toggleFavorite` / `:295` `archive` | 只改收藏 / 归档标志 | ❌ 不翻转 |

另有两处直接写 `questions` 表、绕过 `upsertQuestion` 的路径，也已核对无翻转可能：

- `confirmSplitIntoImpl`（`db_collect.dart`）：直接 `txn.insert` 新题，`isOrganized:false`，不可能翻转。
- `importBackupJsonIntoImpl`（`db_backup.dart`）：恢复时整表原始重插，不走 `upsertQuestion`——见 §4 末尾的残留口子。

## 4. 修法：为什么集中处理、为什么选回填 (b)

### 4.1 集中处理，不逐一修调用点

流转放在数据层 `upsertQuestionIntoImpl`（`db_questions.dart:183`，题写入的唯一汇合点）：

```dart
if (q.isOrganized) {
  await db.update(
    'collect_tasks',
    {'status': CollectStatus.done.name},
    where: 'question_id = ? AND status = ?',
    whereArgs: [q.id, CollectStatus.pendingOrganize.name],
  );
}
```

选集中处理的理由：

- **不会漏**：单题确认、批量整理都走 `repo.save` → `_db.upsertQuestion` → 这里；详情、错题本、收藏、归档的保存也一样经过这里。逐一修调用点要改两处，还要靠人工保证以后新增的整理入口不忘补——集中处理一次，任何调用点（包括未来的）都不会漏。
- **原子性**：与题写同一句柄，不另开事务——调用方若传进来的是 `Transaction`，任务改动与题改动同事务；传普通 `Database` 时与旧写法同口径（本题写本身也不是事务）。
- **自愈**：条件里不读旧行——已整理题的任何一次保存都会把卡住的任务顺手治好；`UPDATE … WHERE status='pendingOrganize'` 本身幂等，只改仍是待整理的行，已是 `done` 或其它状态的行不动，题未整理时不碰任务。
- **无合法反例**：任务与题一对一（`question_id`），题已整理 = 该任务的工作已完成，不存在“题已整理但任务应保持待整理”的合法状态；全仓也无 `isOrganized:false` 的回退路径。

### 4.2 没有补“按 question_id 查收集任务”的方法

任务书原先设想补一个，集中处理后**不需要了**：`UPDATE … WHERE question_id = ?` 本身就是按 `question_id` 的查找，在 SQL 内原子完成；再补一个 Dart 层“先读任务、再 `saveCollectTask` 写回”是多余的一次往返，还会在读与写之间留竞态窗口（整理保存插在中间会丢更新）。`repo.saveCollectTask`（`repository.dart:379`）保持原样，未动。

### 4.3 回填选 (b) 持久化扫一遍，不选 (a) 收集中心派生

选 **(b) 开库时扫一遍持久化置 done**（`backfillCollectDoneIntoImpl` + `openAtImpl` 的 `onOpen`）：

```sql
UPDATE collect_tasks SET status = 'done'
WHERE status = 'pendingOrganize'
  AND question_id IS NOT NULL
  AND question_id IN (SELECT id FROM questions WHERE is_organized = 1)
```

- **治的是持久化状态，不是界面**：收集中心之外，`repo.collectTasks()` 的任何读取方、角标刷新、备份导出读到的都是治好的值；(a) 只在 `_load` 里改内存呈现，库里仍是错的，换个入口读还是错的，备份也会把错状态带出去。
- **一次性的**：开库时跑一条 UPDATE，幂等、无新字段、不改 Schema；新库刚建完表时无行可扫，是空操作；只读探针（`deleteLegacyDatabaseIfPresent`）用自己的 options，不走这里。
- **口径与 SR2-22 的派生信号不同**：SR2-22 的 `_hasSplitSibling` 是“读时信号缺失、靠同源行临时推导”的无奈之举；这里缺失的不是信号，是本应落盘的状态流转，补落盘才是对症。

不选 (a) 的理由：派生只影响内存呈现，治标不治本；且 `_load` 里要为每行再读题表拼映射，给每次进收集中心都加一次全表关联，收益只是一次性回填，性价比低。

### 4.4 残留口子（已知，不在本项修）

恢复（`importBackupJsonInto`）整表重插、绕过 `upsertQuestion`，恢复当次不扫回填——备份里带来的卡住行在**下次启动开库时**治好，不会永久残留。若 Meng 希望恢复当次就治好，在 `importBackupJsonIntoImpl` 事务提交后加一行 `await backfillCollectDoneIntoImpl(db);` 即可（1 行，留作后续，不随本项改，避免动备份路径的既有断言）。

## 5. 自审为什么没发现（SR-P2-33 只记录不追后果）

- **出处**：`docs/ui-replication/SELF-REVIEW.md:416-420`（SR-P2-33，定级 P2），B5 处理见 `docs/ui-replication/B5-P2-COLLECT.md:26`。
- **自审在哪个文件、哪一行看到这个事实**：自审看到的是 `lib/modules/collect/collect_page.dart:107-150` 的 `splitPagesBySource` 与 `:629-640` 的 `_splitPagesFor` 里 `done` 分支走不到，以及 `_statusPill` / `_taskActions` 里的 `done` 行；证据是全仓 grep 无任何 `= CollectStatus.done` / `status: CollectStatus.done`。
- **为什么没追到用户可见后果**：
  1. **检查单元错了**：自审按“单个枚举值 / 单个分支的可达性”在审，看到“done 无人写”就归类为“死分支 / 防御代码”，修的方向写的是“确认 done 是否还有生产入口；没有则删分支或注明防御性保留”。它没有反过来问：`pendingOrganize` 的行在整理完成后由谁改写——即没沿着 `collect_tasks.question_id → questions.is_organized` 这条关联，去查“谁消费这个状态、谁生产这个状态”。
  2. **“无赋值”被解读为死代码，而不是缺失的状态流转**：同样是“全仓无赋值”，两种解读天差地别——死代码删了了事，缺失流转是功能 bug。自审选了前者，B5 的处理就是加注释、保留分支、“无行为可测”。
  3. **计数口径分属两个数据源，单文件审查看不到**：收集中心读任务 `status`，导航 / 整理页读题 `is_organized`——跨页计数不一致只有把两页的计数来源并排放一起才看得见，SR-P2-33 的检查范围只在 `collect_page.dart` 一个文件内。
- **以后怎么防（一条可执行的建议）**：自审清单加一条“**枚举终态闭环检查**”——对每个有多个状态的持久化枚举，检查人必须列出“每个状态的生产者（谁写入）与消费者（谁读取、计数、筛选）”对照表；终态（`done` / 已完成类）若无生产者，**必须当作“功能缺失”提 P0/P1，而不是当作“死代码”提 P2**，并附一张“状态 × 页面”对照表（哪页读哪个状态计数）。本例中这张表会立刻暴露：收集中心读任务 `status`，导航 / 整理读题 `is_organized`，两处口径不一致。

## 6. 测试清单与结果

新文件 `test/b9_1_collect_done_test.dart`，7 项，**7/7 通过**。口径：数据层用真实内存库（`AppDatabase.openForTest()`，只建表不播种、不碰真实库）；全流程用真实内存库 + 整应用 `QuizMasterApp` 真点按（B8-1 写法：有界手动 pump，不用 `pumpAndSettle`）。

| # | 用例 | 口径 | 结果 |
|---|---|---|---|
| 1 | 单题确认路径：`repo.save(organized:true)` 后任务变 done | 数据层 | ✅ |
| 2 | 未整理保存不动任务；已整理题再保存会自愈卡住的任务 | 数据层（卡住行用原始 SQL 插，绕过流转，模拟旧版库） | ✅ |
| 3 | 批量整理路径：逐题 `save(organized:true)` 后任务全变 done | 数据层 | ✅ |
| 4 | 回填只治卡住行：返回 1，余者不动 | 数据层（已整理+待整理→治；未整理+待整理→不动；已是 done→不动；`question_id` 为空→不动；再扫一次返回 0，幂等） | ✅ |
| 5 | 开库即回填：文件库关了再开（`openAt`），卡住行已变 done | 真实文件库 + 生产开库路径（`onOpen`），种子库验证，非演示库 | ✅ |
| 6 | 单题确认真实交互：逐题整理完，收集中心待整理归零、行变已整理 | 整应用真点按：整理工作台选文件夹→确认整理×2→“都整理完了”→收集中心断言“待整理 0”+ 2 个“已整理” pill + 库里状态已持久化 | ✅ |
| 7 | 批量确认真实交互：队列里全选后批量确认，任务同样变 done | 整应用真点按：队列弹窗点“全选”→“批量确认整理”→收集中心同上断言 | ✅ |

**破坏校验**（任务第 3 条）：临时改回旧行为——`upsertQuestionIntoImpl` 的流转条件改为 `false && q.isOrganized`、回填函数改为直接 `return 0`——重跑本文件：**0/7 通过（7 项全失败）**，如期；随后原样恢复，`grep` 核对两处临时改动已清干净，`flutter analyze` 0 问题，本文件重跑 **7/7 通过**。

**用例调试中踩到的两个坑（已修进用例，产品代码无问题）**：

- testWidgets 体跑在 fake async 里，真实 ffi 的 Future 直接 `await` 会永远卡死——种子与库中断言一律包在 `tester.runAsync` 里（B8-1 同款）；收尾加 5×200ms 沉降，等在途的 `_refreshBadges` / `saveLastRoute` 落定再关库，否则报 `database_closed`。
- 等“待整理 0”不能证明行已加载——`_load` 完成前 `_tasks` 为空，chip 也显示“待整理 0”；改等“全部 2”才算加载完成。
- 队列弹窗已有 B9-2 的全选框（1 个全选 + 每题 1 个，共 3 个 Checkbox），批量用例改点“全选”。

## 7. 验证结果

- `flutter analyze`：**0 问题**。
- 本文件：**7/7 通过**（恢复后重跑确认）。
- 全量测试：串行 `--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，默认 `/tmp`（未改 `TMPDIR`，`TMPDIR` 未设置）：**896/896 通过**，exit 0。注：B8 全量是 874；896 = 874 + 本项 7 + 同树内 B9-2/B9-3 工人新增的 15（同树并行工作，非我所加）。
- Linux Release 构建：`flutter build linux --release` 通过，`✓ Built build/linux/x64/release/bundle/quiz_master2`。
- 演示库：全量前备份到 `~/workspace/demo-db-backup/quiz-master2.db.b9-1-start`；跑完核对 `~/.local/share/quiz-master2/quiz-master2.db` 的 md5 仍是标准 v1 `8f7f9c64405dc6e484ac2bf8e5e1a807`，**无需恢复**（备份文件与原备份 `quiz-master2.db` 的 md5 一致）。
- 杀应用：未启动过应用进程，无需 pkill。
- 工具链插曲：验证中途有一次 `flutter test` 报 `No compiler configured … which clang` 找不到 clang（`/usr/bin/clang` 瞬时缺失），随后同一 shell 再查 `clang --version` 已是 18.1.3 在位，未跑恢复脚本即自行恢复；重跑后测试正常。记一笔，若再现按任务书跑 `docs/ui-replication/restore-linux-toolchain.sh`。

## 8. 交给协调员的话

- 本项完成；第 2 项工人在同树改 `organize_page.dart` 的 `_QueuePopup` / 批量条区域，我的改动与该文件零交集（`git diff` 核对 0 处 B9-1），无冲突。
- 另：任务期间 MEMORY 陆续新增第 2 项（整理队列批量操作：全选、批量打标签下拉化、批量条布局重排，截图 image-101）与第 3 项（复习导航角标，截图 image-102），均不属于本项，未碰。
- 建议 Meng 在 Win11 上验证：打开他那台卡住的库，进应用即应看到收集中心 13 行变“已整理”、待整理归零——不需要他手动整理任何东西；再新整理一道题，收集中心应同步变 done。
