# R1 基线记录

> 记录日期：2026-11-13。R1 环境与验证准备（只读审计 + 环境恢复）。
> 本阶段未改任何业务代码：未动 `lib/`、`pubspec.*`、`windows/`、`linux/`；
> 新增仅 `docs/ui-replication/R1-BASELINE.md`、`docs/ui-replication/run-shots-r1.sh`、
> `docs/ui-replication/shots/r1/home-dark.png` 与 `test/theme_smoke_test.dart`（冒烟骨架）。
> 无 commit、无 push。

## 1. 视觉基准 SHA256 核对 — 一致

| 文件 | SHA256 | 大小 |
|---|---|---|
| 交互原型 `~/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html` | `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1` | 485,528 字节 |
| 完整预览 `~/workspace/your_files/quiz-master2-quan-xin-she-ji-yu-lan/quiz-master2-quan-xin-she-ji-yu-lan.html` | `fe4a8e2630cc122f2587a4f147f6fb00f41b00874356692f1b1da1122a69fe86` | 514,490 字节 |

两份 SHA256 均与任务书给定值一致，未发现改动。

## 2. 代码基线

| 项 | 值 |
|---|---|
| 工作目录 | `~/workspace/quiz-master2-UI/` |
| 分支 | `ui-replication` |
| 基线提交 | `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`（`git rev-parse HEAD` 核对一致） |
| 工作树 | 除 `docs/ui-replication/` 与新增 `test/` 外干净；无 commit、无 push |

## 3. 工具链版本（实测）

| 项 | 版本 / 位置 |
|---|---|
| Flutter | 3.47.9（stable，revision c197ca5199，2026-10-29） |
| Dart | 3.13.7（stable） |
| Flutter SDK 位置 | `~/workspace/flutter-install/flutter/bin`（**不在默认 PATH 中**，使用时需 `export PATH="$HOME/workspace/flutter-install/flutter/bin:$PATH"`） |
| ninja | 1.11.1 |
| cmake | 3.28.3 |
| pkg-config gtk+-3.0 | 3.24.41（`pkg-config --exists gtk+-3.0` 通过） |
| pkg-config gdk-pixbuf-2.0 | 2.42.10 |
| libtiff-4.pc | 存在（`/usr/lib/x86_64-linux-gnu/pkgconfig/libtiff-4.pc`） |
| Xvfb / xvfb-run | 已安装（`/usr/bin/Xvfb`、`/usr/bin/xvfb-run`） |
| 截图工具 | ImageMagick `import`（`/usr/bin/import`） |

## 4. 环境恢复 — 本次无需恢复

本次检查时 ninja、cmake、gtk+-3.0、gdk-pixbuf、libtiff-4.pc 均已就位，
`pkg-config --exists gtk+-3.0` 直接通过；未遇到 R0 §7 的
libzstd-dev 依赖链卡住问题，未动用 `apt-get download` + `dpkg-deb -x` 解包办法，
未改 dpkg 数据库，未装新包。唯一需要注意的是 Flutter 不在默认 PATH，
见 §3 的 SDK 位置。

## 5. 基线验证结果（2026-11-13，基线代码未改）

| 检查 | 结果 |
|---|---|
| `flutter pub get` | 成功；14 个包有更新版本但受约束锁定，未升级 |
| `flutter analyze` | **No issues found!**（7.8s） |
| `flutter build linux --release` | **成功**：`✓ Built build/linux/x64/release/bundle/quiz_master2`（exit 0）。本次未遇旧 CMakeCache 残留失败，无需清空 `build/linux` |
| `flutter test test/theme_smoke_test.dart` | **2/2 通过**（冒烟骨架，见 §6） |
| Xvfb 1280×720 运行 + 截图 | **成功**：`docs/ui-replication/shots/r1/home-dark.png`（1280×720 PNG，85,247 字节），首页深色主题正常渲染 |

## 6. 验证脚手架

### 6.1 冒烟测试骨架 — `test/theme_smoke_test.dart`

仓库此前无 `test/` 目录，本次新建，只放最小占位：
- `AppTheme.light()` / `AppTheme.dark()` 可构造不抛错；
- 浅/深底色常量存在且不同。
完整断言（token 值与 HTML 对照、三档缩放 1.00/1.15/1.30、深色纸面/主色裁决后）
等 Token 实现员把 R1 token API 定下来后再补，不要提前按猜测的 API 写。
运行：`flutter test`（`flutter_test` 已在 `pubspec.yaml` 的 dev_dependencies 中）。

### 6.2 截图脚本 — `docs/ui-replication/run-shots-r1.sh`

```bash
./docs/ui-replication/run-shots-r1.sh [shot-name] [wait-seconds]
./docs/ui-replication/run-shots-r1.sh home-dark        # 默认等 4 秒
./docs/ui-replication/run-shots-r1.sh home-dark 6       # 等 6 秒再截
```

- 自动起 Xvfb（1280×720，显示号自动避让已占用的 `:99`），跑 Release 产物，
  用 ImageMagick `import -window root` 截图，存 `docs/ui-replication/shots/r1/<name>.png`。
- 前置：已跑过 `flutter build linux --release`。
- 注意：Xvfb 下无系统主题设置，应用默认深色（与 R0 一致）；浅色截图需在应用内切主题
  或在有主题设置的真机上另行截取，本脚本只负责“跑起来 + 截下来”。
- 应用启动在 `/home`；切到其他页需人工在窗口里点，本脚本不做自动导航。

## 7. 声明

**Linux 结果不能替代 Windows 11 最终验收；Win11 字体（Segoe UI / Microsoft YaHei / Georgia）、
窗口尺寸、DPI、SQLite 原生资源须真机复核。**Linux 构建 + Xvfb 点测只证明基线在 Linux 上
可构建、可运行、可截图，不宣称字体、窗口尺寸、DPI 已在 Windows 上验证。
另：`windows/runner/resources/app_icon.ico` 仍缺失（R0 §8），Windows 构建前置事项未变，
本次未擅自补文件。

## 附录：app_icon.ico 补入记录（2026-11-13，负责人全程自主执行授权后补入）
- 来源：~/workspace/quiz-master2-F2/windows/runner/resources/app_icon.ico（本地 F2 目录已核实的原始图标，33,772 字节）
- 来源 SHA-256：c098d3fc85cacff98b8e69811b48e9f0d852fcee278132d794411d978869cbf8
- 补入位置：windows/runner/resources/app_icon.ico（新建 resources/ 目录；核对过 windows 脚手架：windows/runner/Runner.rc:55 引用 "resources\\app_icon.ico"，未覆盖其他文件）
- 补入后 SHA-256：c098d3fc85cacff98b8e69811b48e9f0d852fcee278132d794411d978869cbf8（与来源一致）
- 状态：未 commit、未 push；Windows 构建仍须在负责人 Win11 真机上验证。
