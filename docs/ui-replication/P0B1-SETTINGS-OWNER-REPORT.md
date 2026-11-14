# P0B1 设置单 owner（第一批第 4 项）— 修复报告

- 日期：2026-11-13
- 分支：`ui-replication`（未提交、未推送）
- 基线：开工时工作树已含 §8 完成态 + 第 1–3 项的未提交改动；基线验证
  `flutter analyze` 0 问题；全量 `flutter test` **407 通过 + 1 跳过（= 408 项）**，
  其中 3 项是本项新增的 `test/p0b1_settings_owner_test.dart`。

## 0. 接手说明

上一位工人做到一半断了，留下的东西：`lib/app.dart` 与
`lib/modules/review/review_page.dart` 的修复代码（23:08）、
`test/p0b1_settings_owner_test.dart`（23:09）、
`docs/ui-replication/run-shots-p0b1-settings.sh` 与
`shots/p0b1-settings/before/` 的两张半截截图（23:15）。
本次接手没有推倒重做：先用 `git diff` 与读文件确认了他改的
内容完整且方向正确（见 §2），再补完他没做完的验证——全量测试、
改前/改后演示机截图对照、演示库恢复——并写本报告。

## 1. 问题（已按文件核实）

复习页“每页”下拉改 `pageSize` 是“改设置”，但改前直接调
`repo.saveSettings` 写库，绕过了应用层：

- `lib/app.dart` 的 `_settings` 是启动快照（`_updateSettings`
  L143–147 才是写库 + 更新快照的唯一入口）；
- 设置页 `initState` 取 `widget.settings`（`settings_page.dart`
  L110–112 `_s = widget.settings`），即 app 传下来的快照；
- 于是：复习页把库里的 `pageSize` 改成 20 → app 快照仍是 10 →
  打开设置页显示 10 → 再改别的项（如主题）时 `_apply`
  （`settings_page.dart` L142–144）全量写回，把旧 `pageSize = 10`
  覆盖回去。库里的一次改动就这么丢了。

## 2. 改了什么（最小改动，未动 Schema、依赖、pubspec.lock）

| 文件 | 改动 |
|---|---|
| `lib/modules/review/review_page.dart` | `ReviewPage` 新增可选回调 `onSettingsChanged`（L33，注释 L41–48）；分页 `onChanged`（L1090–1100）：有回调就走回调，否则回退直接写库（独立使用 / 旧测试行为不变） |
| `lib/app.dart` | `/review` 路由给 `ReviewPage` 传 `onSettingsChanged: _updateSettings`（L401–403），与设置页同一条写路径（L417） |

改后全树复查 `saveSettings` 调用点（`lib/` 内）：只剩两处真实
写点——`app.dart:144`（`_updateSettings` 内，单一 owner）与
`review_page.dart:1096`（未接回调时的回退；应用内恒传回调，
不走这条路）。设置页全部改动都经 `_apply` →
`onSettingsChanged` → `_updateSettings`。单 owner 成立。

## 3. 错题本“每页”下拉核对（未修，理由如下）

- 错题本没有同样问题：它的下拉 `onChanged`（`wrongbook_page.dart`
  L3179–3190）只做本地 `setState`，**从不写库**，不存在陈旧
  快照覆盖；`_load`（L144、L159）每次从库重读 `settings.pageSize`，
  改后值下次进错题本即生效。
- 但存在一个**不对称**（记录在案，未改）：同一个“每页”控件，
  复习页改的是共享默认设置（持久化），错题本改的只是本次查看
  的本地值（下次进页恢复成库里的值）。改成一致需要给错题本也接
  `onSettingsChanged`（约 10 行），但那会改变产品行为（本地速
  改变成改默认值），不属于本项修的 bug，等 Meng 定是否统一。

## 4. 验证

### 4.1 静态与测试

- `flutter analyze`：**0 问题**。
- `flutter test` 全量：**407 通过 + 1 跳过（= 408 项）**，新增的
  `test/p0b1_settings_owner_test.dart` 3 项全部通过：
  1. 复习页改每页数量经 `onSettingsChanged` 通知 app，库、回调、
     app 快照三处一致为 20（改前回调收不到，快照仍是 2）；
  2. 设置页拿到新快照后“每页显示数量”选中 20，再改主题写回的
     设置里 `pageSize` 仍是 20；
  3. 未接回调时回退直接写库（独立使用行为不变）。

### 4.2 演示机改前/改后对照（1280×720，深色，演示库 9 道题）

脚本 `docs/ui-replication/run-shots-p0b1-settings.sh`，
改前包 `~/workspace/.p0b1-settings-before/bundle`（15:08 构建，
不含本项修复），改后包为本次新构建。流程：复习页每页 10→20 →
设置页看“每页显示数量”选中值 → 外观组点“浅色”换主题 → 杀
应用后查库。

| 步骤 | 改前 | 改后 |
|---|---|---|
| 复习页改 10→20 后查库 | `pageSize=20` | `pageSize=20` |
| 设置页“每页显示数量”选中值 | **10**（陈旧快照） | **20** |
| 改主题为浅色、杀应用后查库 | `pageSize=10`（被覆盖回去），`themeMode=light` | `pageSize=20`（保住了），`themeMode=light` |

截图 `docs/ui-replication/shots/p0b1-settings/before/` 与
`.../after/` 各 7 张 + `db-checks.txt`。关键对照：
`05-settings-wrongbook.png`——改前选中 10，改后选中 20。
演示库已恢复原状（9 道题，`pageSize=10`，`themeMode=dark`）。

## 5. 环境事故：演示机工具链丢失与恢复（与本项修复无关，记一笔）

接手时 VM 重启丢过一次 `/usr` 下后装的东西：`ninja`、`clang`、
GTK 开发包（`/tmp/gtk-sysroot`）、`xdotool`、`import`
（ImageMagick）全没了，导致 `flutter build linux` 与截图脚本
都跑不起来。本次已按既往办法恢复：

- `ninja` 1.12.1：GitHub 官方静态二进制；
- `clang` 18.1.3、`libgtk-3-dev` 闭包（54 个包）、`xdotool`、
  `imagemagick`：Ubuntu noble/noble-updates Packages 索引解析
  依赖闭包，`dpkg-deb -x` 解到 `/`（apt 本身是坏的）；
- 关键坑：只用 noble 索引会装上 Mesa 24.0.5 的 `libegl-mesa0`，
  与基础镜像的 `libgl1-mesa-dri` 25.2.8 对不上，应用启动即
  `libEGL fatal: did not find extension DRI_Mesa version 1`；
  改取 noble-updates 的 25.2.8 版 `libegl-mesa0` 后恢复。
  另：旧 `CMakeCache.txt` 缓存了已死的 `/tmp/gtk-sysroot` 路径，
  已删除重配（生成文件，不动源码）。

恢复办法已存成脚本
`docs/ui-replication/restore-linux-toolchain.sh`（内嵌解析器，
noble-updates 优先），下次 VM 重启丢工具链直接跑它即可。
注意：`/usr` 下后装的东西重启仍会丢，这是环境现状，脚本
只是让恢复变成一件事。

## 6. 未动事项

未 commit / push / pull / reset / checkout / clean；未动数据库
Schema；未动 `pubspec.lock`（构建时 `flutter pub get` 只读了
依赖，无改动）；未动错题本下拉行为（见 §3）。
