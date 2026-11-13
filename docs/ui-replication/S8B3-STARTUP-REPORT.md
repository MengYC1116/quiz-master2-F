# S8 B3：启动页设置生效

- 裁决：Meng 2026-11-13 14:37，启动页设置需要生效。
- 状态：完成。`flutter analyze` 0 问题；`flutter test` 全量 331/331；
  Linux Release 构建成功；Linux 真机四张截图验证通过。
- 改动文件：`lib/app.dart`、`lib/data/database.dart`、
  `lib/data/repository.dart`、`test/s8b3_startup_test.dart`（新增）、
  `docs/ui-replication/run-shots-s8b3.sh`（新增，验证脚本）。
- 边界：未改 SQLite Schema（不新开表、不加字段）；未改业务规则/口径
  （除本次裁决的这一处）；未增删功能；未改已定决策；未升级依赖；
  未改 `pubspec.lock`；只做 B3。

## 1. 问题

设置页「启动页」选项（首页 / 上次停下的页面）早已存在，
模型 `AppSettings.startupPage`（`lib/models/models.dart:414`，
`'home'` / `'last'`，默认 `'home'`）与设置页 UI
（`lib/modules/settings/settings_page.dart:993-1001`）都已就绪，
但 app 从来不消费它：`lib/app.dart:34` 写死 `String _route = '/home'`，
全仓没有地方读 `startupPage`，也没有地方持久化“上次停下的页面”。

## 2. 最后路由存在哪

复用 **`settings` 表的 key/value**，key 为 `lastRoute`，值是路由字符串
（例如 `/organize`）。不新开表、不加字段、不碰 Schema。

- 写：`AppDatabase.saveLastRoute(route)`（`lib/data/database.dart`，
  调现有 `saveSetting` 的 upsert）；
- 读：`AppDatabase.loadLastRoute()`（按 key 查 `settings` 表，无行返回 `null`）；
- 仓库透传：`QuestionRepository.lastRoute()` / `saveLastRoute(route)`
  （`lib/data/repository.dart`）。

这样选的理由：

- `settings` 表本来就是 key/value，`saveSetting` 已有 upsert 能力，
  零 Schema 成本；
- `saveSettings` 只写 `AppSettings.toMap()` 的已知键，不会误删
  `lastRoute`；`loadSettings` 的 `fromMap` 忽略未知键，`lastRoute`
  不会污染 `AppSettings`（单测覆盖，见 §4）；
- “最后路由”是会话状态不是用户设置，所以不放进 `AppSettings`
  字段——设置页保存设置时不会顺带改写它，语义干净。

## 3. 启动时怎么读

`lib/app.dart` 新增纯函数 `resolveStartupRoute(startupPage, lastRoute)`
（顶层函数，便于单测），`_loadSettings()` 里设置读完后立即算初始路由：

```dart
final s = await repo.settings();
final last = await repo.lastRoute();
final initial = resolveStartupRoute(s.startupPage, last);
setState(() {
  _settings = s;
  _route = initial;
  _settingsLoaded = true;
});
if (initial != last) {
  unawaited(repo.saveLastRoute(initial)); // 自愈，见 §4 回落规则
}
```

导航时记最后路由：`_go`、`_goReview`、`_goWrongbookFiltered`
三个入口在 `setState` 后都调 `unawaited(repo.saveLastRoute(route))`
（`dart:async` 的 `unawaited`，analyze 无警告）。
题目详情页是 `Navigator` 压栈，不经过这三个入口，退出时最后路由
仍是底层顶级页——与回落规则一致（见下）。

## 4. 回落规则

白名单只含 9 个顶级路由（`topLevelRoutes`，`lib/app.dart`）：

```
/home /collect /organize /wrongbook /review /report /subjects /settings
```

| startupPage | lastRoute | 启动落点 |
|---|---|---|
| `'home'`（或非法值） | 任意 | `/home` |
| `'last'` | 白名单内的顶级路由 | 该路由 |
| `'last'` | 详情路由 `/question/:id` | `/home` |
| `'last'` | 空 / 全空白 / 不在白名单 / 无存值（`null`） | `/home` |

决定这样定的理由：

- **详情路由不恢复**：题目可能已被删，恢复详情页没有意义；且详情页
  是压栈页面不是 `_route`，退出时本来也不会被记为最后路由。
