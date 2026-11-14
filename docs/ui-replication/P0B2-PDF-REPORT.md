# P0B2 · PDF 渲染库选型与接入报告

> 日期：2026-11-14 · 分支 `ui-replication`（未 commit、未 push）
> 依据：方案 `docs/ui-replication/DB-CHANGE-PLAN.md` §1.4（页图长边 2000–3000、PDF 渲染 PNG、导入时复制进库、存储上限 2GB）与 §6 第 3 条（PDF 接受、限 50MB / 20 页）、第 6 条（页图缺失明确报错、不开编辑器）

---

## 1. 选型结论

**选定：`pdfrx_engine` 0.9.2（引擎版，不是完整 `pdfrx` 插件），MIT 许可证。**

只引引擎版的理由：本项目只要“打开文档 + 按页渲染成像素”，不需要查看器 widget。引擎版不带 `material_ui` / `url_launcher` / `path_provider` 等传递依赖；不要求 Win11 开开发者模式（那是完整 `pdfrx` 插件的符号链接构建要求）。

## 2. 选型比较表

| 维度 | pdf_render | pdfrx（完整插件） | **pdfrx_engine（选中）** | pdfx | syncfusion_flutter_pdfviewer |
|---|---|---|---|---|---|
| Win11 可用性 | ❌ 无 Windows（仅 iOS/Android/macOS/Web） | ✅ 支持 Windows，但构建**必须开开发者模式**（符号链接） | ✅ 支持 Windows；native-assets 钩子编译一个 16KB 的 gate 库，Win11 上 Flutter 构建本就需要 VS C++ 工具链，无额外要求 | ⚠️ Windows 需手动跑 `dart run pdfx:install_windows` 改 CMakeLists.txt（额外构建步骤）；pinch 重渲染不支持 | ✅ 支持 Windows |
| 渲染引擎 | 原生 PDF 渲染 | PDFium，多线程渲染 | PDFium（与完整版同引擎） | PDFium | 自有渲染 |
| 渲染成图片文件 | ✅ | ✅（可渲染成图片） | ✅ `page.render()` → BGRA 像素 → 转 PNG | ✅ | ❌ **没有渲染成图片文件的 API**，是查看器 widget，与本项目“页图 PNG”管线不匹配 |
| 50MB 大 PDF 内存 | —（无 Windows，出局） | 逐页渲染，单页常驻 | 逐页渲染、逐页写盘、逐页释放；实测 3 页试卷页整本渲染 1.2 秒，进程 RSS 229MB（含 flutter test 宿主） | — | — |
| 许可证 / 费用 | MIT | MIT | **MIT**（已读 pub 缓存内 LICENSE；传递依赖 `pdfium_dart` 0.4.2 也是 MIT） | MIT | 商业：$599/开发者/年；小组织可用免费 Community License（年收入 <$1M、≤5 开发者、≤10 员工） |
| 包体积 | — | libpdfium 约 7.7MB + 插件代码 | **libpdfium.so 7.7MB + libpdfrx_pdfium_gate.so 16KB**（Linux Release 实测） | libpdfium 约 7.7MB | 体积大（含查看器 UI） |
| 维护状态 | ❌ **作者自述维护模式，不再加新功能** | ✅ 活跃（最新 2.12.1，2026-11-13 发布）；要求 Flutter 3.47 / Dart 3.13，与本项目锁定版本一致 | ✅ 活跃（0.9.2） | ⚠️ 2026-08-20 更新，160 pub points；**pub.dev 评分页明确写“Package does not support platform Linux”**，Linux 验证环境无法用 | ✅ 活跃（商业维护） |
| 结论 | 出局：无 Windows + 维护模式 | 备选：功能够用，但要开发者模式 + 多余依赖 | **选中** | 出局：不支持 Linux | 出局：无渲染成图片 API + 商业授权 |

关键 API（实测可用）：`pdfrxInitialize()`（首次使用前调用，自带幂等保护）；`PdfDocument.openFile(path)`（`firstAttemptByEmptyPassword=true`，无密码加密 PDF 抛 `PdfPasswordException`）；`doc.pages`（`PdfPage` 有 `width/height` 点值、`pageNumber`）；`page.render(fullWidth:, fullHeight:)` 返回 `PdfImage?`（`width/height/pixels` 为 BGRA）；`PdfImage.dispose()`；损坏文件抛 `PdfException`。

