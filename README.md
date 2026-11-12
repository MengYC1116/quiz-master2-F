# quiz-master2

Windows 个人智能错题本（Flutter + SQLite，先做 Windows，后做 Android）。

- Flutter **3.47.9**（Dart **3.13.7**，最新稳定版，2026-10-29 发布，见 `docs/decision-log.md` 第 0 条）
- SQLite 文件：`%LOCALAPPDATA%\quiz-master2\quiz-master2.db`（D-05 已确认改口径；安装目录只放程序，切片图也放同一数据目录）
- YOLO：已转 ONNX（`best.onnx` 约 37 MB），用 onnxruntime 接；本仓库先用占位模型写，见 `lib/services/yolo_onnx_service.dart`
- 打包：`.exe` 安装包（Win11）
- 只实现 4 个已确认模块：首页、收集中心、整理工作台、错题本。题目详情、复习、学习报告、学科管理 & 设置未实现（见 `docs/decision-log.md`）。

## 在 Win11 本地运行

1. 安装 Flutter **3.47.9** 稳定版（`flutter --version` 应显示 3.47.9 / Dart 3.13.7），勾选 Windows Desktop 开发（含 Visual Studio 2022 + C++ 桌面开发工作负载）。
2. `flutter doctor` 确认 Windows 一栏无缺项。
3. 在项目根目录：
   ```bat
   flutter pub get
   flutter analyze
   flutter run -d windows
   ```
4. 打包：
   ```bat
   flutter build windows --release
   ```
   产物在 `build\windows\x64\runner\Release\`，再用 Inno Setup 打成 `.exe` 安装包（D-12 已确认：要桌面快捷方式和开始菜单项；安装目录只放程序，数据目录见上）。
5. 首次运行会自动建库并写入演示数据：数学 / 英语 / 政治各 3 道大学题，共 9 道。

## 模块边界（一个页面一个模块）

| 页面 | 路由 | 文件 |
|---|---|---|
| 首页 | `/home` | `lib/modules/home/home_page.dart` |
| 收集中心 | `/collect` | `lib/modules/collect/collect_page.dart` |
| 整理工作台 | `/organize` | `lib/modules/organize/organize_page.dart` |
| 错题本 | `/wrongbook` | `lib/modules/wrongbook/wrongbook_page.dart` |

模块之间只靠题目 ID、学科 ID 联系；一道题在数据层只存一份（`lib/data/`）。
详细边界见 `docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md`；
写代码时需要用户确认、但未停下等确认的事项见 `docs/decision-log.md`。

## 目录

- `lib/main.dart` 入口；`lib/app.dart` 路由 + 左导航外壳
- `lib/theme/` 年轻学习伙伴感主题（亮色默认，深色冷灰 #1E2228）
- `lib/models/` 数据模型；`lib/data/` SQLite + 仓库 + 演示数据
- `lib/services/` YOLO ONNX（占位）+ 导入服务
- `lib/modules/` 4 个页面模块
- `assets/models/` 占位 ONNX 模型说明（真模型 `best.onnx` 由用户提供后替换）
