# M1 公式渲染器 POC 报告（十三批）

- 时间：2026-11-18
- 结论：**采用 flutter_math_fork 0.7.4，不 POC Ratex，不走原图备选为主路线**
  （原图回退已作为失败兜底实现，不是主路线）。
- 环境：Linux VM；Flutter 3.47.9 / Dart 3.13.7；只在 Linux 上验过，
  Windows 与安卓真机验证由 Meng 在推送后做（见 §7）。

## 一、结论与理由

| 候选 | 结论 | 理由 |
|---|---|---|
| flutter_math_fork 0.7.4 | **采用** | 真实 GLM 公式 25/25 通过；GPT 类型表 22/22 通过（含矩阵、cases、`\text`、`\mathrm`、`\mathbb`）；纯 Dart、离线、Windows/Android 通用；pub.dev 最新版，与 Flutter 3.47.9 / Dart 3.13.7 无冲突 |
| Ratex 0.0.1 | 不 POC | 触发条件未满足（fork 核心类型无大面积失败）。另：本机无 Rust 工具链（`cargo`/`rustc` 均未安装），0.0.1 + Rust FFI 构建风险高；若日后真实公式出现 fork 覆盖不了的类型，再 POC 它 |
| 公式原图小图备选 | 已实现为兜底 | 按 GPT §3.4：GLM `layout_details` 坐标裁小图，裁不到用整张切片。渲染失败时自动换 `ImageFallbackBlock`，不是主路线 |

## 二、测试集来源

- G 组（25 条）：6 道 GLM-OCR 真实输出里的**全部**公式，逐字取自
  `~/workspace/batch13-work/glm-compare/` 的 `single01-q2/q4`、
  `triple01-q3/q4` 的 `*.jsonl.md`（数学 4 道；英语 2 道无公式）。
  含 GLM 原样带空格形式 `$ 4 x^{2}-y^{2}=4 $`（G01r 单独测）。
- P 组（2 条）：政治卷圈号 `\textcircled{1}`、`\textcircled{1}\textcircled{3}`
  （`pol-p01-glm-ocr.jsonl.md`），预期失败、走预处理。
- T 组（24 条）：GPT 评审 §4.3 类型表每一类的合成公式。
- 另有解析器/预处理/渲染器/对齐量测测试 20 项。
- 合计 69 项 widget/单元测试，**全部通过**（见 §三、§四）。

## 三、逐条结果表

### G 组：真实 GLM 公式（25/25 通过）

| 编号 | 来源题 | 通过 |
|---|---|---|
| G01 | 双曲线 `4x²-y²=4` | ✅ |
| G01r | 同上，GLM 原样带空格 | ✅ |
| G02 | `√3` | ✅ |
| G03 | `√5/2` | ✅ |
| G04 | `√5` | ✅ |
| G05 | `cos(α+π/4)=3/5` | ✅ |
| G06 | `α∈(0,π/2)` | ✅ |
| G07 | `sinα=` | ✅ |
| G08 | `√2/10` | ✅ |
| G09 | `3√2/10` | ✅ |
| G10 | `√2/5` | ✅ |
| G11 | `3√2/5` | ✅ |
| G12 | `(2+4i)/(1+i)²`（含 `\mathrm{i}`） | ✅ |
| G13–G16 | `2+i` / `-2+i` / `2-i` / `-2-i`（含 `\mathrm`） | ✅ |
| G17 | 椭圆 `x²/a²+y²/b²=1` | ✅ |
| G18 | `a>b>0` | ✅ |
| G19 | `e=1/2` | ✅ |
| G20 | `ax²+bx-c=0` | ✅ |
| G21/G22 | `x₁` / `x₂` | ✅ |
| G23 | `(x₁,x₂)` | ✅ |
| G24 | `x²+y²=2` | ✅ |

### T 组：GPT 类型表（22/22 通过，2 条预期失败也符合预期）

