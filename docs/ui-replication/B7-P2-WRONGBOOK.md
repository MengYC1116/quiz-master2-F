# 第七批修复 · 错题本 / 复习 / 报告 / 首页（B7-P2-WRONGBOOK）

- 日期：2026-11-15。分支 `ui-replication`，工作树 `~/workspace/quiz-master2-UI`。
- 范围：只修第三次自审的 SR3-17～SR3-20（错题本 / 复习 / 报告 / 首页组），不改其他东西；未提交、未推送。
- 依据：`docs/ui-replication/SELF-REVIEW-3.md`（SR3-17～SR3-20）与 `SELF-REVIEW-3-WRONGBOOK.md`（WRONGBOOK-2～WRONGBOOK-5）。

## SR3-17（P2）— 按组进会话文案与实际作用域不一致：修法 (a)

- 位置：`lib/modules/review/review_page.dart:496-520`（`_startSession` 的 `fromGroup` 分支）。
- 修法：选 (a) 文案按实际块集算。按组进会话时 `scopeLabel` 改为 `_scopeLabelForBlocks(blocks)`，不再一律写 `'${学科名} · ${错因}'`。跨学科同错因时自动退为 `错因「…」`；单科单错因时仍是 `学科名 · 错因`，既有 SR2-33 用例不受影响。`_buildBlocks` 已在内部按 `causesPerSession` 截断，文案取截断后的块集算，备注里的截断失真一并覆盖（截断后不含该组任何题时文案也不再写该组）。块集本身不收窄（未选修法 b），`bi` 仍跳到该组的首个块，会话仍从该组开始、随后继续治其他学科同错因的题；断点恢复分支本来就用 `_scopeLabelForBlocks`，不受影响。
- 用例（实跑验证，第三次自审时探针未跑通的缺口本次补上）：`test/review_page_test.dart` 新增 `crossSubjectRepo()`（在 `reviewRepo()` 基础上加一道英语题 q6，待治错因同样是“计算错误”，`joinedAt` 晚 2 小时使英语组排在数学组后）与用例 `SR3-17 按组进会话跨学科同错因：文案退为错因「…」，会话共 2 道题`。断言：点数学“计算错误”组进会话显示 `第 1 / 2 道题 · 错因「计算错误」` 且全页无 `数学 · 计算错误`；走完 q2 的单个错因后到 `第 2 / 2 道题 · 错因「计算错误」`，且第二道题是 `英语 · 材料题｜英语完形填空`。

## SR3-18（P2）— 搜索态缝隙拖拽拒收零反馈：静态提示

- 位置：`lib/modules/wrongbook/wrongbook_directory.dart`（`_buildDirectory`，工具条下方）。
- 修法：搜索有关键词时在工具条下显示一句静态提示 `搜索时不能调顺序，先清空搜索`（12.5px、muted 色），清空搜索后消失。不改拖拽结构，不改拒收行为（缝隙 `onWillAcceptWithDetails` 仍一律 `return false`）。未用“拒收时轻提示”的方案：`DragTarget` 没有“被拒”回调，提示放在搜索态文案上是最直接的做法。
- 用例：`test/wrongbook_page_test.dart` 新增 `SR3-18 搜索文件夹时显示“不能调顺序”提示，清空后消失`（无搜索时无提示 → 输 `卷` 后出现 → 清空后消失）。

## SR3-19（P2）— failed 目录仍整个进 `preview.items`、清理计数按 1 项算

- 位置：`lib/modules/settings/settings_page.dart:556-562`（`walk` 的 failed 分支）。
- 修法：failed 分支与 cache 分支同款处理。`e` 是目录时递归进去、里面的文件逐个 `add(f, 'failed')`；是文件时照旧 `add(e, 'failed')`。之后 `preview.items` 里只有文件，与 B6“不再有目录本身”的说法对齐；`failedCount` 按文件数计，`totalCount` 与“已清理 N 项缓存”随之按文件数算。`_clearCache` 里删目录的分支保留作防御（现已走不到）。未动 `_cacheCleanedMb = preview.mb` 在个别文件删失败时虚高的小口径差（先于 B6 存在，见遗留）。
- 用例：`test/settings_page_test.dart` 新增 `SR3-19 缓存预览：failed 目录递归进、文件逐个计，清理数按文件算`。用同步 IO 搭 `failed-import/` 目录含 2 个文件（SR-P2-50 同款做法，`testWidgets` 体内不用异步文件 IO）：断言备注行 `其中含导入失败的残留文件 2 个`（旧实现为 1 个）；再点清理缓存（与行标题同名，用 `find.widgetWithText(QmButton, '清理缓存')` 精确定位），用真实时间驱动等 `已清理 2 项缓存` 出现（`_clearCache` 的 `await e.delete()` 是真实异步 IO，FakeAsync 下直接 pump 等不到，SR2-61 同款做法）。

## SR3-20（P2）— 真实仓储首页用例只断言焦点卡总数，未断言分科行；tearDown 注册在播种之后

- 位置：`test/b5_p1_1_subject_counts_test.dart:222-271`（SR2-61 用例）。
- 修法：`addTearDown(AppDatabase.resetForTest)` 移到 `runAsync` 播种之前（播种抛错时测试库单例也不残留）；补断言分科行文案，与 FakeRepo 的 `home_page_test.dart`“下方 4 格”用例同款（`要复习 X 道 · 待整理 Y 道`）。真实仓储算出的数：数学要复习 3 道（q1/q2/q3）· 待整理 1 道（q6 未整理）；英语要复习 1 道（q8）· 待整理 0 道；政治 0 道 · 待整理 0 道。`pendingOrganizeBySubject` 的口径是未整理且未归档，场景里只有 q6 未整理，与断言一致。

## 验证

- `flutter analyze`：0 问题（`flutter` 不在默认 PATH，用 `~/workspace/flutter-install/flutter/bin/flutter`）。
- 相关测试文件串行跑（`--concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`），测试体内不用异步文件 IO：
  - `test/review_page_test.dart`：**39/39 通过**（新增 SR3-17 用例 1 个；另有 1 条既存的 hit-test 警告，非失败）。
  - `test/wrongbook_page_test.dart`：**80/80 通过**（新增 SR3-18 用例 1 个）。
  - `test/settings_page_test.dart`：**28/28 通过**（新增 SR3-19 用例 1 个）。
  - `test/b5_p1_1_subject_counts_test.dart`：**5/5 通过**（SR2-61 用例扩展，未新增用例）。
  - 三条新用例另按名单独重跑确认：SR3-17、SR3-18、SR3-19 各 1/1 通过。
- 未跑全量（协调员最后统一跑）。未提交、未推送；工作树无残留探针文件。

## 遗留

- SR3-19：`_cacheCleanedMb = preview.mb` 在个别文件删失败时仍虚高（先于 B6 存在的小口径差，本次未动）；`_clearCache` 里删目录的分支现已走不到，仅作防御保留。
- SR3-17 选的是修法 (a)（文案按实际块集算），会话行为不变：按组进会话仍会跨学科治同错因的题，只是文案如实写成 `错因「…」`。若 Meng 希望按组进会话只治该组，须另改修法 (b)（收窄块集）。
- SR3-18 的提示只覆盖搜索态缝隙拒收；跨层缝隙拒收（SR-P2-43 同款静默拒收）仍无提示，不在本次范围。
