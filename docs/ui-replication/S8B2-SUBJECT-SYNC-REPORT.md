# S8 B2：新增学科同步首页 / 导航（导航速览最多 5 科）

- 裁决：Meng 2026-11-13 14:37，必须改。
- 日期：2026-11-13
- 分支：`ui-replication`（未 commit、未 push，按任务要求）
- 范围：只做 B2；QmChip / SubjectLabel 未碰（另有专人）；B3 及以后未碰。

## 1. 改了什么

### 1.1 读取点：从 `Subject.all` 写死三科 → 读库里的 `subjects` 表

| 位置 | 改前 | 改后 |
|---|---|---|
| 首页 `lib/modules/home/home_page.dart:551` 附近 | `_BottomGrid` 遍历 `Subject.all` | `_HomePageState._load()` 增加 `widget.repo.subjects()`（`allSubjects()`，`ORDER BY rowid` 入库顺序），经 `_BottomGrid(subjects:)` 遍历，全部学科都显示；库为空时回退 `Subject.all` |
| 导航速览 `lib/widgets/app_shell.dart:214` 附近 | 遍历 `Subject.all` | `AppNavBar` 新增 `subjects` 参数（`List<Subject>?`，null = 未传，沿用预设三科，兼容旧调用与纯展示测试），遍历 `(subjects ?? Subject.all).take(5)` |
| 应用层 `lib/app.dart` | — | `_QuizMasterAppState` 新增 `_navSubjects`（初值 `Subject.all`），`_refreshBadges()` 里 `repo.subjects()` 同步读入，传给 `AppNavBar`。`_refreshBadges` 由 `badgeVersion` 监听驱动，`upsertSubject` 会 bump badgeVersion，所以学科管理页新增学科后导航自动同步，无需单独刷新通道 |

### 1.2 5 科上限的实现

- `app_shell.dart`：`(subjects ?? Subject.all).take(5)`，按入库顺序取前 5。
- 不足 5 科全显示；超过 5 科只显示前 5。**没有加“还有 N 科”提示**——现有设计无此提示，按任务要求不加。
- 首页不设上限，全部学科都显示。

### 1.3 首页格子布局：超过一行时分行（为“全部显示”必须做的适配）

- 原布局写死 4 格：4 列单行、2 列固定取 `minis[0..3]`（第 5 格起会被丢掉）。
- 改为按列数分块：`minis` 按 `columns`（4 / 2）切成若干行，每行 `IntrinsicHeight` + `Expanded` 等高拉伸；末行不满时用空白 `Expanded` 补齐列数，保持各格同宽。
- 4 格时与以前完全一致（4 列一行 / 2 列两行）；1 + 6 格时 4 列分两行（4 + 3）、2 列分四行。1 列分支未变。

### 1.4 计数口径：未变，但键的来源改了

- `lib/data/repository.dart`：`homeRevCounts()` 与 `pendingOrganizeBySubject()` 以前按 `Subject.all` 初始化计数键，新学科的键缺失，首页 `revCounts[s.id] ?? 0` 会把有题的新学科显示成 0。
- 改为按 `await subjects()`（库里的 subjects 表）初始化键；where 口径（要复习：手动加入、已整理、至少一个错因未解决或已到复查时间，数题不数错因；待整理：未确认整理且未归档）一字未动。
- `subjectCounts()`（错题本封面三数）仍按 `Subject.all`，未动——见 §5，它是错题本的口径，属后续同步范围。

### 1.5 颜色回退：`subjectInk` / `subjectSoft` 补 stored 参数

- `lib/theme/design_tokens.dart`：照 S8A2 给 `subjectColor` 加 `stored` 的办法，给 `subjectInk` / `subjectSoft` 补同样的可选参数 `[Color? stored]`。
- 预设三科（math / english / politics）传了存色也仍走主题固定色；非预设 id + 有存色时：
  - `subjectInk`：直接用存色（与 S8A2 圆点做法一致，亮/深同此）。
  - `subjectSoft`：不用存色原值（大块饱和色太刺眼），用存色调出的淡 tint——亮色 = 白底混 12% 存色（数学蓝算出约 `#E6EFFE`，与 `--math-soft #E1EDFF` 同档）；深色 = 深灰底 `#262B33`（三科深色 soft 本就是同一值）混 15% 存色，带一点本科色调。
