# 第九批修复总结（B9-SUMMARY）

**范围：** Meng 在 Win11 真机验收第二轮提的 3 项（截图 image-99～102）+ 他 19:43 裁决追加的第 4 项（复习页顶口径统一）。
**基线：** Batch 8 已推 head `b773224`（测试 874/874）。
工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`。
**状态：** 4 项全部完成并通过最终门禁。**未提交、未推代码**——推送须 Meng 另外批准。

## 一、逐项结果

| # | 内容 | 结果 |
|---|---|---|
| 1 | 整理完后收集中心仍显示待整理 13 | ✅ 完成。根因：确认切分时每道题生成一个 `CollectTask`（`status=pendingOrganize`），整理确认只把题存为 `organized:true`，全仓没有任何生产代码给任务赋 `CollectStatus.done`（SR-P2-33 只记下了这个事实，没追后果）。收集中心只读任务的持久化 `status`，整理队列与导航角标读题的 `is_organized`，所以三处数字对不上。修法在数据层：`upsertQuestionIntoImpl` 末尾加流转（题存为已整理时同句柄把指向它的 `pendingOrganize` 任务置 `done`）；`openAt` 加 `onOpen` 回填，每次开库扫一遍卡住行（幂等，返回治好的行数）。UI 一行未动（已整理态早就备好了）。Meng 库里卡住的 13 行进应用即变“已整理”，不用手动处理。 |
| 2 | 整理队列批量操作：全选 + 标签下拉 + 布局 | ✅ 完成。全选在列表顶栏常驻（三态 Checkbox +「全选」+「已选 N / 共 M 道」），不勾题也能点到；范围是当前筛选出的题，切换式、无反选；取消时只取消眼前这批，筛外已选项保留。批量打标签改成“下拉选标签 + 批量打标签”（预设在前、自定义在后，默认 `#需重做`，打完不清空选中，与批量加文件夹一致）。批量条改三行（标签行、文件夹行、确认／删除／取消行），Wrap 窄窗自动换行。 |
| 2附 | SR3-15 队列弹窗下拉点不动 | ✅ 结论：**是产品问题，不是测试环境问题**。根因已用 Flutter 3.47.9 SDK 源码核实：队列层是直接插进 Overlay 的 `OverlayEntry`，`DropdownButton` 菜单走 Navigator 路由，`OverlayState.rearrange` 把直接插入的条目留在所有路由条目之上，菜单被画在队列层下面、点按也被截住；改前真机截图（`before-folder-menu.png`）上菜单完全不可见。三个下拉（排序、文件夹、标签）已全部改用弹窗自身 Stack 顶层渲染的内联菜单，不走 Navigator 路由。 |
| 3 | 复习加角标 | ✅ 完成。角标数字 = `dueToday().length`（数题不数错因），与首页焦点卡“要复习的数量”同一共享口径；accent 底（与整理工作台一样，0 时隐藏，与收集/整理角标一致）；接进 `_refreshBadges`，复习状态变化的写库点逐一核对均有 bump 覆盖。复查到期是时间驱动、无写库可挂 bump，唯一滞后窗口是“应用一直开着跨过午夜且期间无导航无写库”，与“整夜不碰应用”重合，影响可忽略，不补触发点。 |
| 4 | 复习页顶口径统一（Meng 19:43 裁决） | ✅ 完成。裁决：统一按题数。`_metaCounts` 改按题汇总两边记录后调 `reviewBucketOf` 算桶：待解决/解决中 = 桶 pending 的题数，复查 = 桶 recheck 的题数，已解决 = 桶 solved 的题数；待解决 + 复查 = 角标数。多错因一题只计 1 道，不双计不漏计。文案三处“条”→“道”。列表本身、分页“共 N 条”（组数）、筛选、会话入口文案均未动。 |

## 二、口径翻转 / 纠正记录

- **第 4 项是裁决驱动的新增项**：B9-3 报告 §一/§七曾把“复习页顶要不要统一”列为待 Meng 定夺；19:43 他点选“统一，复习页顶也按题数”，B9-4 落地，B9-3 报告已同步改成已裁决。
- **纠正**：此前给 Meng 的“三处同一个数”（角标、首页、复习页顶）说法不准确——页顶当时是按错因条数计，角标/首页是按题数计；多错因一题上两处数字天然不同。第 4 项之后三处才真正统一。
- **第 1 项的自审遗漏**：SR-P2-33 早就写明“done 全仓无赋值处”，但只当事实记录，没追到“收集中心永远不清”的用户可见后果；与 Batch 8 第 1 项同类（跨页状态链没追全）。

## 三、测试

| 文件 | 结果 |
|---|---|
| `test/b9_1_collect_done_test.dart`（新增，7 项，含整应用真实点按全流程） | 7/7 |
| `test/organize_page_test.dart`（整理页，B9-2 组新增 8 项） | 45/45 |
| `test/b9_3_review_badge_test.dart`（新增，7 项） | 7/7 |
| `test/b9_4_review_header_count_test.dart`（新增，3 项） | 3/3 |
| `test/review_page_test.dart`（B9-4 更新页顶断言） | 39/39 |

破坏校验：第 1 项临时改回旧行为重跑 0/7 如期失败后恢复；第 2 项破坏校验如期失败后恢复（见各阶段报告）。

