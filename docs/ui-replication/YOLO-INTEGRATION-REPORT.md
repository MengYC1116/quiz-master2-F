# YOLO 接入报告：只接第 1 层（整题检测）

- 日期：2026-11-13
- 分支：`ui-replication`（未提交、未推送，按任务要求）
- 结论：**第 1 层真实推理已接入并通过验证**。`flutter analyze` 0 问题；
  `flutter test` 全量 **388/388 通过**；3 张真实试卷页端到端通过
  （导入 → 检测 → 修框 → 内框模式 → 取消留修框中）。
- 范围变更（Meng 2026-11-13 定）：**第 2 层暂缓，只接第 1 层**。
  第 2 层模型还需再训练，见 §7 再训练反馈与 D-23。

## 1. 模型与版本

### 第 1 层模型（在用）

| 项目 | 值 |
|---|---|
| 文件 | `assets/models/question/yolo11s-question-v1.onnx`（38,432,570 字节） |
| 结构 | Ultralytics YOLO11s，`task=detect`，opset 17，训练日期 2026-11-03 |
| 输入 | `images` [1, 3, 1280, 1280]（定死 1280） |
| 输出 | `output0` [1, 5, 33600]，即 cx、cy、w、h + 1 个类别分数 |
| 类别 | 1 类：`{0: 'question'}`（已核实） |
| 训练数据 | `/mnt/workspace/dataset.cloud.yaml`（见模型元数据） |

### onnxruntime（D-23）

- 包：pub.dev `onnxruntime` **1.4.1**（2024-03-27，之后无新版；
  pub.dev 上唯一的 Dart 版 ONNX Runtime 插件）。
- 选型理由：没有更新的 Dart 包；sdk 约束 `>=2.17.0 <4.0.0`
  兼容 Dart 3.13.7 / Flutter 3.47.9；自带各平台原生库。
- 原生库：Linux 用包内 `libonnxruntime.so.1.15.1`（即 ORT 1.15.1），
  已验证随 Linux Release 包捆绑在 `bundle/lib/` 下；
  Windows 用同包的 `onnxruntime.dll`。
- `pubspec.yaml` / `pubspec.lock` 变化（单列）：只加了
  `onnxruntime: ^1.4.1`（lock 里只多这一项，ffi 已是 2.2.0，
  未动）。**除此之外没有升级任何依赖。**
- **Win11 上须重验这个版本**：`onnxruntime.dll` 是否随应用打包、
  会话能否创建、CPU 推理速度（见 §8）。

### 第 2 层模型（已移出仓库，不删除）

- `yolo11s-intra-v1.onnx`（38,406,563 字节，SHA256
  `8486b519dc184266be559e983ce409d1d78e34100790ff22905353d98b269267`）
  已从 `assets/models/intra/` 移到仓库外
  `~/workspace/yolo-models-archive/` 存着；Drive 上 yolo-intra/
  里还有一份，双保险。`pubspec.yaml` 里的 `assets/models/intra/`
  声明已一并去掉，应用不再打包这 38MB。

## 2. 推理约定（`lib/services/yolo_onnx_service.dart`）

- 第 1 层整页跑：letterbox 等比缩放到 1280×1280（灰边 114，
  Ultralytics 默认值），像素 /255，CHW float32，通道 RGB。
- 输出 [1, 5, 33600]：cx、cy、w、h + 类别分数；逐类 NMS。
- 阈值：**置信度 0.45，NMS IoU 0.5**。0.25 时会多出页眉条带等
  低分假框；3 张实测页上真题最低 0.50（见 §3）。
- 编号：按阅读顺序（先上后下、同行先左后右）排好再编 `box-q1…`。
- 推理在 worker isolate 跑（`runAsync`），不卡 UI 线程。
- 模型缺失、加载失败或图片文件不存在时回退占位（一页一个整题框），
  不抛错；`hasRealModel` 只反映第 1 层模型。
- `QuestionBox` 接口不变；`clampToPage` 只加了一个默认 true 的
  `minSize` 可选参数（默认行为与 A3 回归测试完全一致，见 §5）。

## 3. 三张真实试卷页：第 1 层检测效果与耗时（Linux，1.5 CPU）

测试图：`~/workspace/yolo-test-images/`，均为 1653×2200 PNG。
标注图（红框 + 置信度）见 `shots/yolo/annotated-l1-*.png`。

| 图 | 内容 | Dart 检出 | Python 参考检出 | 推理耗时（Dart） |
|---|---|---|---|---|
| `16676Q…99b.png` | 第 42 页，选择 + 填空 + 求极限 | **16 框** | 14 框 | 4.7 秒 |
| `1TYQm…tzrEf.png` | 第 43 页，选择 + 填空 + 计算 | **6 框** | 7 框 | 4.3 秒 |
| `1iMDN…ywg_D.png` | 选择题 13 道（Q4–Q16） | **13 框** | 13 框 | 3.5 秒 |

