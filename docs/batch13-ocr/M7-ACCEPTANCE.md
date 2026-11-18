# M7 全量验收报告 — 十三批 OCR（GLM-OCR 接入）

- 日期：2026-11-18
- 执行员：M7
- 范围：只做 M7（全量验收 + Win11 复核清单）。未碰其他模块逻辑，
  未给 Meng 发邮件/消息，未推送代码，未做任何 git 操作
  （本地 HEAD bca8586 是 stale 的，未拿它当基准）。
- 依据：STATUS.md、M1～M6 报告、decision-log D-103～D-110、
  十二批 Win11 清单格式。

## 一、结论

**全量绿。1644/1644 通过，`flutter analyze` 0 问题，
Linux Release 构建通过，演示库 md5 未变。无真回归，无需修复。**

| 项 | 结果 |
|---|---|
| 全量测试 | **1644/1644，`All tests passed!`**（11:19，0 个 `[E]`） |
| flutter analyze | **No issues found!**（exit 0） |
| Linux Release 构建 | **通过**（`✓ Built build/linux/x64/release/bundle/quiz_master2`，未启动应用） |
| 演示库 md5（跑前 / 跑后） | `8f7f9c64405dc6e484ac2bf8e5e1a807` / `8f7f9c64405dc6e484ac2bf8e5e1a807`（标准 v1，9 道题，未变） |
| 泄漏检查 | 通过（见 §四） |
| Win11 清单 | `~/workspace/batch13-work/WIN11-CHECKLIST-B13.md`（23 项） |

基线 1438/1438 → 本次 1644/1644，**+206**，与十三批新增测试数逐项对得上：
M1 69 + M2 新 17 + M3 37 + M4 34 + M5 41 + M6 8 = 206。

## 二、全量测试

- 命令（`--concurrency=1`，规定环境变量）：
  `TMPDIR=$HOME/workspace/flutter-test-tmp`
  `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`
  `flutter test --concurrency=1`
- 日志：`~/workspace/batch13-work/m7-full-test.log`
  （最后一行 `11:19 +1644: All tests passed!`）。
- 失败定性：**0 失败，无需定性、无需修复。**
  已知 flake（b11_dragdrop_test.dart“一次拖两张”）本次全量中未出现。
- 备注（两次非代码中断，均与测试本身无关）：
  1. 第一轮在 134 项处被服务重启打断（非测试失败，日志尾是
     flutter_tools 关闭时的 `Bad state: Cannot close sink`，属进程被杀的残留）。
  2. 第二轮启动即失败：`pdfium_dart` 原生资源构建报
     `No compiler configured on host 'linux_x64'`——本机无 clang。
     处理：`~/workspace/.local/bin/clang` → gcc 垫片（仅供本机测试/构建用，
     未改仓库、未改 SDK），之后全量一次跑通。
     根因是环境缺 clang，不是十三批引入的回归（M1–M6 各自跑单文件时
     原生资源缓存是热的，未触发重建）。

## 三、Linux Release 构建

- 命令：`flutter build linux --release`（只验证构建，未启动应用）。
- 日志：`~/workspace/batch13-work/m7-build-linux.log`。
- 结果：**通过**。产物
  `build/linux/x64/release/bundle/quiz_master2`（24,280 字节，2026-11-18 07:58）。
- 构建中补的环境依赖（全是本机 Linux 工具链缺失，非代码问题）：
  1. 缺 ninja：系统回放进程装好 `ninja-build 1.11.1` 与 `clang-18`；
     首次构建报 `/usr/bin/ninja: No such file or directory`。
  2. 缺 `libgtk-3-dev`：`apt-get install` 初版因 `libzstd1`
     的 hatch 后缀版本（`1.5.5+dfsg2-2build1.1+hatch1`）与
     `libzstd-dev` 要求（`= 1.5.5+dfsg2-2build1.1`）冲突而报
     held broken packages；用 `--allow-downgrades` 把 `libzstd1`
     降到 stock Ubuntu 版后装好 `libgtk-3-dev 3.24.41`。
  3. 缺 `libsecret-1-dev`：`flutter_secure_storage_linux` 的 CMake
     要求 `libsecret-1>=0.18.4`，装好后构建通过。
  以上只动了本机系统包，未改仓库代码。Win11 侧不受影响，
  但 Win11 构建仍须先装 C++ ATL 库（见清单 §二）。

