# Batch 2 遗留问题汇总报告（B2-LEFTOVER-SUMMARY）

- 日期：2026-11-14
- 分支：`ui-replication`（未提交、未推送，按任务要求）
- 批准：Meng 2026-11-14 18:55“这几个你先修着”
- 结论：7 项全部处理完毕（5 项修好、1 项查无此问题、1 项部分留待后续）。`flutter analyze` 0 问题；全量测试 **560/560 通过**（基线 537 + 新增 23）；Linux Release 构建成功；演示库已恢复原状。

## 逐项结果

| # | 项 | 结果 | 报告 |
|---|---|---|---|
| 1 | renameTag / deleteTag / deleteChapter / deleteKnowledgePoint 包事务 | 查无此问题：当前树里四个方法已是事务实现（`*From` 内 `db.transaction`），任务描述针对的是旧快照。补 4 项触发器回滚回归测试 | [B2-LEFTOVER-DATA.md](B2-LEFTOVER-DATA.md) |
| 2 | 错题本详情返回视图跳回默认大卡片 | 已修：`_load()` 只在首次加载时读 `settings.wrongbookView`（`_viewModeInitialized` 标志），之后保留用户切换的视图；新开页面仍读设置默认值。新增 6 项 widget 测试 | [B2-LEFTOVER-WRONGBOOK-VIEW.md](B2-LEFTOVER-WRONGBOOK-VIEW.md) |
| 3 | 死参数 `onSettingsChanged`（复习页 + app 传入） | 已删：review_page 参数/字段/注释、app.dart `/review` 分支传入；测试相应更新。注意 app.dart 另一处是 SettingsPage 的在用参数，未动 | [B2-LEFTOVER-ONSETTINGSCHANGED.md](B2-LEFTOVER-ONSETTINGSCHANGED.md) |
| 4 | tags/exams/knowledge_points REPLACE + 无 ORDER BY | 已修：`insertExam`/`insertKnowledgePoint` 改 UPDATE-first（新增 `*Into` 可测版），`allTags`/`allExams`/`allKnowledgePoints` 加 `ORDER BY rowid`（新增 `*From` 版）；`insertTag` 本来就是 `ignore`，不动。新增 4 项顺序稳定性测试 | [B2-LEFTOVER-DATA.md](B2-LEFTOVER-DATA.md) |
| 5a | 标记写失败致新位置留重复副本 | 已修：`.old` 备份保留到标记写成功才删；标记写失败时回滚目标（删新拷文件、移回 `.old`）；新增 5 项测试 | [B2-LEFTOVER-DATA.md](B2-LEFTOVER-DATA.md) |
| 5b | 目标只有孤儿文件、无库时迁移失败 | 留待后续：完整修法需要未定的合并语义或设置页对话框改动；现行为安全（失败、目标不动），已用测试钉住。附带发现：只有源也有 `imports/`/`slices/` 要搬时才失败 | [B2-LEFTOVER-DATA.md](B2-LEFTOVER-DATA.md) |
| 5c | zip 恢复不删备份里没有的旧文件 | 不改（有意为之）：实测验证恢复后孤儿能被孤儿清理扫到；恢复只写 `imports/`/`slices/`，扫描覆盖同一范围 | [B2-LEFTOVER-DATA.md](B2-LEFTOVER-DATA.md) |
| 5d | 崩溃残留 staging 清理范围 | 已修：`migrateDataFiles` 开头清掉目标旁符合 `.<target>.staging-<digits>` 的残留目录；新增 2 项测试 | [B2-LEFTOVER-DATA.md](B2-LEFTOVER-DATA.md) |
| 6 | README 与模块边界文档过期 | 已修：README 去掉 onnxruntime 未锁定/YOLO 占位说法（现为 `onnxruntime ^1.4.1`、YOLO 第 1 层真实、pdfrx_engine 0.9.2），补 4 个 service 与 2 个 widget 文件；模块边界文档旧翻卡片 + 1/3/7/14 改为治错因模型（§3、§4.1、§4.3、§4.4、§5.1、§5.2） | [B2-LEFTOVER-DOCS.md](B2-LEFTOVER-DOCS.md) |
| 7 | s8b4 测试用真实用户库 | 查无此问题：文件已是隔离的（内存库 + 临时目录），grep 零命中真实库路径；10/10 通过，跑前后真实库 mtime 不变 | [B2-LEFTOVER-HERMETICITY.md](B2-LEFTOVER-HERMETICITY.md) |

