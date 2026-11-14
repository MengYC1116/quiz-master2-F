# P0.5 图片链路小样报告

- 日期：2026-11-14
- 分支：`ui-replication`（未 commit、未 push）
- 依据：`docs/ui-replication/DB-CHANGE-PLAN.md` §1.4–§1.6、§7 P0.5 行
- 结论：**小样通过，可进 P1。** 7 个验证点全部通过，无“不通过、先修小样”的项。

## 结论总表

| # | 验证点（按方案） | 结论 | 关键数字 |
|---|---|---|---|
| 1 | 页图分辨率：长边 2000–3000 的页图，检测（letterbox 1280）与切片清晰度 | 通过 | 页 1653×2200；检出 16/6/13 框（三页）；切片 1302×118，文字清晰可读（人工看过） |
| 2 | 旋转烘焙 90/180/270；多页旋转（第 1 页 90°、第 2 页不转） | 通过 | 烘焙后切片与正向直接裁剪平均像素差 **0.0**（三个角度）；多页两页均为 0.0 |
| 3 | FileImage 缓存：重切图后 `imageCache.evict` 再读到新图 | 通过 | 不 evict 读旧图（红），evict 后读新图（蓝）；`evict()` 返回 true |
| 4 | 页图格式：照片保留原图（JPG 原样作页图），不转 PNG | 通过 | photo.jpg 141420 字节，复制后字节完全一致，扩展名 .jpg，无 PNG 副本 |
| 5 | 旋转 → 恢复自动框：原页坐标检测结果须先做坐标变换再进框列表 | 通过 | 三个角度变换后像素差 **0.0**；不变换则错位（90°/270° 尺寸都不对、180° 像素差 47.6） |
| 6 | EXIF 图片：带 EXIF 90° 方向的 JPEG，框/页图/切片方向一致 | 通过 | 解析 1/3/6/8 正确；方向 6 归一化后 300×400，红块移到右上；一致性像素差 0.0 |
| 7 | 大图打开耗时：`readAsBytesSync` 在 UI 线程，实测一次 | 通过 | 同步读平均 **0.22ms**；解码 10–18ms；整页 detectPage 稳态 2.6–4.0s（见 §7） |

## 基线与最终结果

- 基线（开工前实测）：`flutter analyze` 0 问题；全量测试 **426 通过 + 1 跳过 = 427**。
- 最终：`flutter analyze` **0 问题**；全量测试 **441 通过 + 0 跳过**。
  新增 14 项：`test/p05_image_pipeline_test.dart` 13 项 + `test/p05_image_pipeline_e2e_test.dart` 1 项
  （端到端小样以 `--dart-define P05_PHASE=write/read` 两阶段跑，见 §8）。
  原先跳过的 1 项（YOLO 冒烟测试）本次因设了 `LD_LIBRARY_PATH` 而真实跑通，不再跳过。
- 真实推理跑测试的前提（重要）：`flutter test` 进程默认找不到
  `libonnxruntime.so.1.15.1`（`DynamicLibrary.open` 按名找，不在 loader 路径上），
  不设环境变量时真实检测测试按既有惯例跳过。真实跑通的命令：
  `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux flutter test …`

## 1. 页图分辨率与检测

- 真实页图：`~/workspace/yolo-test-images/` 三张 PNG，均为 **1653×2200**（长边 2200，在 2000–3000 内）。
  任务书写的 gs_p046/047/048 即这三张文件（`16676QPF…png` / `1TYQmeLk…png` / `1iMDN14n…png`）。
- 真实 YOLO 第 1 层（`assets/models/question/yolo11s-question-v1.onnx`，letterbox 到 1280）：
  页 1 检出 **16 框**，页 2 **6 框**，页 3 **13 框**；全部框都在页内（0..1）。
