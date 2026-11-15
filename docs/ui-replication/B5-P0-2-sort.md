# B5-P0-2：设置“学科首字母”排序进错题本列表触发 DropdownButton 断言

- 来源：自审 SR-P0-2（`docs/ui-replication/SELF-REVIEW.md`）
- 修法：已定方案 (a)，按 2026-11-14 全部同意的第 3 项决定——设置项 `'subject'` 改为 `subj-asc`（并拆成升序/降序两项），`_filteredAll` 补对应 case，`_sort` 加兜底。
- 状态：已修完，单测复核通过。

## 结果

- 设置页“默认排序”不再提供列表下拉没有的 `'subject'`；改为与列表页一致的 `subj-asc`（学科首字母 A → Z）与 `subj-desc`（学科首字母 Z → A）。
- 旧库里已存的 `'subject'` 不会再断言：读库（`AppSettings.fromMap`）、写入（`copyWith`）、错题本加载（`_load`）三处归一为 `subj-asc`；任意未知值回落到 `'new'`。
- `_filteredAll` 补了防御性 `case 'subject'`（与 `subj-asc` 同分支），即使某处直接置了旧值也不静默回落到时间排序。

## 改动文件

| 文件 | 改动 |
|---|---|
| `lib/models/models.dart` | 新增 `AppSettings.wrongbookSortValues`（六项合法值）与 `normalizeWrongbookSort`（`'subject'` → `'subj-asc'`，未知值 → `'new'`）；`fromMap` 与 `copyWith` 入口调用归一；修正 `wrongbookSort` 注释（旧 `new / old / subject`） |
| `lib/modules/settings/settings_page.dart` | “默认排序”选项 `'subject'`（学科首字母）改为 `subj-asc`（学科首字母 A → Z）与 `subj-desc`（学科首字母 Z → A）两项 |
| `lib/modules/wrongbook/wrongbook_page.dart` | `_load` 里 `_sort` / `_defaultSort` 先经 `normalizeWrongbookSort` 再赋值；`_filteredAll` 的 switch 补 `case 'subject'`（与 `subj-asc` 同分支，防御用） |
| `test/wrongbook_page_test.dart` | `FakeWrongbookRepo` 增加可注入的 `settingsValue`；新增 2 条回归测试（见下） |
| `test/settings_page_test.dart` | 新增 2 条测试：两项新选项回调值、模型层归一单测 |

未改动：`lib/modules/review/review_page.dart` 的 `reviewSort == 'subject'` 是另一个设置项（复习列表排序），与本条无关，未动；`lib/modules/wrongbook/wrongbook_list.dart` 的下拉六项本身就是正确的目标值，未动。

## 验证

- `flutter analyze`：**0 问题**。
- 相关测试（`LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux`）：
  - `test/wrongbook_page_test.dart`：**45/45 通过**（含新增 2 条）
  - `test/settings_page_test.dart`：**26/26 通过**（含新增 2 条）
  - 合计 **71/71 通过**。未跑全量测试（按任务要求，协调员在阶段结束统一跑）。
- 未碰真实演示库（测试用 FakeRepo / 内存数据）。

## 单测复核结果（SR-P0-2 的 live 复核）

自审时探针曾因并行测试占住构建缓存、8 分钟无输出而停掉，未拿到真机/ live 复现；本次用 widget 单测复核，**通过**：

1. `列表页 旧值 wrongbookSort='subject' 进列表不断言，按学科首字母排`——**通过**。`FakeRepo` 以 `AppSettings(wrongbookSort: 'subject')`（构造器直传，绕过归一）进错题本列表：`pumpAndSettle` 无 DropdownButton 断言，下拉显示 `排序：学科首字母 A → Z`，且首题为数学题（学科升序），不是时间新→旧会排在前面的英语题。证明旧值既不断言、也不静默回落到时间排序。
2. `列表页 未知 wrongbookSort 回落到时间新→旧，不断言`——**通过**。`wrongbookSort: 'bogus'` 进列表不断言，下拉显示 `排序：时间 新 → 旧`，首题为较新的英语题。
3. `设置：错题本与启动 默认排序：学科首字母 A→Z / Z→A 回调 subj-asc / subj-desc`——**通过**。设置页已无 `学科首字母` 旧选项。
4. `AppSettings 归一：旧值 subject → subj-asc，未知值 → new`——**通过**。`fromMap({'wrongbookSort': 'subject'})` → `'subj-asc'`，`fromMap({'wrongbookSort': 'bogus'})` → `'new'`，`copyWith(wrongbookSort: 'subject')` → `'subj-asc'`，`copyWith(wrongbookSort: 'status-desc')` 保持不变。

四条新测试均单独点名复跑通过（`--plain-name`）。

## 遗留问题

- 无本条遗留。注意：`AppSettings` 构造器本身不归一（const 构造器无法归一），归一发生在 `fromMap` / `copyWith` / 错题本 `_load` 三处入口；直接 `AppSettings(wrongbookSort: 'subject')` 构造出的对象仍含旧值，但唯一消费它的错题本页已在 `_load` 归一，设置页收到的值来自 `fromMap`（已归一），故无断言路径残留。
- 与 SR-P0-2 同源的 P2-2（列表页手动选 `subj-asc/subj-desc` 与设置项语义）随本修一并消除：设置项与列表项现为同一套值，不再有两套语义。
