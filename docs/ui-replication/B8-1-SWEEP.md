# B8-1 扫尾：删学科后幽灵学科复活——剩余 5 处回退清扫

- 批次：第 8 批第 1 项扫尾（Meng Win11 真机验收 2026-11-15 14:46，第 1 项；
  截图 image-89 / 90 / 98）
- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 状态：完成；`flutter analyze` 0 问题；目标测试通过（见下）

## 背景

第 1 项工人已修根因 `subjects.isEmpty ? Subject.all : subjects` 的四处
（导航速览、收集下拉、错题本书架、首页），根因：新库建表时已预置三科
（`db_schema` `_seed`），表空只发生在用户删光学科后，此时回退预设三科
就是幽灵行 / 幽灵下拉项 / 幽灵书。本次扫尾清掉同模式剩余 5 处。

## 改了什么（5 处回退 + 5 处空初始值）

修法与前四处一致：空表就是空，直接用库里的列表；初始值也改成空
（与 `app.dart` 里初始 `_navSubjects` 改 `const []` 的做法一致），避免
加载完成前闪现预设三科。

| 文件 | 回退点（改前 → 改后） | 初始值（改前 → 改后） |
| --- | --- | --- |
| `lib/modules/detail/question_detail_page.dart` | 约 184 行 `_subjects = subjects.isEmpty ? Subject.all : subjects;` → `_subjects = subjects;` | 约 99 行 `List<Subject> _subjects = Subject.all;` → `= const [];` |
| `lib/modules/organize/organize_page.dart`（主态） | 约 181 行同上 → `_subjects = subjects;` | 约 71 行同上 → `= const [];` |
| `lib/modules/organize/organize_page.dart`（队列弹窗 `_QueuePopupState`） | 约 1914 行同上 → `_subjects = subjects;` | 约 1865 行同上 → `= const [];` |
| `lib/modules/report/report_page.dart` | 约 157 行同上 → `_subjects = subjects;` | 约 96 行同上 → `= const [];` |
| `lib/modules/review/review_page.dart` | 约 200 行 `final subjectList = subjects.isEmpty ? Subject.all : subjects;` → `final subjectList = subjects;` | 约 130 行同上 → `= const [];` |

各处“空库回退预设三科”的旧注释已同步改成 B8-1 扫尾口径（与
`collect_page.dart` 的注释同款写法）。

核查：改后 `grep -rn "isEmpty ? Subject.all" lib/` 零命中；
`lib/` 里剩余的 `Subject.all` 只有 `db_schema.dart` 的建表种子
（新库预置三科，正确保留）与两处历史注释里的文字提及。

## 刻意不动的

- 四页 `_subjectOf` / `_subjectName` 里 `Subject.byId(id)` 的兜底不动：
  它只在数据不一致时触发（题的学科 id 不在学科表里时回退数学），是任务
  明确保留的防线。后果见“测试口径”——单题学科名仍可能经兜底显示
  预设名，这是合规行为，不是幽灵复活。
- 未碰：`box_editor.dart`、`collect_page.dart`（第 3/4/5 项工人的文件）；
  第 1 项工人已修的四处（导航速览、收集下拉、错题本书架、首页）不动。

## 回归用例

新增 `test/b8_1_subject_sweep_test.dart`（FakeRepo，不碰真实数据库，
无文件 IO；同一 `testWidgets` 内两次 pump 用 `KeyedSubtree(UniqueKey())`
强制重建 State，见 `detail_page_test.dart` 的 `pumpDetail` 同款做法），
6 个，分四组：

- 详情页（1 个）：学科表为空时题正常显示、不崩；题不存在时空状态
  「这道题不存在了」里无预设三科。
- 整理页（1 个）：学科表为空时队列正常显示（「还剩 1 道」）；无待整理题时
  空状态「没有待整理的题目」里无预设三科。
- 报告页（2 个，差分断言）：学科表为空 + 有一条待解决错因记录时，分布区
  标题「错在哪个学科（只按学科看）」在、但「X · N 道错题」零行——修好前
  这里是数学 / 英语 / 政治三行；学科表非空时分布三行仍在（阳性对照）。
- 复习页（2 个，差分断言）：学科表为空 + 有一条待解决错因时，分组行头
  的单题学科名只出现一次（经 sanctioned 的 `byId` 兜底）；打开学科筛选
  下拉只有「全部」，无英语 / 政治，数学仍只出现一次——修好前下拉里有
  预设三科；学科表非空时下拉三科仍在（阳性对照）。

### 测试口径说明（诚实记录）

- 报告页分布行与复习页学科筛选下拉是直接遍历 `_subjects` 的列表级渲染点，
  上述差分断言真能抓 bug（已验证：修好前会渲染三行 / 三个下拉项）。
- 详情 / 整理两页只用 `_subjectOf` 查单题学科（经 `byId` 兜底），没有
  列表级渲染点——对这两页，本次改动是防呆对齐（消掉一个潜在的闪现 /
  回退源，与 B8-1“空表就是空”的规则对齐），其测试锁的是“空学科库下页面
  正常渲染、不崩、空状态里一个预设名都没有”，差分断言在报告 / 复习两页。
  详情页标题「数学 · 材料题｜函数极限」里的「数学」是单题学科名经 `byId`
  兜底显示的合规行为（题的 `subjectId` 是 `math`，学科表删空后数据不一致），
  不属于幽灵复活。

## 验证

- `flutter analyze`：No issues found。
- `flutter test --concurrency=1 test/b8_1_subject_sweep_test.dart`：6/6 通过。
- `flutter test --concurrency=1 test/report_page_test.dart`：26/26 通过。
- `flutter test --concurrency=1 test/review_page_test.dart`：39/39 通过。
- `flutter test --concurrency=1 test/detail_page_test.dart`：36/37 通过；
  唯一失败是 B8-7 P1-2「大图（200×800 真实切片）仍限高 460」（期望 460，
  实际 2.0）——B8-7 工人进行中的改动（题图区按内容高度自适应），与本次
  只改 `_subjects` 的两行无关。
- 全量：`flutter test --concurrency=1`（串行；`LD_LIBRARY_PATH` 同上），
  873 通过、1 失败（共 874 个）。唯一失败是 `test/detail_page_test.dart`
  的 B8-7 P1-2「大图（200×800 真实切片）仍限高 460」（期望 460，实际
  2.0）——B8-7 工人进行中的改动（题图区按内容高度自适应），与本次两项
  的改动无关（单跑该文件同样 36/37，同 1 项失败）。
- Linux Release 构建：`flutter build linux --release` 通过
  （`✓ Built build/linux/x64/release/bundle/quiz_master2`）。
- 演示库：全量前已备份 live 库到
  `~/workspace/demo-db-backup/quiz-master2.db.b8-6-pre`；跑完从规范 v1
  备份 `~/workspace/demo-db-backup/quiz-master2.db` 恢复 live 库并核对：
  md5 `8f7f9c64405dc6e484ac2bf8e5e1a807` 一致，`user_version` 1，
  9 道题、3 学科（全量前后 live 库均为 v1，未被改动）。
