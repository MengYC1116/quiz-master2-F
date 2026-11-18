# M4：题干切分（保守启发式）——交付报告

- 时间：2026-11-18
- 范围：只做 M4，未碰其他模块，未给 Meng 发邮件/消息，未推送代码。
- 依据：GPT 评审 `gpt-consult-ocr-implementation.md` §1（切分算法评审全文）、
  `glm-vs-vl16-compare.md`、决策日志 D-103～D-106（D-106 调整后方案要点）。

## 一、改动文件清单（只新增 2 个文件，零修改）

| 文件 | 说明 |
|---|---|
| `~/workspace/quiz-master2-UI/lib/services/stem_splitter.dart`（398 行） | 切分器实现：纯函数，无 UI、无网络、无数据库依赖 |
| `~/workspace/quiz-master2-UI/test/b13_stem_splitter_test.dart`（349 行） | 34 个测试：6 道真实输入 + 27 个边界用例 + 1 个结构用例 |

## 二、函数签名（M3 / M5 按此接）

```dart
// lib/services/stem_splitter.dart —— 类型定义只在此一处，M3/M5 直接 import 本文件复用。

/// 切分状态。manuallyAdjusted 由 M5 的纠错编辑器在用户手动改过题干后写入，
/// 本切分器永不产出该值。
enum StemSplitStatus {
  notSplit,         // 未切分
  autoSplit,        // 自动切分
  ambiguous,        // 存在歧义
  manuallyAdjusted, // 人工调整（M5 写）
}

extension StemSplitStatusLabel on StemSplitStatus {
  String get label; // '未切分' / '自动切分' / '存在歧义' / '人工调整'
}

/// 题干切分结果。
class StemSplitResult {
  const StemSplitResult({
    required this.stemText,  // 切分后的题干
    required this.status,    // 切分状态
    required this.cutIndex,  // 切分位置（原始文本中的字符下标，可空）
    required this.reason,    // 简短说明
  });
  final String stemText;
  final StemSplitStatus status;
  final int? cutIndex;
  final String reason;
}

/// 切分原始 OCR 文本（GLM-OCR 的 md_results）。纯函数，不抛异常。
StemSplitResult splitStem(String ocrText);
```

字段语义（M3 存库、M5 编辑器都按此理解）：

- `stemText`：自动切分时是 A 标记之前的文本（去首尾空白，**题号保留**，
  如 `2. 双曲线 …` 的 `2.` 不删）；未切分 / 存在歧义时是整段原文
  （去首尾空白），内容一句不丢。
- `cutIndex`：原始 OCR 文本中的字符下标，指向 A 标记的首字符
  （如 `(A)` 指向 `(`）；未切分 / 存在歧义时为 `null`。
  注意下标对应**调用方传入的原始字符串**（本函数不做 `\r\n` 归一化，
  只把 `\r`、全角空格当空白处理），M3 存 `cutIndex` 时须配合同一份原文。
- `reason`：切了说明切的证据（序列 + 格式，如
  `选项序列 A. B. C. D. 格式一致，自 A 处切分`）；没切说明哪条规则
  没守住（如 `仅发现 A 标记，未见 B，不切分`、`A、B 标记格式不一致，不切分`）。
- 本切分器只产出 `notSplit` / `autoSplit` / `ambiguous` 三种状态；
  `manuallyAdjusted` 已预留在枚举里供 M5 用，不由本函数产出（有测试锁定）。

## 三、切分规则（保守策略：宁可保留选项，也不要误删题干）

同时满足才切（A→B 序列 + 格式一致 + 有内容 + 位置合理）：

1. **标记格式**：`A.` / `A．` / `A、` / `A)` / `A）` / `(A)` / `（A）`、
   全角字母 `Ａ–Ｅ` 视为 A–E；选项支持 A–E（医学常 5 个选项）。
   只认大写，小写 a–e 不认。
2. **A→B 序列**：找到 A 标记，且其后出现 B 标记；C、D、E 出现是更强
   证据（reason 里列出），但不是必要条件——只有 A、B 也切。
3. **格式一致**：A、B 须同属一类（句点 / 顿号 / 右括号 / 括号式，
   全角半角不区分）。`A.` 对 `(B)` 不切。
4. **标记后有实际选项内容**：跳过空白后须有字（字母/数字/中文/公式 `$` 等），
   且不能是下一个选项标记、也不能只剩标点。`A. B. C. …` 连排标记会被这条拦住。
5. **A 的位置（强边界）**：行首，或 ≥2 空格/制表符的栏位间隔，或括号式
   `(A)` 前有空白。行文中单空格后的 `A.`（如“集合 A，且 A. B …”）不算候选——
   这是 GPT 评审漏洞一（题干里的 `A.` 句子）的主要防线。
6. **B 的位置（近邻）**：B 须在 A 所在行或之后 2 行内出现。远在数段之后的
   A、B 句子对不算选项序列（英语长段落里的 `A. …` / `B. …` 靠这条拦住）。

