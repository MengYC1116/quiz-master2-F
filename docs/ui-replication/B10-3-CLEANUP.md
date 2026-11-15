# 第十批第 3 项总结 — 清理（B10-3-CLEANUP）

**范围：** (a) 代码地图头部过期重写；(b) 删设置页“清空演示数据”入口（含数据层整条链）；(c) pubspec.lock 镜像核对。
工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`。
**状态：** 3 件全部完成，验证通过。**未提交、未推代码**——推送须 Meng 另外批准。

## 一、(a) 代码地图头部重写

文件 `docs/代码地图.md`，只改了开头的 `>` 引用块，正文各节一行未动。

过期内容（已删）：
- “Batch 6 已推，远端 head `38cbc4b`；第七批修复进行中”；
- “全量测试 628/628 通过（Batch 4 结束时）”。

重写后（数字以 `docs/ui-replication/B9-SUMMARY.md` 为准，B7/B8 行按各自总结补齐）：
- Batch 7（第三次自审 35 项修复）已完成、已推送（2026-11-15 ~13:52，远端 head `622b6b6`）；最终验证：analyze 0 问题、全量测试 879/879、Linux Release 构建成功，结论见 `B7-SUMMARY.md`。
- Batch 8（Win11 真机验收第一轮 9 项）已完成、已推送（2026-11-15 ~17:17，远端 head `b773224`）；最终验证：analyze 0 问题、全量测试 874/874、Linux Release 构建成功，结论见 `B8-SUMMARY.md`。
- Batch 9（Win11 真机验收第二轮 3 项 + 复习页顶口径统一）已完成、已推送（2026-11-15，远端 head `6316a23`）；最终验证：analyze 0 问题、全量测试 899/899、Linux Release 构建成功，结论见 `B9-SUMMARY.md`。
- 末行改为“第十批清理进行中，其改动未提交、未推送，在 Meng 明确批准之前不要 push。”

核对：`git ls-remote` 远端 `ui-replication` 确为 `6316a230947aa99d5e01173eff49eaec58fe95bc`，提交信息与 B9 内容一致；本地 HEAD `bca8586` 是该远端 head 的祖先（落后 8 个提交），工作树未提交的改动是 B7–B9 的内容，与头部所述一致。

## 二、(b) 删“清空演示数据”入口 + 数据层整条链

### 决定：整条链一起删干净

删前 grep 核对全部调用方（`lib` + `test`）：
- 生产调用方只有设置页一处：`settings_page.dart` 的 `_askClearDemo` → `repo.demoQuestionCount()`（`_askClearDemo` 内）与 `_clearDemo` → `repo.clearDemoData()`。
- 其余命中全是定义本身与测试：`repository.dart` 的两个透传、`db_settings.dart` 的 `clearDemoData()` / `demoQuestionCount()` / `clearDemoDataFromImpl`、`database.dart` 的 `clearDemoDataFrom` 静态方法，以及 3 个测试文件里的 SR-P2-2 测试与 settings 假 repo。
- v2 从不播种演示题（§6 第 1 条，`demo_data.dart` 的 `demoQuestions()` 早在 SR-P2-13 已删），入口点进去永远是“没有演示数据”，无其他功能依赖这条链。

因此按任务书建议：入口 + 数据层方法 + 相关测试全部删除，不留死入口与死方法。

### 删了什么

生产代码：
- `lib/modules/settings/settings_page.dart`：数据组末尾的“演示数据”行（`_row('演示数据', …)` + `清空演示数据` 危险按钮）、`_askClearDemo()`、`_clearDemo()`、文件头注释里的“、清除演示数据”。
- `lib/data/repository.dart`：`clearDemoData()`、`demoQuestionCount()` 两个透传。
- `lib/data/db_settings.dart`：`clearDemoDataFromImpl()`（含整段 SR-P2-2 注释）、`AppDatabaseSettings` 扩展里的 `clearDemoData()` 与 `demoQuestionCount()`；文件头注释去掉“ / 演示数据”。
- `lib/data/database.dart`：`clearDemoDataFrom` 静态方法。
- `lib/models/models.dart`：`isDemo` 字段注释改述（见下“特意保留”）。

测试：
- `test/settings_page_test.dart`：2 个 widget 测试（“模态弹窗确认，确认后清掉并提示”“点取消不清”）、`FakeSettingsRepo` 的 `demoCount` / `clearedDemo` / `demoQuestionCount()` / `clearDemoData()`，文件头注释里的“、清空演示数据确认”。
- `test/p0_hardening_test.dart`：SR-P2-2 测试（`clearDemoDataFrom：演示题走删题事务，非演示一律不动`）。
- `test/b5_p2_data_test.dart`：SR-P2-2 整组（`清演示数据走删题事务`）。

### 特意保留（未动）

- **`is_demo` 列与 `Question.isDemo` 字段保留**：这是表结构（`db_schema.dart`）与模型字段，不是清空功能的一部分。本项不碰数据库、不做迁移；`isDemo` 仍被 `db_codec.dart`、`collect_page.dart`（新建题写 `false`）、`question_detail_page.dart`、`widgets.dart`（切片/旧题判断）读写，v1 老库遗留行的标记仍有意义。只把 `models.dart` 的字段注释改成“演示题标记（v1 老库遗留；v2 新库从空开始、不预置演示题，清空入口已删）”。
- **删题级联行为本身未动**：SR-P2-2 测的是 `clearDemoDataFrom` 对 `_deleteQuestionTxn` 的复用；`_deleteQuestionTxn` 未改，级联仍由同组测试 `deleteQuestionFrom：清 review_history，任务指向置空、任务保留，队列去项`（`p0_hardening_test.dart:349`）覆盖。
- `lib/data/demo_data.dart` 的 `demoKnowledgePoints()` / `demoExams()` 未动——那是预置知识点树与试卷种子，不是演示题，与本项无关。

删后复核：`grep -rn "clearDemoData\|demoQuestionCount\|清空演示数据" lib test` 零命中。

## 三、(c) pubspec.lock 镜像核对

结论：**VM 树干净，无异常；仓库文件一个未改。**

- `grep "pub.flutter-io.cn" pubspec.lock`：0 命中；全仓库跟踪文件 `git grep -l "pub.flutter-io.cn"`：0 命中；`.dart_tool/package_config.json`：无 `flutter-io`。
- `code_assets`（lock 第 44–47 行）是正常的 transitive 依赖，`url: "https://pub.dev"`、`source: hosted`、`version: "1.2.1"`，不是镜像产物。全 lock 所有 hosted 条目（54 个）的 url 均为 `https://pub.dev`，其余为 `source: sdk`。
- VM 树 `pubspec.lock` 相对本地 HEAD 的改动（`git diff`，72 行新增）全是 B7–B9 工作引入的新 transitive 包（`archive`、`http`、`http_parser`、`image` 等），url 全部是 `https://pub.dev`，与镜像无关。
- 镜像 diff 只在 Meng 的 Windows 本地，不在仓库里——按任务书要求未改仓库任何文件。

