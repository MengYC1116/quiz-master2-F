# S8A4：重复/超限黄色横幅——补组件测试 + 截图

## 1. 对象

- 组件：`lib/widgets/uikit.dart` 的 `QmBanner`（约 1218 行起），三档 tone：
  error 红 / warning 黄 / info 蓝；warning 档用 `palette.warnBg` +
  `warnInk` + `warnLine`；支持 title 粗体前导句、actions 并排操作按钮、
  onDismiss「知道了」关闭。
- 两个黄色横幅实例都在 `lib/modules/collect/collect_page.dart` 约 398–430 行：
  (1) 重复文件 warning，标题「这个文件已经导入过。」、操作「仍然再导一份 / 不导了」；
  (2) 超限 warning，标题「文件超过大小上限，只是提示，不直接判失败。」、
  操作「仍然再导一份 / 不导了」（2026-11-13 Meng 定统一，原「仍要导入 / 先不导」，
  见 §6.5）。
- 本次只补测试与截图，未改任何业务代码、文案、口径。

## 2. 口径核对（读代码，未改文案）

| 项目 | 代码现状 | 结论 |
| --- | --- | --- |
| 重复横幅标题 | 「这个文件已经导入过。」（title 粗体） | 与任务描述一致 |
| 重复横幅正文 | 「列表里已有「…」的任务，再导一份会多出一组重复任务。要再导一份吗？」 | 一致 |
| 重复横幅操作 | 「仍然再导一份 / 不导了」 | 一致 |
| 超限横幅标题 | 「文件超过大小上限，只是提示，不直接判失败。」（title 粗体） | 一致 |
| 超限横幅正文 | 「文件较大（25.0MB），超过建议上限 20MB，仍可继续导入。可以先压缩再重新选，也可以仍要导入，大文件检测会慢一些。」（`ImportService.oversizeHint` 生成前半句） | 一致 |
| 超限横幅操作 | **「仍然再导一份 / 不导了」**（2026-11-13 Meng 定统一，原「仍要导入 / 先不导」，见 §6.5） | 与任务描述一致 |
| 关闭行为 | 两处黄色横幅均无 onDismiss（无「知道了」）；点任一操作后 `_pendingImport` 清空；「不导了」整批取消，「仍然再导一份」继续导入 | 与代码一致 |
| 触发条件 | `_pickFiles`：文件名已在当前任务列表 → duplicateNames；`ImportService.oversizeHint`（PDF > 50MB / 图片 > 20MB）非空 → oversizeHints；任一非空即挂起 `_pendingImport` 出横幅 | 与代码一致 |
| R11 §8.3 表述 | 记“组件本身和这两个实例都没有覆盖” | 不完全准确：`test/uikit_test.dart` 已有 QmBanner 基础覆盖（三档亮色、关闭按钮、一个操作按钮、深色 error 一例），本次补齐的是缺口，见 §3 |

## 3. 新增测试：`test/qm_banner_test.dart`（15 个用例）

复用 `uikit_test.dart` 的 `pumpUi` 形态（自带同款 helper：亮/深主题、
`textScaler` 1.00/1.15/1.30）。断言方式：横幅本体取 label 文字最近祖先
Container 的 BoxDecoration（颜色/边框）；文字色取横幅 `Text.rich` 根
TextSpan 的 style（注意：`Text.rich` 会把传入的 span 包成子 span，外层是
DefaultTextStyle 合并后的样式，必须取 `children.first` 才是横幅自己的
span——初版取外层导致文字色断言取到默认 ink 色，已修正）。

