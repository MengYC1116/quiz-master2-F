# B2 遗留清理：删除 ReviewPage.onSettingsChanged — 报告

- 日期：2026-11-14
- 分支：`ui-replication`（未 commit、未 push）
- 来源：`docs/ui-replication/P0B2-PAGESIZE-REPORT.md` 的遗留说明 — P0B2 起复习页“每页”下拉改成本地行为，`ReviewPage.onSettingsChanged` 页内已无使用，仅为兼容保留；本项连同调用点一并删除。
- 范围：只动 `lib/modules/review/review_page.dart`、`lib/app.dart`、`test/p0b1_settings_owner_test.dart`、`test/p0b2_pagesize_test.dart`。未动其他产品文件，未改行为，未动数据库 Schema，未 commit/push/reset/checkout/clean。

## 删了什么

`lib/modules/review/review_page.dart`：
| 位置（改前行号） | 改动 |
| --- | --- |
| 约 L33 | 构造参数 `this.onSettingsChanged` 删除 |
| 约 L41–45 | 字段 `final Future<void> Function(AppSettings s)? onSettingsChanged` 及整段 `///` 注释（P0B1-4 遗留参数说明）删除 |
| 约 L155 | `_pageSize` 注释改写：“下拉改动不写库、不调 onSettingsChanged” → “下拉改动不写库、不改设置默认值” |
| 约 L1092 | `_buildPager` 的 `onChanged` 注释改写：“不调 onSettingsChanged、不写库” → “不写库、不改设置默认值” |

`lib/app.dart`：
- `/review` 分支（改前约 L401–403）：删除注释两行 + `onSettingsChanged: _updateSettings` 传入。`ReviewPage` 构造现只剩 `repo` / `onOpenDetail` / `initialSubjectId` / `onGoWrongbook`。

## L417 的结论

**L417 不属于 ReviewPage，不能删。** 改前约 L417 的 `onSettingsChanged: _updateSettings` 是 `/settings` 分支里 `SettingsPage` 的构造参数（现 L414），`SettingsPage.onSettingsChanged` 是仍在用的必填参数（`settings_page.dart:36,43`，`_apply` 里 `await widget.onSettingsChanged(s)`），原样保留。`lib/app.dart` 里 `ReviewPage` 的传入只有一处（`/review` 分支），已删除。

## 测试更新

- `test/p0b1_settings_owner_test.dart`：`pumpReview` 删 `onSettingsChanged` 形参与传入；第一测删模拟 app 回调（`notified` 列表、`appSnapshot` 快照及对应断言），改名“本页显示变了，库与设置默认值不动”，断言只剩 `settingsValue.pageSize == 2` 与 `saveSettingsCalls == 0`；第三测改名“改每页数量不写库、不持久化：重开复习页仍跟默认值”，新增重开断言（改 20 后重开仍是 `第 1 / 2 页`，证明本地改动不持久化）；文件头历史注释补写 P0B1-4 修法已被 P0B2 取代、参数已删除。设置页本身那测（`pumpSettings` + `SettingsPage.onSettingsChanged`）未动。
- `test/p0b2_pagesize_test.dart`：`pumpReviewP0B2` 删 `notified` 形参与传入；第一测删 `notified` 列表与 `expect(notified, isEmpty)`，注释“不写库、不调回调”改为“不写库、设置默认值仍是 10”；文件头口径注释同步改写。设置页 #17 那测（`SettingsPage.onSettingsChanged`）未动。
- `test/review_page_test.dart`：**未动**——经核查它从未向 `ReviewPage` 传 `onSettingsChanged`（`pumpReview` 无此参数），其 `saveSettingsCalls` 断言仍有效。
- 删除的 fake 字段/计数：`pumpReview` 的回调形参、`pumpReviewP0B2` 的 `notified` 形参、两测里的 `notified` / `appSnapshot` 局部变量均已随参数删除而移除；`FakeOwnerRepo.saveSettingsCalls` 与 `FakeP0B2Repo.saveSettingsCalls` 仍被断言使用，保留。

## 验证结果

- `flutter analyze`：**0 问题**。
- `flutter test test/review_page_test.dart test/p0b1_settings_owner_test.dart test/p0b2_pagesize_test.dart`：**32/32 通过**（`review_page_test` 27 项、`p0b1_settings_owner_test` 3 项、`p0b2_pagesize_test` 2 项）。
- 全量测试未跑（按任务要求，真实 DB 单例由协调方最后统一跑）。
- `flutter build` 未跑。

## 残留核查

全仓 grep `onSettingsChanged` 仅剩 `SettingsPage` 的 live 参数及相关调用/测试（`settings_page.dart:18,36,43,160`、`app.dart:414`、`settings_page_test.dart:108`、`s8a5_section_scroll_test.dart:59`、`p0b1_settings_owner_test.dart:146` 的 `SettingsPage` 构造）与两处历史注释（`p0b1_settings_owner_test.dart:7,179`，记述 P0B1-4 旧修法，已注明被 P0B2 取代）。`ReviewPage` 已无该参数。
