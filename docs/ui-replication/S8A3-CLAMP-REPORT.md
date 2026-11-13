# S8A3：clampToPage 贴边抛错——修服务层，加单元测试

## 1. 问题

`YoloOnnxService.clampToPage`（`lib/services/yolo_onnx_service.dart:32`）用
`box.w.clamp(0.08, 1.0 - x)` 钳制宽。框贴到右/下边时 `1.0 - x < 0.08`
（即 `x > 0.92`），`clamp` 的下限大于上限，Dart 抛 `ArgumentError`。
收集页修框编辑器里把框拖到右/下边缘就会触发（拖动经 `_moveBox` →
`clampToPage`，`collect_page.dart:1235`）。

`collect_page.dart` 原有绕过办法 `_clampBoxSafe`：先把 x/y 收到 0.90 以内再调
服务。服务本身还是会抛，任何其他调用方都可能踩到。

## 2. 根因

`num.clamp(lower, upper)` 要求 `lower <= upper`，否则抛错。旧实现把“最小尺寸
0.08”写成钳制下限，却没保证 `1.0 - x >= 0.08`；x 贴边时上限塌到 0.08 以下，
下限 > 上限。另有浮点坑：`1.0 - 0.92` 的实际值是 `0.07999…`，所以即使把
x 收到 0.92 也仍会抛（这正是 `_clampBoxSafe` 注释里写 0.90 而不是 0.92 的原因）。

## 3. 修法

### 3.1 服务层（`lib/services/yolo_onnx_service.dart`）

```dart
static QuestionBox clampToPage(QuestionBox box) {
  final x = box.x.clamp(0.0, 1.0);
  final y = box.y.clamp(0.0, 1.0);
  final maxW = 1.0 - x;
  final maxH = 1.0 - y;
  final w = box.w.clamp(0.0, maxW);
  final h = box.h.clamp(0.0, maxH);
  final w2 = (maxW >= 0.08 && w < 0.08) ? 0.08 : w;
  final h2 = (maxH >= 0.08 && h < 0.08) ? 0.08 : h;
  return QuestionBox(
      id: box.id, layer: box.layer, type: box.type, x: x, y: y, w: w2, h: h2);
}
```

结构上杜绝抛错：`x` 已钳制到 `0..1`，故 `maxW = 1.0 - x >= 0` 恒成立；
`w` 的钳制下限是 `0.0`，下限永不大于上限。`1.0 - 0.92 = 0.07999…`
不再是坑——此时 `maxW < 0.08`，直接取剩余空间，不经过 0.08 下限。

### 3.2 贴边语义的选择：允许宽/高小于 0.08，不收左上角

二选一，选了前者。理由：

- 编辑器里框的位置由用户拖动决定。把左上角收进来会让框从光标处跳走，
  是静默移位，比“贴边变窄”更意外。
- 用 0.92 做收进下限会重蹈 `0.07999…` 的浮点覆辙；要收就得收 0.90，
  等于凭空吃掉 2% 的页面宽度。
- 最小尺寸 0.08 只是“新框别太小”的意图，不是硬不变量；空间足够时仍把
  过小的宽/高补回 0.08（见 `w2`/`h2`），正常框行为完全不变。

边界值：`x == 1.0` 时剩余空间为 0，宽只能是 0（退化但合法的框，仍在
0..1 内，不抛错）。

### 3.3 `_clampBoxSafe` 的去留：删掉

服务修好后绕过办法已多余，直接删。`collect_page.dart` 的 7 处调用点
（初始化、翻页、拖动更新、新增框、待定框）全部改为直调
`YoloOnnxService.clampToPage`，全仓只剩一处钳制逻辑。删了无风险：
`_clampBoxSafe` 的唯一作用就是给旧服务垫 0.90 上限，且它还会改变行为
（x=0.95 的框会被先收到 0.90，修后则保持 0.95、只收窄宽）——删掉后
行为与“框留在用户拖到的位置”一致。`grep` 确认仓内无残留引用。

## 4. 单元测试

新建 `test/yolo_onnx_service_test.dart`，12 个用例（均断言不抛错且结果框
在 0..1 内，即 `x+w <= 1`、`y+h <= 1`）：

| 用例 | 输入 | 断言 |
| --- | --- | --- |
| 正常框 | (0.1, 0.1, 0.5, 0.5) | 原样保留 |
| 贴右边 | (0.95, 0.1, 0.2, 0.5) | x 不动 0.95，w 收到 0.05 |
| 贴下边 | (0.1, 0.95, 0.5, 0.2) | y 不动 0.95，h 收到 0.05 |
| 贴右下角 | (0.95, 0.96, 0.3, 0.3) | w 0.05、h 0.04 |
| x=1.0 / y=1.0 | (1.0, 1.0, 0.1, 0.1) | w=h=0 |
| 浮点坑 | (0.92, 0.92, 0.5, 0.5) | 不抛错，w=h=`1.0-0.92` |
| 负坐标 | (-0.2, -0.1, 0.5, 0.5) | 收到 (0, 0)，尺寸不变 |
| 框完全在页外 | (1.5, 1.2, 0.5, 0.5) | 收到 (1, 1)，w=h=0 |
| w/h 为 0 或负数 | (0.1, 0.1, 0/−0.3, 0/−0.2) | 空间足够时补回 0.08 |
| w/h 超大 | (0.1, 0.2, 5, 5) | 收到剩余空间 (0.9, 0.8) |
| 过小宽/高补回 | (0.1, 0.1, 0.01, 0.02) | 补回 0.08 |
| 贴边且 w/h 为 0 | (1.0, 0.95, 0, 0) | 保持 0（剩余空间 < 0.08，不补） |