| 组 | 用例 | 断言 |
| --- | --- | --- |
| warning 黄底 | 亮色：黄底 #FFF3D1、文字色 warnInk、边框 warnLine | 底色 `0xFFFFF3D1`、文字 `0xFF8A5A00`、边框 `0xFFF0D488`，与 `DesignTokens.light` 一致 |
| warning 黄底 | 深色：黄底按 `DesignTokens.of(dark)` 取，文字色 warnInk | 底色 `0xFF32342C`、文字 `0xFFCFC488`、边框 `0xFF55563F`，与 `DesignTokens.dark` 一致 |
| 标题 + 正文 | 重复横幅：标题粗体前导 + 正文都渲染 | 标题 span `FontWeight.w700`、正文含「要再导一份吗？」 |
| 标题 + 正文 | 超限横幅：标题 + 正文都渲染 | 标题与「超过建议上限 20MB」都出现 |
| 标题 + 正文 | 无标题时只渲染正文 | children 只有 1 个 span |
| 操作按钮 | 重复横幅两操作：仍然再导一份 / 不导了，点按回调都触发 | 两按钮都存在，各点按一次，回调各置 true |
| 操作按钮 | 超限横幅两操作：仍然再导一份 / 不导了，点按回调都触发 | 同上 |
| 操作按钮 | 深色下重复横幅两操作仍可点按 | 深色点按「仍然再导一份」回调触发 |
| 关闭按钮 | 有 onDismiss 时「知道了」出现，点按回调触发 | 出现且回调触发 |
| 关闭按钮 | 无 onDismiss 时不出现「知道了」 | `findsNothing` |
| 关闭按钮 | 深色下「知道了」点按回调触发 | 深色点按回调触发 |
| 三档颜色区分 | 亮色 error 红 / warning 黄 / info 蓝互不相同 | `0xFFFFE9E5` / `0xFFFFF3D1` / `0xFFE1EDFF` |
| 三档颜色区分 | 深色 error / warning / info 三档互不相同 | `0xFF352C31` / `0xFF32342C` / `0xFF2C3949`，与 `DesignTokens.dark` 一致 |
| 大字号不溢出 | 大字号 1.15：两操作长文案横幅 pump 不抛错 | `takeException()` 为 null |
| 大字号不溢出 | 特大字号 1.30：两操作长文案横幅 pump 不抛错 | `takeException()` 为 null |

## 4. 验证结果

- `flutter analyze`：**0 问题**（初版 1 条 info：`design_tokens.dart`
  导入多余，因 `app_theme.dart` 已重导出，已删）。
- `flutter test test/qm_banner_test.dart`：**15/15 通过**。
- `flutter test` 全量：**309/309 通过**（A4 时 307/307；+2 是 A5 新增
  的回归测试 `test/s8a5_section_scroll_test.dart`，见 S8A5 报告）。
- Linux 真机：Release 构建（`flutter build linux --release`，
  产物装到 `/usr/local/quiz_master2`，CMake 安装前缀配置，同 S8A3），
  Xvfb :99、1280×720、xdotool 驱动、ImageMagick `import` 截图。
  两条黄色横幅均用真实导入流程触发，未改业务逻辑：
  - 重复：先导 `math-test-01.png`（真实试卷页，290.7 kB）建任务，再导
    同一文件 → 重复横幅；
  - 超限：导 25.0MB 的 `big-25mb.png`（随机字节，仅用于触发
    `oversizeHint` 的大小判断，未点「仍要导入」，未产生任务）→ 超限横幅。
  - 亮/深各截一张，横幅样式与文案均正确（§5）。
  - 两次验证后应用均用 `pkill -x quiz_master2` 杀掉；两次运行日志无
    Flutter 异常。

## 5. 截图：`docs/ui-replication/shots/s8a4/`

| 文件 | 内容 |
| --- | --- |
| `01-duplicate-light.png` | 亮色重复横幅：浅黄底 `#FFF3D1`、粗体标题「这个文件已经导入过。」、正文含「math-test-01.png」、按钮「仍然再导一份 / 不导了」 |
| `02-oversize-light.png` | 亮色超限横幅：浅黄底、粗体标题「文件超过大小上限，只是提示，不直接判失败。」、正文「文件较大（25.0MB），超过建议上限 20MB……」、按钮「仍然再导一份 / 不导了」（2026-11-13 已替换旧文案图） |
| `03-duplicate-dark.png` | 深色重复横幅：深橄榄底 `#32342C`、淡黄文字、同样标题/正文/两按钮 |
| `04-oversize-dark.png` | 深色超限横幅：深橄榄底、淡黄文字、同样标题/正文（25.0MB）/两按钮「仍然再导一份 / 不导了」（2026-11-13 已替换旧文案图） |
| `05-error-and-nosubject-dark.png` | 附带：深色 error 横幅（导入失败「知道了」）+ 深色「先选学科」warning 横幅同框 |
| `06-nosubject-warning-dark.png` | 附带：深色「先选学科」warning 横幅（第三处 warning 实例）+ 学科下拉菜单 |

## 6. 发现与备注（未改，均记在此）

1. **超限横幅操作按钮文案与任务描述不符（已解决，见 §6.5）**：任务描述称超限横幅“同样两
   操作（仍然再导一份 / 不导了）”，原代码（`collect_page.dart:421–427`）
   是「仍要导入 / 先不导」。2026-11-13 Meng 定统一为「仍然再导一份 / 不导了」，已改。
2. **R11 §8.3 表述不完全准确**：`test/uikit_test.dart` 的 QmBanner 组
   已有基础覆盖（亮色三档色值、关闭按钮、一个操作按钮、深色 error 一例），
   缺的是 warning 深色色值、双操作按钮全覆盖、标题+正文结构、大字号
   不溢出——本次补的正是这些缺口。