- 切片清晰度：取页 1 首框 box-q1（0.140, 0.085, 0.788×0.054），切片 **1302×118**。
  人工看过该切片：拉格朗日中值定理选择题（`f(x)=√x−1` 在 [1,4]，选项 3/2、2/3、4/9、9/4），
  题干与四个选项文字清晰可读。结论：**从 1653×2200 页图裁剪，不经 1280 检测图，清晰度够用**。
- 观察（非失败，不属小样范围）：页 1 的 16 个框里有重叠（q6/q7、q9/q10/q11 区域相交），
  是模型检出质量问题，P2 接入“恢复自动框/重叠校验”时按既有规则处理即可。

## 2. 旋转烘焙 90/180/270 与多页旋转

- 方向约定先用合成页（红块左上、蓝块右下）钉死：90° 红块→右上、180°→右下、270°→左下，蓝块对应移动，全部通过。
- 烘焙确认路径（`cropRotatedSlice`：页图先烘焙旋转，再按变换后的框裁剪）：
  歪页 + 歪框 → 烘焙 90°/180°/270° → 切片与正向页直接裁剪相比，平均像素差 **0.0**（三个角度全是精确相等）。
- 多页旋转：第 1 页转 90°、第 2 页不转，按 `Map<页, 角度>` 各自烘焙，两页切片与直接裁剪的像素差均为 **0.0**；
  无全局 `_pageRotation` 串页问题。
- 落成的共享方法：`rotateBoxToRotatedPage` / `unrotateBoxFromRotatedPage` /
  `rotateImageBytes` / `cropBoxPng` / `cropRotatedSlice`（见 §9）。

## 3. FileImage 缓存 evict

- 64×48 红图写入文件读到红；覆盖写蓝图、**不 evict 再读仍是红**（缓存命中，复现了问题）；
  `evictCachedFileImage(path)` 返回 true 后再读是**蓝**。通过。
- 测试写法注意（实测坑）：`testWidgets` + FakeAsync 下 `FileImage.resolve` 的
  `ImageStream` 永远不完成，测试会一直挂住（`Future.timeout` 在 FakeAsync 下也不触发）。
  evict 测试因此写成普通 `test()`（真异步）+ `resolve` + 15s 超时保护；小样报告外，
  P2 若要在 widget 测试里验缓存，同样不要用 `testWidgets` + `runAsync` 这一路。

## 4. 页图格式：照片保留原图

- `test/fixtures/photo.jpg`（真实页转 JPG，1200×1597，141420 字节）原样复制到
  `imports/<task-id>/original.jpg`：字节完全一致、扩展名保持 .jpg、未产生 PNG 副本。
  `page_image_path` 与 `source_path` 可为同一文件（EXIF == 1 时，见 §6）。通过。

## 5. 旋转 → 恢复自动框（P2 实施注意提前验证）

- 纯数学：框 (0.1, 0.2, 0.3, 0.4) 经变换——90°→(0.4, 0.1, 0.4, 0.3)、
  180°→(0.6, 0.4, 0.3, 0.4)、270°→(0.2, 0.6, 0.4, 0.3)；往返变换回到原框。
- 像素（合成页 + 真实页）：页已旋转 θ 时，检测结果（原页坐标）经
  `rotateBoxToRotatedPage(box, θ)` 变换后，在旋转页上裁出的切片与原切片旋转 θ 后相比，
  平均像素差 **0.0**（三个角度；真实页 90°/270° 切片 119×1303、180° 切片 1303×119，宽高互换正确）。
- 反例（证明变换不可少）：不变换、拿原坐标直接去旋转页上裁——90°/270° 连尺寸都不对
  （像素差记为无穷大），180° 像素差 **47.6**，明显错位。
- 结论：P2 实现“恢复自动框”时，检测结果必须先做本变换再进框列表；变换函数已落成并单测覆盖。

## 6. EXIF 图片与实现方式二选一结论

### 6.1 二选一结论：选手写轻量 JPEG APP1 Orientation 解析，不引入 image 包

