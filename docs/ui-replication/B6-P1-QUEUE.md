# Batch 6 P1 — 整理队列快照修复（SR2-5 / SR2-6 / SR2-26）

- 执行员：A-queue
- 日期：2026-11-15
- 范围：只改 `lib/modules/organize/organize_page.dart` 与
  `test/organize_page_test.dart`；不提交、不推送。
- 验证：`flutter analyze`（两文件）0 问题；
  `test/organize_page_test.dart` **38/38 通过**（原 30 + 新增 9，
  其中 1 个为对照用例；回退验证见 §4）。

## SR2-5 — 队列弹窗内连续两次批量操作，第二次用旧快照抹掉第一次的改动

### 改了什么

`lib/modules/organize/organize_page.dart:2286-2306`
`_QueuePopupState._batchTagRedo`：保存后用 `setState` 把 `#需重做`
同步回弹窗内的 `_questions`（与 `_batchAddFolder` 同款 map，
按 `_selected` 匹配、未打标签的才追加），随后才发 `onNotify`。
此后 `_batchAddFolder` / `_batchConfirm` 从 `_selectedQuestions`
取行时拿到的已是带标签的新快照，第二次整行覆盖不再抹标签。

- 规定修法是“`_batchTagRedo` 保存后同步更新 `_questions`，或批量
  操作前按 id 重读最新行再合并”——采用前者，无出入。
- `_batchConfirm` 本身未动：它读的就是 `_questions`，同步修好后
  其入参自然新鲜；另 `_batchDelete` / `_deleteOne` 原先已同步，
  弹窗内四条批量路径至此全部闭合。

### 测试

`test/organize_page_test.dart:844,863`（组 `B6-P1 队列快照`）：

- `SR2-5：同一弹窗内打标签 → 加文件夹 → 关闭，标签与文件夹都在`——
  勾选 q1 → 批量打标签 → 批量加入该文件夹（默认本科首个文件夹 f1
  「试卷」）→ 关闭，断言 `q1.tags` 含 `需重做` 且 `folderIds` 含 `f1`。
- `SR2-5：同一弹窗内加文件夹 → 打标签 → 批量确认，标签与文件夹都在`——
  覆盖 SR2-5 点名的另一条路径（先加文件夹再打标签再批量确认），
  断言 `isOrganized`、`tags`、`folderIds` 都在，且页头变“还剩 2 道”。

## SR2-6 — `_saveCurrent` 只写库、不同步内存 `_queue`，切题往返后保存覆盖已落盘改动

### 改了什么

`lib/modules/organize/organize_page.dart:313-327`
按 B5-P1-7 报告自己建议的根治方案：`_saveCurrent` 在 `repo.save` +
`syncCauseRecords` 成功后，把保存后的行（`_formQuestion(q)` 的
返回值 `updated`）写回 `_queue` 中对应 id 的位置；失败时不写回，
`_queue` 保持旧行（由 SR2-26 的调用方拦下切题、提示重试）。

- 写回用直接赋值、不用 `setState`：每个调用方随后都会
  `setState` / `_loadForm` / `_refresh`；且失败路径（未挂载）下
  直接改列表最安全，不会触发 dispose 后 `setState`。
- `lib/modules/organize/organize_page.dart:399-404`
  `_openQueue` 里 B5 的单点补丁（落盘后把表单行写回 `_queue` 再拍
  快照）已删除——`_saveCurrent` 成功后 `_queue` 已是新行，直接拍
  快照即可，单点补丁与根治方案重复，留着是两处事实来源。
  `_openQueue` 的 SR-P1-7 注释仍保留，行为不变。

### 测试

`test/organize_page_test.dart:883`：

- `SR2-6：改表单 → 下一道 → 上一道 → 保存草稿，文件夹与答案仍在`——
  改 q1 表单（选「平时作业」f2 + 答案 `答案：1`）→ 下一道 →
  上一道 → 断言表单仍显示“本题必填已齐” → 点「保存草稿」→
  断言 `repo.saved` 里 q1 最后一次保存的 `folderIds` 含 `f2`、
  `answer` 为 `答案：1`。

## SR2-26 — 四处 `_saveCurrent` 无 try，保存失败时队列打不开且无提示

### 改了什么（与规定修法的出入，见下）

新增 `lib/modules/organize/organize_page.dart:334-344`
`_trySaveCurrent()`：包 try/catch，成功返回 true；失败弹
SnackBar `保存失败，请重试` 并返回 false。以下调用点全部改走它：

| 调用点 | 行 | 失败行为 |
| --- | --- | --- |
| `_saveDraft` | :345 | 不谎报“草稿已保存”，只弹失败提示 |
| `_goTo` | :352 | 拦下切题，留在当前题 |
| `_openDetail` | :382 | 拦下、不进详情页（SR2-26 未点名，同根同文件，顺带修，见 §3） |
| `_openQueue` | :401 | 拦下、不开队列 |
| `_jumpToQuestion` | :460 | 拦下跳转、留在当前题（弹出层已关，用户可重开队列再跳） |
| `_applyQueueSort` | :476 | 拦下、不改排序（弹出层仍开着） |

