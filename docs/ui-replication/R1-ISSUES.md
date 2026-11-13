# R1 未解决问题清单（初版）

> R1（Token + Theme）收尾时的未解决问题。R1 只做 token / theme 层，
> 以下问题一律不在 R1 修；标了归属的进后续阶段，标了“待裁决”的等负责人定夺。
> 本清单每次阶段收尾时更新，不要删旧项（注明状态即可）。

## 1. 待 Win11 真机复核（R1 在 Linux 上无法验证）

| # | 问题 | 说明 |
|---|---|---|
| 1-1 | Win11 字体效果待真机复核 | Segoe UI / Microsoft YaHei / Georgia 在 Win11 真机上的实际显示效果。R1 只声明了字体栈（D2，不打包字体）；Linux 上字体以系统回退为准，截图里的字体不是 Win11 效果，不宣称已验证 |
| 1-2 | Win11 窗口尺寸 / DPI 待真机复核 | HTML 原型按 1280×800 及以上设计；真实窗口尺寸由用户设定。R1 未改窗口尺寸逻辑，DPI 缩放下的 token / 布局表现须真机看 |
| 1-3 | Windows Release 构建待 Win11 验证 | Linux Release 构建成功（`flutter build linux --release`，R1 复核通过），Xvfb 1280×720 下首页正常渲染并截图（`docs/ui-replication/shots/r1-tokens/home-1280x720.png`，深色默认态）。Linux 构建 + Xvfb 点测不能替代 Windows 11 最终验收 |
| 1-4 | SQLite 原生资源待 Win11 真机复核 | 与 R0 相同，R1 未动数据库层 |

## 2. Windows 构建前置事项（R1 不处理）

| # | 问题 | 说明 |
|---|---|---|
| 2-1 | `app_icon.ico` 缺失 | 基线仓库中 `windows/runner/resources/` 为空，`Runner.rc:55` 引用了 `resources\app_icon.ico`，Windows 上构建会因资源缺失而失败。**已解决（2026-11-13，负责人全程自主执行授权后补入）**：使用本地 F2 已核实的原始图标 `~/workspace/quiz-master2-F2/windows/runner/resources/app_icon.ico`（33,772 字节，SHA-256 `c098d3fc85cacff98b8e69811b48e9f0d852fcee278132d794411d978869cbf8`），已补入 `windows/runner/resources/app_icon.ico`，补入后 SHA-256 复核一致；来源与核对记录见 R1-BASELINE.md 附录。未 commit、未 push；Windows 构建仍须在 Win11 真机上验证 |

## 3. R0 §6-B 业务问题冻结清单（R1 一律不动，等裁决）

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| 3-1 | 学习报告 `pendingCount` 不按时间范围过滤 | `report_page.dart:113–130`（`solvedCount` 与复查通过率按范围过滤，`pendingCount` 不按） | 冻结，R1 不动 |
| 3-2 | 学科管理新增学科不同步到首页 / 导航速览 | `Subject.all` 在 `models.dart` 写死三科，首页与导航速览遍历的是 `Subject.all` 而非数据库 `subjects` 表 | 冻结，R1 不动。注意：R1 改了 `Subject` 三科的色值（#2E7CF6/#00A884/#EF4444），但未改“写死三科”的结构 |
| 3-3 | 设置“启动页”设置项未被消费 | `app.dart:39` 路由初始值写死 `'/home'` | 冻结，R1 不动 |
| 3-4 | 通知 / 备份不完整 | 通知提醒只有开关 + 时间字段，无任何通知调度实现；备份导出只含 8 张表，不含 `collect_tasks` / `review_state` / `review_history` / `recent_tasks`；缓存清理为启发式删除；数据库位置切换靠 `db_location.txt` 标记文件、不迁移旧库 | 冻结，R1 不动 |

## 4. R1 已知遗留（token 层）

