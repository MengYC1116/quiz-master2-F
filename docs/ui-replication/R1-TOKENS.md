# R1 Token 规范 — Design Tokens 与亮 / 深 Theme

> 阶段：R1（Token + Theme）。只改 `lib/theme/`、缩放接线（`lib/app.dart`、
> `lib/models/models.dart` 的 token 值）与本文档；九个页面主体未动，
> 数据库 / Repository / 业务语义未动，未 commit、未 push。
> 视觉基准 SHA256 已核对一致：
> - 交互原型 `quiz-master2-jiao-hu-yuan-xing.html`：
>   `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`
> - 完整预览 `quiz-master2-quan-xin-she-ji-yu-lan.html`：
>   `fe4a8e2630cc122f2587a4f147f6fb00f41b00874356692f1b1da1122a69fe86`
> - 两份文件 `:root` / 深色 `@media` 的 token 逐行相同（前 70 行 diff 仅标题不同）。

## 1. 文件与 API

| 文件 | 内容 |
|---|---|
| `lib/theme/design_tokens.dart`（新增） | 唯一事实来源：`AppPalette`（亮 / 深各一套）、`DesignTokens`（颜色 / 字体 / 圆角 / 间距 / 布局）、`FontScale`（缩放档位）、`ScaledTokens`（缩放后的布局 token）、`CoverTokens`（封面色 + 6 样式） |
| `lib/theme/app_theme.dart`（重写） | `AppTheme.light({scale})` / `dark({scale})` / `themeFor(...)` 两套 `ThemeData`；旧公共常量名全部保留、值已修正（页面零改动）；`PaperDots` / `CompanionWidget` 只做 token 化，行为不变 |
| `lib/models/models.dart`（只改 token 值） | `Subject` 三科色、`CoverColors.hex` 4 个值、`AppSettings.fontScale` 映射 1.00/1.15/1.30；存储结构与业务语义未变 |
| `lib/app.dart`（只改主题接线） | 缩放因子改走 `_settings.fontScale`（删掉写死的 1.12/1.25 三元式），`AppTheme.light(scale:)` / `dark(scale:)`；`MediaQuery TextScaler` 保留为字号唯一缩放点 |
| `test/theme_smoke_test.dart`（补全 TODO） | 8 个测试：浅 / 深 token 对照 HTML、深色主按钮、缩放三档、学科色与封面色分离、字体 token；全部通过 |

使用约定：

- 颜色只从 `DesignTokens.light` / `DesignTokens.dark`（或 `DesignTokens.of(brightness)`）取；新代码不要再加 `AppTheme` 常量，不要在页面里写死色值。
- `AppTheme` 里的旧常量是兼容转发（页面一直在用，R1 不动页面）。注意：Dart 的 const 表达式不能跨类取 const 对象的实例字段，所以这批常量写的是与 `DesignTokens` 逐项对应的字面值，改值时两处同步（见 §2 对照表）。
- 学科色与封面色分离（D6）：学科色用 `DesignTokens.subjectColor(id, brightness)`（圆点 / 数字 / 标签）；封面色用 `CoverTokens.of(key)`（错题本封面）。封面蓝 `#2F7CF6` 与学科蓝 `#2E7CF6` 不是同一个值，不要合并。
- 字号缩放（D4）：唯一映射 `FontScale.factorFor`（与 `AppSettings.fontScale` 一致）。字号只在 `app.dart` 的 `MediaQuery TextScaler` 处乘一次；`ThemeData` 的 `TextTheme` 取基准值、不乘；布局类尺寸（圆角 / 间距 / 按钮尺寸）由 `ScaledTokens` / `AppTheme.light(scale:)` 按同一因子缩放。不得重复缩放，不准用整页 `Transform.scale`。
- 字体（D2）：不打包字体。`fontFamily: 'Segoe UI'`，`fontFamilyFallback: ['Microsoft YaHei', 'PingFang SC']`；衬线 `Georgia`（fallback `Songti SC` / `SimSun`）只用于纸面 / 数字需要衬线处。Linux 上字体以系统回退为准，不宣称已验证 Win11 字体效果。

## 2. 颜色 Token 对照表

