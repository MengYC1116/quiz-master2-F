# B8-8 错题本书架封面改固定尺寸 — 修复报告

- 日期：2026-11-15
- 分支：`ui-replication`（未 commit、未 push；不推代码）
- 范围：只改书架封面尺寸与排列布局——`lib/modules/wrongbook/wrongbook_shelf.dart`（书架布局 + `_buildBook`）、`lib/theme/design_tokens.dart`（新增 `bookWidth` token）、`test/wrongbook_page_test.dart`（新增 1 项回归测试）。书架数据加载与刷新逻辑未动（B8-1 的工作原样保留，见 §5）。
- 对照：Meng Win11 真机验收截图 `~/workspace/user/media_library/image/image-95.png`（只剩数学 1 本时封面被拉满全宽）；HTML 预览 `quiz-master2-jiao-hu-yuan-xing.html` 的 `.nb-shelf` / `.nb-book`。

## 1. 问题根因

改前书架布局（`_buildShelf` 的 `LayoutBuilder`）：

- 宽窗口（`constraints.maxWidth > 760`）：`Row` + 每本 `Expanded`——3 本各占 1/3 宽，窗口越宽封面越宽；只剩 1 本时 `Expanded` 把它拉满全宽（image-95：数学一本横贯整个内容区）。
- 窄窗口：`Column`——每本占满整宽，同样随窗口缩放。

封面高已是固定值（`bookMinHeight 376 × scale`），宽没有固定值，是唯一随窗口变的量。

## 2. 定死的尺寸值及依据

| 值 | 数值 | 依据 |
| --- | --- | --- |
| 封面宽 | **300px**（`DesignTokens.bookWidth = 300`，再 × 字号缩放因子 `qmScaleOf`） | HTML 预览本身没有固定宽，宽由 3 列网格撑出：预览 `.wrap` max-width 1260 − padding 22×2 − 导航 216 − `.main` padding 30×2 = 书架区 940px；`(940 − 22×2) / 3 ≈ 298.7`，取整 300 |
| 封面高 | **376px**（沿用 `bookMinHeight`，× 同一因子） | HTML `.nb-book` min-height 376px；内容按同一因子缩放后恒小于该高，固定高与最小高视觉等价（原注释已说明，本次未改） |
| 长宽比 | **300:376 ≈ 0.80** | 与 HTML 预览最大宽度下的网格比例一致；也与 1280×720 窗口下改前实测（书宽约 320）接近，视觉落差小 |
| 间距 | gap 22px（沿用 `shelfGridGap`），行距同值 | HTML `.nb-shelf` gap 22px，未改 |

说明：

- “固定”指不随**窗口**变；宽高仍 × `qmScaleOf`（标准 1.00 / 大 1.15 / 特大 1.30 的字号缩放因子），与全项目 D4 约定一致——字号档变化时封面跟着等比放大，不是窗口缩放。`×1.30` 时书为 390×489，回归测试覆盖三档无溢出（既有测试）。
- 窄到放不下一本时才把宽压到可用宽（`bookW = min(300 × scale, constraints.maxWidth)`）：纯安全阀，桌面正常窗口（内容区 ≥ 324px 即窗口 ≥ ~600px）下不触发，避免极窄窗口溢出。
- 760px 宽窄分界（旧 `Row`/`Column` 切换）已删除：`Wrap` 在任何宽度下都是同一行为——窗口只改变每行本数。

## 3. 改动

| 文件 | 改动 |
| --- | --- |
| `lib/theme/design_tokens.dart` | 新增 `bookWidth = 300` 及推导注释（§2 的 940px 算式写在 token 注释里） |
| `lib/modules/wrongbook/wrongbook_shelf.dart` | `_buildShelf`：`LayoutBuilder` 内的 `Row`+`Expanded` / `Column` 两路改为 `Wrap(spacing: gap, runSpacing: gap)`，每本传固定宽；`_buildBook(Subject s, {required double width})`：`AnimatedContainer` 加 `width: width`，高不动；其余（悬停上移 4px/阴影、书脊、折角、虚线内框、书页边、计数牌、封面内「开始复习」）一字未动 |
| `test/wrongbook_page_test.dart` | 书架组新增 1 项（见 §4） |
| `docs/ui-replication/shots/b8-shelf/run-shots-b8-shelf.sh`（新增，未推） | 截图脚本，见 §4 |