### 给 Meng 的还原命令（在他 Windows 本地跑）

```powershell
git checkout -- pubspec.lock
```

前提：他那边对 `pubspec.lock` 没有想保留的其他本地改动。如果他本地 lock 里除了镜像源之外还有别的改动（例如他自己 `flutter pub get` 后升过某个包版本），先 `git diff pubspec.lock` 看一眼，确认只有镜像源相关行再还原；有想留的改动就别整文件还原，改完再单独处理。
还原后如需恢复与仓库一致的依赖版本，跑一次 `flutter pub get` 即可（仓库 `pubspec.lock` 全是 `https://pub.dev` 源）。

## 四、验证

- `flutter analyze`（`~/workspace/flutter-install/flutter/bin`）：**0 问题**。
- 相关测试串行（`--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，默认 `/tmp`）：**98/98 通过**——`test/settings_page_test.dart` 26 项、`test/p0_hardening_test.dart` 11 项、`test/b5_p2_data_test.dart` 61 项，`All tests passed!`。总数由 B9 的 899 变为 895：本项删 4 项测试（settings 2、p0 1、b5 1）。
- 未跑全量（按任务书，全量门禁由协调员统一跑）；未跑应用；未碰数据库。

## 五、说明

- 未 commit、未 push；本次改动与 B7–B9 未提交改动同在工作树。
- `lib/data/db_settings.dart`、`test/b5_p2_data_test.dart`、`test/p0_hardening_test.dart` 是未跟踪的新文件（B7–B9 期间新建、本地 HEAD `bca8586` 之前不存在），所以 `git diff` 看不到它们，本项对它们的删除以 grep 零命中 + 测试通过为准。
