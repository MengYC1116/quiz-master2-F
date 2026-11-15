# 第十批修复总结（B10-SUMMARY）

**范围：** CodeBuddy 评审 Batch 9 已推基线（远端 head `6316a23`，生产代码 8.8/10、可交付 6.5/10）后提的两处 P0（仓库可复现问题）+ 清理三件。Meng 2026-11-15 ~22:21 批准按此范围开工。
**基线：** Batch 9 已推 head `6316a23`（测试 899/899、analyze 0、Linux Release 通过）。
**状态：** 3 项全部完成并通过最终门禁。**未提交、未推代码**——推送须 Meng 另外批准。

## 一、逐项结果

| # | 内容 | 结果 |
|---|---|---|
| 1 | P0-1：远端残留已删的 3 个二层测试 | ✅ 完成。B8-2 在本地删掉的 3 个文件只删了本地，远端还留着（快照推送删不了文件），导致远端/Win11 树 analyze 48 个错、899 无法复现。用连接器 `delete_file` 逐个删掉，每次删除一次单独提交，三张审批卡全部即时获批；删完逐个用 `get_file_contents` 核对远端已无此路径。删除后远端新 head `a1021d7b`（删除前 `6316a23`）。另做远端整树与本地整树全面对账（depth-1 克隆远端 644 文件 vs 本地 999 文件，路径集合比对）：除上述 3 个外远端再无其他孤儿；本地多出的 355 个文件全部落在约定不推项内（截图 348 个、固件 7 个），排除后两边路径集合完全一致。 |
| 2 | P0-2：测试固件测试内生成 | ✅ 完成。先把 `test/fixtures/` 原样备份到 `~/workspace/test-fixtures-backup-b10/`（`diff -r` 核对一致），再动手。新增共享入口 `test/test_fixtures.dart`：EXIF 方向 JPEG ×4 与加密 PDF 用 base64 内嵌（逐字节相同，解回 md5 与原文件一致）；`photo.jpg` 改为生成（方向 1 固件去掉 APP1 段 → 3604B、400×300 真实 JPEG、无 EXIF，可解码；188KB base64 按要求不内嵌）；`slice-narrow-500x120.png` 在 `setUpAll` 用 dart:ui 现场画 500×120 白底黑条。改了 5 个测试文件（`p05_image_pipeline_test.dart`、`p2_main_chain_test.dart`、`b2_win11bug_organize_test.dart`、`import_service_p1_fixes_test.dart`、`pdf_render_service_test.dart`），无测试增删（仅 p2 一个测试改名）；`lib/` 零改动。验收：移走 `test/fixtures/`（已 `rm -rf`）后全量测试仍通过，测试零依赖磁盘文件。 |
| 3 | 清理三件 | ✅ 完成。(a) `docs/代码地图.md` 头部整块重写：删掉过期的“Batch 6 已推 head 38cbc4b、第七批进行中、628/628”，补齐 B7（已推 `622b6b6`、879/879）、B8（已推 `b773224`、874/874）、B9（已推 `6316a23`、899/899、analyze 0）；远端 head 用 `git ls-remote` 核实。(b) “清空演示数据”整条链删干净：设置页入口（数据组“演示数据”行、`_askClearDemo()`、`_clearDemo()`）+ 数据层（`repository.dart` 两个透传、`db_settings.dart` 的 `clearDemoDataFromImpl()` 与 `clearDemoData()`/`demoQuestionCount()`、`database.dart` 的 `clearDemoDataFrom`）+ 4 个相关测试（settings 2 个、p0 的 SR-P2-2、b5 的 SR-P2-2 整组）；删后 `grep "clearDemoData|demoQuestionCount|清空演示数据" lib test` 零命中。特意保留 `is_demo` 列与 `Question.isDemo` 字段（表结构/模型字段，本项不碰数据库；仍被 codec、收集页、详情页读写）。(c) `pubspec.lock`：VM 树干净（`pub.flutter-io.cn` 全仓库 0 命中；`code_assets` 是正常 transitive 依赖，`https://pub.dev`、1.2.1；54 个 hosted 条目 url 全部是 `https://pub.dev`），仓库文件一个未改。给 Meng 的还原命令：他 Windows 本地跑 `git checkout -- pubspec.lock`，前提是他对 lock 没有想保留的其他本地改动（有则先 `git diff pubspec.lock` 确认）。 |