渲染时机决定：**导入时整本渲染**（§1.4 留待选型时定）。理由：20 页上限本就要求导入时知道页数；全渲后修框翻页不等待；磁盘成本受 2GB 上限 + 导入前估算约束。

## 3. pubspec 改动清单

唯一新增依赖（`flutter pub add pdfrx_engine`，已记录再动手，无静默改动）：

| 包 | 版本 | 为什么必须加 |
|---|---|---|
| `pdfrx_engine` | `^0.9.2` | PDF 渲染引擎（PDFium 封装）：打开 PDF、按页渲染成像素；纯 Dart 封装 + native-assets 钩子编译 gate 库，无需手写原生代码 |
| `pdfium_dart`（传递） | 0.4.2 | `pdfrx_engine` 的 PDFium Dart 绑定 |
| `rxdart`、`posix` 等（传递） | 见 `pubspec.lock` | `pdfrx_engine` 的传递依赖，共 8 个依赖变化 |

改动文件：`pubspec.yaml`、`pubspec.lock`。其余依赖未动。

## 4. 接入改动

### 4.1 新文件 `lib/services/pdf_render_service.dart`

- 异常：`PdfEncryptedException`（默认文案“这个 PDF 带密码”）、`PdfCorruptException(reason)`（损坏 / 不是 PDF / 渲染失败，带具体原因）。
- `PdfPageRender {png, width, height}`；抽象 `PdfEngine`（`open(path)` → `PdfEngineDocument`）与 `PdfEngineDocument`（`pageCount`、`renderPage(page, {targetLongEdge})`、`close()`），可注入假引擎；生产实现 `PdfrxEngine`（调 `pdfrx.pdfrxInitialize()`；`PdfPasswordException` → 加密；`PdfException` → 损坏，文案经 `_readableOpenError` 翻译）。
- `PdfRenderService`：`targetLongEdge = 2500`（方案 §1.4 长边 2000–3000）；`pageCount(path)`、`renderPagePng(path, page)`、`renderAllPagesToDir(path, outDir, {pageFileName, onProgress})`（逐页渲染、逐页写盘、逐页释放，文件 `page-001.png`…，`onProgress` 为 `Future<void> Function(int rendered, int total)?`；任何一页失败抛错）。BGRA→PNG 经 `dart:ui`（`decodeImageFromPixels` + Completer + `toByteData(PNG)`）。

### 4.2 `lib/services/import_service.dart`

- 构造器新增可选参数 `PdfRenderService? pdfRenderService`（默认真实服务）。
- 新增 `maxPdfPages = 20`、`estimatedBytesPerRenderedPage = 2MB`。
- 新增 `renderedPageRelative(taskId, page)` → `imports/<task-id>/pages/page-<三位页码>.png`；`pageImageRelativeForTask(task, {int? page})` 改为 PDF 感知（PDF → 当页渲染页图；图片 → 原有归一化副本/原图逻辑）；新增 `isPdfTask(task)`（按 sourcePath/fileName 扩展名判 `.pdf`）。
- `enqueue` 重构：PDF 先判 50MB（复制前；超了失败任务，文案“这个 PDF 有 X.XMB，超过 50MB 上限，请拆成多个小 PDF 再导入”，不建目录）；复制进库（0→70%）后走新 `_importPdf`：先 `pageCount`（不渲染）判 20 页（超了失败，文案“这份 PDF 有 N 页，超过 20 页上限，请分批导入：拆成每份不超过 20 页再导入”）、0 页判损坏、空间估算（已有占用 + 原文件 + 页数×2MB > 2GB 则失败）；再 `renderAllPagesToDir` 整本渲染（70→100%）；成功为 needBox、`pageCount` 为真实页数、`sourcePath` 为 `original.pdf` 相对路径。加密 / 损坏 / 渲染失败 → `_failAndClean`（失败任务 + 删任务目录，不留半截文件）。旧“暂不支持 PDF”分支已删。图片分支（EXIF）未动。

### 4.3 `lib/modules/collect/collect_page.dart`