## 四、最终门禁（协调员在最终树上重跑）

- `flutter analyze`：**0 问题**。
- 全量测试串行（`--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，默认 `/tmp`）：**899/899 通过，`[E]` 0 处，EXIT 0**，约 6 分 03 秒，日志 `/tmp/b9-gate-full.log`。总数由 Batch 8 的 874 变为 899：B9-1 +7、B9-2/B9-3 +15、B9-4 +3。
- Linux Release 构建：**通过**（`Built build/linux/x64/release/bundle/quiz_master2`），日志 `/tmp/b9-gate-build.log`。
- 演示库：门禁跑前备份到 `~/workspace/demo-db-backup/quiz-master2.db.b9-final`（md5 已核）；跑后 live 库核对为 **v1**，md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，`user_version` 1，9 道题、3 学科，无需恢复。全量测试未动 live 库。

## 五、遗留与 Win11 真机清单

**本次未动、留待 Meng 定夺或真机复核的：**
- 复习会话总结页“今天解决了 X 个错因 · 还有 Y 个未解决”仍按错因**记录**数（本轮按错因治的进度），有意保留未改——第 4 项的裁决只覆盖页顶三数；如要统一，另立项。
- 页顶三数仍不过滤（与改前一致）；分页“共 N 条”是学科 × 错因分组数，不是题数，与页顶三数无关。
- 复查到期的角标滞后窗口（应用开着跨午夜且无导航无写库），已评估可忽略，未补触发点。
- Batch 8 的 P2 审计项仍未定（字号字面量收敛到 token、4 个死 token、图标控件补 Semantics、空状态“去收集/去整理”接跳转）。
- `double` 封面折角仍是 Meng 自己与 CodeBuddy 对接（未变）。

**Win11 真机仍需复核的（Linux 替代不了）：**
- 打开 Meng 那台卡住的库，进应用即应看到收集中心 13 行变“已整理”、待整理归零；再新整理一道题，收集中心应同步变 done。
- 队列全选三态手感、标签下拉与文件夹下拉的内联菜单手感（真机上是否都可见、可点）、批量条三行在窄窗口下的观感。
- 复习角标观感（展开/折叠态）、页顶三数与角标/首页数字一致（多错因一题时）。
- `flutter build windows`（libpdfium 打包 + onnxruntime.dll + VS C++ 工具链）、字体/DPI/窗口尺寸、SQLite 原生资源、CPU 推理速度；详情页“重新框选”端到端、拖放导入、错题本分页；SR-P2-11 Windows 文件锁分支、SR-P0-2 真机列表行为（既往遗留）。

**过程记录（供下次参考）：**
- VM 中途被替换一次：`/usr` 下后装的工具（xdotool、ImageMagick、ninja、clang、GTK 开发包）全部丢失，`~/workspace` 与 `~/.pub-cache` 完好，代码与测试未丢。已按 `docs/ui-replication/restore-linux-toolchain.sh` 恢复；另补 Mesa：恢复后 libegl-mesa0 是 noble 的 24.0.5，与 DRI 25.2.8 对不上，应用启动报 `libEGL fatal`，从 noble-updates 单独取 libegl-mesa0 / libgbm1 / mesa-libgallium 25.2.8 覆盖安装后恢复。`/tmp` 也被清空（探针脚本与 Xvfb 日志丢失，无影响）。
- 跑应用会删 v1 演示库（§6-1 的设计）：B9-2 工人第一次直接跑基线应用时 live v1 库被删成空 v2，已从备份恢复，并改用 B8-9 的 v1→v2 转换脚本生成截图专用库。
- 第一次 B9-2 全量中途停滞（subjects 页加载 12 分钟无进展）+ 2 项设置缓存测试因 `/tmp` 写满失败；杀掉重跑后 896/896 全过。教训：同目录双全量并行会争 CPU 与 /tmp，全量应串行错开跑；全量前先 `df -h /tmp`。
- B9-1 验证中途 `flutter test` 一度报找不到 clang，随后同一 shell 再查 clang 18.1.3 已在位，未跑恢复脚本即自行恢复；若再现按任务书跑恢复脚本。

## 六、报告与截图索引

- `docs/ui-replication/B9-1-COLLECT-DONE.md`（收集中心归零 + 开库回填）
- `docs/ui-replication/B9-2-QUEUE-BATCH.md`（队列全选 / 标签下拉 / 布局重排 + SR3-15 根因修复）
- `docs/ui-replication/B9-3-REVIEW-BADGE.md`（复习角标；§一/§七已同步第 4 项裁决）
- `docs/ui-replication/B9-4-REVIEW-HEADER-COUNT.md`（页顶三数改按题数）
- 截图（不推）：`docs/ui-replication/shots/b9-queue-batch/`（改前改后 × 1280/窄窗/下拉菜单，6 张）、`docs/ui-replication/shots/b9-review-badge/`（改前改后 × 展开/折叠，4 张）、`docs/ui-replication/shots/b9-review-header/`（改前改后页顶，2 张）

**未推代码说明：** 本批所有改动均在工作树未提交状态，推送须 Meng 另外批准；截图、测试固件、YOLO 模型（38MB，不进仓库）一律不推。