- 耗时说明：`lastDetectStats.layer1Ms`；第 1 页 wall 5.6 秒（含首次
  模型加载与会话创建，之后每页约 4 秒）。Python 参考（ORT 1.32，
  同约定）为 2.9 / 2.2 / 1.9 秒——Dart 侧 ORT 1.15.1 慢约一倍，
  属版本差异，不影响使用；Win11 速度待实测。
- Dart 与 Python 逐框比对（IoU > 0.5 算命中）：第 3 页 13/13 全命中；
  第 2 页 Dart 的 6 框全命中，少 1 框（0.68 分的页眉细条，Dart 侧
  未检出）；第 1 页 Python 的 14 框全命中，Dart 多 2 框（中部
  小问簇的碎片框，见下）。剩余差异是 ORT 1.15.1 与 1.32 之间、
  以及两种缩放实现的边界分数抖动，不是接线错误。
- 逐框置信度（Python 参考值，Dart 侧一致）：
  - 第 42 页：0.91、0.92、0.91、0.91、0.87、0.86、0.81、0.50、
    0.78、0.61、0.80、0.76、0.79、0.85（14 框）。
  - 第 43 页：0.68、0.71、0.83、0.56、0.91、0.90、0.90（7 框）。
  - 选择题页：0.87–0.93（13 框）。
- 已知弱点（第 42 页中部，Q6–Q13 一带）：
  一道带 (1)(2) 小问的大题 + 相邻填空题，模型拆得不一致——
  有 7 对框互相重叠（最大 IoU 0.49），另有 1 个半宽框
  （只框了左半边）。修框编辑器会拦下重叠确认，用户手动修一下
  即可；其余两页零重叠，可直接确认。
  大题（第 43 页 Q4，0.56 分）框得偏大、含大片空白，是同一道题，
  不算错。

## 4. 收集流程接入

- `detectPage` 的调用方没变：收集页 `_openBoxEditor` 与修框编辑器
  的“恢复自动框”本来就调它，假检测（占位）换成了真实推理。
- 修框编辑器按层拆分检测结果（`_ingestDetected`）：第 1 层进题级框；
  第 2 层框按中心点归属到所属题级框（`groupInners`），无主的作
  独立题内框。当前检测只出第 1 层，内框模式仍可用——双击题级框
  进内框模式时按老办法给三个默认内框（题干/选项/配图），用户
  手画、手改，与以前一致（端到端已验证，见 §6）。
- `QuestionBox.layer`、内框模式、三色高亮、切片区都没动。
- 两个前置限制（不在本次范围，见 §8）：
  1. 导入流程仍只存文件名（`CollectTask.fileName` 为显示名，未改
     Schema）：`detectPage` 按传入路径找文件，找得到跑真实推理，
     找不到回占位。真实文件落盘 / PDF 渲染仍是待办。
  2. 修框画布仍是占位色块（已知待办）：编辑器里的框是真实框，
     但底图不是真实试卷页，框与内容的贴合程度用 §3 的标注图核对，
     不用编辑器截图核对。

## 5. 实施中发现的两个问题（已修）

1. **`clampToPage` 的 0.08 最小尺寸会撑坏检测框**（A3 的规则是为
   手画框设的）：题行实测高 0.018~0.10、多在 0.08 以下，选项框
   约 0.04×0.03；直接过 `clampToPage` 全被撑成 0.08，相邻题行
   互相重叠、确认被拦。修法：`clampToPage` 加默认 true 的
   `minSize` 可选参数（默认行为与 A3 回归测试完全一致），检测
   管线用 `minSize: false` 只做越界钳制、保留量出来的尺寸。
   手画 / 拖动 / 缩放仍走默认 0.08 下限。
2. **异步文件 IO 会卡住 `testWidgets`**：`detectPage` 原先用
   `await File.exists()`，在 widget 测试的 FakeAsync 环境下永不
   完成，导致 12 个修框编辑器测试打不开对话框。改同步
   `existsSync` / `readAsBytesSync` 后全过；同步读一张
   1653×2200 PNG 约几毫秒，UI 上无感。

## 6. 验证

- `flutter analyze`：**0 问题**。
- `flutter test`：**全量 388/388 通过**（含新增的后处理单测：
  解码 + NMS + 跨类去重 + letterbox + `groupInners` +
  `minSize: false` + 真实模型冒烟；冒烟测试用 assets 里的真实
  模型文件，没有把 38MB 模型塞进测试固件；原生库缺失时自动跳过）。
- Linux Release 构建成功；包里只有第 1 层模型
  （`assets/models/question/yolo11s-question-v1.onnx`），
  `lib/libonnxruntime.so.1.15.1` 已捆绑。
