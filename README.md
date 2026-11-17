# quiz-master2 v2 — Flutter + SQLite

Windows 个人智能错题本（大学个人用），1:1 复刻主预览
`quiz-master2-quan-xin-she-ji-yu-lan` 的 9 个页面。

## 从 0 重写（v2，2026-11-12）

旧项目 `~/workspace/quiz-master2-F/` 已完整备份到
`~/workspace/quiz-master2-F-old-20261112/`（不动）。本目录是全新项目，
9 个模块按当前预览定稿重写，不 patch 旧代码。

## 环境

- Flutter 3.47.9 / Dart 3.13.7（锁定）
- 依赖：`drift ^2.35.4` + `sqlite3 ^3.5.2`（SQLite，Drift 驱动；B1 起替代
  `sqflite_common_ffi`，见 D-45）、`path ^1.9.1`、
  `file_picker ^8.0.0`、`flutter_lints ^5.0.0`、
  `onnxruntime ^1.4.1`（D-23，2026-11-13 已 pin）、
  `pdfrx_engine ^0.9.2`（PDF 渲染，PDFium 引擎的纯 Dart 封装）
- YOLO 第 1 层已接真模型：`lib/services/yolo_onnx_service.dart`
  加载 `assets/models/question/yolo11s-question-v1.onnx`，
  letterbox 预处理 → CHW float32 输入 → OrtSession 推理 →
  解码 + NMS；第 2 层暂缓（`intraEnabled=false`，模型需重训；
  检测逻辑与数据模型保留，见 D-23，再接入点见该文件注释）。

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
    database.dart      SQLite（v2 全新 schema，schemaVersion 2，13 张表）
                       Batch 4 拆分后只剩入口 + 10 个 part 文件
                       db_backup / db_catalog / db_codec / db_collect /
                       db_orphans / db_paths / db_questions / db_schema /
                       db_settings / db_storage（实现见代码地图 §2）
    repository.dart    各页共用查询口径
    demo_data.dart     演示数据定义：`demoQuestions()` 已于 Batch 5
                       （SR-P2-13）删除，演示题的唯一合法来源是 v1 老库
                       （已整体删除，不迁移）；演示试卷/知识点树
                       （`demoExams()` / `demoKnowledgePoints()`）仍在；
                       新库建库时不预置演示题（§6 第 1 条），种子只写
                       学科/文件夹/标签/试卷/知识点树
    badge_notifier.dart 角标刷新通知
  services/
    yolo_onnx_service.dart  YOLO 第 1 层（真模型，见上；第 2 层暂缓）
    import_service.dart     PDF/JPG/PNG 导入（PDF 50MB/20 页、图片 20MB）
    pdf_render_service.dart PDF 按页渲染（pdfrx_engine / PDFium）
    page_image_pipeline.dart 框坐标变换、按框裁剪、EXIF 归一化
    recheck_reminder.dart   复查提醒（应用内、进入应用时一次）
    zip_archive.dart        备份/恢复用最小 ZIP 读写（纯 Dart）
  widgets/
    widgets.dart            整题切片 / 小伙伴形象 / 纸纹微点
    uikit.dart              公共组件库（R1，取自视觉基准 HTML）
    app_shell.dart          应用外壳 · 左导航（R2，纯展示组件）
  modules/
    home/ collect/ organize/ wrongbook/ detail/
    review/ report/ subjects/ settings/
    （Batch 4 拆分：collect/ 下入口 collect_page.dart + box_editor.dart
    修框编辑器 + collect_widgets.dart；wrongbook/ 下入口
    wrongbook_page.dart + wrongbook_shelf / wrongbook_directory /
    wrongbook_list / wrongbook_cover / wrongbook_widgets；详见代码地图 §2）
```

## 决策日志

见 `docs/decision-log.md`（v2 从 D-00 起重新记）。
