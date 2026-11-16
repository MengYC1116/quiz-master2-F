# B11-9 考试倒计时

- 范围：Batch 11 第 9 项，按 Meng 2026-11-15 23:19 更正后的最终范围——考试事件与试卷完全脱钩（旧 brief 里“可选关联试卷”的说法作废，不做）。
- 状态：完成。未 commit、未 push。`docs/decision-log.md` 未改（存储选址与倒计时口径见 §5“决策”，由协调员统一记 D-25+）。
- 演示库未动：跑测试前后 `~/.local/share/quiz-master2/quiz-master2.db` md5 均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（备份在 `~/workspace/demo-db-backup/quiz-master2.db.b11-w5`）。未跑应用（见 §7），无应用截图。

## 1. 改了什么文件

| 文件 | 改动 |
|---|---|
| `lib/models/exam_event.dart`（新增） | `ExamEvent` 模型（id / 自定义名称 / 仅日期）+ 纯函数倒计时逻辑：`daysUntilExam`、`nearestExamEvent`、`examCountdownText`、`isExamCountdownNear`、`formatExamEventDate`、`dateOnly` |
| `lib/data/db_settings.dart` | `loadExamEventsFromImpl` / `saveExamEventsIntoImpl` + `AppDatabaseSettings` 扩展的 `loadExamEvents()` / `saveExamEvents()` |
| `lib/data/database.dart` | 新增 `examEventsKey = 'examEvents'` 常量 + `loadExamEventsFrom` / `saveExamEventsInto` 静态转发 + import |
| `lib/data/repository.dart` | 新增 `examEvents()`（按日期升序）、`saveExamEvent()`（同 id 覆盖）、`deleteExamEvent()` |
| `lib/modules/settings/settings_page.dart` | 新增第六组“考试”（分段折叠风格不变）；新增/改名/改日期/删除；新增 `initialOpenGroup` 参数 |
| `lib/modules/home/home_page.dart` | 焦点卡上方新增倒计时条 `_ExamCountdownStrip`；`_load` 里多读 `examEvents()`；新增 `onGoSettings` 回调 |
| `lib/app.dart` | 新增 `_settingsGroupArg` + `_goSettings({group})`；首页倒计时点按 → 设置页并展开考试组 |
| `test/b11_9_exam_countdown_test.dart`（新增） | 23 个测试（见 §6） |
| `test/home_page_test.dart`、`test/s8b2_subject_sync_test.dart`、`test/b8_1_subject_refresh_test.dart` | 各补一行 `examEvents()` Fake 覆盖（默认空，见 §5） |

未碰：collect / organize / wrongbook / detail 的页面文件、`docs/decision-log.md`、现有表 schema、备份表清单。

## 2. 行为

- **设置页 → 考试组**（第六组，位于“错题本”与“数据”之间，分段折叠：默认全折、一次只开一组）：
  - 加一场考试：只填自定义名称（最长 40 字）+ 选考试日期，不选试卷、不关联试卷、不读任何试卷数据；名称为空 / 未选日期 / 重名时给提示，不入库。
  - 列表按日期升序，每行显示名称 + `yyyy-MM-dd` + 当天算出的倒计时文案，右侧“改名 / 改日期 / 删除”。
  - 改名：弹窗改，保存后原地更新；改日期：日期选择器改，保存后原地更新（顺序按新日期重排）；删除：`_showConfirmDialog` 确认（“删除这场考试，确定吗？／「X」删了就没了，确定吗？”），只删事件本身，不动任何题目/试卷。
  - 空态：“还没有考试，加一场吧。”；组头说明：“这里的考试只用来在首页倒计时，不关联任何试卷。”
  - 考试列表平时不读库：只在考试组打开时读（`_toggleGroup('exams')`，与数据组的打开时扫描同一做法）；从首页倒计时点进来时（`initialOpenGroup == 'exams'`）在 `initState` 读一次。