- **结论：手写解析。不要改 pubspec，不需要 Meng 批准改依赖。**
- 理由：
  1. 零新依赖：不改 `pubspec.yaml`、不升级依赖，符合本次边界；引入 image 包是唯一需要改 pubspec 的选项，而它带来的增量价值经实测并不存在（见第 3 点）。
  2. 解析范围极小：只需 APP1（Exif）段 IFD0 里的 tag 0x0112，约 70 行，已单测覆盖方向 1/3/6/8、
     非 JPEG（PNG）→ null、无 EXIF 的 JPG → null、截断输入 → null（不抛错）。
  3. **关键实测发现：dart:ui 解码 JPEG 时已按 EXIF 方向自动转正。**方向 6 的 400×300 JPEG
     解码后直接就是 300×400 正向像素（红块已在右上）；方向 3/8 同理。
     因此归一化根本不需要“按角度手动旋转图片”——只需用解析器**判断方向是否 != 1**，
     需要时把解码后的正向像素编码为 PNG 副本即可。image 包的手动旋转能力在这里用不上。
  4. 镜像方向（2/4/5/7）两种方案都要额外处理（需翻转，旋转不够），image 包并不能省掉这层决策逻辑；
     目前暂不支持，调用方应提示用户（见 6.3）。
- 小样初版曾按“解析方向 → 再按角度转一次”实现，结果**转了两次**（解码自动转 + 手动转），
  方向 6 的归一化产物变成 400×300 歪图，测试失败；改成“只解码重编码”后通过。
  此坑已写进 `normalizeExifImageBytes` 与 `rotateImageBytes` 的注释：
  **带 EXIF 的 JPEG 绝不能直接传给 `rotateImageBytes`，先归一化。**

### 6.2 验证结果

- 解析：`test/fixtures/exif-orientation-{1,3,6,8}.jpg` 读出 1/3/6/8；PNG 与无 EXIF 的 JPG 返回 null；截断字节返回 null。
- 归一化：方向 6 → 300×400 PNG 副本，红块从存储左上移到右上、绿块移到左下；
  方向 3 红块→右下、方向 8 红块→左下；方向 1 字节原样、不生成副本（`wasNormalized=false`）。
- 框/页图/切片方向一致：归一化页上的框与“存储页解码后的正向像素”上的同一框裁出的切片，
  平均像素差 **0.0**。即 P2 里框一律用正向坐标系，与解码后的页图一致。

### 6.3 已知的 EXIF 边界

- 镜像方向 2/4/5/7：解析器能读出方向值，但归一化返回原字节、不生成副本（`wasNormalized=false`）。
  手机照片几乎只用 1/3/6/8；P2 遇到镜像方向时应显式提示用户，不可静默按旋转处理（会错向）。
- 归一化副本是 PNG（dart:ui 只方便输出 PNG），比原 JPG 大；仅 EXIF != 1 时生成，符合 §1.4。

## 7. 大图打开耗时（§1.6 要求至少实测一次）

1653×2200 PNG（约 290KB），Linux 虚拟机实测（多次运行）：

| 步骤 | 耗时 |
|---|---|
| `readAsBytesSync`（20 次平均） | **0.22–0.28ms** |
| 解码 `instantiateImageCodec` | **10–18ms** |
| `detectPage` 稳态（含读 + 解码 + 推理） | **2.6–4.0s**，其中纯推理 2.6–3.9s，16 框 |
| 首次 `detectPage`（含模型加载） | 3.5–8.1s（模型加载约 0.5–0.7s，其余为推理；8.1s 那次与并行跑 analyze 抢 CPU 有关） |

- 结论：**同步读本身只有约 0.2ms，不是瓶颈**；大图打开耗时几乎全是 YOLO 推理（约 3s）。
  §1.6 定稿的“生产用异步读或 isolate”仍值得做（读在 UI 线程毕竟不规范），但别指望它解决打开慢——
  打开慢的主因是推理，P2 若要在意打开体感，应考虑推理放 isolate/后台 + 先显示页图（检测进度另行提示），
  而不是只改读图方式。
