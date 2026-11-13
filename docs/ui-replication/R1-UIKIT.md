# R1 UI Kit — 公共组件库

> 阶段：R1（UI Kit）。新增 `lib/widgets/uikit.dart` + `test/uikit_test.dart`；
> 九个页面文件一个字未动，`lib/models` / `lib/data` / `lib/services` 未动，
> 未升级依赖、未改 `pubspec.lock`、未 commit、未 push。
> 视觉基准 SHA256 已核对一致：交互原型
> `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`。

## 1. 组件清单

| 组件 | API 入口 | HTML 来源（选择器 / 类名） | 用途页 |
|---|---|---|---|
| `QmButton` | `QmButton(label, onPressed, variant, size, leadingGlyph, trailingGlyph, block)` | `.btn` / `.btn.primary` / `.btn.small` / `.org-confirm-big` / `.rev-wrap .btn:not(.primary)` | 全部页 |
| `QmChip` | `QmChip(label, selected, onTap, onDelete, subjectId)`；预置标签 `QmChip.presetTags` | `.chip` / `.fchip` / `.err-sel-chip` | 整理、错题本、详情 |
| `QmSegmented<T>` | `QmSegmented(options, value, onChanged)` + `QmSegmentOption(value, label)` | `.seg` | 设置（主题/字体）、错题本视图切换 |
| `QmStatusPill` | `QmStatusPill.cause(status)` / `QmStatusPill.tone(label, tone)` / `QmStatusPill(label, background, foreground)` | `.status` / `.pill`；`causePill()`、`detailCauseStatus()` | 复习、错题本、详情 |
| `QmBanner` | `QmBanner(tone, message, title, actions, onDismiss, dismissLabel)` + `QmBannerAction(label, onPressed)` | `.banner` / `.banner.err` / `.banner.warn`；info 档取 `.mode-banner` | 首页、收集、详情 |
| `QmEmptyState` | `QmEmptyState(title, description, actionLabel, onAction, companionSize)` | `.empty` / `.empty .et`；`emptyBox()` | 全部空状态页 |
| `QmRowLine` | `QmRowLine(kind)`（`line` / `paper`） | `.kv` / `.mgrow`（`1px dashed var(--line)`）；`.nb-prow` / `.nb-toc-row`（`1px dashed var(--paper-line)`） | 错题本目录/列表、复习、报告 |
| `QmFoldSection` | `QmFoldSection(title, subtitle, expanded, onToggle, child, variant)` | `.set-group-head` / `.org-sec-head` / `.dt-fold-head` | 设置、学科管理、整理、详情 |
| `QmGlyph` / `QmGlyphs` | `QmGlyph(QmGlyphs.back)` 等 | 原型实际用到的符号：`← ＋ × ✓ › ▾ ▸` | 导航、按钮、折叠箭头 |

`QmButtonVariant`：`primary` 主按钮、`secondary` 次按钮（白底蓝字细蓝边）、
`plain` 普通按钮（HTML `.btn` 默认态：surface 底 + ink 字 + line-strong 边）、
`danger` 危险按钮、`ghost` 幽灵/文字按钮。
`QmButtonSize`：`small`（13px 字、6×14 内边距、最小高 34）、`regular`
（14px 字、9×20 内边距、最小高 40）、`large`（整理台底部全宽确认：
17.5px/800 字、16×20 内边距、最小高 56、圆角 14）。
`QmCauseStatus`：`pending` 待解决 / `inProgress` 解决中 / `solved` 已解决 /
`recheck` 复查。`QmTone`：`warn` / `error` / `info`。
`QmFoldVariant`：`group`（设置五组 / 学科管理四组）、`form`（整理表单五段）、
`detail`（详情三段）。

## 2. Token 来源（逐组件）

颜色、圆角、间距全部取自 `DesignTokens`；字号基准值见 `DesignTokens`
（正文 15 / `bodySmall` 13.5 / `caption` 12.5），其余为 HTML 实读值，
集中列在 `uikit.dart` 的 `_Html` 里（见 §7）。

