# P0B1 错题本返回不刷新 — 修复报告

- 日期：2026-11-13
- 分支：`ui-replication`（未 commit、未 push）
- 基线：开工时工作树已含第一批其他项的未提交改动（B2 学科同步等）；基线验证 `flutter analyze` 0 问题、全量 `flutter test` 388 项全部通过（387 通过 + 1 跳过），与 §8 完成态一致，遂按任务继续。

## 改了什么

`lib/modules/wrongbook/wrongbook_page.dart` —— 三处详情入口由 fire-and-forget 改为
先 `await onOpenDetail`、再 `await _load()`，与整理页（`organize_page.dart:286-287`
`await onOpenDetail(...); await _refresh();`）和复习页（`review_page.dart:1380-1381`
`await onOpenDetail(...); await _load();`）的写法一致。重载方法经读文件确认为本页
已有的 `_load()`（重读学科/题目/文件夹/试卷/标签/知识点/计数/错因记录/设置并 `setState`）。

| 入口 | 位置 | 形态 |
| --- | --- | --- |
| 大卡片 | `_buildLargeCard` 约 L2854，`QuestionSlice.onTap` | `onTap: () async { await widget.onOpenDetail(q, orderIds); await _load(); }` |
| 紧凑行 | `_buildCompactRow` 约 L2935，`InkWell.onTap` | 同上 |
| 已归档行 | `_buildArchivedRow` 约 L3090，`InkWell.onTap` | 同上 |

`onOpenDetail` 签名未动（`Future<void> Function(Question q, List<String> orderIds)`）。
未动数据库 Schema、未改依赖、未动 `pubspec.lock`、未 commit/push/pull/reset/checkout/clean。

## 新增回归测试

`test/wrongbook_page_test.dart` 新增 group「详情返回刷新」，3 个 widget 测试（复用
既有 `FakeWrongbookRepo` / `pumpWrongbook`，`onOpenDetail` 回调直接改 fake 库，
模拟详情里的真实写操作）：

1. 大卡片：详情里删题，返回后卡片由 3 张变 2 张；
2. 紧凑列表：详情里改收藏，返回后星标由 1 颗变 2 颗（切回紧凑列表后断言，见下「偏离」）；
3. 已归档行：详情里恢复归档，返回后该行消失。

## 验证证据

- `flutter analyze`：**0 问题**（改前基线与改后各跑一次，均为 0）。
- `flutter test` 全量：改前 388 项全部通过（387 通过 + 1 跳过）；改后 **391 项全部
  通过（390 通过 + 1 跳过）**，新增 3 项即本组；单文件 `test/wrongbook_page_test.dart`
  40/40 通过。
- 真机（Linux 虚拟机，Xvfb 1280×720，深色，演示库 9 道题/3 学科）：脚本
  `docs/ui-replication/run-shots-p0b1.sh`（用法 `./run-shots-p0b1.sh <before|after>`）
  各跑一轮改前/改后对照；归档与编辑走交互验证。截图在
  `docs/ui-replication/shots/p0b1-refresh/{before,after}/`。

| 操作 | 改前（before/） | 改后（after/） |
| --- | --- | --- |
| 详情收藏定积分 → 返回 | `09-compact-after-fav.png`：定积分仍是 ☆（过期），只有函数极限 ★ | 同名截图：两行都是 ★ 金色星标 |
| 详情删除定积分 → 返回 | `12-list-after-delete.png`：紧凑列表仍有定积分+函数极限，「共 2 道」（删掉的题还在） | 同名截图：只剩函数极限 1 张大卡片，「共 1 道」；`11-detail-after-delete.png` 证实删后详情自动进了下一题 |
| 详情编辑题名 → 返回（仅改后交互验证） | — | `16-compact-after-edit.png`：函数极限显示为「函数极限-v2」 |
| 详情归档 → 返回（仅改后交互验证） | — | `17-detail-archived.png` 详情出现「已归档」横幅；`18-list-after-archive.png` 列表只剩定积分 1 道 |

- 演示库验证后已恢复：`~/.local/share/quiz-master2/quiz-master2.db` 与跑前备份
  `/tmp/qm2-p0b1-orig.db` md5 一致（`ff5c3758782ce34dfcc52715e906346b`），
  9 道题、题名/收藏/归档均为原状。杀应用只用 `pkill -x quiz_master2`。

## 偏离与说明

1. **返回后视图会跳回大卡片（既有行为，未改）。** `_load()` 会把 `_viewMode` 重置为
   设置里的默认视图（演示库为 `large`），而「紧凑列表」切钮只是本地 `setState`，不持久化。
   所以从紧凑列表进详情、改完返回后，列表先回到大卡片，需再点一次「紧凑列表」才看到
   星标/新题名。行内点星（`_toggleFavorite`）同样走 `_load()`，同样会跳回——这是
   `_load` 的既有行为，不是本次修复引入的。本次按任务边界未动它；回归测试第 2 项也按此
   写（返回后先切回紧凑列表再断言）。建议 Meng 另立一项决定：是否让 `_load` 保留当前
   视图，或让切钮持久化到设置。
2. **脚本首跑走偏一次，原因是脚本坐标问题，不是应用 bug。** 收藏后底部「☆ 收藏」变成
   宽按钮「★ 已收藏（点击取消）」，「下一题」「删除」整体右移，删除中心由 (785,653)
   移到约 (888,653)；首跑用旧坐标点中了「下一题」。已修正脚本并重跑两轮通过；交互
   复核中行点击与删除本身均正常。脚本头部已记下该坐标教训。
3. **构建环境说明。** 本机 `flutter build linux --release` 初次失败：`/usr/include/gtk-3.0`
   缺失（`libgtk-3-dev` 未装），且 `apt-get install libgtk-3-dev` 被 hatch 改版的
   `libzstd1`（`1.5.5+dfsg2-2build1.1+hatch1`）版本钉死而装不上。未动 dpkg 数据库：
   改把 `/var/cache/apt/archives/` 里已缓存的 .deb 解到 `/tmp/gtk-sysroot`（改写 .pc 的
   prefix、修 .so 悬空链接），用 `PKG_CONFIG_PATH` 指过去构建，两版 release 包均构建成功。
   另：`/tmp` 是 512M tmpfs，首次在 `/tmp` 拷对照副本时爆满（onnx 模型复制失败），对照
   副本改放 `~/workspace/.p0b1-before`，验证完已删除；复现方法记在脚本头部。
   构建时还清过一次 `build/linux/x64/release/CMakeCache.txt`（旧缓存指向不存在的
   gtk 头文件路径，属可再生成的构建产物）。
4. **编辑验证的小限制。** `xdotool type` 在本机打不出中文（`Invalid multi-byte sequence`），
   题名改为追加 ASCII 后缀「函数极限-v2」验证；编辑流程本身（编辑态→保存→返回列表刷新）
   正常。截图 `after/14-edit-saved.png` 是中文输入失败那次的中间态，已删除；报告以
   `13/15/16` 为编辑证据链。
5. **改前对照版的来源。** `before/` 截图用的 release 包由当前工作树复制、在副本里只回退
   本次 3 处改动后构建（其余第一批改动与改后版一致），以便对照只差这一项；副本已删。