3. **验证过程小插曲（已清理）**：GTK 文件选择器里 `xdotool type` 输入
   路径时，输入框自动补全会多出 `p`/`/` 杂字符，首次未核对就回车，
   导致导进一个名为 `math-test-01.pngp` 的失败任务并弹出红色 error 横幅
   （截图 `05-…` 顺带留证：深色 error 横幅样式正确）。后续每次输入后
   都截图核对路径栏、删掉多余字符再回车，未再出错。演示库已从备份恢复，
   该失败任务不存在了（§7）。
4. **深色下横幅可读性**：深色 warning 底 `#32342C` + 文字 `#CFC488`
   对比足够，截图中标题/正文/按钮均清晰；亮/深两档按钮均为细边描边
   按钮（`currentColor` 边），与 HTML 口径一致。

5. **超限横幅按钮文案统一（2026-11-13，Meng 定，已做）**：超限横幅两按钮由
   「仍要导入 / 先不导」改为「仍然再导一份 / 不导了」，与重复横幅一致；
   只改超限那一处，重复横幅未动。`collect_page.dart:422/426` 两处 label +
   同文件 132–133 行注释里的旧文案措辞同步改掉；正文 prose 里的“也可以仍要导入”
   （`collect_page.dart:419` 与测试里的 message 文案）不是按钮，保持原样。
   `test/qm_banner_test.dart` 同步改：文件头注释、超限两操作用例名与 label
   断言、特大字号用例的 label（message 文案未动）。
   - **改文案牵出的布局问题**：新文案「仍然再导一份」比旧文案长 2 字，特大字号
     1.30 + 320px 宽下横幅 Row 溢出 18px（`qm_banner_test.dart` 特大字号用例
     失败）。根因是 Row 给非 flex 子节点无限宽约束，按钮区的 Wrap 在 Row 里
     永远不换行。修法在 `QmBanner`（`uikit.dart`）：`LayoutBuilder` 实测
     （TextPainter 量按钮文本宽）一行能否放下图标 + 按钮 + 至少 48px 正文；
     放得下走旧 Row 布局（常规宽度外观与原来完全一致），放不下改走上下两行
     （正文在上、按钮另起一行右对齐，Column 给紧宽度约束，Wrap 才能正常换行）。
     HTML `.banner` 是不换行的 flex，窄到 320px 同样会溢出；本修法只在 HTML
     也会溢出的宽度下换行，常规宽度无变化。应用无最小窗口限制（默认 1280×720），
     窗口缩到约 550px 以下 + 特大字号时旧代码在真机上也会溢出，本修法一并兜住。
   - 验证：`flutter analyze` 0 问题；`test/qm_banner_test.dart` 15/15；
     全量 `flutter test` 309/309（含 A5 回归测试 2 个用例，见 S8A5 报告）。
     Linux 真机重截超限横幅亮/深各一张（`02-`/`04-`，文件名不变，内容已替换），
     均一行新文案按钮；亮/深两次均用真实导入流程触发（25.0MB `big-25mb.png`，
     未点「仍然再导一份」，点「不导了」丢弃，未产生任务），演示库已从备份恢复
     （9 道题、3 学科、`collect_tasks` 0 条、`themeMode=dark`、`fontSize=standard`）。

## 7. 演示库恢复核对

- 验证前备份到 `/tmp/qm2-s8a4-orig.db`；验证后从备份恢复并核对：
  9 道题、3 学科、`collect_tasks` 0 条、`themeMode=dark`、
  `fontSize=standard`。验证中途曾用 SQL 把 `themeMode` 改为 light 跑
  亮色截图，恢复时一并还原。
- 验证用临时文件在 `/tmp/s8a4/`（`math-test-01.png`、`big-25mb.png`），
  未进工程目录；`/tmp` 截图原片与过程截图保留在 `/tmp/s8a4/`。

## 8. 改动清单（未 commit、未 push）

- `test/qm_banner_test.dart`：新建，15 个用例（§3）。
- `docs/ui-replication/S8A4-BANNER-REPORT.md`：本报告。
- `docs/ui-replication/shots/s8a4/`：验证截图 6 张（§5）。
- 2026-11-13 文案统一追加改动（§6.5，未 commit、未 push）：
  `lib/modules/collect/collect_page.dart`（超限两按钮 label + 注释措辞）、
  `lib/widgets/uikit.dart`（`QmBanner` 窄宽换行，`_bannerFitsOneLine`）、
  `test/qm_banner_test.dart`（超限 label 断言）、`shots/s8a4/02-`/`04-`（重截替换）。
- 未动其他文件；工作区其余未提交改动均为开工前已有的其他工人改动，
  本次未碰。
