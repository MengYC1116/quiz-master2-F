# S8A2 — 新学科封面默认灰 + 轮换表同步新值 + 圆点显示修复报告

- 日期：2026-11-13
- 来源：Meng 2026-11-13 14:53 裁决的两处小问题（代码地图编写时发现），并入修复队列
- 状态：**已修复，真机验证通过**
- 改动文件：
  - `lib/modules/subjects/subjects_page.dart`（`_newSubjectColors` 同步新值；`_addSubject` 显式传 `coverColor: 'grey'`）
  - `lib/theme/design_tokens.dart`（`subjectColor` 增加可选 `stored` 参数；验证中发现的 R1 回归，见 §3）
  - `lib/widgets/app_shell.dart`（导航学科速览圆点传 `widget.subject.color`）
  - `test/subjects_page_test.dart`（新增学科断言：轮换紫 + 封面灰 + 圆点真画成紫）
- 报告截图：`docs/ui-replication/shots/s8a2/`
- Linux 结果不替代 Win11 最终验收。

## 1. 结论

两处原定修复已落地并通过真机验证；验证中另发现一处 R1 回归（新学科圆点永远显示数学蓝），已一并修复，否则原定验收标准“新学科圆点应为紫”无法达成（见 §3）。

| 验证项 | 新库（删库重建） | 老库（当前演示库） |
| --- | --- | --- |
| 新学科圆点 | 紫 0xFF7C5CFC（像素实测） | 新蓝 0xFF2E7CF6（像素实测，见 §4） |
| 新学科封面 | 纯色折角 · 灰色（文字 + 灰色小图 + 灰色已勾） | 灰色（库值 `cover_color='grey'`） |
| 老三科颜色 | 新值（数学 0xFF2E7CF6 / 英语 0xFF00A884 / 政治 0xFFEF4444） | 旧值保持不动（数学 0xFF2F7CF6 / 英语 0xFF1F9D66 / 政治 0xFFE0524D） |

## 2. 原定两处修复

### 2.1 新学科封面默认灰色

- 现状：`_addSubject` 建 `Subject` 时没传 `coverColor`，模型默认值是蓝；Meng 2026-11-12 定的是新学科封面默认灰色。
- 修法：只在 `_addSubject` 里显式传 `coverColor: 'grey'`，**不动模型默认值**（避免影响其他构造点）。
- 入口确认：全库 grep，UI 上创建学科的入口只有 `_addSubject` 一处；其余 `Subject(` 构造点是种子三科（`Subject.all`）、读库行（`database.dart`）、`copyWith`（改名/换封面），均不属于“新建学科”。

### 2.2 `_newSubjectColors` 同步成 R1 新值

- 现状：轮换表还是改色前的旧值蓝 0xFF2F7CF6 / 绿 0xFF1F9D66 / 红 0xFFE0524D。
- 修法：前三项改成新值蓝 0xFF2E7CF6 / 绿 0xFF00A884 / 红 0xFFEF4444；紫 0xFF7C5CFC、橙 0xFFF08A1D 保持不变。

## 3. 验证中发现的第三处问题：圆点显示回归（R1 引入，本次一并修了）

### 3.1 现象

新库上新增“物理”后，库里存的颜色正确（`color=4286340348=0xFF7C5CFC` 紫，`cover_color='grey'`），但列表里的圆点像素实测是新蓝 (46,124,246)，全图没有一个紫色像素。

### 3.2 根因

学科列表圆点根本不读 `s.color`，而是读 `DesignTokens.subjectColor(s.id, brightness)`——一个按 id 查表的硬编码 switch：

```dart
static Color subjectColor(String subjectId, Brightness brightness) {
  return switch (subjectId) {
    'english' => p.eng,
    'politics' => p.pol,
    _ => p.math, // 任何新学科 id 都落到这里：数学蓝
  };
}
```

v2 基线（0c812172）圆点是直接用 `s.color` 的；R1 改成 id 查表后，新学科的轮换色只写库、不显示。`s.color` 全库只剩一处读取（`_addSubject` 里算 `usedColors`），其余消费点（学科列表 2 处、封面块表头 1 处、导航速览 1 处、QmChip、`SubjectLabel`）全部走 id 查表。

