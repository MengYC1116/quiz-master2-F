# B8-345 修框编辑器交互（第 3、4、5 项）

工人：B8-345。工作树 `~/workspace/quiz-master2-UI`，分支 `ui-replication`。
未 commit、未推代码；未动其他工人的文件（`organize_page.dart`、详情页、错题本列表均未碰）。

改动文件（3 个）：

| 文件 | 改动 |
|---|---|
| `lib/modules/collect/box_editor.dart`（B8-2 拆分出的未入库文件） | 第 3、4、5 项实现 |
| `lib/services/yolo_onnx_service.dart` | 只改 `clampToPage` 的文档注释（见第 5 项） |
| `test/b8_345_box_interaction_test.dart`（新增） | 13 个真实交互用例 |

另：`box_editor.dart` 里顺手修了 2 处旧代码的无大括号 `if`（画框层，`curly_braces_in_flow_control_structures`），零行为变化，只为让 `flutter analyze` 干净到 0。

---

## 第 3 项：框四角拖动不灵敏

### 病根（三个，不是只有一个）

1. **柄伸出框外的半边根本点不到**。旧柄嵌在框的 `GestureDetector` 里，以角点为中心外扩 6.5px；但 `RenderBox` 命中测试先看框体 bounds，框外那半边在命中路径里到不了柄——柄只有框内一半能点。
2. **柄与拖框进同一个手势竞技场**。柄是框 `GestureDetector` 的子孙，两套 pan 识别器 + 画布滚动的拖动识别器同场竞争，输赢看时序，所以“有时能调有时不能”。
3. **拖动回调闭包里的 box 是上次 build 的快照**。连续两次 move 事件可能在同一帧里共用它，增量会被丢一次（坐标换算本身没错，`delta/pw` 的单位是对的，丢的是增量）。

### 怎么修的

- **柄移到画布级浮层**（`_resizeHandleOverlay`）：与框体平级、画在最上，不再嵌在框的 `GestureDetector` 里。浮层是 `Positioned.fill` 盖满整个滚动内容（不只是 `pw×ph` 的画布），框贴页边时柄伸进边距的部分也能命中；浮层空白处不拦截（`Stack` 无子节点命中即放行），不影响点框、画框、平移。
- **命中区 24×24，视觉仍 13×13 居中**（`_handleHitSize = 24.0`，key 保持 `editor-resize-<角>-<id>` 不变）。`GestureDetector` 用 `HitTestBehavior.opaque`。
- **拖动按 id 读最新态**：`_moveBox` / `_resizeBox` 改传 `boxId`，每次经 `_boxById` 读当前内存态再算增量；同时 `_pointHitsInteractive` 的锁滚动余量从 `8*scale` 改为 `max(8*scale, 12)`（柄半边 12px），点柄时滚动不再抢拖动。
- `_resizeBox` 增加翻转归一：拖过对边时 `w/h` 变负改为翻转（`x += w; w = -w`），不用最小尺寸兜底。

## 第 4 项：滚轮只缩放、不滚动，且以指针为准

### 病根

旧代码在画布**外层** `Listener.onPointerSignal` 里改 `_scale`，但 `Listener` 拦不住滚轮事件：Flutter 的滚轮事件由 `PointerSignalResolver` 裁决，**先注册的处理者独占**，而命中测试按从深到浅分发——内层的 `Scrollable` 比外层 `Listener` 先收到，先注册了滚动，缩放和滚动就同时发生。

### 怎么修的

- 滚轮处理搬到**滚动视图内容里**的 `Listener`（`_onWheel`，在两个 `SingleChildScrollView` 的 `Listener` 之下、比它们都深）：指针在图内且 `dy != 0` 时向 `GestureBinding.instance.pointerSignalResolver.register` 注册缩放回调，先注册即独占该事件，滚动视图收不到；指针在图外、或纯横向滚轮（`dy == 0`）时不注册，事件照常交给滚动视图滚动页面。回调里调 `event.respond(allowPlatformDefault: false)`（与 `Scrollable` 处理滚轮时同款）。
- **zoom-to-cursor**（`_zoomAtCursor`）：缩放前后指针下的页面点（`local/pw` 的比例坐标）保持在屏幕同一位置——用滚动偏移补偿：`targetS = 新画布偏移 + 比例坐标×新页宽 − 指针在视口中的位置`，钳制到滚动范围；新尺寸要等下一帧布局完，偏移在 `addPostFrameCallback` 里 `jumpTo`。画布两个滚动视图各挂一个 `ScrollController`（`_hScrollController` / `_vScrollController`，`dispose` 里释放）供缩放时读/写偏移。
- 缩放步进不变（每格 `dy/1200`），范围仍 0.5~3.0。操作说明文案改为“滚轮在图上以指针为中心缩放（不滚动）、在图外滚动”。

