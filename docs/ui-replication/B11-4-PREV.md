# B11-4 整理返回上一道（最小版）

## 结论

**产品行为已在 R5 存在，本项无 lib 代码改动。** 整理工作台右表单底部的
工作区（`_workActs`）已有「上一道 / 下一道 / 查看题目详情」一组按钮；
「上一道」按当前队列顺序回上一道、第一道时禁用、切题时自动保存、已填
内容原样显示——四条验收点逐条核对均已满足。本项补的是验收测试：
第一道禁用与往返后内容原样此前没有显式用例钉住（SR2-6 只覆盖了
“改表单 → 下一道 → 上一道 → 保存草稿”这一条往返链，没有断言禁用态）。

## 改了什么文件

| 文件 | 改动 |
|---|---|
| `test/b11_4_prev_question_test.dart`（新） | 2 个 widget 测试（见下） |
| `lib/modules/organize/organize_page.dart` | 未改动 |
| 其他 | 未改动 |

## 行为（现状核对，逐条对验收）

按钮位置：`_workActs`（右表单底部，保存草稿说明行之下），与「下一道」
并排，`QmButtonVariant.plain`。

- **按当前队列顺序回上一道**：`onPressed: _index > 0 ? () => _goTo(_index - 1) : null`。
  `_goTo` 只改下标，不动 `_queue` 顺序（队列顺序只由 `_sortQueue` /
  队列弹窗改排序决定，本项未碰）。
- **第一道时禁用**：`_index == 0` 时 `onPressed` 为 null；`QmButton`
  经 `_QmPressable` 按 disabled 处理（透明度 .45、不可点、不可聚焦），
  不是“看着可用但点了没反应”。
- **已填内容原样显示**：`_goTo` 先 `await _trySaveCurrent()`（失败则拦下
  切题、提示“保存失败，请重试”，见 SR2-26），成功后 `_loadForm()` 从
  已写回 `_queue` 的新行重建表单；`_saveCurrent` 成功后把新行写回内存
  `_queue`（SR2-6 根治），往返不丢改动。
- **保存失败时留在当前题**：与「下一道」同一路径（SR2-26 已覆盖）。

## 测试结果

新文件 `test/b11_4_prev_question_test.dart`，2/2 通过（串行，
`flutter test --concurrency=1`，默认 /tmp）：

1. `第一道时“上一道”禁用，点按不切题；“下一道”启用`——断言第一道时
   上一道 `QmButton.onPressed` 为 null、下一道非 null；禁用态点按后仍在
   第一道（数学 · 函数极限），且 `repo.saved` 为空。
2. `到第二道后“上一道”启用；点回第一道，改动内容原样`——先改表单
   （选文件夹「平时作业」+ 答案「答案：1」），下一道到导数综合后上一道
   启用；点回第一道，显示“本题必填已齐”，`repo.saved` 里 q1 的保存行
   文件夹含 f2、答案为「答案：1」；回到第一道后上一道再次禁用。

相关既有测试复核（串行，同批跑）：`test/organize_page_test.dart`、
`test/b11_11_empty_states_test.dart`、`test/b2_win11bug_organize_test.dart`、
`test/b8_6_accordion_test.dart`、`test/b8_1_subject_sweep_test.dart`、
`test/b5_p2_collect_test.dart` 共 92/92 通过（第一次跑时
`b5_p2_collect_test.dart` 的 SR2-62 闪失败 1 个；单跑该用例与重跑整批
均通过，是该用例本身的时间敏感随机段断言抖动，与本项无关——本项未改
任何 lib 代码）。

`flutter analyze`（所改文件）：0 问题。

## 决策

- D（待协调员编号，D-25+）：第 4 项不新增代码——「上一道」按钮自 R5
  已在 `_workActs`，行为与验收一致；本项只补禁用态与往返的显式测试。
  若后续要改（如键盘快捷键、长按连续切题），另立项。