## 四、泄漏检查（grep 代码与测试）

| 检查项 | 方法 | 结果 |
|---|---|---|
| BigModel key 明文 / 硬编码 | grep `sk-…`、key 赋值字面量、长字面量 | **通过**：无硬编码 key；命中均为测试夹具 id（如 `task-importing`）等误报 |
| key 进日志 / 报错 / 界面 | grep `print/debugPrint` 含 apiKey/latex/ocrRaw/md_results；`getApiKey` 调用点 | **通过**：`getApiKey()` 只在 `glm_ocr_client.dart:308`（拼 Authorization 头）与 `ocr_queue.dart:454`（判有无 key）调用；设置页不调用 `getApiKey()`（只调 `hasApiKey()`）；生产代码无相关 print/debugPrint |
| LaTeX 源码出现在日志 / 报错 / 复制文本 | grep 复制路径（Clipboard）与 ocr 模块日志 | **通过**：复制只走 `copyImageToClipboard`（PNG 字节，无文本）；`ocrRaw` 只在内部解析（`GlmOcrRawData.tryParse`、公式裁图、状态推导），不作界面文本；M1/M5 测试已断言渲染后文本无 `frac` |
| VL-1.6 / Paddle 代码实现 | grep `vl-1.6`、`paddleocr`、`pp-ocr` | **通过**：仅 2 处注释提到 `glm-vs-vl16-compare.md` 报告文件名，无实现、无依赖 |
| SimpleTex 引用 | grep `simpletex`（lib/、test/、pubspec.yaml） | **通过**：0 命中 |

## 五、Win11 复核清单

- 文件：[WIN11-CHECKLIST-B13.md](sandbox://workspace/batch13-work/WIN11-CHECKLIST-B13.md)
- 格式与十二批一致：前言（拉取、核对 head、构建、备份数据库、确认模型文件）
  + 逐项核对步骤，共 23 项。
- 覆盖：C++ ATL 库前置确认（清单 §二，构建前必做）；设置页填 key
  （已设置/未设置显示，项 1–3）；导入自动识别端到端（有 key / 无 key，
  项 4–5）；失败与重试状态显示（项 6）；原图兜底（项 7）；
  整理页纠错入口（切片下方、编辑题干、候选预览、编辑中不丢草稿，项 8–11）；
  详情页纠错入口与重框自动重识别（项 12–13）；
  公式渲染目视（`\text{}` 中文、①②③④、分数/根号、长公式滚动、
  深色主题，项 14–18）；破折号已知弱点（项 19，不用修）；
  备份恢复（含 OCR 数据、先备份真实数据库再测、v3 备份恢复、v3→v4 迁移不丢，
  项 20–22）；回归抽查（项 23）。
- 注意：清单编写时代码尚未推送，head 一栏写明“以推送后协调员公布的 head 为准，
  不要拿本地旧 head bca8586 当基准”；Meng 按清单核对时须先拿到推送汇报里的 head。

## 六、遗留事项（给协调员 / M8）

1. **本机环境缺口（已就地补齐，仅影响本机）**：Linux VM 原无 clang/ninja/
   libgtk-3-dev/libsecret-1-dev；全量与构建已通过垫片 + apt 补齐跑通。
   其中 `libzstd1` 被从 hatch 后缀版降到 stock Ubuntu 版
   （`1.5.5+dfsg2-2build1.1+hatch1` → `1.5.5+dfsg2-2build1.1`），
   如需恢复请另行处理；`~/workspace/.local/bin/clang`（→gcc 垫片）
   留在 workspace 内，不影响仓库与 SDK。
2. **Win11 真机验证仍待 Meng 推送后做**：公式中文/`\text{}`、圈号字形、
   长公式滚动手感、深色主题公式颜色、ATL 构建、凭据管理器读写——
   均已列入清单，Linux 侧无法代验。
3. **GLM 破折号弱点**：政治腿 4 错全是破折号读成“一”，不做后处理、
   靠纠错入口兜底（D-103/D-104 已定），清单项 19 已写明。
4. **double01-q1 一框两题**：切分判“存在歧义”、整段保留（M4），
   等上游拆框或 M5 人工处理（D-107）；不在本次验收范围内。
5. **未推送代码，未联系 Meng**：按任务要求，M7 不推送、不发邮件/消息；
   推送与汇报由协调员安排。