## 第 5 项：框大小不设限制

### 病根

最小尺寸在 `YoloOnnxService.clampToPage` 的默认分支里：`w/h < 0.08` 时补回 0.08；修框编辑器的 `_replaceBox`（拖动/缩放出口）和 `_onDrawEnd`（画框出口）都走默认分支；另画框中 `_onDrawUpdate` 还有 `0.01` 下限。

### 怎么修的

- `_replaceBox`、`_onDrawEnd` 改传 `clampToPage(..., minSize: false)`（交集语义：框与页面求交，溢出侧扣宽/高）；`_onDrawUpdate` 的宽/高下限 `0.01 → 0.0`。
- 框仍钳制在页内，不出页：`minSize: false` 的交集语义 + `_resizeBox` 的翻转归一保证 `w/h ≥ 0` 且 `x+w ≤ 1`、`y+h ≤ 1`。
- `_onDrawEnd` 里 `< 0.02` 的丢弃保留——那是“点一下 vs 拖出框”的手势区分，不是尺寸限制。
- `clampToPage` 本体与默认 `minSize: true` 分支未动（S8A3 回归测试锁定它）；只修正了它的文档注释里过时的说法（“用户手画/拖动/缩放沿用 0.08 下限”→ B8-345 起编辑器各入口都传 `minSize: false`；默认分支现无调用方，保留只为 S8A3 语义）。检测管线本来就走 `minSize: false`，不受影响。

---

## 真实交互用例（`test/b8_345_box_interaction_test.dart`，13 个）

按 `flutter-testing` skill 的分级写：全是 widget 测试，用**真实指针事件**驱动编辑器（鼠标主按键拖动、`PointerScrollEvent` 滚轮），再用确认返回的 `BoxEditorResult` / 屏幕矩形 / 缩放百分比断言，不只验逻辑。

脚手架：沿用 B5 收集测试的宿主模式（点“打开修框”调 `showBoxEditorDialog`，`_EmptyYolo` 桩不跑真模型）；页图是内嵌 1×1 PNG（base64），**同步写临时文件，测试里无异步文件 IO**；DB 一律不用；每测一框 `x=0.2, y=0.2, w=0.4, h=0.3`。

| 组 | 用例 | 真实交互 | 断言（失败即行为坏了） |
|---|---|---|---|
| (5) 单测 | `clampToPage(minSize: false)` 不补最小尺寸 | 直接调钳制 | 0.03×0.02 原样保留；对照默认分支仍补 0.08 |
| (3) | SE 角向外放大、向内拖回原位 | 鼠标拖 SE 柄 +60/+45，再拖回 | 右/下边长、左/上不动；拖回后矩形回原位（±20px，手势 slop 余量）；确认后分数坐标回 0.2/0.2/0.4/0.3（±0.06） |
| (3) | NW / NE / SW 角向外放大 | 各角鼠标拖柄 | 各角只动对应的两边，另两边不动（±2px）；确认后分数坐标向对应方向变大 |
| (3) | 柄框外半边能抓住 | 四角各从角外 10px（视觉柄 6.5px 外、24px 命中区内）起拖 | 框尺寸变化 > 10px（旧 13px 柄够不到，必失败） |
| (3) | 对照：角外 16px 抓不到柄 | SE 角外 16px 起拖 | 只平移图片，确认后框分数坐标纹丝不动（±0.01） |
| (4) | 图上滚轮只缩放不滚动（zoom-to-cursor） | 放大到 250% 后，在框中心滚一格到 260% | 框中心屏幕位置不动（±3px，旧行为会被滚走几十像素）；滚动偏移只为补偿而动（> 1px） |
| (4) | 滚轮方向 | 图中心上滚、下滚 | 100% → 110% → 100% |
| (4) | 图外滚轮不缩放、页面滚动 | 放大到 200% 后在画布左缘外 10px 处下滚 | 仍 200%，竖向滚动偏移变大 |
| (5) | 角柄能把框缩到 0.08 以下 | SE 柄向内拖 0.37pw/0.28pw | 确认后 `w < 0.08` 且 `h < 0.08`，均 > 0 |
| (5) | 角柄能把框放大到贴页边 | SE 柄向外拖 300px | `x+w ≤ 1`、`y+h ≤ 1`，`w/h ≈ 0.8`（±0.03） |
| (5) | 右键手画小框也不补最小尺寸 | 删框后右键拖约 0.05×0.05 的框 | 确认后 `0.02 < w/h < 0.08` |