注：最后一例第一版期望写错（以为 h 会变成 0.05），实际 h 保持 0——
剩余空间 0.05 < 0.08 不触发补回；已修正期望为 0，属测试本身的错误，
实现无改动。

## 5. 验证

- `flutter analyze`：**No issues found**（0 问题）。
- `flutter test`：**292/292 通过**（含新增 12 个；改前套件 280 个）。
- Linux 真机：Xvfb :99、1280×720、Release 构建，`libapp.so` `bd647450`。

### 5.1 真机拖动验证（收集页修框编辑器）

演示库无收集任务，先插一条临时任务（`s8a3-测试页.jpg`，数学，
`needBox`，占位检测给 1 个整题框 x=0.06/y=0.05/w=0.88/h=0.85），
验证后删库恢复（见 §5.2）。纸面实测 289×365px（左上 495,178）。

| 步骤 | 框位置（像素扫描实测） | 结论 |
| --- | --- | --- |
| 打开编辑器 | x=0.06, y=0.05（占位框） | 正常 |
| 向右下拖（25 步） | x=0.574, y=0.553，右缘贴纸面右缘 | 未崩 |
| 继续向右拖（36 步） | x=0.803，右缘仍贴纸面右缘 | 未崩 |
| 再向右拖（20 步） | **x=0.934**，窄条贴右缘 | **越过 0.92 旧抛错阈值，未崩** |
| 向下拖（50 步） | x=0.934, y=0.800 | 未崩 |
| 再向下拖（40 步） | 框被推到右下角成极小点，仅标签“题级框 1”可见，标题仍“本页 1 道题” | **x、y 双贴边，未崩** |

旧代码下 `x=0.934` 一步就会抛（`1.0-0.934=0.066 < 0.08`），
本次全程应用存活、编辑器标题计数不变、日志无 Flutter 异常。
截图 `shots/s8a3/`：`03-editor.png`（打开）、`04-drag-to-edge.png`、
`06-drag-right-edge2.png`（**x=0.934 关键帧**）、`07-drag-bottom-edge.png`、
`08-drag-bottom-right-corner.png`（双贴边终态）、`09-after-cancel.png`（取消后）。

方法说明：xdotool 分步拖动的实际位移只有请求值的约 40–60%
（与 A1 的发现一致，属事件投递/手势合并特性），故分多轮拖、每轮后用
像素扫描实测框边位置，而非按请求位移推算。点击“修框”按钮时前两次
坐标估偏落在空白处未响应，改按裁剪放大图定位到 (810,595) 后成功。

### 5.2 演示库恢复

验证前备份到 `/tmp/qm2-s8a3-orig.db`，验证后从备份恢复并核对：
9 道题、学科 数学/英语/政治、`collect_tasks` 0 条、`themeMode=dark`、
`fontSize=standard`。应用用 `pkill -x quiz_master2` 杀掉。

## 6. 环境备注（本次验证的额外动作）

- 本机 `flutter` 不在 PATH，实际路径
  `~/workspace/flutter-install/flutter/bin`。
- `flutter build linux --release` 初次失败：缺 GTK3 开发头文件
  （`/usr/include/gtk-3.0` 不存在，A1 时补过的包已不在）。装
  `libgtk-3-dev` 时遇 `libzstd-dev` 依赖冲突：已装的 `libzstd1` 是
  `1.5.5+dfsg2-2build1.1+hatch1`，仓库版要求 `1.5.5+dfsg2-2build1.1`；
  用 `--allow-downgrades` 只降了 `libzstd1` 这一包（同上游版本，仅去
  hatch1 后缀，0 个包被删除），随后构建成功。构建产物装到
  `/usr/local/quiz_master2`（非 `build/.../bundle`，属本工程 CMake
  安装前缀配置）。
- 另装了 `xdotool`（真机点击/拖动用）。以上均为验证所需的环境准备，
  未动工程依赖与 `pubspec.lock`。

## 7. 改动清单（未 commit、未 push）

- `lib/services/yolo_onnx_service.dart`：`clampToPage` 重写（§3.1）。
- `lib/modules/collect/collect_page.dart`：删 `_clampBoxSafe` 定义，
  7 处调用点改直调服务。
- `test/yolo_onnx_service_test.dart`：新建，12 个用例。
- `docs/ui-replication/S8A3-CLAMP-REPORT.md`：本报告。
- `docs/ui-replication/shots/s8a3/`：验证截图 10 张。