HTML 来源：浅色 `:root`，深色 `@media (prefers-color-scheme: dark)`（与 `:root[data-theme="dark"]` 相同）。“R0 旧值”指 R1 前代码里的值。

### 2.1 基础

| token | 浅色 | 深色 | HTML 来源 | R0 旧值 → 差异 |
|---|---|---|---|---|
| `--bg` | #FDF8EC | #1E2228 | `:root` / dark | 与旧值一致 |
| `--surface` | #FFFEF9 | #262B33 | 同上 | 与旧值一致 |
| `--surface-2` | #FDF3D8 | #21262E | 同上 | 旧代码只有导航底用过，未成 token；现为正式 token |
| `--surface-3` | #F3E9C8 | #333A45 | 同上 | 旧代码无此 token（深色 `darkElevated` #333A45 碰巧一致）；新增 |
| `--ink` | #17233B | #E9EDF3 | 同上 | 与旧值一致 |
| `--ink-2` | #3D4E6B | #C6CEDA | 同上 | 旧代码无此 token；新增 |
| `--muted` | #5F718E | #97A2B2 | 同上 | 浅色旧值 #5B6B84 → **#5F718E**（修正） |
| `--line` | #E8DFC2 | #333B47 | 同上 | 与旧值一致 |
| `--line-strong` | #CFC39E | #485364 | 同上 | 与旧值一致 |
| `--accent` | #2E7CF6 | #7FA8D0 | 同上 | 浅色旧值 #2F7CF6 → **#2E7CF6**（1 位差修正）；深色旧值 #8AB6FF → **#7FA8D0**（冷雾蓝修正） |
| `--accent-soft` | #E1EDFF | #2C3949 | 同上 | 与旧值一致（旧名 `lightFocusCard` / `darkFocusCard`） |
| `--accent-ink` | #FFFFFF | #131A24 | 同上 | 旧代码无此 token；新增。深色主按钮文字用 #131A24（深字），不再是白字 |
| `--accent-text` | #175CD3 | #A9C6E4 | 同上 | 与旧值一致 |
| `--radius` / `--radius-lg` | 12 / 16 | 12 / 16 | 同上 | `--radius-lg` 旧代码无 token；新增。按钮圆角 10 仍是代码现有值（HTML 无 `:root` 项） |
| `--shadow` | 0 2px 6px rgba(23,35,59,.05), 0 14px 34px rgba(23,35,59,.09) | 0 2px 6px rgba(0,0,0,.35), 0 14px 34px rgba(0,0,0,.30) | 同上 | 旧代码全部 `elevation: 0`、无阴影 token；现为 `AppPalette.shadow`（`List<BoxShadow>`），页面在 R2 接入前暂不改变外观 |

### 2.2 状态色（旧代码全部缺失，新增）

| token | 浅色 | 深色 | 用途 |
|---|---|---|---|
| `--warn-bg` / `--warn-ink` / `--warn-line` | #FFF3D1 / #8A5A00 / #F0D488 | #32342C / #CFC488 / #55563F | 黄色提示横幅（重复文件 / 超限 / 已归档提示等） |
| `--err-bg` / `--err-ink` / `--err-line` | #FFE9E5 / #B42318 / #F5B8AE | #352C31 / #D2A3AC / #59424A | 红色错误横幅 |
| `--info-bg` / `--info-ink` | #E1EDFF / #175CD3 | #2C3949 / #A9C6E4 | 蓝色信息横幅（HTML 无 `--info-line`） |
| `--keep` / `--merge` / `--cut` | #0E9F6E / #B97A0A / #D93A2B | #8FB8A4 / #B4AC8E / #C08A94 | 修框：保留 / 合并 / 裁掉 |

### 2.3 纸面（负责人已确认，以 HTML 为准）

| token | 浅色 | 深色 | HTML 来源 | R0 旧值 → 差异 |
|---|---|---|---|---|
| `--paper` | #FFFDF4 | **#D8DCE2** | `:root` / dark | 深色旧值 #262B33（冷灰）→ **#D8DCE2（浅灰纸）**。深色下打开的书仍是浅灰纸页，纸面字 #232830、纸面线 #AEB6C2 |
| `--paper-ink` | #22251F | #232830 | 同上 | 旧代码无此 token；新增 |
| `--paper-line` | #E3D9BE | #AEB6C2 | 同上 | 与旧值一致（旧名 `lightPaperLine` / `darkPaperLine`） |