- **存值两侧空白先 trim**：手改库留空格时仍能恢复。
- **自愈**：回落后的路由与存值不一致时写回去（存值非法/为空、
  或 `startupPage` 是 `'home'` 时上次停留页被首页覆盖），下次启动
  不再重复回落；合法恢复时 `initial == last`，不写。

边界情况：设置读失败（`_loadSettings` 的 `catch`）时沿用旧行为——
默认设置继续跑、`_route` 保持 `'/home'`、设置页出错误横幅。

## 5. 测试清单与结果

### 5.1 `flutter analyze`

0 问题（`No issues found!`）。

### 5.2 `flutter test`（全量 331/331）

新增 `test/s8b3_startup_test.dart`，8 个测试，全部通过：

`resolveStartupRoute` 纯函数（7 个）：

- `'last'` + 存过 `/organize` / `/settings` / `/review` → 恢复该路由；
- `'last'` + 9 个顶级路由逐个 → 都恢复；
- `'home'` + 存过某路由 → 落首页；
- `'last'` + 存的是 `/question/q-m1`、`/question/abc` → 回落首页；
- `'last'` + `null` / `''` / 全空白 / `/nope` / `organize`（缺斜杠）
  → 回落首页；
- `startupPage` 非法值（`'bogus'`、`''`）→ 回落首页；
- 存值两侧空白 `'  /review  '` → trim 后恢复 `/review`。

`lastRoute` 持久化（1 个，读写真实演示库 `settings` 表，只碰
`lastRoute` 一个 key，先读原值、finally 原样恢复）：

- 存取往返 `/home` → `/organize` → `/review` 均读回一致；
- 全量 `saveSettings(AppSettings.defaults.copyWith(startupPage: 'last'))`
  后 `lastRoute` 仍为 `/review`、`startupPage` 读回 `'last'`，
  证明 `saveSettings` 不误删 `lastRoute`。

注：整应用 `QuizMasterApp` 在 widget 测试里 `pumpAndSettle` 永不静止
（应用内有持续 Timer），按仓库惯例（见 S8A5 报告）不直接测整应用；
启动恢复的端到端行为以 §5.3 的 Linux 真机截图为直接证据。

### 5.3 Linux 真机验证（1280×720，Xvfb，深色）

验证脚本 `docs/ui-replication/run-shots-s8b3.sh`（备份整库、trap 恢复；
杀应用 `pkill -x quiz_master2`）。导航点击坐标取自探针图：
「整理工作台」行中心 (100, 172)。

| 截图 | 步骤 | 预期 | 结果 |
|---|---|---|---|
| `01-start-last-home.png` | `startupPage=last`、`lastRoute=/home`，启动 | 首页 | ✅ 首页（与探针图哈希一致） |
| `02-organize-after-click.png` | 点左侧导航「整理工作台」 | 整理工作台；库 `lastRoute=/organize` | ✅ 整理工作台（政治·中国式现代化），`lastRoute=/organize` |
| `03-restart-restores-organize.png` | 退出重进 | 恢复整理工作台 | ✅ 与 02 像素一致，`lastRoute` 仍为 `/organize` |
| `04-start-home-again.png` | `startupPage` 改回 `home`，退出重进 | 首页 | ✅ 首页（与探针图哈希一致） |

截图目录：`docs/ui-replication/shots/s8b3/`（另有 `probe-home-dark.png`
探针图）。深色主题；亮色未单独截——恢复逻辑与主题无关，
且 01/04 与深色探针图逐字节一致已能证明落点正确。

### 5.4 演示库恢复

验证后恢复原状（脚本 trap 自动执行）：学科 3、题目 9、
`themeMode=dark`、`startupPage=home`、`lastRoute=/home`，
备份文件已删除。

注：验证前发现往返测试的第一版末尾用
`saveSettings(AppSettings.defaults)` 把演示库 `themeMode` 写成了
`system`；已把测试改成“先读原值、finally 原样恢复”，并按任务要求
把恢复态定为深色。本次验证结束时库状态已按 §5.4 核对无误。

## 6. 未做的事

- 未碰 B4 及以后；未碰 `QmChip` / `SubjectLabel`（另有专人）。
- 亮色主题未单独截图（理由见 §5.3）。
- Win11 真机复核仍待 Meng：启动恢复在 Win11 上的表现、
  字体/DPI 下的导航点击位置与本报告无关（本项无界面改动）。