未动：书架分页（每页最多 6 本）、封面三数（题数/要复习/待复查）、「开始复习」按钮、封面样式与颜色体系、书脊/折角/虚线框等视觉元素、数据加载与刷新逻辑、数据库 Schema、依赖、`pubspec.lock`。

## 4. 验证

### flutter analyze / 测试

- `flutter analyze`（全项目）：**0 问题**（改前基线也是 0；收尾复核时有一次跑出 1 个问题，立即重跑即恢复 0——应为并行工人改文件途中的瞬时状态，本次 3 个文件单独分析始终 0 问题）。
- 针对性测试 `flutter test --concurrency=1 test/wrongbook_page_test.dart`：**81/81 通过**（含新增 1 项；基线时该文件已有 80 项——B8-1 等并行工作新加的测试在内）。
- 新增回归测试「B8-8 封面固定 300×376：窗口变窄只改每行本数，不改封面尺寸」：1280 宽三本一行、每本 `Size(300, 376)`；窗口缩到 900 后政治换到第二行、三本仍是 `Size(300, 376)`；只剩数学一本时仍是 `Size(300, 376)`（image-95 回归：不再拉满全宽）。
- 全量测试：**本次未跑通（见 §6 第 1 条）**。两次尝试均被共享机并行争用打断，未得到完整结果；最接近的完整数据点是 B8-2 工人在另一树状态下跑出的 +841 −4（失败在收集/服务/B8-1 探针文件，均不在错题本）。本次的有效验证是：针对性错题本测试 81/81（后 B8-9 工人同文件跑出 86/86，全过，含本项新增测试）+ `flutter analyze` 0 + Linux Release 构建通过 + 双窗口截图实测。

### 截图（`docs/ui-replication/shots/b8-shelf/`，浅色、标准字号，隔离库 + 隔离 HOME，live 库未动）

| 文件 | 内容 | 实测 |
| --- | --- | --- |
| `shelf-1000.png` | 窗口 1000×720 | 每行 2 本（数学/英语），政治换到第二行；三本尺寸相同 |
| `shelf-1600.png` | 窗口 1600×720 | 每行 3 本；与 1000px 图同尺寸 |
| `shelf-1000-single.png` | 窗口 1000×720、只留数学 1 本（复现 image-95 场景） | 1 本 300×376 居左，不拉满全宽；分页文案「共 1 本」 |
| `run-shots-b8-shelf.sh` | 截图脚本 | 见下 |

像素实测（数学书，纯色区取样）：三张图书顶 y 均为 158，高 376（y 158–533）；纯色区宽 289 = 300 − 11（书脊宽，不计入纯色区），与 300 宽一致。计数：数学 2/2/0、英语 2/0/1、政治 1/0/0（v2 演示库 9 道题口径，见 §6）。

## 5. 与并行 B8-1 工作的交接

- 开工时 `wrongbook_shelf.dart` 还是旧版 `_buildShelf`；基线测试进行中 B8-1 工人改了同一文件（书架空状态：学科删空时 `QmEmptyState` + `widget.onGoSubjects` 去学科管理按钮）。本次只替换了其中的 `LayoutBuilder` 布局块，B8-1 的空状态分支原样保留，未动其数据加载/刷新逻辑。
- `design_tokens.dart` 与 `test/wrongbook_page_test.dart` 也有其他工人的并行改动；本次只加了 `bookWidth` token 与 1 项测试，未碰他人行。
- 截图用的二进制是共享树的 Release 构建（含并行各组的未提交改动），书架页渲染与本次改动一致；空状态分支只在 0 学科时出现，3 学科截图不受影响。

## 6. 过程记录与遗留

