# Batch 6 P1 — SR2-3 详情页重框事务失败删唯一切片（执行员 A-detail）

- 日期：2026-11-15
- 任务：SR2-3（Batch 5 引入的新回归），协调员定修法：临时文件 + 事务成功后 rename
- 状态：已完成，未提交、未推送

## 改了什么

### `lib/modules/detail/question_detail_page.dart`

- `:22`：新增 `import 'dart:math' as math;`（临时文件名随机后缀用）。
- `:357-434`：`_reworkBoxes` 的切片写盘 / 事务 / 失败处理整段按规定修法重写：
  - 新裁切片先写临时文件 `slices/<qid>.tmp-<毫秒>-<32 位随机>.png`（`:374-376`），与正式切片同目录，`resolveDataPath` 正常解析；临时写盘失败仍报“重新框选失败：切片写不进去”，旧切片 untouched。
  - 事务 `replaceQuestionBoxesAndSlice` 失败时 catch 只删临时文件（`:403-410`），正式路径上的旧切片从未被动过；提示文案不变（“重新框选失败：保存失败，请重试”）。
  - 事务成功后才 `File(tmpAbs).rename(sliceAbs)`（同目录同文件系统，原子替换，`:412-429`）；`evictCachedFileImage(sliceAbs)`（`:428`）随 rename 后移到事务成功后（旧写法在 `:373` 事务前清缓存）。
  - rename 失败分支（`:417-427`）：删临时文件，报“重新框选失败：切片保存失败，框已更新，请重试”——此时框与切片字段已提交、正式文件仍是旧切片，不谎称全失败，重试重框即可恢复一致。见“遗留问题”。
  - 旧的 SR-P2-3 注释（“失败即删掉正式切片”）已随整段改写删除，改为 SR2-3 新注释。

### `test/detail_page_test.dart`

- `:234-253`：`FakeDetailRepo` 增加事务失败桩 `replaceShouldThrow` / 调用记录 `replaceCalled`；`replaceQuestionBoxesAndSlice` 置桩时抛错且不记框、不存题（与真实事务回滚语义对齐）。
- `:789-851`：‘重新框选 §1.5.1’组新增 `SR2-3：事务失败时旧切片字节完好、框与题不动（有旧切片）`——夹具事先用同步 IO 把真实页图字节写成 `slices/q1.png` 旧切片，事务桩抛错后断言：提示“重新框选失败：保存失败，请重试”；旧切片逐字节相等；`slices/` 下无 `.tmp-*` 残留；`replacedBoxes` 无 q1、`saved` 无 q1（框与题不动）。文件准备与断言均用同步 IO，未在 testWidgets 里用异步文件 IO。

### 未改动的文件（说明）

- `lib/data/db_questions.dart` / `lib/data/db_collect.dart`：**均未改**。事务本体 `replaceQuestionBoxesAndSliceIntoImpl` 实际在 `db_collect.dart:325`（不在任务书所写的 `db_questions.dart`），其“换框 + 写 slice 字段同事务”的契约本身无问题，修法只涉及调用方的写盘顺序，DB 层无须动。`db_collect.dart:340-343` 的注释“切片文件本身仍由调用方在事务前写盘”现表述略旧（现为写临时文件、事务成功后 rename），因该文件不在任务清单内未碰，建议总协调转交文档/收集执行员顺带修正。
- `test/b5_p2_collect_test.dart`：**未改**。B5 的 P2-3 回归测试实际在该文件（`SR-P2-3 详情页重框事务失败不留孤儿切片`组，约 `:891-960`），不在任务书所写的 `detail_page_test.dart`；新“有旧切片”测试按任务书要求加在 `detail_page_test.dart`。旧测试未单独跑（规则只跑负责的测试文件），按代码链推断仍通过：该夹具无预置旧切片，事务失败只删临时文件，`slices/q1.png` 从未被创建，其 `existsSync() isFalse` 断言仍成立；最终以总协调阶段关口全量测试为准。

## 与规定修法有出入处

- **无出入**：严格按协调员定的临时文件方案执行，未用备选方案（写盘前读旧字节、失败写回）。
- 规定修法未提及的两处附加处理，均为该方案的直接推论，已在代码注释中写明：
  1. rename 失败分支单独提示（见上，事务已提交、只剩文件未换）；
  2. 进程在写临时文件与 rename 之间被杀会留一个孤儿 `.tmp-*.png`，由 §4.5 孤儿扫描兜底（`slices/` 下无引用文件）。

## 测试证据

- `flutter analyze`：**0 问题**。
- `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux flutter test --concurrency=1 test/detail_page_test.dart`：**28/28 通过**（约 29 秒），含新用例：
  - `重新框选 §1.5.1 SR2-3：事务失败时旧切片字节完好、框与题不动（有旧切片）` ✓
  - 同组原有 3 个用例（重框成功、SR-P1-8 源页 ≥2、无页图无入口）均仍通过——成功路径经临时文件 + rename 后切片与框均正常更新。
- 未跑全量测试（总协调在阶段关口统一跑）。
- 新测试对旧代码的检出能力为**代码链推断，未 live 验证**（工作树多执行员共享，不能 stash 验证）：旧写法下旧切片先被新裁覆盖、事务失败时又被 catch 删掉，`readAsBytesSync()` 会抛错，测试必失败。

## 遗留问题

1. `db_collect.dart:340-343` 注释略旧（见上），需顺带修正，非本项代码问题。
2. rename 失败分支（事务已提交、正式文件仍是旧切片）无测试覆盖：`File.rename` 不可桩，注入需文件系统级故障；触发极罕见（同目录同文件系统），后果是“新框配旧图 + 明确提示”，重试可恢复。
3. B5 的旧 P2-3 测试（`b5_p2_collect_test.dart`）仍只覆盖“无旧切片”场景；新场景的覆盖在 `detail_page_test.dart`，两处未合并——有意为之（旧文件不在任务清单内），如需合并请总协调定夺。
