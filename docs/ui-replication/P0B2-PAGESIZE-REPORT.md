# P0B2 复习页“每页”下拉改成本地 — 报告

- 日期：2026-11-14
- 分支：`ui-replication`（未 commit、未 push）
- 基线：开工时工作树已含第一批其他项的未提交改动；基线验证 `flutter analyze` 0 问题、全量 `flutter test` 408 项全部通过（407 通过 + 1 跳过），与任务基线一致，遂按任务继续。
- 工作方式：按 Meng 2026-11-14 00:02 的决定，真机验证不再要求截图；本报告无截图产物。实测脚本里三张 /tmp 临时图只用于自查点击命中，看完即删。

## 改了什么

复习页的“每页”下拉由“改共享默认设置”改成本地行为，与错题本一致：只改本页显示，不写库、不调回调、不改设置默认值；初值仍在打开时从设置默认值读。

`lib/modules/review/review_page.dart`：

| 位置 | 改动 |
| --- | --- |
| 约 L41-48 | `onSettingsChanged` 的注释改写：P0B2 起不再用于每页，参数保留只为兼容既有调用点（app / 测试仍传 `_updateSettings`），页内已无使用；后续清理可连同 app.dart 的传入一并删掉 |
| 约 L155-160 | 新增本页本地字段 `int _pageSize = AppSettings.defaults.pageSize` |
| 约 L290 | `_load` 的 `setState` 里加 `_pageSize = settings.pageSize`（初值仍从设置默认值读） |
| 约 L330 | 删掉 `int get _pageSize => _settings.pageSize`（不再从设置读当前值） |
| 约 L1085-1095 `_buildPager` | `onChanged` 由 async（`copyWith(pageSize)` → `onSettingsChanged` 或回退 `repo.saveSettings` → `setState`）改为同步本地 `setState(() { _pageSize = v; _resetPage(); })` |

`lib/app.dart` 约 L401-403：只改注释（说明复习页每页已本地化、传入保留兼容），接线未动。

错题本未动。未动数据库 Schema、未改依赖、未动 `pubspec.lock`、未 commit/push/pull/reset/checkout/clean。

## 新增 / 改动的回归测试

- 新增 `test/p0b2_pagesize_test.dart`，2 个 widget 测试（自带 `FakeP0B2Repo`，15 道题、每题唯一错因 → 复习 15 组、错题本 15 道，默认 10 时两页都是 2 页）：
  1. 复习页改 10→20：本页变 1 页，`saveSettings` 0 次、`onSettingsChanged` 0 次、库里默认值仍是 10；同一库新开错题本仍是 `第 1 / 2 页`、下拉值 10；反向错题本改 20 同样不碰默认值。
  2. 设置页 #17 改默认 10→20（经 `saveSettings` 模拟 app 写库）：复习页与错题本首次打开都跟新默认 20（`第 1 / 1 页`、下拉值 20）。
- `test/review_page_test.dart`：`每页数量可改` 一测按新口径改写（改 20 后 `settingsValue.pageSize` 仍是 2，`saveSettingsCalls` 为 0）；`FakeReviewRepo` 加 `saveSettingsCalls` 计数。
- `test/p0b1_settings_owner_test.dart`：P0B1-4 的两测按新口径重写（改 20 后回调不触发、库与 app 快照不动；未接回调也不写库），组名改为 `P0B2 复习分页本地化`；设置页本身那测不变（注释修正：快照 20 是模拟已改过默认值，不再是“复习页改完的终态”）。

## 验证结果

- `flutter analyze`：**0 问题**（改前基线与改后各跑一次，均为 0）。
- `flutter test` 全量：改前 408 项全部通过（407 通过 + 1 跳过）；改后 **410 项全部通过（409 通过 + 1 跳过）**，新增 2 项即 `p0b2_pagesize_test.dart`；相关三组 `p0b2_pagesize_test` / `review_page_test` / `p0b1_settings_owner_test` 32/32 通过。
- Linux Release 构建：`flutter build linux --release` 成功（工具链齐全，未跑恢复脚本；`build/linux/x64/release/bundle/quiz_master2`）。
- Linux 真机功能实测（Xvfb 1280×720，深色，演示库 9 道题，脚本 `docs/ui-replication/run-p0b2-pagesize.sh`，坐标复用 `run-shots-p0b1-settings.sh` 的同布局实测值）：
  - 复习页点“每页”下拉 10→20：临时自查图确认下拉显示 20（`共 3 条 · 第 1 / 1 页`）；查库 `pageSize` 仍是 10。
  - 设置页开「错题本」组：临时自查图确认「每页显示数量」选中仍是 10；查库 `pageSize` 仍是 10。
  - 错题本数学列表：临时自查图确认 `共 2 道 · 第 1 / 1 页 每页 10 道`；查库 `pageSize` 仍是 10。
  - 全程 `themeMode` 保持 dark，应用无崩溃。
- 演示库验证后已恢复：`~/.local/share/quiz-master2/quiz-master2.db` 与跑前备份 md5 一致（`8a827ea944b7d0a3c66d59c10f5f0d46`），9 道题、3 学科、深色、`pageSize=10`。杀应用只用 `pkill -x quiz_master2`。

## 遗留说明

- `ReviewPage.onSettingsChanged` 参数现已无页内使用，仅为兼容保留；app.dart 仍传入 `_updateSettings`。如需彻底清理，可另立一项连同传入一并删除（不影响行为）。
- 演示库复习列表只有 3 组，10 与 20 在真机上都是一页，改后差异只体现在下拉显示值上；多组区分（15 组 2 页→1 页）由 widget 测试覆盖。