1. **全量测试两次尝试均未跑通（共享机并行争用，非代码问题）**：
   - 基线全量（改动前）：与另两个工人的全量/单文件测试同时跑，VM 内存耗尽，`flutter test` 进程被 OOM kill（4 次），结果 +749 −35，大量 `did not complete` / `loading …` 失败——失败全是加载中断，不是断言失败。
   - 改后全量（第二次）：等 B8-2 全量跑完（+841 −4）才启动，仍撞上三组并行测试；第一次启动 46 秒即以 exit 255 夭折（+41 −1，`detail_page_test` SR2-3 一处失败后日志截断——该失败与本次改动无关，见下）；第二次启动后卡在 +18（`detail_page_test` 加载中）19 分钟零进展：`flutter_tools` 进程 CPU 0.3%，因 `.dart_tool/hooks_runner` 的 sqlite3/pdfium 锁被另一工人进程 PID 28619（跑 `collect_page_test` 等 3 文件）持有 26 分钟以上、且其自身也空闲（0.3% CPU），队列未疏通。已按确切 PID 杀掉本次运行（bash 30872 及其子进程），未动他人进程。结论：不要多组同时跑全量；全量须由协调员排队单跑。SR2-3 失败（详情页重框事务）与本次改动无交集（本次只动书架布局 + token + 1 项错题本测试，未碰详情页/服务层/数据层），且 B8-2 的全量里详情页未失败，更像并行争用下的偶发失败，留待门禁单跑时复核。
2. **live 演示库在工作期间被其他工人的应用启动改写过多次，最终已由协调员恢复为 v1**：开工时 live 库是 v1（md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，9 道题）——本任务开始前已备份到 `~/workspace/demo-db-backup/quiz-master2.db.b8-8-start`（md5 一致）。期间 live 库被某次应用启动按 §6 删 v1 重建为空 v2（0 道题，md5 `e0d47224…`），之后又被换成 v2 演示库（9 道题，md5 `522799a8…` / `9b44ff61…` / 协调员口径 `78b8661e`）。**都不是本次脚本所为**：本次截图全程用隔离 HOME（`/tmp/qm2-b8-8-home`）+ 隔离库，从未写 live 路径；每次跑完核对 live md5 只做只读记录。收尾时 live 库已是 v1（协调员约 15:49 恢复；本次核对：md5 `8f7f9c64405dc6e484ac2bf8e5e1a807`，`user_version = 1`，3 学科 9 道题，无 -wal/-shm 残留），与工作区备份 `~/workspace/demo-db-backup/quiz-master2.db` 一致——本次未再覆盖，符合“批末统一恢复核对”的安排。
3. **v1 库不能直接用来截图**：应用启动时按 §6（老 v1 库直接删除、不迁移）会删掉 v1 库文件重建空 v2 库（第一轮截图因此拍到空白页 + 0 道题）。本次造了隔离 v2 演示库 `/tmp/qm2-b8-8-v2demo.db`：在应用建出的空 v2 库上，从 v1 备份迁入 9 道题 + 7 条错因记录（`questions` / `cause_records` 两表结构两库一致，直插；其余表沿用 v2 种子），`PRAGMA user_version = 2`，启动不再删库。该文件在 `/tmp`，随 VM 重启可能丢失；如需复现截图，用备份 v1 库按同样方法重建。
4. **截图脚本的两个坑（已修，写在脚本注释里）**：(a) `xdotool search --name quiz_master2` 会先命中 10×10 的 `com.quizmaster2.quiz_master2` 占位窗，必须用 `^quiz_master2$` 精确匹配真正的应用窗（默认 1280×720）；(b) `windowactivate + windowsize + windowmove` 写在同一条 xdotool 里时 resize 不生效，必须分开调并复核 `WIDTH`，不对再调一次。
5. **第一轮截图脚本的 ROOT 路径 bug（已修）**：脚本在 `docs/ui-replication/shots/b8-shelf/`，上溯 3 级算错成 `docs/`，二进制路径不存在，拍到 3 张黑屏空图；已改为上溯 4 级 + 启动前校验 BIN 存在，错位目录 `docs/docs/` 已删。
6. **遗留（不在本次范围）**：窄窗口下第二行书会被纵向裁切（1000×720 时政治只露上半，需滚动）——这是书架页纵向空间不足的固有表现，不是本次改动引入的；未动。极窄窗口（内容区 < 300×scale）的安全阀压缩在 widget 测试里未覆盖（只覆盖了 900/1280 两档），因测试视口改到 < 640 宽会牵动整页其他元素，不属于本次回归范围。