- **首页**：焦点卡上方一条倒计时（最近一场考试），整条可点：
  - 文案：`距离 <名称> 还有 N 天`；当天 `今天 <名称>`；过期 `<名称> 已考完`；右侧小字“设置 ›”。
  - 临近标红：0 ≤ N ≤ 7 时文字用 `DesignTokens` 的 `errInk`（亮色 `#B42318`，不新增颜色）；8 天以上与过期用常规墨色。
  - 无考试时不显示、不占位，布局 C 不变。
  - 点按 → 进设置页并直接展开考试组（`app.dart` 的 `_goSettings(group: 'exams')` + `SettingsPage.initialOpenGroup`；`didUpdateWidget` 里组键变化时跟进展开）。
- **明确不做的**：不做“可选关联试卷”、不做“点倒计时进该试卷题目列表”、不做“考前冲刺（只练这场考试的错因）”。

## 3. 存储选址与理由

**选址：复用同一 SQLite 库的 `settings` 表，`examEvents` 键下存 JSON 数组**（与 `lastRoute` / `backupFailed` / `lastRecheckReminderDate` 同一做法）。未新建 `exam_events` 表。

理由：

1. **不碰备份校验**：`validateBackupData` 要求 `backupTables` 里的每一张表键齐全（SR-P2-4 的有意设计，缺键即拒绝恢复）。新表若进 `backupTables`，此前导出的旧备份会因缺 `exam_events` 键而无法恢复；若不进，考试事件会在备份/恢复时静默丢失。放 settings 表则 settings 整表本来就在备份里，事件随备份走、随恢复回来，旧备份恢复也不受影响（新备份才多这一行，旧备份缺行按空列表读）。
2. **不改 schema**：不新增表、不改现有表、不写 onUpgrade（v2 老库直删不迁移的口径也不受影响）；v1 演示库结构完全不动。
3. **数据量与访问形态匹配**：用户手管几场考试，列表很小、总是整读整写、无关系查询；增删改走 repository 层读-改-整表写回。JSON 行坏了按空列表读（坏行单独跳过，不弹错、不拖垮列表）。
4. **与试卷彻底隔离**：`ExamEvent` 与 `Exam`（试卷实体）无任何关系——不同存储位置、不同 id 前缀（`exam-event-` vs `exam-`）、无外键、无引用；`questions.exam_id` 一行代码未动。

## 4. 倒计时口径（写死定义）

- **N = 考试日期 − 今天**：两者先去掉时分秒（本地时区的日历日），再相减。今天 = 0，明天 = 1，昨天 = −1；同一天内任何时刻结果相同。
- **多场取“最近一场”**：未过期的（含今天）里取 N 最小的一场；全部过期时取最近过期那场（N 最大，即离今天最近的过去日期）；无考试返回 null；同一天两场取列表先出现者。
- **文案**：N > 0 → `距离 <名称> 还有 N 天`；N = 0 → `今天 <名称>`；N < 0 → `<名称> 已考完`。
- **标红**：0 ≤ N ≤ 7（7 天 / 3 天 / 1 天都在内）；过期（N < 0）与 8 天以上不标红。
- **日期**：只存年月日（`yyyy-MM-dd` 字符串），不存时分秒、不存时区。

## 5. 决策（供协调员记 D-25+，按更正写）

1. **考试事件独立存储，与试卷实体无任何关联**：存 settings 表 `examEvents` 键（JSON 数组），不新建表、不并入试卷表（理由见 §3）。
2. **倒计时口径**：N 按日历日算（不含时分秒）；最近一场 = 未过期里 N 最小，全部过期时取最近过期那场；文案与标红阈值按 §4。
3. **设置页分组**：考试管理单独成组“考试”，放“错题本”与“数据”之间，保持分段折叠风格（默认全折、一次只开一组）。
4. **标红口径**：临近 7 天 / 3 天 / 1 天理解为“7 天内”（0 ≤ N ≤ 7）标红，而非仅在 N 恰好等于 7 / 3 / 1 当天标红。
5. **考试列表懒加载**：设置页平时不读考试事件，只在考试组打开时读（从首页倒计时点进来时读一次），避免无谓读库，也避免旧测试被新 repo 调用波及。
6. **旧 Fake 补覆盖**：首页 `_load` 新增 `repo.examEvents()` 调用后，三个直接 pump 首页的旧 Fake（`home_page_test.dart` / `s8b2_subject_sync_test.dart` / `b8_1_subject_refresh_test.dart`）必须覆盖该方法返回空——否则会走到真实单例库。背景：`dataDirectoryPath` 无测试守门，未覆盖的 Fake 在测试里会真的打开 `~/.local/share/quiz-master2/quiz-master2.db` 并按 §6 删掉 v1 演示库。整应用测试（`QuizMasterApp`）用的是内存库单例，不受影响。本次已补三处；今后新增 repo 调用进首页/设置页时，须同步检查这些 Fake。