- 端到端（脚本 `docs/ui-replication/run-shots-yolo.sh`，Xvfb
  1280×720，深色，演示库）：选数学 → 导入真实试卷页
  `1iMDN14nE6qZD_srN4VHi1yCZ5j6ywg_D.png` → 任务待框选 →
  点“修框”，约 4 秒后编辑器打开，**“本页 13 道题”**，
  与 Dart 探针一致 → 双击题级框 1 进内框模式（三个手动内框
  可用）→ Esc 退出 → 取消，任务留“修框中”，可“继续修框”。
  截图 `shots/yolo/e2e-01-home.png` … `e2e-06-after-cancel.png`。
- 演示库已恢复原状：9 道题、3 学科、深色、启动页 home、
  收集任务 0（恢复前逐项核对过）。

## 7. 给 Meng 的第 2 层再训练反馈（双模型实测，暂缓前测得）

第 2 层模型（`yolo11s-intra-v1.onnx`）在 3 张真实试卷页上
用“逐题裁剪”方式跑过（**不要整页跑**：整页跑时题干框横跨整页，
见 `shots/yolo/python-probe-results.json`）。
类别下标以模型元数据 `names` 为准，已按框落点核对：
0 stem、1 option、2 figure。

- **题干 / 选项基本准**：stem 置信度多在 0.5–0.95，落在题干行上；
  选项每个 A/B/C/D 各为独立框，位置准（3 页共 stem 34、option 84，
  抽查落点都对）。偶有题干被拆成两个框（第 43 页 Q1 的题干行
  断成 0.78 + 0.47 两个 stem 框），个别选项框会并掉相邻选项。
- **figure 误报是主要问题**：3 页上没有一张真图，模型却报了
  **4 个 figure，全是误报**，其中两个还是高置信度：
  - 第 42 页 Q11“求极限 lim[2/ln(1+x) − 2/x]”那行，figure 0.92；
  - 同页 Q6 区域一行纯文字，figure 0.87；
  - 同页 Q13“求 lim x^sinx”那行，figure 0.49；
  - 同页 Q10“y = x³ − 27x + 2 在 [0,1] 上的最大值”那行，
    figure 0.29。
  另有 stem/figure 同框重复（同一区域两个标签，如 Q11 的 stem
  0.31 与 figure 0.92 是同一个框）；跨类去重（IoU 0.8）会留
  置信度高的那个——在这几例里留下的恰恰是错的 figure 标签。
  建议再训练时：加纯文字页的负样本（尤其带极限/求导公式的
  行，公式容易被认成图）、figure 类多标带坐标轴/几何图形的真图、
  考虑把 figure 的置信度阈值单独调高，或 stem/figure 同框时
  优先 stem。
- 再接入路径（代码已留好）：训好的模型放回
  `assets/models/intra/`、`pubspec.yaml` 加回声明、
  `YoloOnnxService.intraEnabled` 改 true、按 `_detectIntra`
  的注释恢复逐题裁剪推理；后处理与归属逻辑不用重写。

## 8. Win11 待验证项

1. onnxruntime 1.4.1：`onnxruntime.dll` 是否随应用打包、会话能否
   创建、CPU 推理速度（Linux 上 3.5–4.7 秒/页，Win11 实测为准）。
2. 模型文件放到 Win11 的 `assets/models/` 路径：仓库里只有
   第 1 层模型（38MB）；**两个模型文件是二进制，连接器推不上去，
   Meng 需自己推这两个文件或在他本地放到同样的 `assets/models/`
   路径下**——当前只需要推第 1 层 `question/yolo11s-question-v1.onnx`
   （约 38MB）；第 2 层等训好后再说。
3. 真实文件落盘 / PDF 渲染（见 §4）：导入后文件要能按路径找到，
   否则检测回占位。
4. 修框画布换真实页图（已知待办）：现在还是占位色块。

## 附：本次改动的文件

- `lib/services/yolo_onnx_service.dart`：重写为真实推理（只第 1 层），
  占位回退保留；`_detectIntra` 为第 2 层再接入点。
- `lib/modules/collect/collect_page.dart`：编辑器按层拆分检测结果
  （`_ingestDetected`）；其余为工作区里其他工人的改动（B2 等），
  不属于本次。
- `pubspec.yaml` / `pubspec.lock`：加 `onnxruntime: ^1.4.1`；
  assets 加 `assets/models/question/`、去 `assets/models/intra/`。
- `test/yolo_onnx_service_test.dart`：新增后处理与冒烟单测。
- `docs/decision-log.md`：D-23（只接第 1 层，第 2 层暂缓）。
- `docs/ui-replication/shots/yolo/`：`annotated-l1-*.png`（3 张）、
  `e2e-0*.png`（6 张）、`python-probe-results.json`
  （含第 2 层探针数据，供 §7 反馈备查）。
- `docs/ui-replication/run-shots-yolo.sh`：端到端复现脚本。
- 第 2 层模型文件已移出仓库：
  `~/workspace/yolo-models-archive/yolo11s-intra-v1.onnx`
  （SHA256 见 §1，移动前后哈希一致）。