### 2.4 区域色（两层框，旧代码无 token，新增）

| token | 浅色 | 深色 | 用途 |
|---|---|---|---|
| `--stem` | #2E7CF6 | #7FA8D0 | 题干区 |
| `--option` | #00A884 | #8FB8A4 | 选项区 |
| `--figure` | #F97316 | #A79BC0 | 配图区 |

### 2.5 学科色（只用在圆点 / 数字 / 标签）

| 学科 | 浅色（本色） | 深色（冷雾色 `--math/--eng/--pol`） | 深色标签文字色（`--*-ink`） | R0 旧值 → 差异 |
|---|---|---|---|---|
| 数学 | #2E7CF6 | #87A9CC | #ACC8E2 | 浅色旧值 #2F7CF6 → **#2E7CF6**；深色两档与旧值一致（旧 `darkMathMist` 即 `--math-ink` #ACC8E2，保留为兼容常量） |
| 英语 | #00A884 | #8AB5A3 | #AFD2C2 | 浅色旧值 #1F9D66 → **#00A884**；深色与旧值一致 |
| 政治 | #EF4444 | #C295A5 | #D8B4C0 | 浅色旧值 #E0524D → **#EF4444**；深色与旧值一致 |
| 其他（预留） | #64748F（soft #E8EDF5 / ink #47556B） | #9AA5B3（soft #262B33 / ink #C3CBD6） | — | 旧代码无此 token；新增，当前三科不用 |

说明：深色下学科色分两档——基本色（`--math` #87A9CC 等）与标签文字色（`--math-ink` #ACC8E2 等）。HTML 深色 `.subj-label` 用的是 `--*-ink`，所以 `widgets.dart` 的 `subjectLabelColor` 沿用 `-ink` 档（值未变，R1 未动该文件）。`DesignTokens.subjectColor` 返回基本色档，`subjectInk` 返回 `-ink` 档，`subjectSoft` 返回 `--*-soft` 档（浅色 #E1EDFF/#D8F5EB/#FFE7E2，深色统一 #262B33）。

### 2.6 封面色（D6，与学科色分离的独立取值）

| 预设 | 值 | 与学科色关系 |
|---|---|---|
| 蓝 blue | #2F7CF6 | 与学科蓝 #2E7CF6 不是同一个值，不要合并 |
| 绿 green | #1F9D66 | 与英语学科色 #00A884 不同 |
| 红 red | #E0524D | 与政治学科色 #EF4444 不同 |
| 紫 purple | #7C4DDB | 旧代码值 #7C5CFC → **#7C4DDB**（修正） |
| 橙 orange | #ED7D31 | 旧代码值 #F08A1D → **#ED7D31**（修正） |
| 黄 yellow | #D9A404 | 旧代码值 #E8B800 → **#D9A404**（修正） |
| 灰 grey | #64748F | 旧代码值 #8A94A6 → **#64748F**（修正） |

封面 6 样式 token：`plain`（纯色折角）/ `lines`（横线纹）/ `dots`（圆点）/ `grid`（方格纹）/ `diagonal`（斜纹）/ `double`（双线框），key 与 `CoverStyles.all` 一致。存储仍是 subjects 表的 `cover_style` / `cover_color` 字段（不改 Schema）；`models.dart` 的 `CoverColors.hex` 已同步为上表值（与 `CoverTokens.colors` 保持一致，R2 统一收口到一处）。

## 3. 字体 Token

