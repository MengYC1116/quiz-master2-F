# P0B2 书架封面去英文（小修第 2 项）— 修复报告

- 日期：2026-11-14
- 分支：`ui-replication`（未 commit、未 push）
- 基线：开工时工作树已含 §8 完成态 + 第 1 项（复习页“每页”下拉本地化）等未提交改动；基线验证 `flutter analyze` 0 问题、全量 `flutter test` 410 项全部通过（409 通过 + 1 跳过），与任务书一致，遂按任务继续。

## 1. 改了什么

只改 `lib/modules/wrongbook/wrongbook_page.dart` 的 `_buildBook`，两处删除，无新增代码：

| 位置 | 改动 |
| --- | --- |
| 约 L1239-1242 | 删 `enName` 写死映射：`'english' => 'ENGLISH'`、`'politics' => 'POLITICS'`、`_ => 'MATHEMATICS'`（新学科一律回退成 MATHEMATICS，即 P0B1 报告 §4 第 6 点记的遗留问题） |
| 约 L1337-1352 | 删封面顶部的英文名 `Padding > Text(enName)`（HTML `.nb-book-en`，12px/600/字距 4.08/白色） |

- 改前先 grep 确认：`enName` / `ENGLISH` / `POLITICS` / `MATHEMATICS` 在 `lib/`、`test/` 里只出现在这两处（定义 + 唯一使用点），无别处引用，删除不留死代码、不误删他处。学科管理页「错题本封面样式」块只有样式小图 + 颜色选择，无英文文本，未动。
- 布局影响：学科名（52px）上移至封面顶部内边距（`bookPaddingTop` 34）处；其余不动——「错 题 本」副标题、计数牌、封面内「开始复习」、折角 / 书脊 / 虚线内框均保持原样。未动数据库 Schema、未改依赖、未动 `pubspec.lock`、未 commit/push/pull/reset/checkout/clean。

## 2. 新增回归测试

`test/wrongbook_page_test.dart` 书架组新增 1 项：「封面顶部无英文：数学/英语/政治/新学科均无英文行」。

- 用 `threeSubjectRepo()` 追加新学科化学（`Subject(id: 'chemistry', name: '化学', icon: '化', coverColor: 'purple')`）+ 一道化学题，泵起整页错题本（4 本书）。
- 断言：数学 / 英语 / 政治 / 化学中文名各出现 1 次；`错 题 本` 出现 4 次；分页文案 `第 1 / 1 页 · 共 4 本（每页最多 6 本）`；`MATHEMATICS` / `ENGLISH` / `POLITICS` 均 `findsNothing`（含旧映射的三词与新学科的回退词）。

## 3. 验证证据

- `flutter analyze`：**0 问题**（改前基线与改后各跑一次，均为 0）。
- `flutter test` 全量：改前 410 项全部通过（409 通过 + 1 跳过）；改后 **411 项全部通过（410 通过 + 1 跳过）**，新增 1 项即本组；单文件 `test/wrongbook_page_test.dart` 41/41 通过。
- `flutter build linux --release`：构建成功（`build/linux/x64/release/bundle/quiz_master2`）。
- 真机（Linux 虚拟机，Xvfb 1280×720，深色，演示库，release 包现场构建）：
  - 打开错题本：数学 / 英语 / 政治三科封面顶部均无英文，只有中文学科名 + 「错 题 本」+ 计数牌 + 「开始复习」；计数与演示库一致（数学 2/2/0、英语 2/0/1、政治 1/0/0）。
  - 学科管理页走 UI 新建化学（输入框 + 「＋ 添加学科」，库里新增 `subject-1794586804946 | 化学 | grey`，新学科默认灰色封面）：回错题本，书架 4 本，化学封面顶部同样无英文（不再是旧的 MATHEMATICS），计数 0/0/0，分页文案 `第 1 / 1 页 · 共 4 本（每页最多 6 本）`。
- 演示库验证后已恢复：`~/.local/share/quiz-master2/quiz-master2.db` 与跑前备份 `/tmp/qm2-p0b2-cover-en-orig.db` md5 一致（`6801a73bd02920d31fd9c48d32722ffd`），9 道题、3 学科、0 归档、深色、`pageSize=10`、`notifyTime` 20:00。

## 4. 偏离与说明

1. **截图按 2026-11-14 00:02 新口径免了。** 真机核对用的临时截图只存 `/tmp`（`qm2-cover-en-*.png`），看完即删，未进 `shots/`。本报告无配图，结论以测试断言 + 自查截图目视 + 库值核对为准。
2. **xdotool `type` 输不了中文。** 新建化学时 `xdotool type -- "化学"` 报 `Invalid multi-byte sequence`，输入框为空、学科未加上；改用 `xdotool key U5316 U5B66`（「化学」的 Unicode 码点）输入成功，其后添加、封面核对均走 UI。
3. **清理时 `pkill -f "Xvfb :99"` 自匹配。** 该命令的匹配串出现在执行 shell 自身的命令行里，shell 被一并杀掉，排在其后的恢复库命令未执行；随后检查发现库仍有 4 学科（md5 不符），重跑恢复并核对 md5 一致、题数 / 学科数 / 设置均回原状（见 §3）。应用与 Xvfb 已确认停掉。
