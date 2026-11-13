# S8A2（A2 项）— 紧凑列表缩略图深色纸面修复报告

- 日期：2026-11-13
- 对应：R11 §8.3“`CompactSliceThumb` 仍白色，与 `QuestionSlice` 纸面改动不一致”
- 状态：**已修复，真机验证通过**
- 改动文件：
  - `lib/widgets/widgets.dart`（`CompactSliceThumb` 背景色取 token）
  - `test/wrongbook_page_test.dart`（新增亮/深纸面色回归测试）
- 报告截图：`docs/ui-replication/shots/s8a2-thumb/`
- Linux 结果不替代 Win11 最终验收。

> 注：报告编号 S8A2 在本轮已被学科颜色修复（S8A2-SUBJECT-COLORS-REPORT.md）
> 占用，本项报告文件名为 S8A2-COMPACT-THUMB-REPORT.md，任务清单里的“A2 项”。

## 1. 问题

`QuestionSlice`（大卡片）在 R7 已改为纸面色取 token（亮色 `#FFFDF4` /
深色 `#D8DCE2`，D1），但 `CompactSliceThumb`（紧凑列表里 64×48 的小缩略图）
背景写死 `Colors.white`，注释还写明“深色模式下同样保留”。深色下紧凑列表
里两张小图是纯白，与大卡片的 `#D8DCE2` 纸面不一致。

## 2. 修法（一行）

`lib/widgets/widgets.dart` 的 `CompactSliceThumb.build`：

```dart
// 旧：
color: Colors.white, // 缩略图白底：深色模式下同样保留
// 新：与 QuestionSlice 同取 palette.paper
color: DesignTokens.of(Theme.of(context).brightness).paper,
```

边框不动：它用的 `AppTheme.darkPaperLine` / `lightPaperLine` 与
`palette.paperLine` 是同一组值（深 `#AEB6C2` / 亮 `#E3D9BE`），已核对。
缩略图内的 mini 条、简图画笔、失败占位均未动。

## 3. 回归测试

`test/wrongbook_page_test.dart` 新增
“紧凑列表缩略图：亮色纸面 #FFFDF4、深色纸面 #D8DCE2，与大卡片一致”：
亮/深各泵一次紧凑列表，读第一个缩略图根 Container 的
`BoxDecoration.color` 断言（新增 `_thumbPaperColor` 辅助函数）。

## 4. 真机验证（Xvfb :99，1280×720，Linux Release 构建）

路径：错题本 → 数学书 → 全部题目 → 紧凑列表，逐像素采样两个缩略图区域。

| 主题 | 缩略图主色（像素实测） | 结论 |
| --- | --- | --- |
| 深色 | `#D8DCE2` (216,220,226)，两图 2437 / 2246 px | 与大卡片一致 |
| 亮色 | `#FFFDF4` (255,253,244)，两图 2437 / 2246 px | 与大卡片一致 |

- 深色整图扫描：纯白 `(255,255,255)` 像素为 0。
- 截图：`shots/s8a2-thumb/compact-dark.png`、
  `shots/s8a2-thumb/compact-light.png`（另附深色大卡片对照
  `large-cards-dark.png`）。

## 5. 静态检查

- `flutter analyze`：No issues found。
- `flutter test`：**280/280 通过**（279 基线 + 1 个新增测试）。
- 演示库已恢复原状：9 道题、themeMode=dark（从 `/tmp/qm2-s8a2-orig.db` 恢复并核对）。