### ⚠️ 与规定修法的出入（有意为之）

SR2-26 给了两个选项：(a) 失败弹提示后**仍允许**打开队列/切题，
(b) **明确拦下**并提示原因。本修复选 (b)，原因：

- 选 (a) 时“表单改动留在内存里”不成立：`_goTo` /
  `_jumpToQuestion` / `_applyQueueSort` 随后就调 `_loadForm`，
  `_openQueue` 随后 `_closeQueue` 就调 `_refresh`——两者都会用
  `_queue` / 库里的旧行重建表单控制器，未保存的改动当场丢掉，
  与 SR2-6 投诉的是同一类静默丢失，只是换了触发条件。
- 选 (b) 时改动真正留在内存里（控制器与 `_queue` 都没动），
  用户点一次「队列」/「下一道」/「保存草稿」即可重试保存，
  行为与提示一致。

### 测试

`test/organize_page_test.dart:256-277`
新增 `FailingSaveRepo`（包住 `FakeOrganizeRepo`，`failSave`
开关打开后 `save` 一律抛 `StateError('模拟写库失败')`，其余调用
仍走内存假实现；开关留在测试手里，先正常打开队列、再打开失败，
分别覆盖 `_openQueue` 与 `_jumpToQuestion` / `_applyQueueSort`
的失败路径）。用例（:911-1006）：

- `SR2-26：打开队列时保存失败，弹提示且队列打不开`
- `SR2-26：切题时保存失败，弹提示且留在当前题`
- `SR2-26：队列内跳转时保存失败，弹提示且留在当前题`
- `SR2-26：队列内改排序时保存失败，弹提示且主队列排序不变`
  （恢复写库后关掉重开，父页仍是时间降序，q1 在上）
- `SR2-26：保存草稿失败时提示失败，不谎报已保存`
- `SR2-26（对照）：队列内改排序保存成功时，主队列按新排序重排`
  （保存成功时排序照常生效，排除“修法把排序功能修没了”的可能）

每个失败用例都另断言 `tester.takeException()` 为 null（异常
已被接住，没有未处理的异步异常逃出 `onTap`）。

#### 排序用例的键盘选单（测试手法说明）

队列层是 OverlayEntry，里面的 `DropdownButton` 菜单项**点按在
测试里落不到菜单上**：5 个探针确认，点按菜单项后菜单仍开着、
`onChanged` 不触发、`saved` 不变（Flutter SDK 的菜单项本身是
正常 InkWell + `Navigator.pop`，疑似 OverlayEntry 与 PopupRoute
在测试绑定里的叠放/命中顺序问题，未深究——产品行为不受影响，
真机上点按菜单是正常路径）。改走键盘：菜单打开时当前项已获
焦点（`autofocus: isSelected`），Tab 移到下一项（时间升序），
回车选中；探针证实该路径下 `onChanged` → `_applyQueueSort` 正常
触发（失败时 snack=1、saved 不变；成功时排序生效）。若将来有
执行员改这处测试，先确认点按是否恢复可用。

## 验证

- `flutter analyze lib/modules/organize/organize_page.dart test/organize_page_test.dart`：**No issues found**。
  （全仓 analyze 另有 1 个 warning：
  `lib/modules/wrongbook/wrongbook_directory.dart:161` 未用局部变量，
  是另一执行员的文件（SR2-7），未碰。）
- `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux flutter test --concurrency=1 test/organize_page_test.dart`：
  **38/38 通过**（约 14 秒）。未跑全量测试（按任务要求，留给总协调）。
- 回退验证（新测试确实钉得住 bug）：临时去掉三处修复
  （`_saveCurrent` 写回、`_batchTagRedo` 同步、`_trySaveCurrent`
  的 try/catch）后重跑本组，**8 个修复相关用例全失败、仅对照
  用例通过**；恢复后再次全绿。回退标记已清掉，`grep 临时回退验证`
  无残留；5 个探针用的临时测试文件已删除。

## 遗留问题

- `_confirmCurrent`（:360 起）自己的保存（`repo.save` +
  `syncCauseRecords` + `saveRecentTask`）仍无 try：确认整理时写库
  失败会直接抛到按钮回调、无提示。这是 SR2-26 未点名的第五处，
  与本批三项同根但路径不同（确认整理成功后还要 `_refresh`），
  未动，留给协调员决定是否另立一项。
- `_jumpToQuestion` 失败时弹出层已先关闭（入口在保存前移除）：
  用户留在当前题、改动完好，但需重开队列再跳一次。属可接受的
  轻微体验代价；若要“失败时层也不关”，需把保存移到移除入口
  之前，改动稍大，未做。
- 队列内排序下拉的菜单项点按在测试里失效（见 §SR2-26 末尾）：
  目前用键盘选单绕过；若真机或后续 Flutter 版本下该行为有变，
  值得回头确认是否产品侧也有叠放问题——但现有测试（行点击、
  复选框、批量条）都证明队列层本身的点按正常，只有
  DropdownButton 菜单这一种点按失效，倾向于是测试绑定里的
  PopupRoute 叠放 quirks，而非产品 bug。