| token | 值 | HTML 来源 |
|---|---|---|
| 字体栈 | `Segoe UI, system-ui, -apple-system, PingFang SC, Microsoft YaHei, sans-serif` | body 字体栈；Flutter 里 `fontFamily: 'Segoe UI'` + `fontFamilyFallback: ['Microsoft YaHei', 'PingFang SC']`（`system-ui` / `-apple-system` 无对应 Flutter 字体名，落到系统默认回退） |
| 衬线栈 | `Georgia, Songti SC, SimSun, serif` | 纸面 / 数字需要衬线处；Flutter fallback 不写泛型 `serif` |
| 正文 | 15px / 行高 1.65 | body 基准。旧代码 `bodyMedium 14` → **15 / 1.65** |
| 页标题 | 24px / 800 | `h2.st`、`.main h3.pt` |
| 问候大标题 | 34px / 800 / 行高 1.25 | `.ahead h1` |
| 焦点大数字 | 46px / 800 / 行高 1.15 | `.focus-card .fc-num` |
| 封面竖排学科名 | 52px / 800 / 行高 1.15 | `.nb-book-name` |
| 次级字号 | 13.5px（bodySmall）、12.5px（caption/labelSmall） | HTML 高频值，R2 逐页核对后收紧 |

## 4. 缩放 Token（D4）

| 档位 | 因子 | 旧值 → 差异 |
|---|---|---|
| 标准 standard | 1.00 | 旧 1.0，一致 |
| 大 large | 1.15 | 旧 1.12 → **1.15** |
| 特大 extraLarge | 1.30 | 旧 1.25 → **1.30** |

映射唯一入口：`FontScale.factorFor(fontSizeKey)` 与 `AppSettings.fontScale`（两处同一映射，测试覆盖）。`ScaledTokens(scale)` 提供缩放后的 `radius` / `radiusLg` / `buttonRadius` / `contentPadding` / `navWidth` / `navCollapsedWidth` / 间距（4/8/12/16/24）。字号不进 `ScaledTokens`（见 §1 约定）。

`ThemeData` 里 `scale` 的覆盖范围（R1）：按钮最小尺寸与内边距、卡片 / 对话框 / 输入框圆角。导航宽（216/64）与内容区 padding（26/30）已有 token，但 R1 未改外壳布局（`app.dart` 的导航宽仍为写死值），由 R2 外壳重构时接入 `ScaledTokens`。

## 5. ThemeData 对照

- `light()` / `dark()`：`useMaterial3`、亮度、字体栈、`ColorScheme`（primary=accent、onPrimary=accentInk、surface、onSurface=ink、surfaceContainerHighest=surface-2、outline=line、outlineVariant=line-strong、error=errInk、errorContainer=errBg）、`scaffoldBackgroundColor`=bg、卡片（surface、elevation 0、radius、line 边框）、按钮（见下）、对话框（surface、radius-lg）、输入框（line 边框、聚焦 accent 边框）、分隔线（line）。
- `FilledButton`：亮色底 #2E7CF6 + 白字；**深色底 #7FA8D0 + 深字 #131A24**（旧代码深色按钮还在用浅色 accent + 白字，已统一）。
- `OutlinedButton` / `TextButton`：文字 accentText、边框 accent（深色下即 #7FA8D0 体系）。
- 亮深切换：沿用现有设置（跟随系统默认、可手动亮 / 深），`app.dart` 的 `_themeMode` 未变。
- 兼容性：页面引用的 `AppTheme` 公共 API（`accent`、`lightBackground`、`darkPaper`、`darkMathMist`、`radius` 等）名字全部保留；`light()` / `dark()` 零参调用仍可编译（`scale` 为可选命名参数，默认 1.0）。`test/theme_smoke_test.dart` 的旧断言未改，全部通过。

## 6. 已知取舍（R1 明确不做的）

- `AppTheme` 兼容常量因 Dart const 限制写了字面值（见 §1），与 `DesignTokens` 是两处同步，R2 页面接入 token 后可删。
- `widgets.dart` 未动：其中 `_SliceFigurePainter` 演示简图仍写死旧色 `#2F7CF6` / `#5B6B84`（1 位差与旧 muted），待 R2 真实图片切片替换时一并清理；`subjectLabelColor` 的深色 `-ink` 档与 HTML 一致，无需改。
- 旧数据库里已存入的 subjects `color` 仍是旧值（种子只在建库时写一次）；新装应用取新值。是否迁移旧库数据属业务决策，R1 不动（见 R1-ISSUES.md）。
- 阴影 token 已提供但页面仍是 `elevation: 0`、无阴影外观变化；R2 逐页接入。
- 设置里“字号”三档的文案与存储键未变；`ScaledTokens` 的导航宽 / 内容区 padding 在 R1 未接入外壳布局。