## 验证

- `flutter analyze`：0 问题（最终全树复核）。
- 全量 `flutter test`：**560/560 通过**（基线 537；新增 23 = 数据层 17 + 错题本视图 6；其余项只改现有测试或不涉及测试）。YOLO 冒烟需 `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`。
- Linux Release 构建：成功（`build/linux/x64/release/bundle/quiz_master2`）。构建前工具链恢复：VM 重启丢了 GTK 开发包，跑 `docs/ui-replication/restore-linux-toolchain.sh` 两次才成功（第一次 Ubuntu 索引下载中途 `IncompleteRead`，第二次成功：GTK 3.24.41、clang 18.1.3）。

## 演示库事件（重要）

- 本批开工时演示库是 v1、9 道题、深色（与文档一致）。Worker A 跑 `test/p0_hardening_test.dart` 时，其 §4.1 测试打开了真实库单例，v2 代码首次打开 v1 库触发 P1 删库逻辑，演示库被删成 v2 空库（0 道题）；`/tmp` 里的旧备份（qm2-p2-demo-backup 等）已随 VM 重启消失。
- 已按 F2 树的 v1 `_onCreate` DDL + `_seed` 逻辑完整重建演示库（临时测试 `zz_regen_v1_demo_test.dart`，跑完已删）：user_version=1、9 道题、3 学科、7 条错因记录、themeMode=dark、pageSize=10，与文档记载的演示库状态一致；科目颜色用 F2 原值（数学 0xFF2F7CF6 / 英语 0xFF1F9D66 / 政治 0xFFE0524D）。
- 重建后备份（md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`）再跑全量测试；全量测试后库再次被删成 v2 空库（符合 P1 既定行为），已从备份恢复并核对 md5 一致。
- 教训：`p0_hardening_test.dart` 的 §4.1 单例测试是已知的非隔离点（报告原文即注明“走单例 db”）。以后任何跑测试的任务，跑前必须先备份演示库——本次已按此执行。建议后续把 §4.1 单例测试改为隔离方式（未做，超出本次范围）。

## 未修 / 待后续

- `deleteExam` 与本次第 1 项同类（3 步写、无事务），不在任务列出范围，未动。
- 模块边界文档 §4.2 仍写两层框、§4.3/§5.1 仍提第 2 层切片（第 2 层已去掉），以及 §3/§5 复习仍标“未确认”——超出本次“只改旧复习模型段落”范围，需另一次梳理。
- 错题本旧测试里“详情返回刷新”组注释仍写旧的重置行为，现为无害的 no-op，待注释清理。
- 迁移标记写与 `.old` 删除之间极小窗口崩溃会留 `.old` 副本（无数据丢失），下次迁移不清理 `.old`（按“只清 staging”规则）。
- s8b4 的 B4.2 组有个创建了但没用的 `tmp` 目录，可顺手清理（与隔离性无关）。

## 改动清单

| 文件 | 改动 |
|---|---|
| `lib/data/database.dart` | 事务已存在（第 1 项无改动）；upsert 改 UPDATE-first + 读方法 ORDER BY rowid；迁移标记回滚；staging 残留清理 |
| `lib/modules/wrongbook/wrongbook_page.dart` | `_viewModeInitialized` 标志，首次加载才读设置默认视图 |
| `lib/modules/review/review_page.dart`、`lib/app.dart` | 删死参数 `onSettingsChanged`（复习页） |
| `README.md`、`docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md` | 过期内容更新 |
| `test/b2_leftover_data_test.dart`（新增，17 项） | 事务回滚、顺序稳定、迁移回滚、staging 清理 |
| `test/b2_leftover_wrongbook_view_test.dart`（新增，6 项） | 视图默认值与详情返回保留 |
| `test/p0b1_settings_owner_test.dart`、`test/p0b2_pagesize_test.dart` | 随参数删除改写 |
| `docs/ui-replication/B2-LEFTOVER-*.md`（5 份 + 本汇总） | 逐项报告 |
