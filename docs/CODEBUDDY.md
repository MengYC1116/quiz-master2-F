# CodeBuddy 交接说明（quiz-master2）

> 给接手这个项目的 AI 编程助手（CodeBuddy）看的。先读完下面列出的文档再动手。
> 负责人是 Meng，他本人也在用 CodeBuddy 维护这个项目；推代码前必须经他确认。

## 项目是什么

- **quiz-master2**：Windows 个人智能错题本，只给单个大学生自己用。
- 技术栈：**Flutter 3.47.9 / Dart 3.13.7 + SQLite**，Windows 优先，Android 以后可能做。
- 核心流程：收集 → 整理 → 复习 → 掌握。错题管理是主线，复习按错因治（不是背题）。
- 仓库：`MengYC1116/quiz-master2-F`，当前工作分支 **`ui-replication`**（从 `main` 的 `0c812172` 分出）。

## 先读这三份文档（按顺序）

1. **`docs/代码地图.md`**——代码地图：目录、数据流、九页地图、Dart 速成、常见任务手册。看不懂代码时先翻它。
2. **`docs/decision-log.md`**——决策记录 D-00～D-22：所有已定事项（技术选型、数据库位置、演示数据等）。有疑问先查这里，不要凭感觉改。
3. **`docs/ui-replication/R11-REPORT.md`**——R11 最终验收报告（有条件通过）：九页完成情况、视觉对照结果、未解决问题清单（§8）、Win11 待验证事项（§9）。

## 硬边界（绝不能碰，除非 Meng 明确说可以）

1. 不改 SQLite Schema，不加字段、不改表结构。
2. 不改业务规则、数据口径、状态机（错因治愈规则、复查间隔、分页默认值等）。
3. 不增删产品功能，不改已定的产品决策。
4. 不升级依赖，不改 `pubspec.lock`，不换技术栈。
5. 不动本项目范围外的目录，不删旧备份和原始材料。
6. **不擅自 commit、push**。改完先在本地验证，报给 Meng，他确认后才推。
7. HTML 交互原型（`docs/` 外的 `quiz-master2-jiao-hu-yuan-xing.html`，SHA256 `18c8c434…35e1`）是唯一视觉目标；原型里的死代码（旧翻卡模型、静态演示数字、学科管理死按钮）不实现。

## 改完必须验证（缺一不可）

```powershell
flutter analyze        # 必须 0 问题
flutter test           # 必须全过
flutter build windows --release   # Win11 上必须构建成功
```

界面改动还要在真机窗口里跑一遍、截图，和 HTML 原型对照；Linux 构建成功不替代 Win11 真机验收（字体、DPI、尺寸要在 Win11 上复核）。

## 当前状态（2026-11-13）

- R0–R11 UI 重构已完成并推送，分支 head 为 `0d9d15d`（含 Win11 实机验收的两个 bug 修复）。
- R11 §8 的 A/B 组修复正在进行：放大浮层 1.5× 初始偏移、报告口径、启动页、备份、通知等，逐项验收，不是一次性全改。
- YOLO 还是占位实现（`lib/services/yolo_onnx_service.dart`，`hasRealModel` 为 false）；两个真实 `.onnx` 模型文件名相同，必须分文件夹放，真实文件在 Meng 的 Google Drive 里，还没接入。
- 演示数据库在 `%LOCALAPPDATA%\quiz-master2\quiz-master2.db`，改代码前先备份，验证完恢复原状。

## 工作方式

- 一次只做一件事，做完一项汇报一次：改了什么、怎么验证的、截图、还有什么没解决。
- 遇到要 Meng 裁决的点（两个页面对同一功能说法不一致、原型在 Flutter 里实现不了），停下来记进 `docs/decision-log.md`，按自己的判断先写、继续往下做，等他事后定——不要中途反复问。
- 回复用简体中文，简短，先说结论。
