# B11-1 拖放导入（最小版）

状态：完成，未 commit、未 push。分支 `ui-replication`，基于 Batch 10 远程 head `05468129` 后的工作树。

## 改了什么

- `pubspec.yaml` / `pubspec.lock`：新增 `desktop_drop: ^0.8.4`、`crypto: ^3.0.8`
  （后者是第 2 项内容哈希用的，见 B11-2 报告）。只加依赖，未升级任何
  已有依赖（lock diff 只有新增包，无版本变动行）。
  注意：`pubspec.yaml` 同时有 B11-8 worker 加的 `super_clipboard`，
  两处改动并存，无冲突。
- `lib/modules/collect/collect_page.dart`（主改动）：
  - 拖放区包一层 `desktop_drop` 的 `DropTarget`（只接收集中心落点，
    不接全窗口、不接微信 / QQ 窗口拖入）。
  - 落点回调 `_onFilesDropped`：文件夹与空路径跳过并提示，其余与
    文件选择导入走同一条 `_handleIncomingPaths`（先选学科、PDF 50MB /
    图片 20MB、重复提示“已经导入过”）。
  - 悬停态：拖入时标题变“松开就导入”并加粗边框（只用现有 DesignTokens，
    不新增颜色）。
  - 删掉占位文案“拖放导入还没接好，先点「选择文件」导入”；类注释同步更新。
- `test/b11_dragdrop_test.dart`（新增，7 个测试）：落点存在与文案、
  悬停切换、单张拖入导入、猜不出学科时暂存、批量队列与重试、不支持
  类型跳过、文件夹跳过。
- `test/collect_page_test.dart`（改 1 处，B11-2 的流程变化连带）：
  旧测试“没选学科不能导入：点选择文件出黄色提示”改为新行为（见下），
  并新增 `_FakeFilePicker`（见“测试说明”）。

## 行为

- 从文件管理器把 PDF / JPG / PNG 拖到收集中心拖放区，等同于点
  “选择文件”选了这批文件：没选学科时先按文件名猜学科建议预填
  （B11-2），猜不出则暂存文件等用户选学科；重复 / 超限走既有黄色
  横幅；确认后逐个导入。
- 只收 PDF / JPG / PNG：文件夹（Win11 上拖文件夹也是一条路径，
  按 `Directory.existsSync` 拦）与不支持类型跳过并出 snack
  提示，不建任务。
- 单文件拖入行为与点选导入一致，不建批量队列卡片。
- 行为变化（B11-2 需要）：以前“没选学科不能点选择文件”，现在没选
  学科也能先选文件 / 先拖文件，文件暂存，等用户选好学科点“开始导入”
  再导；“没选学科不能导入”的口径不变（开始导入时仍要求选了学科，
  否则出“先选学科”提示）。

## 测试结果

- `flutter test --concurrency=1 test/b11_dragdrop_test.dart`：7/7 通过。
- `flutter test --concurrency=1 test/collect_page_test.dart`：42/42 通过
  （含上面改过的 1 个测试）。
- `flutter analyze`（9 个改动文件，含测试）：0 问题。
- 测试一律用内存库 + 临时数据目录；演示库未动（md5 始终
  `8f7f9c64405dc6e484ac2bf8e5e1a807`，备份在
  `~/workspace/demo-db-backup/quiz-master2.db.b11-w1`，无需恢复）。
  本次未跑应用，无截图。

## 测试说明（值得后续 worker 知道的两点）

- 拖放用 `desktop_drop` 的 `desktop_drop` 通道模拟（`entered` /
  `performOperation`，与真机上插件发来的调用同格式），不是 mock
  的 `DropTarget`——落点回调是真实触发的。
- `testWidgets` 体是 fake async：文件流式读在 fake 区订阅后，即使
  之后进 `runAsync` 也永远不交付（探针 `b11_probe3_test.dart` 已
  验证并删除）。所以触发导入的动作（拖放发送、点“开始导入”、
  点“重试失败项”）必须在 `runAsync` 内发起；等终态（非 `importing`）
  再断言，只数行数会在 `importing` 行上早退。相关注释已写进测试文件。
- `FilePicker.platform` 是 `late` 字段，测试里插件注册不跑，直接调
  会抛 `LateInitializationError`（被 `_pickFiles` 的 catch 吃掉变
  snack）。`collect_page_test.dart` 里用继承 `FilePicker` 的
  `_FakeFilePicker` 代替。

## Win11 待验项（Linux 上只能做到 widget 测试验证落点处理逻辑）

1. 从资源管理器真拖文件到拖放区：悬停高亮、松手导入、多文件一次拖入。
2. `flutter build windows` 能正常编过 `desktop_drop` 原生部分
   （C++ 插件注册），应用启动不闪退。
3. 从资源管理器拖文件夹：应跳过并提示（Linux 上已按路径拦住，
   Win11 上确认插件是否把文件夹当文件路径发过来）。
4. 虚拟文件拖入（如 OneDrive 占位文件、Outlook 附件拖拽）：无本地
   路径时应跳过并提示，不崩溃。
5. 含中文 / 长路径文件名拖入不报错。
6. 拖放手感（拖入/拖出/松手时机）只在真机上验，Linux 上不做结论。

## 决策（请协调员记 D-25+，未改 docs/decision-log.md）

- **插件选型：`desktop_drop` 0.8.4。** 理由：维护活跃（2026-10 刚发
  0.9.1）、支持 Windows / Linux / macOS、纯 Dart API（`DropTarget` +
  `onDragDone`）、除插件自身外无额外原生依赖。0.9.x 未采用：它要求
  `cross_file ^0.4.0`，与 `file_picker` 8.x 的 `cross_file ^0.3.x`
  冲突，升级 `file_picker` 超出本次范围。备选已排除：`super_drag_and_drop`
  （更重，还带拖出端能力，本次用不上）、`windows_drop_target` 0.0.1
  （仅 Windows、刚发布不成熟）、手写 Win32 FFI（原生代码自己维护，
  成本过高）。
- **落点范围：只收集中心拖放区。** 全窗口落点、微信 / QQ 窗口拖入
  不做（任务明确排除）。
- **拖放与点选同流程。** 拖入不走任何捷径：学科、大小限制、重复提示
  全部复用 `_handleIncomingPaths`，行为差异为零。
- **悬停态只换文案与边框。** 不改布局、不新增颜色（现有
  `palette.accent` / `accentSoft`）。
