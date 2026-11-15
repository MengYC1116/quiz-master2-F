# B10-2 固件测试内生成（P0-2）

目标：`test/fixtures/` 磁盘目录未入库、远端也没有，fresh clone 跑测试会失败。
本项让测试自给自足——小固件 base64 内嵌、大照片现场生成、切片现场画，
`test/fixtures/` 整个移走后全量测试仍通过。

## 备份

- 改动前已备份：`~/workspace/test-fixtures-backup-b10/`（`cp -r`，`diff -r` 核对与原目录完全一致）。
- 原固件 md5（供日后核对）：
  - `exif-orientation-1.jpg`（3640B）`f5da8ae2def60aad4b35c9d1ca85c0c6`
  - `exif-orientation-3.jpg`（3640B）`8e7697243d819e203b8c3410b6f13432`
  - `exif-orientation-6.jpg`（3640B）`24dae621a6380cf64c63c36a2cadde63`
  - `exif-orientation-8.jpg`（3640B）`0707d88ba71b6d70804a03c0e0451922`
  - `pdf-encrypted.pdf`（1035B）`91f528917c17d2a2219fcae030cf1335`
  - `photo.jpg`（141420B，1200×1597，无 EXIF）
  - `slice-narrow-500x120.png`（579B，500×120 白底黑字条）
- `test/fixtures/` 已删除（`rm -rf`，验收后未恢复——测试不再需要它；备份在上面）。
- 演示库：全量前备份到 `~/workspace/demo-db-backup/quiz-master2-b10-before.db`；
  全量跑完核对演示库未被改动（跑前跑后 md5 均为 v1 `8f7f9c64405dc6e484ac2bf8e5e1a807`），
  仍执行恢复并再次核对 md5 一致。

## 每个固件的新来源

共享入口：新增 `test/test_fixtures.dart`（唯一固件来源；生成物一律写进各测试自己的临时目录，不写仓库）。

| 固件 | 新来源 | 依据（读测试后定） |
|---|---|---|
| `exif-orientation-{1,3,6,8}.jpg` 各 3640B | **base64 内嵌**（`exifFixtureBytes(ori)`），与原文件逐字节相同（base64 解回后 md5 与上表一致） | P0.5-6 归一化测试验像素级内容（红块左上、绿块右下、400×300、JPEG 有损阈值），且 p2 镜像测试就地改字节偏移 48..49（值 SHORT）改方向 6→2；只有逐字节相同才能不改断言。生成侧若手写 JPEG 编码器风险大、没必要 |
| `pdf-encrypted.pdf` 1035B | **base64 内嵌**（`encryptedPdfFixtureBytes()`），逐字节相同 | 断言是 PDFium 抛 `PdfEncryptedException` 与导入失败文案，须是真实加密 PDF；1035B 内嵌最简单 |
| `photo.jpg` 141420B | **生成**：方向 1 固件去掉 APP1（Exif）段（`photoFixtureBytes()`，JPEG 段行走器，SOS 后原样复制；结果 3604B、400×300 真实 JPEG、无 EXIF、`file` 认 JFIF、PIL/dart:ui 可解码） | 各引用只验：复制字节相同（P0.5-4）、无 EXIF（`readJpegExifOrientation → null`）、<20MB（`oversizeHint → null`）、可解码进 `needBox`（导入链路 `canDecodeImageBytes`）、尾部补零到恰好 20MB 仍放行。没有任何测试验原照片像素或 1200×1597 尺寸。141KB 转 base64 约 188KB，按任务要求不内嵌 |
| `slice-narrow-500x120.png` 579B | **生成**：dart:ui 在 `setUpAll` 现场画（`narrowSlicePngBytes()`），500×120 白底 + 三条黑色“文字行”（原夹具黑像素包围盒 x 16..470、y 30..75；原图是文字笔画、非实心矩形） | b2 测试只量卡/图几何（卡宽 ≤ 图宽 +25），不验像素；尺寸 500×120 是唯一硬性要求 |

## 改了哪些测试文件

只改测试，不动产品代码（`lib/` 零改动）。未 commit、未推代码。

- 新增 `test/test_fixtures.dart`：4 个 base64 常量 + `exifFixtureBytes()` / `photoFixtureBytes()` / `encryptedPdfFixtureBytes()` / `narrowSlicePngBytes()` / `writeFixtureFile()`。
- `test/p05_image_pipeline_test.dart`：P0.5-4 把照片固件写进临时目录再复制；P0.5-6 三处改读 helper 字节（EXIF 方向解析、归一化像素、裁剪一致性）。
- `test/p2_main_chain_test.dart`：`setUpAll` 写照片 + 方向 6 固件进 `_tmp`；导入/归一化测试改用生成路径；镜像测试改读 `exifFixtureBytes(6)`（偏移 48..49 补丁原样保留）；“EXIF 方向 1 的照片”改名“无 EXIF 的照片”（新照片无 EXIF，行为相同：不生成归一化副本）。
- `test/import_service_p1_fixes_test.dart`：`setUpAll` 写照片 + 方向 6 固件；全部 14 处 `test/fixtures/...` 路径改用生成路径；相对/绝对去重测试改用 `path.relative(_photoPath, from: Directory.current.path)`；大小写去重测试改用 `_photoPath.toUpperCase()`（临时目录名含小写，大写后一定不存在，Linux 行为与原来一致）；恰好 20MB 测试改读 `photoFixtureBytes()`。
- `test/b2_win11bug_organize_test.dart`：`setUpAll` 用 `narrowSlicePngBytes()` 生成窄切片写进 `slices/q-real.png`，删 `existsSync` 断言；头注释更新来源。
- `test/pdf_render_service_test.dart`：`setUpAll` 写加密 PDF 固件进 `_tmp`；3 处路径改用 `_encryptedPdfPath`。
- 核对：`git diff` 显示 5 个文件无任何 `test(`/`testWidgets(` 行增删（只改名 1 个测试）；`grep` 显示测试代码中已无 `test/fixtures` 路径引用（仅 `test_fixtures.dart` 与 b2 头注释提及原路径作来源说明）；`flutter analyze` 6 个文件 0 问题。

## 验收过程

环境：`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`，
Flutter SDK `~/workspace/flutter-install/flutter/bin`，串行 `--concurrency=1`，默认 `/tmp`。

1. 改完先跑 5 个相关文件（fixtures 尚在）：**60/60 通过**（p05 13、p2 13、b2 2、p1-fixes 19、pdf 13）。
2. `rm -rf test/fixtures`（已备份），跑一次完整全量（约 6.5 分钟，只跑一次）：
   **895 通过、0 失败、0 跳过，`All tests passed!`**。
3. 演示库恢复并 md5 核对 v1（见上）。

## 待协调：全量总数 895 vs B9 基线 899

全量通过，但总数比 B9 报告的 899 少 4 项。已排除本项原因：

- 本项 `git diff` 无任何测试增删；5 个文件的测试数与改前一致（60）。
- 差额来自本项未碰的文件：`test/settings_page_test.dart`、`test/b5_p2_data_test.dart`、
  `test/p0_hardening_test.dart` 在本会话开始前后（22:26 CST，UTC 14:26）被另一并行工人改动，
  与 B10-3“删清空演示数据死入口”清理吻合；现全树已无“清空演示”引用。
- 建议由协调方与 B10-3 核对：删死入口时一并删了 4 个测试是否符合预期；
  如不是，须另查。本项验收本身（fixtures 移走后全量通过）不受影响。