- **QmButton**：主按钮亮色 accent `#2E7CF6` + accent-ink 白字，深色 accent
  `#7FA8D0` + accent-ink `#131A24` 深字；圆角 `buttonRadius` 10；
  次按钮 surface 底 + accent-text 字 + accent 1px 边，悬停 accent-soft；
  普通按钮 surface 底 + ink 字 + line-strong 边，悬停 surface-2；
  危险按钮 surface 底 + err-ink 字 + err-line 边，悬停 err-bg
  （HTML 整理台批量删除按钮行内样式）；幽灵按钮无底无边 + accent-text 字，
  悬停 accent-soft。Hover 主按钮提亮 7%（HTML `.btn.primary:hover` 的
  `filter:brightness(1.07)`，用 `Color.lerp(accent, white, 0.07)` 实现）；
  Pressed 主按钮加深 10%；Focus 2px accent 描边（HTML `:focus-visible`）；
  Disabled opacity .45（HTML `.btn:disabled`）。
- **QmChip**：未选中 surface 底 + line-strong 边 + ink-2 字；选中 accent 填充 +
  accent-ink 字（HTML `.chip[aria-pressed="true"]`），选中带 `✓` 前缀；
  传 `subjectId` 时选中填充改用学科色（`DesignTokens.subjectColor`），
  深色下选中字色为 `#1E2228`（HTML 深色 `.fchip.subj-*[aria-pressed="true"]`
  的字色规则，即深色底色）；可删除芯片为 `.err-sel-chip` 形态
  （accent-soft 底 + accent 边 + accent-text 字 + ` ✕`，悬停 err 系）；
  预置标签 `易错 / 常考 / 需重做`（HTML 整理台标签栏）。
- **QmSegmented**：外框 line-strong 边 + 999 圆角 + surface 底；未选中段
  muted 字（600），悬停 surface-2；选中段 accent 填充 + accent-ink 字。
- **QmStatusPill**：999 圆角、12px/700 字、`padding:1px 9px`（HTML `.pill` /
  `.status`）；错因映射与 HTML `causePill()` 一致——待解决 warn 系
  （`.status.todo`）、解决中 info 系（`.status.doing`）、已解决 accent-soft 系
  （`.status.done`）、复查 err 系（`.status.fail`）；tone 三档取同名 token。
- **QmBanner**：radius 12、padding 12×16、14px 字、下边距 18；
  err（err-bg/err-ink/err-line）、warn（warn-bg/warn-ink/warn-line）；
  info 档 HTML 没有 `.banner.info` 类，取 `.mode-banner` 的
  info-bg / info-ink + accent 边（1.5px）；右侧按钮 currentColor 细边、
  radius 10、padding 4×14、13px/700（HTML `.banner button`）；
  图标 `⚠`（err/warn）/ `ℹ`（info）为文字符号。
- **QmEmptyState**：1.5px 虚线 line-strong 边、radius-lg 16、padding 52×30、
  居中；标题 17px/700 ink-2；说明 14px muted；小伙伴用 `app_theme.dart` 已有
  的 `CompanionWidget`（不重画）；CTA 为 `QmButton` 主按钮。与 `widgets.dart`
  的 `EmptyState`（无边框简化版）不同，本组件是 HTML 忠实形态，供 R2 各页替换。
- **QmRowLine**：1px 虚线（4px 实线 + 3px 间隔，画法与 `widgets.dart` 的
  `DashedDivider` 一致）；`line` 档取 `line` 色，`paper` 档取 `paper-line` 色。
- **QmFoldSection**：group 形态（`.set-group-head`：surface-2 头底、16.5px/800
  标题、13×18 内边距、最小高 48、悬停 surface-3、箭头 `▾ 收起` / `▸ 展开`）；
  form 形态（`.org-sec-head`：14.5px/800 标题、11×16 内边距、最小高 44）；
  detail 形态（`.dt-fold-head`：无头底、15px/800 标题、箭头只有 `▾` / `▸`）。
  一次只开一段的互斥逻辑由调用方控制，组件只提供展开态与 `onToggle` 回调。
