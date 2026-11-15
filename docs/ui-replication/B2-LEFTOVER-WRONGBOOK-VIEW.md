# B2 Leftover：错题本视图模式在 _load() 刷新后被弹回默认

## 根因

`lib/modules/wrongbook/wrongbook_page.dart` 的 `_load()`（约 L135–170）
每次执行都在 `setState()` 里无条件执行：

```dart
_viewMode = settings.wrongbookView;   // 约 L160（修复前）
```

而 `_load()` 是全页唯一的刷新入口，被 19 处调用：

- 详情返回：大卡片行 `onTap`（约 L2838）、紧凑行 `onTap`（约 L2922）、
  已归档行 `onTap`（约 L3080），都是 `await widget.onOpenDetail(...); await _load();`
- 文件夹操作：新建 / 改名 / 删除 / 移动 / 调顺序 / 拖放（约 L577、L603、L609、L690、L724、L740、L757）
- 批量操作：加标签 / 移文件夹 / 移出 / 收藏 / 归档 / 删除（约 L842、L876、L891、L900、L909、L921）
- 行内操作：点星 `_toggleFavorite`（约 L926）、恢复归档 `_restoreArchived`（约 L931）

于是用户在列表页点「紧凑列表」切到 compact 后，只要进一次详情再回来
（或点一次星、做一次批量操作），`_load()` 就把 `_viewMode` 写回设置默认值
（默认 `large`），视图被弹回大卡片。切换控件本身（约 L2241–2248，
`setState(() => _viewMode = ...)`）没有问题，问题只在 `_load()` 的覆盖。

## 修复

只改 `lib/modules/wrongbook/wrongbook_page.dart`，两处：

1. 新增标志位（约 L98–103，`_viewMode` 字段之后）：
   ```dart
   // 视图模式只在首次 _load() 时取设置默认值；之后用户在页内切换
   // （大卡片 / 紧凑列表）后，_load() 不再覆盖，避免从详情返回、
   // 批量操作、点星等刷新后被弹回默认视图（B2 leftover）。
   // 新进错题本（新 State 实例）时该标志为 false，仍读设置默认值。
   bool _viewModeInitialized = false;
   ```
2. `_load()` 内（约 L162–168）只在首次应用设置默认值：
   ```dart
   if (!_viewModeInitialized) {
     _viewMode = settings.wrongbookView;
     _viewModeInitialized = true;
   }
   ```

覆盖面：所有 19 处 `_load()` 调用都走同一个 `_load()`，标志位方案一次性
覆盖详情返回、文件夹操作、批量操作、点星、恢复归档，无需逐处改。
`_sort` / `_defaultSort` / `_pageSize` 仍每次跟随设置（不在本次范围，未动）；
切换控件未动；新进错题本（新 `State` 实例，标志位复位）仍读设置默认值。

注意：首个 `_load()` 在 `initState` 发起、加载完成前页面是 loading
转圈、切换控件不可见，因此不存在“用户在首次加载完成前切换、又被覆盖”
的竞态。

## 测试

新增 `test/b2_leftover_wrongbook_view_test.dart`（独立 `FakeViewRepo`，
不碰真实数据库；只覆盖本文件用到的 repository 调用；`settingsValue`
可配 `wrongbookView`），6 个 widget 测试：

| 测试 | 断言 |
|---|---|
| 首次进入用设置默认值：默认 large 显示大卡片 | 3 张 `QuestionSlice`，无 `CompactSliceThumb` |
| 首次进入用设置默认值：设置 compact 则默认紧凑列表 | 3 个 `CompactSliceThumb`，无 `QuestionSlice` |
| 切到紧凑列表后从详情返回，仍是紧凑列表 | 点行进详情（`onOpenDetail` 后 `_load()`）后仍 3 个紧凑行 |
| 切到紧凑列表后点星刷新，仍是紧凑列表 | 点 `☆`（`_toggleFavorite` → `_load()`）后仍紧凑 |
| 切到大卡片后从详情返回，仍是大卡片（双向保留） | 设置 compact 默认下切大卡片、进详情返回后仍大卡片 |
| 新进错题本重新读设置默认值 | compact 默认的页面实例后，全新页面实例读 large 默认 |

## 验证结果

- `flutter analyze`（全项目）：**No issues found!**
- `flutter test test/b2_leftover_wrongbook_view_test.dart`：**6/6 通过**
- `flutter test test/wrongbook_page_test.dart`（回归）：**41/41 通过**
- 未跑全量测试套件（按任务要求，真实 DB 单例由 coordinator 在备份后跑）；
  未跑 `flutter build`；未 push；未改 DB schema；未动其他产品文件。

## 遗留（未动，有意）

`test/wrongbook_page_test.dart` 中「详情返回刷新」组里的
「紧凑列表：详情里改收藏，返回后星标出现」一测，注释仍写着
“_load 会把视图重置为设置里的默认视图（大卡片）……切回紧凑列表再断言”，
并在返回后多点了一次「紧凑列表」。修复后该注释已过时、那次重切是无操作
（no-op），但测试本身仍通过；因本次任务限定只动一个新测试文件，未顺手
改它，建议后续清理该注释与多余点击。