| 编号 | 类型 | 通过 |
|---|---|---|
| T01 | 基础运算 `(a+b)²` | ✅ |
| T02 | 复杂分式（分式套分式） | ✅ |
| T03 | 高次根 `³√(x²+1)` | ✅ |
| T04 | 组合上下标 `a_{i,j}^{n+1}` | ✅ |
| T05 | 极限 `\lim` | ✅ |
| T06 | 求和 `\sum` | ✅ |
| T07/T08 | 积分（含 `∫_{-∞}^{∞}`） | ✅ |
| T09 | 三角函数 `sin²+cos²=1` | ✅ |
| T10/T11/T12 | matrix / pmatrix / vmatrix（行列式） | ✅ |
| T13 | `\begin{cases}` | ✅ |
| T14 | cases + `\text{当 }` 中文 | ✅（无异常；中文显示见 §7 待真机目视） |
| T15 | `\text{已知 } x>0` | ✅（同上） |
| T16 | 希腊字母/箭头/不等号 | ✅ |
| T17 | 集合符号 + `\mathbb{R}` | ✅ |
| T18 | 独立公式（display，求根公式，GPT 例） | ✅ |
| T19 | `\mathrm{d}x` | ✅ |
| T21 | `\frac{1}`（缺参数） | ❌→回退 ✅（预期失败） |
| T22 | 未知命令 | ❌→回退 ✅（预期失败） |
| T23 | 二项式系数 `\binom{n}{k}` | ✅ |
| T24 | 嵌套根式 | ✅ |

### P 组：圈号（预期失败，预处理接管）

| 编号 | 内容 | 直接渲染 | 预处理后 |
|---|---|---|---|
| P01 | `\textcircled{1}` | ❌ 失败（符合预期） | ① 文本显示 ✅ |
| P02 | `\textcircled{1}\textcircled{3}` | ❌ 失败（符合预期） | ①③ 文本显示 ✅ |

## 四、显示正确性量测（不只是“报不报错”）

| 检查项 | 方法 | 结果 |
|---|---|---|
| 上标对齐 | `x` / `x²` / `x₁` 同字号尺寸对比 | ✅ 上标抬高整体高度：`x`=16.0×6.89，`x²`=27.99×11.84，`x₁`=27.99×9.29（逻辑像素） |
| 中文行内公式对齐 | RichText 中文 + WidgetSpan 行内公式（PlaceholderAlignment.middle），量中心偏差 | ✅ 偏差 **0.02px**（阈值 8px） |
| 长公式溢出 | 200px 窄容器 + display 长公式 | ✅ `FormulaView` 横向滚动，无异常、无回退；对照：裸 `Math.tex` 同条件**抛 overflow 异常**，证明滚动包装是必需的 |
| 渲染失败回退 | 非法公式进 `QuestionContentRenderer` | ✅ 自动换 `ImageFallbackBlock`（“公式原图”占位），不抛错，其余段落正常显示 |
| 不泄漏源码 | 回退界面文本检查 | ✅ 界面无 `frac`、无 `ParseException` 文本；fork 默认错误回调（会显示含源码的报错文本）已被覆盖 |
| 真实题干端到端 | 椭圆题整段题干解析+渲染 | ✅ 7 个公式全部渲染，0 回退 |
| 回退回调 | `onFormulaFallback` | ✅ 失败后下一帧回调一次，只报成败 |

## 五、已验证不支持的命令清单

| 命令/情形 | 实测结果 | 处理 |
|---|---|---|
| `\textcircled{n}` | 不支持（源码里该命令被注释掉，见 fork `accent.dart`） | 预处理成 ①–⑳（§六）；超出 1–20 的保留原命令→渲染失败→回退原图 |
| `\frac` 缺参数（如 `\frac{1}`） | 解析失败 | 回退原图 |
| 未知命令（如 `\unknowncmd`） | 解析失败 | 回退原图 |
| 其余 | 本批测试集内无其他不支持项 | —— |

注意：`\text{}`、`\mathrm`、`\begin{cases}`、`pmatrix`/`vmatrix`、
`\mathbb` 均已验证支持，不在不支持清单里。

## 六、`\textcircled{n}` 预处理验证

- 转换只发生在明确识别为圈号命令的位置（正则 `\\textcircled\{(\d{1,2})\}`），
  1–20 → ①–⑳；`{0}`、`{21}` 保留原命令（不静默编造字符），进渲染失败→回退。
- 不做 Unicode 全量规范化，已验证：全角 `Ａ．`、破折号 `——`、普通数字 `123`
  在预处理前后原样不动。
- 解析器补充规则：预处理后仍包在 `$...$` 里的纯圈号内容（如 `$①③$`）
  还原成 `TextBlock`，不再进公式渲染（GPT §4.4：圈号是正文标号，直接当
  Unicode 文本显示）；混合内容（如 `$① x$`）仍走公式。
- 全部 4 项预处理测试 + 2 项解析器测试通过。

## 七、只在 Linux 上验过；待 Windows / 安卓真机验证

- 本报告所有结论只在 Linux VM（Flutter 3.47.9）上实测；Windows 与安卓
  由 Meng 在推送后验证。