| # | 问题 | 说明 |
|---|---|---|
| 4-1 | 旧库 subjects 颜色仍是旧值 | R1 改了 `Subject` 三科的静态色值，种子只在建库时写入；已存在的数据库里 `subjects.color` 仍是旧值（数学 #2F7CF6 / 英语 #1F9D66 / 政治 #E0524D）。是否迁移旧库数据属业务决策，R1 不动数据库 |
| 4-2 | `AppTheme` 兼容常量是字面值副本 | Dart const 表达式不能跨类取 const 对象的实例字段，`AppTheme` 旧公共常量写的是与 `DesignTokens` 逐项对应的字面值，两处需同步。R2 页面接入 token 后可删除这批常量；`test/theme_smoke_test.dart` 有对照断言兜底 |
| 4-3 | `widgets.dart` 演示简图仍有旧色值 | `_SliceFigurePainter` 里写死的 `#2F7CF6`（1 位差）与 `#5B6B84`（旧 muted）未动；待 R2 真实图片切片替换时一并清理。`subjectLabelColor` 的深色 `-ink` 档与 HTML 一致，无需改 |
| 4-4 | 阴影 token 未接入页面 | `AppPalette.shadow` 已提供，但页面仍是 `elevation: 0`、外观无阴影变化；R2 逐页接入 |
| 4-5 | 缩放未接入外壳布局 | `ScaledTokens` 的导航宽（216/64）与内容区 padding（26/30）已有 token，但 `app.dart` 外壳布局 R1 未改；由 R2 外壳重构时接入。页面内硬编码字号仍靠 `MediaQuery TextScaler` 缩放（R1 前即如此），R2 逐页接入 token 字号后仍由该 TextScaler 统一缩放一次，不得另乘 |
| 4-6 | `bodySmall` / `caption` 字号待 R2 核对 | 13.5px / 12.5px 是 HTML 高频值，R2 逐页核对后收紧（见 R1-TOKENS.md §3） |

## 5. HTML 死代码不实现（R1 已执行，R2 继续遵守）

- 不复活旧翻卡模型（`REV` / `syncRevStatus` / `viewStub` 旧口径，含“下次复习时间”字段），只按 REV2 / cause 模型。
- 不照搬静态演示数字（首页三科“待整理 3”为写死演示数，真实应用按待整理队列实时算；R1 未动该口径）。
- 不实现学科管理死按钮：隐藏学科 / 换图标 / 排序（原型 `bind()` 有处理器但渲染层无按钮，按已定决策学科管理只有增 / 删 / 改名）。
- 不实现错题本学科筛选下拉（原型 `bind()` 有死处理器，筛选面板无此下拉）。
- 不把学科管理文件夹残留代码（`FOLD_*` / `.set-fold-*`）实现成第五组。
- 设计说明文字不抄入应用（只保留真实业务说明；R1 未动任何文案）。

## 6. R0 已知未实现项（与 R1 无关，原文照录，属后续模块范围）

YOLO 真模型缺失（占位服务，`assets/models/` 只有 README）；图片切片为示意绘制；系统拖拽导入未接；导入进度 Timer 模拟；加密 PDF 启发式判断；分页翻页未验证（演示数据每科最多 3 道）；修框全流程未用真实文件验证；关于页作者写死“作者：Meng”未核实。

## 7. 后续集成 / Win11 待验证（负责人补充背景，2026-11-13，R1–R11 不擅自改）

项目有两个 YOLO 模型，与定稿的两层 YOLO 设计一致：
- 第 1 层：检测单题（整题框）。
- 第 2 层：检测题内结构，只含 `stem` / `option` / `figure` 三类，绝不产生独立题目。
- **两个独立的 `.onnx` 模型文件**：一个检测单题（第 1 层整题框），一个检测题内结构（第 2 层 stem / option / figure）。
- **同名问题**：两个文件名字一样（都是 `best.onnx` 之类的同名文件），接入时**不能放在同一个目录**，必须用文件夹区分（例如外层/内层各一个子目录），或在接入时明确重命名规则——具体等负责人提供文件后再定，**不要自己猜文件名、不要自己改名**。

现状（仅记录，不动）：
- 当前 Flutter 代码里 YOLO 还是占位实现（`lib/services/yolo_onnx_service.dart` + `lib/services/import_service.dart`）。
- onnxruntime Dart 包版本未锁定（D-07，待 Win11 实测后定）。
- 真实模型文件尚未接入。

待办（记入 R11 验收报告的 Windows 11 待验证事项）：
- **接入两个真实 YOLO 模型并在 Win11 上实测**。等负责人提供模型文件后再处理；不要自行编造模型文件名或路径。
- UI 重构范围外：R1–R11 期间不擅自改 YOLO 相关业务代码。

## 8. R1 验证记录

- `flutter analyze`：**No issues found!**
- `flutter test test/theme_smoke_test.dart`：**8/8 通过**（浅 / 深 token 对照 HTML、深色主按钮、缩放三档、学科色与封面色分离、字体 token）。
- `flutter build linux --release`：成功（`✓ Built build/linux/x64/release/bundle/quiz_master2`）。
- Xvfb 1280×720 真实窗口运行：首页正常渲染，截图 `docs/ui-replication/shots/r1-tokens/home-1280x720.png`（Xvfb 下无系统主题设置，应用默认深色；Atk/GSettings 两条无害警告，与 R0 基线相同）。
- 未 commit、未 push；`pubspec.lock` 未动；数据库 / Repository 未动；九个页面文件未动。