- 另：本机 CPU 推理约 3s/页；Win11 真机速度仍待 Meng 复核（方案文首不确定项第 2 条）。

## 8. 端到端小样（Linux，真实图片，重启后读回）

两阶段、两次独立 `flutter test` 进程（中间即“重启”），工作目录固定 `/tmp/p05-spike`
（已清理；不进仓库、不进数据目录、不碰演示库）：

- 写阶段（`--dart-define P05_PHASE=write`）：复制页图 → 真实检测 16 框 → 取首框、
  页旋转 90° 烘焙 → 裁剪 → 存 PNG 切片 → 写 `manifest.json`（路径 + FNV 哈希 + 框 + 耗时）。
  耗时：复制 **6ms**、检测 **3451ms**（纯推理 2831ms）、烘焙+裁剪 **352ms**、写切片 **0ms**；
  切片 118×1302。**通过。**
- 读阶段（`--dart-define P05_PHASE=read`，全新进程）：切片/烘焙页图/原页图哈希全部一致，
  切片尺寸 118×1302，从烘焙页图 + 清单里的旋转后框重裁，像素差 **0.0**。**通过。**

## 9. 落成的文件（P2 可复用的小型共享方法）

小样代码未接进应用界面；以下 helper 经上述单测验证通过，标为 P2 可复用：

- `lib/services/page_image_pipeline.dart`（新）：`rotateBoxToRotatedPage` /
  `unrotateBoxFromRotatedPage` / `rotateImageBytes` / `cropBoxPng` /
  `cropRotatedSlice` / `readJpegExifOrientation` /
  `exifOrientationToClockwiseDegrees` / `normalizeExifImageBytes` /
  `evictCachedFileImage`。
- `test/p05_image_pipeline_test.dart`（新，13 项）：覆盖验证点 1–7（旋转裁剪、多页旋转、
  evict、EXIF、恢复自动框坐标变换、耗时实测）。
- `test/p05_image_pipeline_e2e_test.dart`（新，1 项两阶段）：真实图片端到端 + 重启读回。
- `test/fixtures/`（新）：`photo.jpg`（真实页转 JPG，1200×1597）与
  `exif-orientation-{1,3,6,8}.jpg`（400×300 合成图，红块左上、绿块右下，EXIF 方向各异）。

## 10. 演示库状态

- 小样测试全程只用临时目录（`Directory.systemTemp` / `/tmp/p05-spike`）与只读的真实页图，
  未引用 `AppDatabase`，未写演示库。
- 验收后核对：演示库仍为 **9 道题、3 学科、深色（themeMode=dark）、pageSize=10**，
  与要求一致。注：文件哈希与开工前记录的不同，但内容逐项核对无误——
  全量测试套件里既有测试（§8.1 已知问题，`s8b4_backup_migration_test` 等）会打开真实库，
  属于既有行为，非小样造成；小样本身未动库。
- 临时图片/切片（`/tmp/p05-spike`、`/tmp/p05-slices` 及测试临时目录）已全部清理。

## 11. 给 P1/P2 的交接要点

1. 小样通过，可进 P1；无待修假设。
2. EXIF 定稿：手写 APP1 解析 + 解码重编码 PNG 副本（不引入 image 包、不改 pubspec）；
   镜像方向 2/4/5/7 暂不支持，P2 须显式提示。
3. “恢复自动框”必须先做 `rotateBoxToRotatedPage` 再进框列表（§5 的反例数据即证据）；
   旋转烘焙用 `cropRotatedSlice`（页图烘焙 + 框变换 + 裁剪一体）。
4. 重切图/页图替换后先调 `evictCachedFileImage` 再读（§3）。
5. 大图打开慢的主因是 YOLO 推理约 3s/页，不是同步读（0.2ms）；P2 如要优化打开体感，
   优先考虑推理放后台/先显页图，而非只改读图方式。
6. 真实检测测试在 `flutter test` 下需设
   `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，
   否则按既有惯例跳过（不报错、不阻塞套件）。
