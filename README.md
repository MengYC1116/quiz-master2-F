# quiz-master2 v2 — Flutter + SQLite

Windows 个人智能错题本（大学个人用），1:1 复刻主预览
`quiz-master2-quan-xin-she-ji-yu-lan` 的 9 个页面。

## 从 0 重写（v2，2026-11-12）

旧项目 `~/workspace/quiz-master2-F/` 已完整备份到
`~/workspace/quiz-master2-F-old-20261112/`（不动）。本目录是全新项目，
9 个模块按当前预览定稿重写，不 patch 旧代码。

## 环境

- Flutter 3.47.9 / Dart 3.13.7（锁定）
- 依赖：`sqflite_common_ffi ^2.3.6`、`path ^1.9.1`、
  `file_picker ^8.0.0`、`flutter_lints ^5.0.0`
- onnxruntime 的 Dart 包版本故意不 pin：须在 Win11 上验证后再定
  （decision-log D-07）；在此之前 YOLO 以占位模式运行。

## 运行（Linux 验证）

```sh
flutter pub get
flutter analyze
flutter build linux --release
```

Windows（用户电脑 Win11）：

```sh
flutter pub get
flutter analyze
flutter run -d windows
flutter build windows --release
```

数据库 `quiz-master2.db` 在 `%LOCALAPPDATA%\quiz-master2`；
Linux 验证时在 `~/.local/share/quiz-master2/`。

## 结构

```
lib/
  main.dart            入口
  app.dart             外壳：左导航 + 9 路由
  theme/app_theme.dart 年轻学习伙伴感（亮色 / 深色冷灰）
  models/models.dart   学科/错因/题目/文件夹/设置等模型
  data/
    database.dart      SQLite（v2 全新 schema，version 1）
    repository.dart    各页共用查询口径
    demo_data.dart     演示数据：数学/英语/政治各 3 道大学题
    badge_notifier.dart 角标刷新通知
  services/
    yolo_onnx_service.dart  两层 YOLO（占位：一页一个整题框）
    import_service.dart     PDF/JPG/PNG 导入（50MB/20MB）
  widgets/widgets.dart      整题切片 / 小伙伴形象 / 纸纹微点
  modules/
    home/ collect/ organize/ wrongbook/ detail/
    review/ report/ subjects/ settings/
```

## 决策日志

见 `docs/decision-log.md`（v2 从 D-00 起重新记）。