### 3.3 修法（最小面，恢复基线行为）

- `DesignTokens.subjectColor` 增加可选参数 `[Color? stored]`：预设三科忽略它，仍走主题感知的固定色（深色下是雾色版）；非预设 id 直接返回库里存的轮换色。深色下新学科用存的单值色（与基线一致，无深色变体）。
- 调用点传值：学科页三处（列表改名行、列表正常行、封面块表头）传 `s.color`；导航速览（`app_shell.dart` 的 `_SubjectRow`，有 `widget.subject`）传 `widget.subject.color`。
- 未动：`QmChip` 的 `subjectId`（文档注明只用于预设三科的筛选芯片）、`SubjectLabel`（`Subject.byId` 只认三科）、首页的 `subjectInk`/`subjectSoft`（首页目前仍遍历 `Subject.all`，是 B2 的范围；B2 让首页读库时，同样的 stored 回退也要补上，见 §5）。

## 4. 真机验证（Xvfb :99，1280×720，Linux Release 构建，libapp.so 2d4e5115）

### 4.1 新库（删 `quiz-master2.db` 重建）

- 种子三科库值：数学 0xFF2E7CF6 / 英语 0xFF00A884 / 政治 0xFFEF4444，封面蓝/绿/红。
- 新增“物理”（Unicode 键码输入，xdotool type 打不了中文）：库值 `color=0xFF7C5CFC`、`cover_color='grey'`；列表圆点像素实测紫 (124,92,252) 132px（`added-fresh-dot-purple.png`）；封面块展开后物理行显示“当前封面：纯色折角 · 灰色”，灰色小图 + 灰色已勾（`added-fresh-cover-grey.png`）。
- 验证方式说明：圆点像素采样曾因行高估错 y 波段而误判（数学/英语行扫不到点），后按包围盒精确定位：数学 y 198–209、英语 y 260–271、政治 y 322–333、物理 y 384–395。

### 4.2 老库（当前演示库，`/tmp/qm2-bugfix-orig.db` 恢复）

- 老三科库值保持旧值（数学 0xFF2F7CF6 / 英语 0xFF1F9D66 / 政治 0xFFE0524D），未迁移（Meng 已定）。
- 新增“化学”：库值 `color=0xFF2E7CF6`（新蓝）、`cover_color='grey'`；圆点像素实测新蓝 (46,124,246) 132px（`added-demo-newblue.png`）。
- **既有后果（决定 2 的直接结果，只记录不处理）**：老库上新学科拿到新蓝 0xFF2E7CF6，与数学旧蓝 0xFF2F7CF6 只差 1 个色阶（R: 46 vs 47），肉眼几乎无法区分；深色下三科预设圆点仍是雾色版（数学 #87A9CC / 英语 #8AB5A3 / 政治 #C295A5，像素实测），新学科圆点则直接用存的单值色（亮/深同一色）。

### 4.3 静态检查

- `flutter analyze`：No issues found。
- `flutter test`：**279/279 通过**（含新增的圆点真画成紫的 widget 断言：新增物理后，`BoxDecoration.color == 0xFF7C5CFC` 的 Container 恰好一个）。
- 演示库已恢复原状：9 道题、3 科、themeMode=dark、fontSize=standard（从 `/tmp/qm2-bugfix-orig.db` 恢复并核对）。

## 5. 遗留与提醒

- **B2 注意**：首页目前遍历 `Subject.all`，改读库后，新学科在首页的 `subjectInk`/`subjectSoft`（也是 id 查表）同样会落到数学色；B2 做的时候要给这两个方法补同样的 stored 回退，或改用新学科的存色。本报告只修了圆点（`subjectColor`）一处。
- `QmChip`（学科筛选芯片）与 `SubjectLabel`（收集任务行）仍只认三科 id，新学科在这些位置仍显示数学蓝；是否修，由 Meng 定（不在本次两处小问题范围内）。
- `docs/代码地图.md` 学科管理一段已按修好后的行为更新（轮换表新值、封面默认灰、圆点显示规则、老库后果）。