- `CollectPage` 新增可选参数 `pdfRenderService`，`_pickFiles` 与 `_importFiles` 透传给 `ImportService`。
- 拖放区文案更新：'PDF 与 JPG / PNG 照片都能导（Word 先导出成 PDF 再导入）'；限制行改为 '单个 PDF 不超过 50MB、20 页，超了进失败任务并提示分批导入 · 图片不超过 20MB · 一份卷子会按页逐页框题 · …'。页头注释同步更新。
- `_openBoxEditor`：PDF 多页任务校验**全部**页图存在（缺任何一页都不开编辑器，§6 第 6 条）；构建 `pageImagePaths`（页 → 绝对路径）传给编辑器。
- `_confirmSplit` 签名改为 `(task, result)`（去掉 `pageImageAbs/pageImageRel` 参数）；循环内按页取页图（PDF 每页一张、图片各页同一张；缺失则整单失败、库不动）；`sourceKind` 按 `ImportService.isPdfTask(task)` 取 `'pdf'`/`'image'`；旋转烘焙仍按页走 `bakedPageRelative`。
- `showBoxEditorDialog` 与 `_BoxEditorDialog` 新增可选参数 `pageImagePaths = const {}`（页 → 绝对路径；单页 / 重框模式不传）。编辑器新增 `_currentPageImagePath` getter（`pageImagePaths[_currentPage] ?? widget.pageImagePath`）；`_loadPageImageSize` 改走当前页图（切页重调，防旧页尺寸串页）；`_switchPage` 切页后重载尺寸并调新增 `_autoDetectIfEmpty(page)`（草稿模式、目标页无框时自动检测一次；失败静默，不落占位）；`_restoreAutoBoxes`、`_restoreAutoBoxForRework` 与画布 `Image.file` 均改走 `_currentPageImagePath`。缩略图条外观未改（仍为示意缩略图，只翻页）。

页图接口 `page_image_path` 未动（独立插件接入）。

## 5. 验证结果

### 5.1 静态与单测