- 调用点：
  - 首页 `home_page.dart`：`subjectInk(s.id, brightness, s.color)` / `subjectSoft(s.id, brightness, s.color)`。
  - 导航速览圆点：S8A2 已修好（`_SubjectRow` 传 `widget.subject.color`），本次核对无误，未再改。
  - 学科管理页圆点：已传 `s.color`（S8A2 时已是此做法），未改。

## 2. 未改的 `Subject.all` / `subjectInk` 清单（请 Meng 定是否后续同步）

本次裁决范围只是首页 / 导航，以下均未改：

| 位置 | 现状 | 影响（新学科时） |
|---|---|---|
| `lib/modules/review/review_page.dart:220-221` | 复习排序用的学科顺序表按 `Subject.all` 建索引 | 新学科在复习列表排序中无索引位（排序回退行为待定） |
| `lib/modules/review/review_page.dart:885` | 学科筛选 chips 遍历 `Subject.all` | 新学科没有筛选 chip，筛不出来 |
| `lib/modules/report/report_page.dart:163` | 弱点定位用 `Subject.all.indexWhere` | 新学科的弱点定位不到（index = -1） |
| `lib/modules/report/report_page.dart:444-450` | 按学科分布遍历 `Subject.all` | 新学科不出现在分布里 |
| `lib/modules/report/report_page.dart:622-623` | 弱点行颜色 `subjectInk(group.subjectId, brightness)`，未传存色 | 新学科弱点行落到数学色 |
| `lib/data/repository.dart:202` `subjectCounts()` | 仍按 `Subject.all` 初始化键（错题本封面三数用） | 新学科封面“要复习 / 待复查 / 已解决”三数缺键（错题本页读库 subjects 显示书，但三数可能显示 0） |
| `lib/modules/collect/collect_page.dart:577` | 导入学科下拉框 `items: Subject.all` | **新学科在收集中心选不到，无法导入题目**——新学科目前只能由别处产生题目，收集入口是断的；建议优先定 |
| `lib/modules/wrongbook/wrongbook_page.dart:3020` | 紧凑行 / 归档行 `_prowMetaLine` 用 `Subject.byId(q.subjectId)`（未知 id 回退到数学）+ `subjectInk(..., Brightness.light)` 未传存色 | 新学科的题目在紧凑行里学科名会显示成“数学”，且为数学色 |
| `lib/modules/wrongbook/wrongbook_page.dart:48,145` | 初始值 `Subject.all`，加载后用库 subjects（空库才回退） | 已读库，无影响，列出仅为完整 |
| `lib/data/database.dart:185,199` | 种子数据（建库时写入初始三科及文件夹） | 种子专用，无影响 |
| `lib/widgets/uikit.dart:532,556` | QmChip / SubjectLabel 的 `subjectColor` 未传存色 | 另有专人修，本次未碰 |

## 3. 测试

- `flutter analyze`：**0 问题**。
- `flutter test`：**323/323 通过**（新增 `test/s8b2_subject_sync_test.dart` 11 个；另补了 `test/home_page_test.dart` 的 `FakeRepo.subjects()` 覆盖——首页改读库后，不覆盖会在测试里打开真实数据库）。
- 新增测试覆盖：
  - 首页：新增第 4 科后显示 4 科格，化学格数字走新学科 id 的计数键（要复习 1 道 · 待整理 1 道）；新增到第 6 科后 6 科格全显示；6 科 × 亮/深 × 2 列窄窗无溢出；新学科格标题色 / 底色走存色、不等于数学色（亮/深各断言）。
  - 导航：4 科全显示；6 科只显示前 5 科，第 6 科（地理）不出现、其计数也不出现；未传 subjects 时沿用预设三科。
  - Token：非预设学科 ink 直接用存色、soft 是存色 tint（均不等于数学值，亮/深）；预设三科传了存色仍走主题固定色；无 stored 时与旧行为一致。

