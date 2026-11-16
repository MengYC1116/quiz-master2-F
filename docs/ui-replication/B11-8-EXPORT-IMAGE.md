# B11-8：详情页导出本题图片（拓展版）

- 批次：Batch 11 第 8 项；执行 worker 汇报
- 日期：2026-11-15
- 分支：ui-replication（未 commit、未 push）
- 状态：完成；测试 17/17 通过；analyze 0 问题；Linux Debug 构建通过

## 改了什么文件

| 文件 | 改动 |
| --- | --- |
| `pubspec.yaml` | 新增 `super_clipboard: ^0.9.1`（剪贴板图片，见“决策”） |
| `pubspec.lock`、`linux/flutter/generated_plugins.cmake`、`windows/flutter/generated_plugins.cmake` | `flutter pub get` 自动更新（新插件注册） |
| `lib/services/question_export_service.dart`（新增） | 导出服务：读切片字节、复制到剪贴板、另存为对话框、写盘、RepaintBoundary 转 PNG、文件名清理；两个外部边界（剪贴板写、另存为对话框）可注入 |
| `lib/widgets/question_share_card.dart`（新增） | 分享卡片 widget：题目图在上、答案/解析在下，带学科/文件夹/错因小字；空答案/解析显示“待补充” |
| `lib/modules/detail/question_detail_page.dart` | 底部操作区加三个按钮（复制图片 / 保存图片 / 导出带答案版，与收藏/归档/删除并列）；新增 `_copyImage`、`_saveImage`、`_exportShareCard` 与 `_ShareCardExportDialog` 预览弹窗；另含 B11-11 顺手活（见下） |
| `lib/app.dart` | `_openDetail` 给详情页接 `onGoReview: () => _goReview()`（B11-11 顺手活） |
| `test/b11_8_export_image_test.dart`（新增） | 17 个测试（见“测试结果”） |
| `docs/ui-replication/shots/b11-detail/`（新增，不推 GitHub） | 三张留样截图（见“截图”） |

未碰其他 worker 的主文件；未改 `docs/decision-log.md`（决策见下，协调员统一记 D-25+）。

## 三个动作的行为

入口都在详情页底部操作卡片里，顺序：返回 / 收藏 / 归档 / **复制图片 / 保存图片 / 导出带答案版** / 上一题 / 下一题 / 删除。三个动作共用同一份切片字节（`question.slicePath` 指向的 PNG 文件，由 `QuestionExportService.sliceBytes` 读）。

- **(a) 复制图片**：读切片 PNG → super_clipboard 写 PNG → 提示“图片已复制到剪贴板”。失败（剪贴板不可用）提示“复制失败：当前环境不支持复制图片”，不抛错。
- **(b) 保存图片**：file_picker 另存为对话框（默认文件名 `〈题名〉.png`）→ 服务自己写盘（桌面端 file_picker 只返回路径、不写文件，与设置页备份的 B4.2 同款做法）→ 提示“题目图片已保存”；取消不做任何事；写盘失败提示“图片没存上，换个位置再试一次”。
- **(c) 导出带答案版**：先弹预览框（标题“导出带答案版”），框里是 `QuestionShareCard`（RepaintBoundary 包着）：小字行 `学科 ｜ 文件夹 ｜ 错因`、题名、题目图（满卡片宽、等比）、分隔线、“答案 / 解析”两行、页脚 `quiz-master2 错题本`。框里点“保存图片”→ boundary 按 pixelRatio 2.0 转 PNG（卡片宽 720 逻辑像素 → 约 1440px）→ 另存为对话框（默认 `〈题名〉-带答案.png`）→ 写盘提示“带答案版已保存”。答案/解析为空时卡片该区显示“待补充”，不编造内容；生成失败留在弹窗里提示“分享卡片生成失败，请重试”，不关弹窗。
- **无图时**：三个动作都只提示“这道题没有图片可导出”。v1 演示库的 9 道题都没有 `slicePath`（只有 `sliceText` 占位），所以在演示库上三个按钮点下去都是这句提示——这是符合预期的，不是 bug；真实导入的题才有切片文件。
- 文件名清理：题名里的 `\ / : * ? " < > |` 换成下划线，空题名回退 `question`。
- 卡片跟随当前主题（DesignTokens，不新增颜色）；深色主题下导出的卡片也是深色底。