- **QmGlyph**：文字符号（D3，不用图标字体）：`← ＋ × ✓ › ▾ ▸ ▴ ⚠ ℹ ★ ⠿`
  （`⠿` 为错题本目录页拖拽柄 `.nb-toc-drag` 的符号）。全库无 `Icon`，
  测试断言覆盖（`find.byType(Icon)` 为空）。

## 3. 亮 / 深与三档缩放覆盖

- **亮/深**：全部组件只读 `DesignTokens.of(Theme.of(context).brightness)`，
  无写死色值；测试覆盖亮/深两套（主按钮、次按钮、芯片学科色、药丸、横幅）。
- **三档缩放（D4）**：缩放因子唯一来源是 `qmScaleOf(context)`——从
  `MediaQuery.textScaler` 读出 app.dart 全局乘过的同一因子（标准 1.00 /
  大 1.15 / 特大 1.30）；字号只写基准值，由 TextScaler 全局缩放一次，
  组件内不乘字号；布局尺寸（内边距 / 最小高 / 圆角 / 间距）用 `ScaledTokens`
  按同一因子乘一次。不用 `Transform.scale`，不重复缩放。测试断言：
  1.15/1.30 下按钮高度按因子放大、字号样式值仍是基准值（14）。
- **单行控件行高**：按钮 / 芯片 / 分段 / 折叠头文字显式 `height: 1.2`
  （HTML 单行控件的 `line-height: normal` 等效值）；否则 Flutter 会从
  `DefaultTextStyle` 继承正文 1.65，按钮比 HTML 高约 6px。横幅正文、
  空状态说明保持 1.65 正文行高；药丸保持继承行高（总高 ≈ HTML `.pill`
  的 22px 行高）。

## 4. 交互状态实现

`_QmPressable`（`uikit.dart` 内部）统一提供四态：MouseRegion 悬停、
Focus 节点（Enter / Space 键触发）、GestureDetector 按压、Disabled
（`onTap == null` 时外包 Opacity .45 且不可点、不可聚焦、鼠标为默认箭头）。
焦点描边平时透明、聚焦时 2px accent，不占布局、不抖动。
`QmSegmented` 整体 Disabled（`onChanged == null`）时同样 opacity .45。

## 5. 测试结果

- `flutter analyze`：**No issues found!**
- `flutter test`：**38/38 通过**（`test/theme_smoke_test.dart` 8 个 +
  `test/uikit_test.dart` 30 个）。
- `test/uikit_test.dart` 覆盖：亮/深主按钮与次按钮色值、危险/幽灵/普通按钮、
  小/大按钮尺寸、Hover（鼠标手势触发，断言提亮 7% 色值）、Focus
  （`FocusNode.requestFocus`，断言 2px accent 描边出现/消失）、Pressed
  （按住断言加深 10%、松开断言恢复并触发回调）、Disabled（opacity .45、
  点按无回调）、键盘 Enter 触发、三档缩放（1.15/1.30 高度按因子放大、
  字号不重复缩放）、芯片选中/学科色/可删除/预置标签、分段切换与 Disabled、
  药丸四态与三色（亮/深）、横幅三档/关闭/操作按钮、空状态（小伙伴+标题+
  说明+CTA）、分隔线、折叠段三形态与展开切换、文字符号且库内无 `Icon`。

## 6. 截图验证（Xvfb 1280×720 真实窗口，Release 产物）

临时展示入口 `lib/showcase_main.dart`（`--dart-define` 切亮/深与上/下半页），
验证完已删除，不在最终代码里；截图后已重新 `flutter build linux --release`
恢复真实应用产物。

| 截图 | 内容 | 路径 |
|---|---|---|
| 亮色上半页 | 按钮、芯片、分段、药丸、横幅、空状态、折叠段 | `docs/ui-replication/shots/r1-uikit/light-uikit.png` |
| 深色上半页 | 同上，深色 | `docs/ui-replication/shots/r1-uikit/dark-uikit.png` |
| 亮色下半页 | 横幅操作/关闭、分隔线、文字符号、三档缩放对照 | `docs/ui-replication/shots/r1-uikit/light-uikit-bottom.png` |
| 深色下半页 | 同上，深色 | `docs/ui-replication/shots/r1-uikit/dark-uikit-bottom.png` |

