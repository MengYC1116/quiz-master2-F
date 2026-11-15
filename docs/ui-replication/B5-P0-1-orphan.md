# B5-P0-1：孤儿扫描误删未拆分 PDF 任务页图（SR-P0-1）

## 结果

已修。孤儿扫描不再把存续收集任务的派生文件当孤儿：未拆分 PDF 任务的
`imports/<taskId>/pages/*.png` 与图片任务的
`imports/<taskId>/page-normalized.png` 均被视为被引用，设置页一键清理
不会再删掉它们。

## 改动文件

- `lib/data/db_orphans.dart`（`_referencedRelativePaths`，唯一生产代码改动）
  - `collect_tasks` 查询补 `id` 列；对每个任务行，除 `source_path` 外再按
    任务 id 补两条引用：
    - `imports/<taskId>/page-normalized.png`（图片任务 EXIF 归一化副本）；
    - `imports/<taskId>/pages/` 目录下实际存在的文件（PDF 渲染页图，
      含 `page-<p>-r<角度>.png` 等旋转变体，枚举目录而非拼文件名）。
  - 采用报告建议里的窄口方案，未用“整个 `imports/<taskId>/` 目录视为
    被引用”：任务目录里的其它杂文件仍按孤儿处理，现有测试
    `p3_backup_migration_test.dart`（`imports/task-1/extra.png` 仍为孤儿）
    无需改动且继续通过。
  - `original.*` 未另行枚举：它就是任务行的 `source_path` 本身，已在口径内。
  - 任务 id 含 `/` 或 `\` 时跳过派生口径，防止 `p.join` 被带出任务目录。
  - 设置页（`settings_page.dart`）不用改：调用链不变，扫描结果直接变对。

## 附带影响（同一共享口径）

`_referencedRelativePaths` 也被 zip 备份共用（`db_backup.dart` 的
`exportBackupZipFromImpl`）：修后未拆分任务的页图也会进备份，恢复后
任务不再丢页图。此前备份同样漏掉了这些页图，与本项同根因。

## 验证

- 回归测试新增 `test/b5_p0_1_orphan_test.dart`，3 个测试，全部通过：
  1. needBox 的 PDF 任务（只有 `source_path`，无题），两张页图不在孤儿列表里；
  2. 图片任务的 `page-normalized.png` 不在孤儿列表里；
  3. 真孤儿仍被列出（已删任务残留目录、无引用切片），且存续任务目录里的
     杂文件（`extra.png`）仍是孤儿——锁定窄口，不扩大保护范围。
  - 测试用内存库 + 临时数据目录，未碰真实演示库。
- 相关既有测试 `test/p3_backup_migration_test.dart`：27/27 通过。
- `flutter analyze`：No issues found（0 问题）。
- 未跑全量测试（按任务要求，协调员在阶段结束统一跑）。
- 未对旧代码跑新测试验证“先红后绿”：旧口径只收 `source_path`，页图
  无任何行引用，代码上可直接判定旧测试 1、2 会失败；未做临时回退验证。

## 遗留问题

无。本项无遗留。`git status` 未动历史、未 commit、未 push。