## 4. Linux 真机验证

- 构建：`flutter build linux --release` 成功。
- 脚本：`docs/ui-replication/run-shots-s8b2.sh`（仿 S8B1 脚手架；`probe` 只截一张，默认四张全截；改库前整库备份，trap 恢复）。
- 临时改库（拍完已恢复）：加化学（紫 `0xFF7C5CFC`，轮换表第 4 位）+ 2 道题（`q-chem-1` 已整理已加入复习 + 1 条 pending 错因 → 要复习 1；`q-chem-2` 未整理 → 待整理 1）；再加历史（橙 `0xFFF08A1D`）、地理（蓝 `0xFF2E7CF6`，轮换表绕回首位，与学科管理页新建第 6 科的实际取色一致），无题。
- 截图（`docs/ui-replication/shots/s8b2/`，1280×720，标准字号）：
  - `home-4-dark-standard.png`：导航 4 行（化学紫圆点，待整理 1 · 待复习 1）；首页 1 + 4 格，化学格紫标题 + 紫 tint 底、“要复习 1 道 · 待整理 1 道”；焦点卡由 3 道变为 4 道要复习。
  - `home-4-light-standard.png`：同上，亮色；化学格浅紫底 + 紫标题。
  - `home-6-dark-standard.png`：首页 1 + 6 格（第二行化学 / 历史 / 地理，标题各为紫 / 橙 / 蓝）；导航只显示前 5 行（数学 / 英语 / 政治 / 化学 / 历史），地理不出现。
  - `home-6-light-standard.png`：同上，亮色；三科新格底色分别为浅紫 / 浅橙 / 浅蓝 tint。
- 库恢复核对：`subjects=3`、`questions=9`、`themeMode=dark`，备份文件已删；应用已杀（`pkill -x quiz_master2`），无残留 Xvfb 进程。

## 5. 观察到的问题（未修，超出 B2 范围）

1. **6 科时导航速览 5 行把“设置”按钮顶出 720px 首屏**（见 `home-6-*.png` 左下角：第 5 行“历史”只露一半，设置按钮不可见）。导航列本身可滚动（R2 已有设计），按钮能滚出来，不是丢失；高窗口下能放下。是否要为 5 行速览压缩行高或改布局，请 Meng 定。
2. 导航速览计数文字在 216px 宽下会折成两行（“待整理 1 · 待复习 1”分两行显示）——R2 已有 `Flexible` 换行处理，是既有行为，B2 未动；4 科时同样如此。
3. 第 6 科地理的轮换色绕回蓝色 `0xFF2E7CF6`，与数学新蓝相同（学科管理页 `_newSubjectColors` 只有 5 个色，第 6 科 `orElse` 取首位）。圆点 / 标题色与数学完全一样，只能靠科名区分。这是既有轮换表行为，B2 未动；如需区分请另定（加色或改轮换规则）。

## 6. 改动文件（未 commit、未 push）

- `lib/theme/design_tokens.dart`：`subjectInk` / `subjectSoft` 加 stored 回退。
- `lib/data/repository.dart`：`homeRevCounts` / `pendingOrganizeBySubject` 的键改按库 subjects 表。
- `lib/modules/home/home_page.dart`：读库 subjects、传 stored 色、格子按列数分行。
- `lib/widgets/app_shell.dart`：`subjects` 参数 + `take(5)`。
- `lib/app.dart`：`_navSubjects` 状态 + `_refreshBadges` 同步 + 传参。
- `test/s8b2_subject_sync_test.dart`（新增，11 个测试）。
- `test/home_page_test.dart`：`FakeRepo` 增加 `subjects()` 覆盖（不碰真实数据库）。
- `docs/ui-replication/run-shots-s8b2.sh`（新增）、`docs/ui-replication/shots/s8b2/*.png`（4 张）。
- 本报告 `docs/ui-replication/S8B2-SUBJECT-SYNC-REPORT.md`。