不切的情况（整段保留为题干，一句不丢）：

- 只出现 A（无 B）；A 之后未见 B（中间隔了 C 或别的标记也算未见）；
  A、B 格式不一致；B 后无内容；A 不在选项起始位置；B 离 A 过远。
- **多个候选切分点 → `存在歧义`**，不随便选第一个，`cutIndex` 为空。
- 完全没选项标记（填空、解答、名词解释等非选择题）→ `未切分`。
- ①②③④、`(1)`/`(2)` 小问、`( )` 答题空不参与切分（正则只认 A–E 字母标记）。
- 开头题号不盲删：`1.` 可能是题干里的数学序号，留着。
- **无题型判断**：只用选项标记当切分边界，不引入任何题型判断
  （“用 A/B/C/D 判题型”方案已被 Meng 否决）。

## 四、测试结果：34/34 通过

命令（只跑本模块测试，未跑全量）：

```bash
export TMPDIR=$HOME/workspace/flutter-test-tmp
export LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux
flutter test --concurrency=1 test/b13_stem_splitter_test.dart
# 00:00 +34: All tests passed!
```

`flutter analyze`（只针对改动文件）：

```bash
flutter analyze lib/services/stem_splitter.dart test/b13_stem_splitter_test.dart
# No issues found!
```

### 4.1 六道真实输入的切分结果

真实输入是 `glm-compare/` 里 6 道题的 `.md` 文本原文照录
（`*-glm-ocr.jsonl.md`，未改一字），期望题干以
`glm-vs-vl16-compare.md` 的结论为准：

| 题 | 结果 | 题干（`stemText`） | 说明 |
|---|---|---|---|
| single01-q2 双曲线 | ✅ 自动切分 | `2. 双曲线 $ 4 x^{2}-y^{2}=4 $的离心率为` | `A. B. C. D.` 同行，格式一致；题号 `2.` 保留 |
| single01-q4 cos/sin | ✅ 自动切分 | `4. 若 $ \cos(\alpha+\frac{\pi}{4})=\frac{3}{5}, $ $ \alpha\in(0,\frac{\pi}{2}) $ ，则 $ \sin\alpha= $` | `A. B. C. D.` 独立行；题号 `4.` 保留 |
| double01-q1 英语听力 Q6+Q7 | ✅ 存在歧义 | 整段原文（未切） | 一框含两道题，Q6、Q7 各有一个可信 A，共 2 个候选切分点，按规则不选第一个；`cutIndex` 为空 |
| double01-q5 英语听力 Q1 | ✅ 自动切分 | `1. What will the man probably do for the woman?` | 只有 A、B、C，没有 D 也切（C/D 非必要） |
| triple01-q3 复数 | ✅ 自动切分 | `1. 化简 $ \frac{2+4 \mathrm{i}}{(1+\mathrm{i})^{2}} $的结果是 (    )` | `(A) (B) (C) (D)` 括号式；题干里的 `(    )` 空格不误切 |
| triple01-q4 椭圆 | ✅ 自动切分 | `9. 设椭圆 $ \frac{x^{2}}{a^{2}}+\frac{y^{2}}{b^{2}}=1 $ （ $ a>b>0 $ ）的离心率为 $ e=\frac{1}{2} $ ，右焦点为 F(c,0)，方程 $ ax^{2}+bx-c=0 $ 的两个实根分别为 $ x_{1} $和 $ x_{2} $ ，则点 P $ ( x_{1},x_{2} ) $ （    )` | `(A)(B)` 与 `(C)(D)` 跨行；题干里的 `（    )` 不误切 |

另有 1 个测试锁定：6 道真实输入的 `reason` 都不为空，且切分器
永不产出 `manuallyAdjusted`。

**关于 double01-q1（存在歧义）的说明**：一框含两道题不在 OCR 层处理
（GPT 评审 §1.1 赞成保留的点）。若在此处切第一个 A，Q7 整道题
（题干 + 选项）会被丢弃，违反“不因一次切分丢失内容”的原则。
因此标歧义、整段保留，等上游把一框两题拆成两个框，或由用户在
M5 纠错编辑器里人工处理。本模块不为此放宽规则。

### 4.2 边界用例（27 个，全部通过）

