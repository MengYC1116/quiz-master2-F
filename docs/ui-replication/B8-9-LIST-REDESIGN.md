# B8-9 题目列表 UI 重新设计

**结论先行：Meng 2026-11-15 15:44 定稿 A 留白卡片。** 代码已按 A 方向落地为最终实现，`b8ListStyle` 开关与 B、C 方向分支已删除；B、C 截图留档，不删。空状态文案修复（文件夹为空 vs 搜索无结果）包含在 A 内，三方向时期共用同一份文案逻辑，定稿后保留。

## 改了什么

文件（只动本项范围，不提交、不推代码）：

- `lib/modules/wrongbook/wrongbook_list.dart`：主改动。
  - 删掉蓝色大框（`_openBookFrame` 不再包列表页）：工具条 / 筛选面板 / 列表 / 分页直接落在页面底色上。目录页的书框不动（不在本次范围）。
  - 大卡片：每张卡独立一张白卡（`palette.surface` + `palette.line` 细边 + 圆角 12 + 柔和阴影，内边距 12，卡间距 14）。不再用固定高度内部滚动容器——整页只有一个 `SingleChildScrollView`，卡片全部建出来、随页滚动（旧逻辑是 >2 张卡进固定高度 `ListView` 内部滚动）。
  - 紧凑列表 / 归档行：共用一张白卡（`_listSurface`，横向 8 / 纵向 4 内边距），行间普通细分隔线。
  - 页尾留白 24px：分页器是页内最后一个元素，滚到底时贴着视口底边；留 24px 后“每页 N 道”下拉菜单打开时不再把菜单底推出视口（见“验证”里的 dropdown 断言）。
  - 保持已定行为不变：大卡片默认、紧凑列表切换、分页 10/页（10/20/30/40/50）、筛选/排序/重置、批量操作、收藏星标、大卡片蓝色序号圆盘（本页内 1、2、3…重编号）。
- `lib/modules/wrongbook/wrongbook_page.dart`：仅改一行 import 注释（`app_theme` 转出 `design_tokens`；C 方向用的 `CompanionWidget` 引用已随 C 分支删除）。
- `test/wrongbook_page_test.dart`：空状态新增 5 个用例（见下）；>2 张卡不再用固定高度内部滚动容器的断言、分页下拉的 `ensureVisible`、SR-P2-54（书框已删）相应改写；定稿后两个“三方向循环”用例收成单方向断言（用例数不变）。

## 三个方向（Meng 已挑 A）

| 方向 | 做法 | 截图 |
| --- | --- | --- |
| **A 留白卡片（定稿）** | 大卡片各成白卡；紧凑/归档行共用白卡；空状态虚线框 + 小伙伴 | `after-A-list.png` / `after-A-compact.png` / `after-A-empty.png` |
| B 纸面通栏（废弃） | 整列共用一张纸面；空状态纸面样式、无小伙伴 | `after-B-list.png` / `after-B-compact.png` / `after-B-empty.png` |
| C 极简线条（废弃） | 无容器，只留白与细分隔线；空状态裸放小伙伴 | `after-C-list.png` / `after-C-compact.png` / `after-C-empty.png` |

- 改前：`before-list.png`（蓝框套列表，2 张大卡）、`before-compact.png`、`before-empty-folder.png`（复现 image-97 的 bug 文案）。
- 四格对照：`compare-list.png`（改前 / A / B / C）。
- 截图条件统一：1280×720，同一份演示数据（数学·全部题目 2 道、数学·平时作业空文件夹），截图脚本与 v2 转换见 `docs/ui-replication/shots/b8-list/make-v2-shot-db.py`。
- 截图目录：`docs/ui-replication/shots/b8-list/`（截图不推）。

## 空状态文案新旧对照

`_emptyCopy()` 四分法（定稿 A 保留，B/C 时期三方向共用）：

| 场景 | 旧文案 | 新文案（标题 / 说明 / 按钮） |
| --- | --- | --- |
| 文件夹里没题（范围本身为空） | “没找到这道题，换个词试试” + “这一科里没有符合当前搜索与筛选的题。” + 清除全部筛选（错：文件夹空也被当成搜不到） | **“这个文件夹还是空的”** / “这里还没有整理进来的题。去收集中心拍一道题，或去整理工作台把待整理的题归到这个文件夹。” / “返回目录” |
| 学科里没题 | 同上（搜索无结果文案） | “这科里还没有错题” / 去收集/去整理的引导 / “返回目录” |
| 跨学科全空 | 同上 | “错题本里还没有题” / “去收集中心拍第一道题吧。” / “返回书架” |
| 范围有题、但无搜索无筛选还为空（只剩“全部已解决被默认隐藏”一种可能） | 同上 | “这里的题错因都已解决” / “错因全部解决的题默认不显示，在「筛选」里把错因状态选成「已解决」就能看到它们。” / “看看已解决的题”（点后切到已解决筛选） |
| 搜索/筛选确实无结果 | “没找到这道题，换个词试试”（正确） | 不变 |
| 已归档视图为空 | “这一本里还没有归档的题”（正确） | 不变 |

判断依据：`_scopeQuestionCount()`（范围里已整理、未归档的题数，不含搜索/筛选/已掌握隐藏的影响）为 0 才算范围本身为空；否则按有无搜索/筛选分流。去收集/去整理目前只做文案引导、未接跳转——`WrongbookPage` 只有 `onOpenHome` / `onOpenDetail` / `onGoReview` 回调，接收集中心/整理工作台要改共享 `lib/app.dart`，不在本项范围。