## 决策（请协调员记 D-25+）

### D-25（候选）：剪贴板图片用 super_clipboard ^0.9.1，可行，Windows 下可用

- **结论**：Windows 下复制图片可行，不只做保存。Flutter 自带 `Clipboard` 只支持文本，图片必须走插件。
- **依据**（2026-11-15 查 pub.dev，super_clipboard 最新稳定版 0.9.1，Min Dart SDK 3.0）：
  - 官方 README 明确写：支持 Windows + Linux 等平台；写 PNG 时“On Windows PNGs are on-demand converted to DIB and DIBv5 formats, which is what native applications expect”——即 Windows 原生应用（微信、Word、画图等）粘贴时拿到的是标准 DIB/DIBv5 位图；`Formats.png` 的文档注释也写了 DIBv5 保留透明通道。
  - 用法就是 `SystemClipboard.instance`（不可用时为 null）+ `DataWriterItem` + `item.add(Formats.png(bytes))` + `clipboard.write([item])`，本实现即按此写。
  - 与 Dart 3.13.7 / Flutter 3.47.9 兼容（SDK 下限 3.0）；`flutter pub get` 无冲突；Linux Debug 构建已通过。
- **代价与 caveat**：
  - Rust 内核：未装 Rust 时构建自动下载对应平台的预编译二进制——Windows 上 `flutter build windows` 首次构建需要联网下载；README 仍称插件“very early stages…experimental”。
  - 备选 `clipboard` 包（^3.0.11，平台通道 + Windows GDI+）未采用：它只声明 Android / iOS / Web / Windows，不支持 Linux（开发机是 Linux，测试与构建都受影响），且是单人维护包；super_clipboard 由 superlist 维护、支持 Linux，长期更稳。
- **验证边界**（如实说明）：
  - 测到了：服务层复制成功/失败分支（注入 writer 的单测）；Linux Debug 构建通过（含该插件的原生层编译链接）。
  - 没测到：Windows 真机粘贴（必须 Win11 实测，见“Win11 待验项”）；Linux 测试环境下**没有**调真实 super_clipboard 写——本轮实测：带真实写的探针让 `flutter_tester` 空转挂起（6 分钟无输出，只得杀掉重跑），原因是无显示服务时原生写调用阻塞。测试文件里已把该探针删掉并写明原因。

### D-26（候选）：分享卡片先预览、再保存，不直接静默落盘

- 点“导出带答案版”先弹预览框，用户确认后再走另存为；不提供“直接保存到默认位置”的静默路径（与保存图片的另存为体验一致）。

## B11-11 顺手活（已做，不是“未接”）

`question_detail_page.dart:2112` 附近复习记录空状态“暂无复习记录，去复习页练一次会出现在这里”原是纯文字，现已接线：

- 详情页新增可选回调 `VoidCallback? onGoReview`（可选，不传不显示按钮，旧测试构造零改动）；空状态文案不变，下面多一个小按钮“去复习”。
- `app.dart` 的 `_openDetail` 已接 `onGoReview: () => _goReview()`，与其他页（首页/整理/报告/错题本）同款接法，点后去 `/review`。
- 测试 2 个（有回调：按钮出现、点后回调触发；无回调：只有文字、没有按钮），均通过。

## 测试结果

只跑新增/相关文件（串行，`--concurrency=1`，默认 `/tmp`，`LD_LIBRARY_PATH` 按任务要求）：