- `flutter analyze`：**0 问题**。
- 全量 `flutter test`：**537 通过、0 失败**（约 2 分 47 秒；基线 523 + 新增 14；YOLO 冒烟用 `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）。
- Linux Release 构建成功：`build/linux/x64/release/bundle/quiz_master2`；`bundle/lib` 含 `libpdfium.so`（7.7MB）、`libpdfrx_pdfium_gate.so`（16KB）、`libonnxruntime.so.1.15.1`、`libsqlite3.so`；模型 `data/flutter_assets/assets/models/question/yolo11s-question-v1.onnx` 已打包。

### 5.2 新增测试（14 项）

- `test/pdf_render_service_test.dart`（13 项）：手写最小 PDF 生成器（Dart 版；每页文字 + 黑色实心矩形）；夹具 `test/fixtures/pdf-encrypted.pdf`（pypdf 7.1.0 加密，用户密码 `1234`）。覆盖：3 页 PDF 真实渲染（页数 3；第 1 页 1932×2500 PNG、PNG 魔数、非白像素）；`renderAllPagesToDir` 写出 page-001..003.png、进度到 (3,3)；页码越界抛错；加密 PDF 抛 `PdfEncryptedException`；损坏 PDF（随机字节 / 空文件 / 截断）抛 `PdfCorruptException`；导入 3 页 PDF（needBox、pageCount 3、原文件 + 3 张页图落盘、`pageImageRelativeForTask(task, page: 2)` 为 page-002.png、进度到 100）；21 页 PDF 失败（文案含 '21 页'、'20 页上限'、'分批'，目录已删）；51MB PDF 失败（稀疏文件 truncate，文案含 '50MB'、'拆成多个小 PDF'，目录已删）；加密 PDF 导入失败（错误 exactly '这个 PDF 带密码，解开密码再导'）；损坏 PDF 导入失败（错误以 '文件损坏：' 开头）；假引擎注入（3 页走整本渲染、页图为 10×10 红 PNG；第 2 页渲染失败 → 失败任务、目录已删；打开即加密错 → 提示带密码）。
- `test/pdf_collect_page_test.dart`（1 项）：复用 `collect_page_test.dart` 的 FakeRepo 等；真实 `PdfRenderService` 渲手写 3 页 PDF；打开编辑器底图为 page-001.png、检测跑在第 1 页图上；点 `editor-thumb-2` 后底图换 page-002.png、空页自动检测用第 2 页图、画布出现“题级框 1”；确认后 `savedQuestions` 2 道、`sourcePage` {1,2}、`sourceKind` {'pdf'}、切片文件存在且非空、原任务已删。注：确认等待用轮询 `repo.savedQuestions.length`（上限 100×300ms），固定等待在全量并行时会因 CPU 争用超时。
- `test/p2_main_chain_test.dart` 更新：旧测试 'PDF 导入：显式失败“暂不支持 PDF”，不复制文件' 改为 'PDF 导入：损坏的 PDF（只有文件头）显式失败，不留任务目录'。

### 5.3 渲染性能实测

- 3 页真实试卷页（1653×2200）整本渲染：**1.2 秒**（约 0.4 秒/页），测试进程 RSS 229MB（含 flutter test 宿主 + PDFium，逐页释放）；20 页约 8 秒。
- 3 页渲染出 1878×2500 PNG，分别为 624KB / 792KB / 973KB（合计约 2.3MB；原文件 560KB）；`imports/` 合计 2.9MB。20 页最坏情况约 12–20MB，2MB/页的存储估算偏保守。

### 5.4 Xvfb 真机端到端（Release 包，1280×720）

用真实 3 页试卷 PDF（`/tmp/qm2-pdf-spike/test3.pdf`）走完全链路：

1. 收集中心顶部红色横幅同时出现两条失败提示：big-51mb.pdf “这个 PDF 有 51.0MB，超过 50MB 上限，请拆成多个小 PDF 再导入”；pdf-21page.pdf “这份 PDF 有 21 页，超过 20 页上限，请分批导入：拆成每份不超过 20 页再导入”。任务列表两行均标“导入失败”并附红字原因。
2. test3.pdf 任务“检测完成，等你修框确认 · 数学 · 第1页 / 共3页”。点“修框”打开编辑器：第 1 页真实 YOLO 检测出 **14 框**，标题“修框 · test3.pdf 第1页 · 本页 14 道题”；点第 2 页缩略图切页，自动检测出 **7 框**，标题变“第2页 · 本页 7 道题”，确认按钮变“拆成 21 个待整理任务”——多页翻页 + 切页自动检测均在真机上工作。
3. 两页均有重叠框，确认被拦（红字“框重叠有重叠了…”）。按 P2 的做法：取消（草稿入库：第 1 页 14 框、第 2 页 7 框）→ SQL 删每对重叠中较小的（第 1 页 14→11，第 2 页 0 个重叠）→ “继续修框”重开：重叠警告消失，确认按钮启用，文案“确认修框，拆成 18 个待整理任务”。
4. 确认后：**18 道题入库**，全部 `source_kind='pdf'`，`source_page` 第 1 页 11 道、第 2 页 7 道；18 个切片 PNG 落盘（尺寸 594×47 至 1487×134，非白像素 4–22%，合计约 1MB）；原任务已删。
5. 整理工作台：“队列 还剩 18 道”，“当前整理：数学 · test3.pdf · 第2页 · 第7题”，左侧显示真实题目切片（选择题 A. y = sin2x… B. y = tanx… C. y = x²+3x+1 D. y = √x²−1），“修框切片”区显示真实切片图；左导航角标收集中心 18、整理工作台 18。

### 5.5 演示库恢复

验证后已恢复原状：`~/.local/share/quiz-master2/quiz-master2.db` 从 `/tmp/qm2-demo-backup/quiz-master2.db` 拷回；删除 e2e 产生的 `imports/`、`slices/`（及 `-wal`/`-shm`）；验证恢复后：**9 道题、3 学科、`themeMode=dark`、`pageSize=10`、`user_version=1`**（v1 库）。

## 6. Win11 待复核（与 onnxruntime 同类 caveat）

- `flutter build windows` 是否成功打包 libpdfium（Linux 已验证，Windows 未验）。
- 完整 `pdfrx` 插件的“开发者模式”要求**不适用于**引擎版，但 Win11 上 native-assets 钩子编译 gate 库仍需 VS C++ 工具链（Meng 本地构建本就需要）。
- 20 页整本渲染约 8 秒（Linux 实测外推），Win11 真机上首次导入大 PDF 时的等待体验待 Meng 复核。

## 7. 备注

- 临时文件 `test/pdf_e2e_seed_test.dart`、`test/pdf_timing_tmp_test.dart` 已删；测试夹具 `/tmp/qm2-pdf-spike/`（test3.pdf、pdf-21page.pdf、big-51mb.pdf 等）与 pypdf venv `/tmp/qm2-pdf-venv` 保留在 /tmp，未进仓库。
- 演示库备份 `/tmp/qm2-demo-backup/quiz-master2.db` 保留在 /tmp，未进仓库。
- 本次未 commit、未 push；工作区改动除本轨文件外还包含 P0–P3 的既有改动（同分支未提交状态）。