## 二、门禁验证（协调员最终复核，全部在最终树上跑）

- `flutter analyze`：**0 问题**。
- 全量测试串行（`--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，默认 `/tmp`）：**895/895 通过，`[E]` 0 处，EXIT 0**，约 6 分 28 秒，日志 `/tmp/b10-gate-full.log`。总数由 B9 的 899 变为 895：**−4 全部来自第 3 项删除的 4 个测试**（settings 2、p0 SR-P2-2 1、b5 SR-P2-2 1）；第 2 项无测试增删，第 1 项只动远端。删除前第 2 项工人已先跑过一次同样条件全量，结果一致（895/895）。
- Linux Release 构建：**通过**（`Built build/linux/x64/release/bundle/quiz_master2`），日志 `/tmp/b10-gate-build.log`。**中途一次失败**：首次构建 CMake 报错 `/usr/include/gtk-3.0` 不存在（VM 又丢了 GTK 开发头文件，老问题）；跑 `docs/ui-replication/restore-linux-toolchain.sh` 恢复（GTK 3.24.41）后重跑通过。ninja/clang/cmake 本次都在。
- 演示库：门禁跑前备份到 `~/workspace/demo-db-backup/quiz-master2.db.b10-gate`（md5 已核）；跑后 live 库核对为 **v1**，md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，无 -wal/-shm 残留。全量测试未动 live 库，无需恢复。
- 远端 head 核对：删除后 `a1021d7b09514d239fce262f6d08e40156523cc9`（`git fetch` 后核对，删除前后一致，无他人推送）。

## 三、口径与记录说明

- **计数口径**：895 = 899 − 4（第 3 项删 4 个测试）。不是测试丢失，是清理死入口连带删掉的测试。
- **同步记录未跟进删除提交**：`~/workspace/quiz-master2-UI.muse-github-snapshot-sync.json` 的最后一条仍是 B9 的 `6316a23`（push_files 记录）；第 1 项的三次 `delete_file` 提交（`db5c6917`、`3262a041`、`a1021d7b`）不在该记录格式内。下次推送前，须以 `a1021d7b` 为远端 head 核对，不要拿记录里的 `6316a23` 当 head。
- **本地 HEAD 谱系**：`git fetch` 后核对，本地 HEAD `bca8586` 是远端 `a1021d7b` 的祖先（之间 11 个提交：8 次快照推送 + 3 次删除）。第 1 项工人初版“不在同一谱系”的说法是误判（当时本地还没有远端新对象，`merge-base` 查不到），以本次 fetch 后核对为准。

## 四、未动、留待以后

- P1-1（v1 改重命名备份）：Meng 22:19 否了——v1 演示库压根不需要（演示题和实际试卷差太多，没意义），v1 库该删就删。本项未动 `db_schema.dart` 的删除逻辑。
- Win11 打包与真机行为验收（build windows/DLL/工具链、拖放导入、错题本分页、重框）：Meng 说先不做，往后放。
- 三个大文件再拆（organize 112K、review 76K、detail 80K）、B9 的 P2 审计项、CI：本次不动。
- `test/fixtures/` 的备份在 `~/workspace/test-fixtures-backup-b10/`（7 个文件，含只在此处有的 `slice-narrow-500x120.png`）；旧固件 zip 链接 2026-11-17T06:20:19Z 过期，现已不再依赖它。

## 五、报告与文件索引

- `docs/ui-replication/B10-1-REMOTE-ORPHANS.md`（远端删文件 + 整树对账，含每个删除文件、删除前 SHA、新 head、355 个本地文件的完整清单）
- `docs/ui-replication/B10-2-FIXTURES.md`（固件测试内生成、各固件新来源、验收过程）
- `docs/ui-replication/B10-3-CLEANUP.md`（代码地图头部、清空演示数据整条链、pubspec.lock 核对与还原命令）
- 备份：`~/workspace/test-fixtures-backup-b10/`、`~/workspace/demo-db-backup/quiz-master2.db.b10-gate`；门禁日志 `/tmp/b10-gate-full.log`、`/tmp/b10-gate-build.log`

**未推代码说明：** 本批所有本地改动均在工作树未提交状态，远端三次删除提交除外（那是第 1 项的任务本身，经审批卡批准）；本地改动的推送须 Meng 另外批准。截图、测试固件备份、YOLO 模型（38MB，不进仓库）一律不推。
