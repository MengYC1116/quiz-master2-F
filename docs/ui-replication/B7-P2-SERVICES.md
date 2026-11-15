# 第七批修复 · 服务层 / 主题 / 组件（B7-P2-SERVICES）

- 日期：2026-11-15。分支 `ui-replication`，工作树 `~/workspace/quiz-master2-UI`。
- 范围：只修 SR3-21、SR3-22、SR3-23、SR3-24、SR3-34 五项；SR3-25 是 B2 旧遗留、本批不回炉，不归本组，未动。
- 未提交、未推送。

## SR3-21（P2）— 金角 36 步耗尽后细扫取最优色

- 位置：`lib/modules/subjects/subjects_page.dart`（`_addSubject` 的 `orElse`）。
- 修法（Meng 定口径 (a)）：37° 步进循环耗尽（仍 `tooClose` 或撞色）后，不再原样返回违规色，改在 1° 细粒度上扫描 0–359°，取“与全部已用色最小色相距最大”的色相（首个最大值胜出，平局取最小色相），再按该色相生成颜色。
- 实测值（新用例字面值断言，真机跑通）：
  - 第 15 科：细扫取 110°，`0xFF63D94C`，最小色相距约 25.3°——仍 ≥25°，旧耗尽值是 `0xFFD9744C`（17°，与橙只差 14°）。
  - 第 16 科：细扫取 307°，`0xFFD94CC8`，最小色相距约 23.2°，为 15 色下的最优。
  - 附注：自审报告“14 色下理论最优约 12–13°”是下界估算（360/14 的一半），实际色相分布不均，最大空隙更大，故 15 科仍可达 25° 以上；之后随科数增加最优值递减，但恒为当前最优而非任意色。
- 用例：`test/subjects_page_test.dart` 新增 `SR3-21 第 15 科起 36 步耗尽后细扫取最优色，不静默返回违规色`——加 13 科到 16 科，字面值断言 13–16 科颜色（`0xFFB34CD9` / `0xFF4CD970` / `0xFF63D94C` / `0xFFD94CC8`），另断言第 15 科不等于旧耗尽值 `0xFFD9744C`、16 科颜色全不相同。

## SR3-22（P2）— QmChip 双区 × 区上下死区

- 位置：`lib/widgets/uikit.dart`（`QmChip` 双区分支 `Row`）。
- 修法：双区 `Row` 外包 `IntrinsicHeight` + `crossAxisAlignment: CrossAxisAlignment.stretch`，两识别器精确撑满行高；芯片总尺寸不变（实测仍 26px 高，含 1px 边框）。
- 两处与任务书字面修法的偏差（均经探针实测，见下）：
  1. 未用裸 `stretch`：松约束下 `stretch` 会把芯片撑到约束最大高——临时探针实测在 `Center` 里芯片变成 600px 高。`IntrinsicHeight` 让行高由最高的标签区内在高度决定，`stretch` 只在该高度内生效。
  2. 未用算出的 23.6px 定高 `SizedBox`：Text 实际行高会向上取整，标签区实为 24px（标签字 15.6→16px），23.6px 的盒子仍差 0.4px，边缘探针点不到。
  3. 探针点：顶部取 `chipRect.top + 1`（内容区首行），底部取 `chipRect.bottom - 2`（内容区末行）——任务书的 `bottom - 1` 恰是 1px 边框线本身，命中测试下边为排他边界，容器内任何识别器都点不到它，标签区同样点不到，不属于 × 区死区。另：`find.byType(QmChip)` 在测试架里取到的是外层 `SizedBox`（320×600），不能当芯片矩形用；用例改取标签文字最近的祖先 `Container`（带边框的装饰容器）作芯片矩形。
- 用例：`test/uikit_test.dart` 新增 `SR3-22 双区芯片：点 × 区顶部/底部边缘也删除，不留死区`——双区芯片（`onTap` + `onDelete`），点 × 字形横坐标上 `top + 1` 与 `bottom - 2` 各一次，断言 `deleted` 为 1、2，且 `tapped` 始终为 false（点中的是 × 区不是标签区）。
- 遗留：1px 边框线本身（`bottom - 1` 所在行）仍是任何区都点不到的排他边界，与标签区一致，不属本项死区；如将来要连边框线也可点，需把手势层移到装饰容器之外，另立项。

## SR3-23（P2）— gate 以 error 完成时 `_loadFuture` 被毒化