- Widget 测试能证明“不抛错、有尺寸、对齐量测通过”，**不能证明字形本身
  正确**。以下须真机目视确认：
  1. `\text{当 }`、` \text{已知 }` 里的中文是否正常显示（KaTeX 字体无 CJK
     字形，依赖系统字体回退；Linux 测试环境无异常不等于真机显示正常）。
  2. ①②③④ 在 Windows / 安卓系统字体下的显示。
  3. 分数线、根号、大括号等字形在真机上有无缺损；长公式横向滚动手感。
  4. 与深色主题的配合（公式颜色跟随 `DefaultTextStyle`，理论上跟随主题）。

## 八、交付：接口骨架与改动文件

### 改动文件清单

| 文件 | 改动 |
|---|---|
| `pubspec.yaml` | 新增 `flutter_math_fork: ^0.7.4`（pub.dev 最新版；sdk `>=3.0.0 <4.0.0`、flutter `>=3.0.0`，与 Dart 3.13.7 / Flutter 3.47.9 兼容） |
| `pubspec.lock` | 随 `flutter pub get` 更新（fork + `provider`/`tuple`/`flutter_svg` 等传递依赖） |
| `lib/modules/ocr/question_content.dart` | **新文件**：段模型（`TextBlock` / `FormulaBlock` / `ImageFallbackBlock` / `CodeBlock`）+ `parseQuestionContent` 解析器 + `preprocessCircledNumbers` 圈号预处理。纯 Dart，不依赖渲染库 |
| `lib/modules/ocr/question_content_renderer.dart` | **新文件**：`QuestionContentRenderer`（按段分发）、`FormulaView`（fork 渲染 + 失败自动回退原图 + 失败回调只报成败）、`FormulaImageFallback`（M5 传入真实裁图，未传显示通用占位） |
| `test/m1_formula_renderer_test.dart` | **新文件**：69 项测试（覆盖率 + 预处理 + 解析器 + 渲染器 + 对齐/溢出量测 + 汇总打印，测试名只用编号、不含公式源码） |

### 接口骨架（给 M5 用）

```dart
// 解析：含 $...$ / $$...$$ 的混合文本 → 内容段
List<QuestionContentBlock> parseQuestionContent(String markdown);
// 圈号预处理：\textcircled{n} → ①②③④（1–20，确定性、命令位置限定）
String preprocessCircledNumbers(String input);
// 渲染：按段类型分发；公式失败自动换 ImageFallbackBlock
QuestionContentRenderer(blocks: ..., fallbackImage: ..., onFormulaFallback: ...)
// 单公式：displayMode 独立公式横向滚动；失败回退 + post-frame 通知
FormulaView(latex: ..., displayMode: ..., onFallbackShown: ...)
```

- `CodeBlock` 是 D-105 通用性要求：围栏代码块优先于公式定界符，
  计算机题干里的程序按等宽文本显示，不当公式解析。
- `ImageFallbackBlock.cropPath`：按 GLM `layout_details` 坐标裁出的公式小图；
  为空时用整张题切片（M5 接入时传入）。
- LaTeX 只存在 `FormulaBlock.latex` 内部数据里；渲染器覆盖了 fork 默认
  错误回调，不展示、不复制、不打日志。

## 九、测试运行方式与环境说明

- 命令（只跑本模块，不跑全量）：
  `TMPDIR=$HOME/workspace/flutter-test-tmp LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux flutter test --concurrency=1 test/m1_formula_renderer_test.dart`
- 结果：**69/69 通过**；`flutter analyze`（两个新 lib 文件 + 测试文件）无问题。
- 演示库：跑测试前后 `~/workspace/demo-db-backup/quiz-master2.db` 的 md5
  均为标准 v1 值 `8f7f9c64405dc6e484ac2bf8e5e1a807`，未被触碰。
- **阻塞说明（不在 M1 范围内，报给 parent/M7）**：共享工作树里有其他模块
  未提交的 Drift 改动——`lib/data/db_questions.dart`（未追踪新文件）引用了
  `DbQuestion.ocrRaw / ocrStem / ocrSplitStatus / ocrManualEdited /
  contentVersion`，但生成的 `lib/data/drift/quiz_database.g.dart` 里没有
  这些字段；`test/flutter_test_config.dart` 每个测试文件都会加载
  `package:quiz_master2/data/database.dart`，所以在真实树下 `flutter test`
  任何文件都会编译失败。本次 M1 测试是在 `/tmp` 隔离副本里跑通的
  （副本删掉了测试配置加载；M1 文件本身不依赖数据库，`flutter analyze`
  在真实树下也干净）。M7 跑全量之前，须由相关模块重新生成 Drift 代码。
  本任务未动其他模块、未发邮件、未推送代码。
