# S8 B1 — 学习报告 pendingCount 按时间范围过滤

- 裁决：Meng 2026-11-13 14:37，已裁决“要”（原 R0 §6-B-1 待裁决项）。
- 分支：`ui-replication`；未 commit、未 push。
- 修改文件：`lib/modules/report/report_page.dart`、`test/report_page_test.dart`；
  新增：本报告、`docs/ui-replication/run-shots-s8b1.sh`、
  `docs/ui-replication/shots/s8b1/`（4 张截图）。

## 1. 原来怎么算

`lib/modules/report/report_page.dart` 三个核心数的口径不一致：

| 核心数 | 原口径 |
|---|---|
| 已解决错因数 solvedCount | `status == solved` 且 `lastCheck` 为空或在范围内 |
| **待解决错因数 pendingCount** | **`status != solved`，不按范围过滤** |
| 复查通过率 passRate | `review_history` 中 `reviewedAt` 在范围内、已判定的记录 |

范围定义（`_rangeStart` / `_inRange`，三数共用）：本周 = 本周一到今天；
本月 = 当月 1 号到今天；全部 = 不过滤。后果：切到“本周”时待解决数
恒等于全部（如演示库恒为 6），而弱点、分布、已解决数都会变。

## 2. 现在怎么算

pendingCount 与 solvedCount **同一字段、同一范围定义**，只把状态条件取反：

```dart
final pendingCount = _records
    .where(
      (r) =>
          r.status != CauseStatus.solved &&
          (r.lastCheck == null || _inRange(r.lastCheck!)),
    )
    .length;
```

- 字段：`CauseRecord.lastCheck`（与已解决数同一字段；复查通过率用的是
  自查记录的 `reviewedAt`，那是另一张表，不适用）。
- 范围：同一 `_inRange`（本周一到今天 / 当月 1 号到今天 / 全部）。
- `lastCheck` 为空的分支与已解决数完全一致：视为在范围内，计入所有范围。
- 其余不动：弱点组、学科分布仍按题目 `createdAt` 过滤；“接下来练什么”
  仍取范围内弱点首行；类注释已同步更新（原“待解决不按范围过滤”已删）。

## 3. `lastCheck` 代理的近似性

- 模型没有“治愈日期”字段，也没有“待解决起始日”字段；不要为精确口径
  加字段——那是 Schema 改动，未授权。
- `lastCheck` 是**最近一次自查时间**（每次自查“已解决/未解决/不确定”
  都刷新它）。用它过滤待解决数，含义是“这个错因最近一次被自查的
  时间在所选范围内”。一个上月自查过、之后再没碰过的待解决错因，
  在“本周”里不出现——这是近似口径的固有含义，与已解决数用同一代理
  保持一致（已解决数同样以 `lastCheck` 近似治愈日期，复查通过也会
  刷新 `lastCheck`，原解决日期丢失；见 R9-REPORT §6 第 4 条）。
- 从未自查过的待解决错因 `lastCheck` 为空：无活动日期可供过滤，按与
  已解决数同一分支计入所有范围。替代方案（空视为范围外）会把从未碰过
  的待解决错因从报告里藏掉，与“待解决 + 解决中，还留在复习列表里”
  的小字含义相悖，故不采用。
- 未考虑的字段：`joinedAt`（加入复习时间）不是已解决数的过滤字段，
  不采用；`recheckDate` 只对已解决的复查有意义，不采用。

## 4. 测试与构建结果

- `flutter analyze`：**No issues found!**
- `flutter test test/report_page_test.dart`：**23/23 通过**（原 22 + 新增
  B1 测试 1 个）。新增测试 `待解决按范围过滤（S8 B1）／本周 2 · 本月 2/3 ·
  全部 3/4，已解决恒为 1`：构造 5 条记录——A 待解决·今天（三档都进）、
  B 解决中·上周日（只进本月/全部；本周一是 1 号时该档不存在，期望值按
  实际周一起始日分支断言）、C 待解决·40 天前（只进全部）、D 待解决·
  从未自查（`lastCheck` 为空，三档都进）、E 已解决·今天（不进待解决）；
  断言三档切换后 pendingCount 分别为 2 / 2 或 3 / 3 或 4，已解决恒为 1。
  日期一律相对今天取，跑在任何一天结果都一样（与 R9 测试同一做法）。
  既有测试 `已解决 1 · 待解决 4 · 复查通过率 67%` 不用改：默认库的待解决
  记录要么 `lastCheck` 为空、要么在周内，新口径下本周仍为 4。
- `flutter test` 全量：**312/312 通过**。
- `flutter build linux --release`：**成功**，产物
  `build/linux/x64/release/bundle/quiz_master2`。
- Flutter/Dart 3.47.9 / 3.13.7，路径 `~/workspace/flutter-install/flutter/bin/flutter`。