## 6. 测试结果

- 新测试 `test/b11_9_exam_countdown_test.dart`：**23/23 通过**（`flutter test --concurrency=1`，`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，默认 /tmp）：
  - 单元（纯函数）：天数数学（今天/明天/过去/时分秒忽略）、最近一场（未来优先、今天优先、全部过期取最近过期、空、无/同日平局）、文案（未来/今天/过期）、标红阈值（0~7 红、8 与 −1 不红）、日期格式与 JSON 往返/坏行。
  - 存储（内存库）：空库读空、写后读回、坏 JSON/坏行按空列表；经 repository 增删改（按日期升序、同 id 覆盖、删只删自己、删不存在的 id 不动）。
  - Widget 设置页：默认六组全折、空态、加一场（名 + 日期选择器 OK）、改名弹窗、改日期（点当月 15 号）、删除确认、`initialOpenGroup='exams'` 直接展开。
  - Widget 首页：无考试不显示、5 天后标红 + 点按回调、10 天后不红、今天标红、过期“已考完”不红、多场只显示最近一场。
- 回归（同条件，逐文件跑）：`home_page_test` 18/18、`settings_page_test` 26/26、`s8b2_subject_sync_test` 11/11、`b8_1_subject_refresh_test` 11/11、`s8a5_section_scroll_test` 2/2、`p0b1_settings_owner_test` 3/3、`p0b2_pagesize_test` 2/2、`b8_1_subject_refresh_flow_test` 1/1、`b9_3_review_badge_test` 7/7、`b9_1_collect_done_test` 6/6（首次跑 5/6：其中“单题确认”一次 `_pumpUntil` 超时，属整理台流程用例；立即单独重跑通过，系多 worker 并发跑测试时 CPU 争用导致的等待超时，与本次改动无关——本次未碰 collect/organize）。
- `flutter analyze`（11 个改动/相关文件）：**0 问题**。
- 全量测试未跑（按 brief，协调员最后统一跑全量验收）。

### 测试中修掉的两个真 bug

1. `loadExamEventsFromImpl` 在无行/坏 JSON 时返回 `const []`（不可变），`repository.examEvents()` 对其 `sort()` 抛 `Unsupported operation`。已改为返回可变空列表。
2. 改名弹窗里 `TextEditingController` 在 `showDialog` 返回后立即 `dispose()`，弹窗关闭动画期间字段仍挂在树上，触发 “used after being disposed”，并连带污染后续测试。已改为 `TextFormField(initialValue + onChanged)`，不用控制器。

### 环境说明（与本次代码无关）

- 多 worker 并发跑测试时 VM 很挤：一次 7 文件合跑被饿死 12 分钟无输出（共享测试缓存锁 + 1.5 核）；一次合跑因 `/tmp`（512M tmpfs）被并发编译占满而 `No space left on device`——清掉自己失败残留的两个 `flutter_tools.*` 目录后逐文件重跑通过。后续如再遇，先查 `df /tmp` 与并发编译。
- 未跑应用、未截图：跑应用会删 v1 演示库且与其他 worker 共用同一份 live DB，视觉覆盖已由 widget 测试（文案、颜色、点按）承担；如需真机截图，协调员安排错峰跑应用。

## 7. 遗留与建议

- 无已知遗留 bug。协调员全量验收时留意：`b9_1` 的“单题确认”在重负载下有一次等待超时（已单独重跑通过），若全量时再现，优先看 CPU 争用而非本次改动。
- 未来如需扩展（如临近提醒通知），考试事件已在 settings 表 JSON 里，可直接复用 `nearestExamEvent` / `daysUntilExam`；不要把事件往 `exams`（试卷）表里并。