新增测试（`test/wrongbook_page_test.dart`，“B8-9 空状态文案”组，5 个）：文件夹为空文案 + 引导 + “返回目录”往返；搜索无结果仍显示搜索文案且不出现文件夹文案；全已解决场景（“看看已解决的题”点出已掌握卡片）；定稿 A 空状态；定稿 A 列表渲染（3 张大卡、序号圆盘、分页、无 ListView）。

## 验证结果（定稿 A 代码）

- `flutter analyze`（全项目）：0 问题。
- 错题本文件：`flutter test --concurrency=1 test/wrongbook_page_test.dart` → **86/86 通过**（基线 81 + 新增 5），定稿后又复跑一次，同样 86/86。
- 全量串行：`flutter test --concurrency=1` → **848 通过、1 失败**，共 849。唯一失败是 `test/detail_page_test.dart` 的 SR2-3（“事务失败时旧切片字节完好、框与题不动”），断言在 `detail_page_test.dart:869`：失败后 `.tmp-*.png` 临时切片未清干净——详情页重新框选的事务清理问题，属于 B8-7 详情页范围，与本项的错题本列表无关；本项文件在全量中全部通过。
- Linux Release 构建：通过（`flutter build linux --release`，定稿 A 代码）。
- 演示库：已按父级要求用标准 v1 备份 `~/workspace/demo-db-backup/quiz-master2.db` 恢复 live 库并核对——md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，`user_version=1`，9 道题、3 学科。截图用的 v2 转换库是单独副本（`make-v2-shot-db.py` 生成），不影响标准库。
- 全量日志：`~/workspace/demo-db-backup/b8-9-full-final2.log`；错题本日志：`~/workspace/demo-db-backup/b8-9-wrongbook-final.log`。

## 过程中遇到的问题（已处理，记在这里供批末参考）

1. **`/tmp` 满了（512M tmpfs，96%）**：5 个并行 flutter 进程的 `flutter_tools.*` 临时目录占了 ~484M，第一次全量在编译期报 `No space left on device` 而崩。未删他人文件；改用 `TMPDIR=$HOME/workspace/.tmp-flutter` 跑测试与构建，之后全量正常。建议批末各 worker 退出时清自己的 `/tmp/flutter_tools.*`。
2. **全量中途被 SIGTERM 杀掉一次**：第一次全量（定稿前三方向代码）在 6:28、833 通过 / 2 失败时被外部 SIGTERM 终止，来源不明（不是我杀的）；重跑后正常完成。期间唯一失败除 SR2-3 外，另有 `b5_p2_collect_test.dart` 一项在日志落盘前被杀，未留详情——重跑的最终全量里它通过了，属当时环境抖动。
3. **页尾下拉菜单触发框架断言**：定稿前发现——分页器贴视口底边时点“每页 N 道”，框架按选中项对齐按钮中心会把菜单底推出视口，debug 下触发 `dropdown.dart:438` 的 `menuLimits` 断言（release 下菜单底被裁 ~5px）。根因是去蓝框后分页器离底边太近（旧蓝框的底边内边距正好挡住了这个问题）。已用 24px 页尾留白修在产品侧（列表页与归档视图都加了），不是只改测试。
4. **环境丢包（VM 换机后遗留）**：`clang` 与 `libgtk-3-dev` 等 -dev 头文件不在了，导致 `flutter test`（pdfium 原生 hook 需 clang）与 `flutter build linux --release`（CMake 需 gtk+-3.0 头文件）失败。已恢复：`clang` 用 apt 装回（18.1.3）；GTK 等约 40 个 -dev 包因 `libzstd-dev` 依赖 `libzstd1 (= 1.5.5+dfsg2-2build1.1)`、而镜像 pin 了 `1.5.5+dfsg2-2build1.1+hatch1` 装不上，改用 `apt-get download` + 解压、只把头文件 / `.pc` / 链接符号拷进 `/usr`（不动已装运行库与 dpkg 版本 pin）。`pkg-config --cflags/--libs gtk+-3.0` 已通，构建通过。真正的修法（解 libzstd pin 或重装 -dev 包）留给环境侧决定；.deb 暂存在 `~/workspace/.tmp-flutter/gtkfix/`（~10M），可删可留。
5. **并行 worker 的树是活的**：定稿前 `detail_page_test.dart` 一度编不过（`DetailStyle` 测试已用新 API、lib 未定义），是 B8-7 详情页正在改；几分钟后它自己合上，之后全量与 analyze 全过。本项验证均在树稳定后重跑。

## 遗留

- SR2-3（详情页重新框选事务失败后临时切片清理）未修——B8-7 范围，本项只记录。
- `DesignTokens.cardsScrollHeight` / `cardsScrollPadding` 两个 token 现已无人用（固定高度内部滚动容器已删），是否删留给后续清理。
- 10 张大卡片/页时分页器在三屏之下，要滚动才看到——改前内部滚动容器是把分页钉在视口内的代价换来的；定稿 A 接受这个取舍（紧凑列表是密集替代方案）。
- B/C 方向截图留档在 `docs/ui-replication/shots/b8-list/after-B-*.png`、`after-C-*.png`；代码里已无 B/C 分支。
- 全量总数 849（基线 Batch 7 为 879）：差值来自第八批其他项对测试的增删，不在本项。