- 位置：`lib/services/yolo_onnx_service.dart`（`_loadOnce`）。
- 修法：把 `await gate.future` 移进 `try` 块内。gate 报错后走与加载失败同一路径：`_loadOnce` 返回 false，`_ensureLoaded` 清掉 `_loadFuture`，下次检测重新加载（`_loadAttempts` 随之增长）。
- 用例：`test/yolo_onnx_service_test.dart`（SR2-73 组）新增 `SR3-23：测试屏障以 error 完成时 _loadFuture 不被毒化，下次检测重试加载`——gate 先 `completeError(StateError)`，第一次检测 fallback、`loadAttempts == 1`；屏障换成已正常完成的 completer 后第二次检测重试，`loadAttempts == 2`。

## SR3-24（P2）— 串行队列无超时

- 位置：`lib/services/yolo_onnx_service.dart`（`_detectQueue` + `_serializedDetect`）。
- 修法（Meng 定口径 (a)）：单次推理加 60 秒超时——`_serializedDetect` 里 `fn().timeout(_detectTimeout)`，`detectTimeout` 为 60 秒常量。超时按推理异常走 fallback 并放行队列（链的 `onError` 已吞错，后续检测仍能跑）。超时只放行队列，不取消原生推理（onnxruntime 无取消语义）：超时的那次推理仍在后台跑完，调用方不再等它、也不假装它已结束；其晚到的 `lastDetectStats` 可能覆盖，不作为成功依据。
- 可测性：新增 `@visibleForTesting` 的 `detectTimeoutForTest`（默认 60 秒，`resetLoadStateForTest` 时恢复），与既有的 `loadGateForTest` 同款做法。
- 用例：同文件新增 `SR3-24：单次推理超时走 fallback，队列不被堵住，下次检测仍能跑`——先正常检测加载好模型（无原生库时跳过），再把超时缩到 1ms：该次推理必超时 → fallback；等后台推理跑完（`lastDetectStats` 晚到，最多等 30 秒）再恢复 60 秒发起下一次检测，断言成功。等后台跑完再测下一次，是为避免两次原生 `runAsync` 重叠（SR2-73 的 SIGSEGV 起因）；队列“超时即放行”本身由链结构保证（超时 future 一到即完成，不等后台推理）。
- 遗留：超时后后台推理与下一次推理在原生层仍可能短暂重叠（仅当超时的推理在 60 秒后又跑完、且下一次推理已开始时），这是“不取消原生推理”的固有代价；60 秒超时本身极少触发。

## SR3-34（P2）— 测试内复写产品 hue 公式

- 位置：`test/subjects_page_test.dart`（SR-P2-51 用例内的本地 `hueDistance`）。
- 修法：删除本地 `hueDistance` 函数与逐色 `>= 25` 的循环，生成色与已用色的距离只断言字面值（第 13 科 `0xFFB34CD9`，见 SR-P2-51 用例内注释）。25° 阈值的覆盖由字面值 + SR3-21 的 14–16 科字面值钉住，不再在测试内复写产品公式。
- SR3-21 的新用例写进同一测试文件，两处改动一并完成。

## 验证

- `flutter analyze`：0 问题（改动后、格式回退后各跑一次，均为 0）。
- 相关测试文件串行跑（`--concurrency=1`；YOLO 文件加 `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）：
  - `test/subjects_page_test.dart`：27/27 通过（含新增 SR3-21）。
  - `test/uikit_test.dart`：31/31 通过（含新增 SR3-22）。
  - `test/yolo_onnx_service_test.dart`：29/29 通过（含新增 SR3-23、SR3-24，真模型实跑）。
- 未跑全量（协调员最后统一跑）。测试里未用异步文件 IO（新增 YOLO 用例是普通 `test`，沿用该文件既有的同步/异步写法；`testWidgets` 下无异步文件 IO）。
- 临时探针 `test/zz_probe_sr3_22_test.dart`（SR3-22 几何探针）已删除，工作树无残留。
- 附注：改动后曾对 6 个文件跑整文件 `dart format`，仓库本身不执行 `dart format`（HEAD 版三文件已非 format-clean），整文件格式化引入了与 B7 无关的重排噪声；已用脚本把保护范围外的纯格式 hunk 逐一还原（53 处），保护范围（本次编辑区）内保留格式化后样式；与 B6 改动混在同一 hunk 内的少量重排无法分离，予以保留。

## 遗留

- SR3-25（B2 遗留，错题本紧凑行深色下用亮色存色）不在本批范围，未动。
- SR3-22：1px 边框线（`bottom - 1`）仍为全区排他边界，见上。
- SR3-24：超时后原生推理仍在后台跑，与下一次推理短暂重叠的固有代价，见上。