破坏校验（skill 要求的“故意破坏应失败”）：临时把 `_replaceBox` 改回默认 `clampToPage(updated)`，缩框用例如期失败；已恢复。

注意：选中后框标签变成“题级框 1 · 已选中”，测试里的框查找用 `textContaining`；拖动断言留了手势 slop 余量（首段位移会被吃掉一部分，见既有测试同款注释）。

---

## 验证结果

- `flutter analyze`：**0 问题**（修前全量 2 个 info，均为旧画框层无大括号 `if`，已顺手修掉）。
- 目标测试：`flutter test --concurrency=1 test/b8_345_box_interaction_test.dart`，**13/13 通过，两次连续**；破坏校验 1 次（见上）。
- 相邻回归：`test/collect_page_test.dart` + `test/b5_p2_collect_test.dart`，**69/69 通过**（含既有 B2-6b 滚轮用例“图上缩放、图外滚动”）。
- 全量：`flutter test --concurrency=1`，**872 通过、2 失败**（日志 `~/workspace/demo-db-backup/b8-345-full.log`；`TMPDIR=$HOME/workspace/.tmp-flutter`，`/tmp` 当时 29% 未满也走了该路径；`LD_LIBRARY_PATH` 指到 `onnxruntime-1.4.1/linux`）。
  - 2 失败都在 `test/detail_page_test.dart`：
    - **P1-2“大图仍限高 460”（期望 460、实际 2.0）**：全量进行中 B8-7 工人正在改详情页测试文件（`test/detail_page_test.dart` 在全量运行期间 09:00:43 UTC 被改过），属中途编辑伪影；**单独重跑详情页文件后该用例通过**。
    - **SR2-3“事务失败时旧切片字节完好”（残留 `.tmp-*.png`）**：单独重跑仍失败，但与本次改动无关——该用例全程无选中、无滚轮、无拖动、无画框，我的五处行为改动都走不到；且 **B8-7/9 审计（`docs/ui-replication/B8-7-9-AUDIT.md` §四-9，08:42 写就）已记录它是已知失败**（“1 失败为详情页 SR2-3 事务清理问题”）。留给详情页工人/协调人处理，本批未碰 `question_detail_page.dart`。
  - 全量后稳态为 873/874，仅 SR2-3 失败。
- Linux Release 构建：`flutter build linux --release`，**通过**（`✓ Built build/linux/x64/release/bundle/quiz_master2`，日志 `~/workspace/demo-db-backup/b8-345-build.log`）。clang 18.1.3、ninja 均在，无需跑工具链恢复脚本。
- 演示库：全量前后 live 库 `~/.local/share/quiz-master2/quiz-master2.db` 的 md5 均为 `8f7f9c64405dc6e484ac2bf8e5e1a807`（v1，9 道题 3 学科）；全量跑完已用 `~/workspace/demo-db-backup/quiz-master2.db`（v1 备份）恢复并核对一致。绝无拿 live 文件当备份。

## 遗留与注意

1. **zoom-to-cursor 的近似边界**：内容比视口小、无滚动余量的方向补偿不到（画布在内容里居中），该方向只能近似。测试特意先放大到 250%（横、竖都有滚动余量）再验指针不动；日常从 100% 起滚时，居中方向会有几个像素的漂移，是居中布局本身的限制，不是滚轮消费问题。
2. **`clampToPage` 默认 `minSize: true` 分支现无调用方**，保留只为 S8A3 回归测试锁定的贴边语义；若后续有人想删，先改那组回归测试。
3. **SR2-3 仍失败**（见验证结果），是详情页事务清理的已知问题，不在本批三项内。
4. Win11 真机仍需复核（测试复现不了真机鼠标/DPI/事件透传）：角柄 24px 命中、滚轮 zoom-to-cursor 在真机上的手感；以及框贴页边时柄伸进边距那半边的可点性。