| 用例 | 期望 | 守住的规则 |
|---|---|---|
| 只有 A、没有 B | 未切分 | A→B 序列必要 |
| 英语题干 `"A. student..."` 句子（只有 A） | 未切分 | 只出现 A 不切 |
| `A. B. C. D.` 连排标记 | 未切分 | 标记后须有实际选项内容 |
| 只有 A、B，没有 C、D | 自动切分 | C/D 非必要 |
| 医学 5 选项 A–E | 自动切分 | 选项支持 A–E |
| 填空题 / 解答题（证明）/ 名词解释 | 未切分 | 无标记整段当题干 |
| 无选项的题保留开头 `1.` | 未切分 | 题号不盲删 |
| 空文本 / 纯空白 | 未切分，题干为空 | 空输入兜底 |
| “集合 A，且 A. B 分别表示……” | 未切分 | A 须在选项起始位置 |
| A、B 句子相隔数段 | 未切分 | B 须在 A 之后 2 行内 |
| 一框两题（合成） | 存在歧义 | 多候选不自动选 |
| 全角 `Ａ．Ｂ．Ｃ．` | 自动切分 | 全角字母/句点归一化 |
| 全角括号 `（Ａ）（Ｂ）` | 自动切分 | 括号式全角 |
| `A)` 风格一行一个 | 自动切分 | 右括号式 |
| `A、` 顿号风格 | 自动切分 | 顿号式 |
| A、B 格式不一致（`A.` 对 `(B)`） | 未切分 | A、B 格式一致 |
| B 标记后无实际选项内容 | 未切分 | 标记后有内容 |
| 同一行 `A. 第一项 B. 第二项` | 自动切分 | B 可在同行 |
| 同行 A 与题干只隔 1 空格 | 未切分 | A 强边界（保守） |
| 同行 A 与题干隔 ≥2 空格 | 自动切分 | 栏位间隔算选项起始位置 |
| 小问 `(1)(2)`（全角/半角） | 未切分 | 小问不参与切分 |
| 圈号 ①②③④ | 未切分 | 圈号不参与切分 |

结构测试（2 个）：自动切分时 `cutIndex` 指向 A 标记且
`stemText == 原文.substring(0, cutIndex).trim()`；状态枚举共 4 值，
含 M5 用的 `manuallyAdjusted`。

每个失败用例的测试名即规则名；没有为过测试放宽规则——
同行单空格 A、远距离 A/B 句对这两处都是按保守策略判未切分
（内容保留，用户可在 M5 里人工切），而非放宽成切分。

## 五、以后接 layout bbox 可以怎么辅助（本版未接，不改接口）

GLM-OCR 的 `layout_details` 里每块有 `bbox_2d`。本版是纯文本版，
接口不为它留参数；以后要接时，由调用方在调 `splitStem` 之前做，
签名不用改：

1. **块过滤**：只把相关块的文本拼进输入，或去掉页眉/页脚/水印块，
   减少误切的输入噪声；
2. **位置校验**：把本函数找到的候选切分点映射回块——A、B 是否落在
   同一水平行、是否集中在题目下半部、是否各占独立文本块，用来给
   “存在歧义”的候选排序，或把低置信度候选升级为自动切分。

单题裁剪上 GLM 只返回 1 个块（整题一块），bbox 在此场景下几乎没有
区分度，所以本版先做纯文本版；走“整页调一次再映射回各题”路线时
bbox 才有实际价值。

## 六、验证过程说明（给协调员）

- **在树内直接跑 `flutter test` 失败，与 M4 无关**：树内另有进行中的
  同批模块文件（M3 相关，未提交）：`lib/data/db_questions.dart` 引用了
  `ocrRaw` / `ocrStem` / `ocrSplitStatus` / `ocrManualEdited` /
  `contentVersion` 等 Drift 生成类里尚不存在的 getter，
  `lib/data/db_backup.dart` / `db_orphans.dart` 引用了尚不存在的
  `db.ocrJobs`；而 `test/flutter_test_config.dart` 会 import
  `package:quiz_master2/data/database.dart`，导致任何 `flutter test`
  在加载阶段就编译失败。M4 未碰这些文件。
- **实际验证方式**：把仓库的 `lib/`、`test/`、`pubspec.*`、
  `analysis_options.yaml` 拷到 `~/workspace/.m4-verify/`（隔离副本，
  已删除），只删副本里的 `test/flutter_test_config.dart`
  （它只负责把测试数据目录指到临时目录，M4 测试不碰库，删了不影响
  本模块测试行为），离线 `flutter pub get` 后跑本模块测试，
  **34/34 通过**；跑完已删副本。`/tmp` 是 512M tmpfs 且已满，
  故副本放 workspace 下而非 `/tmp`。
- `flutter analyze` 是在原树内直接对两个改动文件跑的，
  **No issues found**（初版 6 条 `constant_identifier_names` info，
  已按 lint 把测试常量改成 lowerCamelCase）。
- 待 M3 的 Drift 生成代码补齐后，建议由 M7 全量回归时再在树内复跑
  本文件（预期无需改动）。

## 七、已知局限（诚实记录）

1. 英文段落里行首的 `A. …` 句与行首的 `B. …` 句若在 2 行内相邻，
   纯文本无法与真选项区分，会误切。缓解靠两点：近邻上限（2 行）
   已拦住多数情况；剩余情况靠 layout bbox 位置校验（见 §五）或
   M5 人工纠错。样本里未出现此情形。
2. 选项与题干同行且只隔 1 个空格时保守判未切分（选项保留，待人工切）。
   6 道真实样本里选项都在独立行，未受影响。
3. 选项字母只支持 A–E；6 选项以上的题（极少）会判未切分，整段保留。