- `test/b11_8_export_image_test.dart`：**17/17 通过**（两次完整运行通过；中间一次运行因机器拥挤出现 1 个“界面未稳定”抖动，见下）。
- `test/detail_page_test.dart`（既有相关文件）：**37/37 通过**。
- `flutter analyze`（5 个改动文件）：**0 问题**。
- `flutter build linux --debug`：**通过**（`✓ Built build/linux/x64/debug/bundle/quiz_master2`）。

17 个测试分组：服务层 3（切片读取有图/无图/缺文件、safeFileName、复制成功/失败注入 writer）· 详情页三个按钮 6（并列、复制成功/失败、保存落盘且字节与切片一致、取消不写文件、无切片题三动作提示）· 导出带答案版 3（弹窗预览内容、弹窗保存落盘、空答案两处“待补充”）· B11-11 去复习按钮 2 · 分享卡片真实渲染 2（RepaintBoundary → PNG 签名正确、2.0 倍率下宽 1440px；空答案卡片同样可转）· 留样截图 1（生成三张 PNG）。

测试方法论（本轮踩到的两个坑，留给后来人）：

1. **testWidgets 是 fake async 区**：真实文件 IO（`readAsBytes` / `writeAsBytes`）在测试体内直接 await 会永远卡死。本文件沿用仓库惯用法：点按后用 `_pumpUntil`（b8_1 的同款 helper：pump → 检查条件 → `runAsync` 切回真实异步等 100ms → 再 pump）等结果出现；文件内容断言用同步 `readAsBytesSync` / `writeAsBytesSync`；截图写盘同样用同步写。
2. **等提示、不要只等中间状态**：曾用“文件已存在”作等待条件，读到过写一半的文件（文件创建在写盘开始时）；改成等“已保存”提示出现（提示只在写盘完成后才发）后稳定。`_pumpUntil` 轮数放宽到 60——多 worker 并行跑测试时本机很挤，30 轮曾出现过一次超时抖动。

## 截图

`docs/ui-replication/shots/b11-detail/`（不推 GitHub；测试文件里“留样截图”一组生成，flutter_test 的测试字体无中文字形，所以中文显示为方框，只看版式）：

- `01-detail-actions.png`（1280×720）：详情页底部操作区，9 个按钮一排——返回错题本 / ☆ 收藏 / 归档 / 复制图片 / 保存图片 / 导出带答案版 / 上一题（置灰）/ 下一题 / 删除。
- `02-share-card.png`（1440×1472）：带答案版分享卡片（有答案）：小字行 + 题名 + 满宽题目图 + 答案“1” + 解析。
- `03-share-card-empty-answer.png`（1440×1472）：同上，答案/解析为空，两处均为 muted 色“待补充”。

## Win11 待验项（须真机）

1. **复制图片真机粘贴**：在 Win11 上打开一道真实导入的题（有切片），点“复制图片”，分别粘贴到微信聊天框、Word、画图里，确认图片能贴出（super_clipboard 应转 DIB/DIBv5；若某应用贴不出，记下是哪个应用）。
2. **保存图片 / 带答案版另存为**：Win11 上走一遍 file_picker 对话框与写盘，确认默认文件名与 PNG 内容无误。
3. **首次 `flutter build windows`**：确认 super_clipboard 的预编译二进制能正常下载（需联网）；若构建机无网，须先装 Rust 再构建。
4. **B11-11 去复习按钮**：Win11 上在无复习记录的题点“去复习”，确认跳到复习页。
5. 深色主题下导出的分享卡片是深色底——如 Meng 觉得分享图应该是固定浅色纸面，再改。

## 其他说明

- 演示库未动：全程测试只用临时目录（`AppDatabase.testDataDirectory` 指向临时目录）；跑前备份 `~/workspace/demo-db-backup/quiz-master2.db.b11-w4`，跑完校验 md5 仍为 `8f7f9c64405dc6e484ac2bf8e5e1a807`，与备份一致。
- 未跑应用（不需要：截图由 widget 测试生成；未删演示库）。
- 未 commit、未 push；只用只读 git 命令。