并排对照结论（与 HTML 原型对应组件形态比对）：

- 按钮：亮色主按钮 `#2E7CF6` 白字、深色 `#7FA8D0` 深字，与 HTML 一致；
  次按钮白底蓝字细蓝边、危险按钮红字红边、幽灵按钮无底无边、禁用态置灰，
  均与 HTML 一致；大按钮全宽 17.5px/800 字形态与 `.org-confirm-big` 一致。
- 芯片：未选中浅底细边、选中 accent 填充带 `✓`、学科芯片选中用学科色
  （深色下数学 `#87A9CC` + 深字），与 HTML 一致；可删除芯片 accent-soft 底
  + `×`，与 `.err-sel-chip` 一致。
- 分段控件：圆角 999 外框、选中段 accent 填充，与 `.seg` 一致。
- 状态药丸：待解决黄底、解决中蓝底、已解决浅蓝底、复查红底，与 HTML
  `.status` 四档一致。
- 横幅：红/黄/蓝三档底色与边框、右侧细边按钮，与 `.banner` 一致；
  info 档取 `.mode-banner` 形态（HTML 无 `.banner.info` 类，见 §7）。
- 空状态：虚线圆角框 + 小伙伴 + 标题 + 说明 + 主按钮 CTA，与 `.empty` 一致。
- 折叠段：group 段 surface-2 头底 + `▾ 收起` / `▸ 展开`、form 段、
  detail 段无头底 + 纯箭头，与三处 HTML 折叠头一致。
- 三档缩放：1.00/1.15/1.30 三行并排，按钮/芯片/药丸/分段同步放大，
  无错位、无截断。

## 7. 未解决问题 / 待裁决

1. **HTML 实读字号/间距暂无 DesignTokens 对应项**（`uikit.dart` 的 `_Html`
   集中列出，每项注明 HTML 来源，供 R2 收进 token）：按钮字 14px /
   小按钮 13px / 大按钮 17.5px、芯片 13px、分段 14px、横幅 14px、药丸 12px、
   空状态标题 17px、折叠头 16.5px/14.5px、大按钮圆角 14px（=(12+16)/2）、
   各内边距（9×20、6×14、16×20、5×14、4×12、7×18、12×16、52×30）、
   单行控件行高 1.2。组件未因此改用 token 近似值（如 13.5/15），而是忠实
   HTML 值并集中标注；是否收入 `DesignTokens` 请负责人 / R2 定夺。
2. **info 横幅无 HTML `.banner.info` 类**：info 档取 `.mode-banner`
   （info-bg / info-ink + 1.5px accent 边），已在 §2 注明；如负责人希望
   info 横幅用 1px 边框或另定形态，请裁决。
3. **危险按钮无 HTML 专属类**：取整理台批量删除按钮的行内样式
   （surface 底 + err-ink 字 + err-line 边，悬停 err-bg）；删除确认框的主
   按钮在 HTML 里仍是 accent 主按钮（`.btn primary`），调用方按场景选择。
4. **学科色与封面色**：本文件只用学科色（圆点/数字/标签），未碰封面色
   （`CoverTokens`，错题本封面用，R2 接入）。
5. **Linux 结果不替代 Win11 最终验收**：Segoe UI / Microsoft YaHei /
   Georgia 字体显示、窗口尺寸、DPI 须 Win11 真机复核；Xvfb 下字体为
   Linux 系统回退。
6. **`widgets.dart` 未动**：其中 `EmptyState`（无边框简化版）、`InfoChip`、
   `DashedDivider` 与本库的 `QmEmptyState` / `QmChip` / `QmRowLine`
   并存；R2 各页接入 UI Kit 时再统一收口（R1 不重构它）。