## 5. Linux 真机截图验证（Xvfb 1280×720，深色标准字号）

演示库原数据下三档区分不开（6 条待解决记录要么 `lastCheck` 为空、要么
在周内，新口径三档都是 6，与旧口径相同），故截图前临时改了两条
`last_check` 制造区分度，拍完用整库备份恢复并核对：

| 记录 | 临时 last_check | 含义 |
|---|---|---|
| q-pol-1 审题失误（待解决） | 2026-11-08 10:00 | 本月内、本周外 |
| q-pol-3 方法不会（待解决） | 2026-10-04 10:00 | 本月外 |

其余不动：q-math-3 解决中 lastCheck 2026-11-11（本周内），q-eng-1 已解决
lastCheck 2026-11-11（本周内），另 3 条待解决 lastCheck 为空。
预期核心数（已解决 / 待解决 / 通过率）：本周 1 / 4 / —，本月 1 / 5 / —，
全部 1 / 6 / —。旧口径下三档待解决都是 6。

| 截图 | 数字 | 结论 |
|---|---|---|
| `shots/s8b1/report-week-dark-standard.png` | 1 / **4** / —，范围说明“本周 · 11-9 ~ 11-13” | ✓ 与预期一致 |
| `shots/s8b1/report-month-dark-standard.png` | 1 / **5** / —，范围说明“本月 · 11-1 ~ 11-13” | ✓ 与预期一致 |
| `shots/s8b1/report-all-dark-standard.png` | 1 / **6** / —，范围说明“全部时间” | ✓ 与预期一致 |
| `shots/s8b1/probe-report-dark-standard.png` | 探针图（校准分段控件坐标用），本周 1 / 4 / — | ✓ 与正式周图逐像素一致 |

分段控件坐标用探针图像素扫描实测：“本月”文字中心 x≈350、“全部”
文字中心 x≈417，y=88（R9 的 344 亦落在“本月”文字内）。
截图脚本：`docs/ui-replication/run-shots-s8b1.sh`（`probe` 只截探针图，
无参数截三档；杀应用用 `pkill -x quiz_master2`）。

演示库已恢复并核对：9 道题、数学/英语/政治各 3 道；错因记录 5 待解决 +
1 解决中 + 1 已解决；`last_check` 非空的只有 q-eng-1、q-math-3 两条（原值）；
设置 themeMode=dark、fontSize=standard；备份文件已删除；无残留应用/Xvfb 进程。

## 6. 环境问题（构建工具链丢失，本轮恢复过程）

与 R0/R9 相同：VM 换机后 ninja、GTK 开发包、xdotool、ImageMagick 丢失。

1. `apt-get update` 时 apt 锁被系统进程（装 clang）占用，等待约 8 分钟释放；
   之后 `apt-get install ninja-build xdotool imagemagick` 显示已是最新版
   （系统进程刚装好）。
2. `libgtk-3-dev` 正常安装仍被 `libzstd-dev` 依赖链卡住（已装 `libzstd1`
   为 `1.5.5+dfsg2-2build1.1+hatch1`，`libzstd-dev` 要求
   `= 1.5.5+dfsg2-2build1.1`），沿用 R0 的办法：`apt-get download`
   libgtk-3-dev、libgdk-pixbuf-2.0-dev、libtiff-dev、libzstd-dev 后
   `dpkg-deb -x` 解包。注意：`sudo dpkg-deb -x <deb> /usr` 在本环境静默
   失败（无报错、无落盘）；改走解到 `/tmp` 再 `sudo cp -r` 到 `/usr` 才
   生效，随后 `pkg-config --exists gtk+-3.0 / gdk-pixbuf-2.0` 通过，
   `libtiff-4.pc` 就位。
3. 首次构建后 flutter 报告成功，但产物装到了 `/usr/local`（CMakeCache
   里 `CMAKE_INSTALL_PREFIX=/usr/local`），`build/.../bundle/` 不存在；
   清空 `build/linux` 后重建，prefix 恢复为 bundle 目录，构建成功。
   误装到 `/usr/local` 的内容（`quiz_master2`、`data/flutter_assets`、
   `data/icudtl.dat`）已删除。
4. 上述恢复只动系统工具链与 `/usr/local` 误装产物，未动项目源码、
   未升级依赖、未改 `pubspec.lock`。

## 7. 边界与遗留

- 只改报告页待解决计数口径（本次裁决的一处）；未改 SQLite Schema、
  未改业务规则、未增删功能、未改已定决策、未升级依赖、未改
  `pubspec.lock`、未动范围外目录；未做 B2 及以后的项。
- 遗留（与本项无关，Win11 真机仍需复核，见 R11）：Linux 结果不替代
  Win11 最终验收；字体/DPI/SQLite 原生资源须真机复核。
