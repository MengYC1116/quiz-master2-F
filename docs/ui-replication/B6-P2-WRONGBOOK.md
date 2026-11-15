# Batch 6 · P2 错题本 / 复习 / 报告 / 首页（D-wrongbook）

- 日期：2026-11-15
- 范围：SR2-28、SR2-29、SR2-30、SR2-32、SR2-33、SR2-52、SR2-53、SR2-74、SR2-75、SR2-76，另加同批已定的月筛选（`age <= 30` → `age < 30`）
- 分支：`ui-replication`，工作树 `~/workspace/quiz-master2-UI`；未提交、未推送

## 验证状态（先说结论）

- `flutter analyze`：**0 问题**（改完后两遍；中途 3 处 `const Subject` 与 1 处闭包写法被 analyze 指出，已修正再跑回 0）。
- `flutter test`：**一次都没跑起来**。按任务要求只尝试跑了一次
  `LD_LIBRARY_PATH=$HOME/.pub-cache/hosted/pub.dev/onnxruntime-1.4.1/linux flutter test --concurrency=1 test/wrongbook_page_test.dart`，
  在 `pdfium_dart-0.4.2` 原生资源构建处失败（`Building native assets failed`，
  `which clang` 无结果，VM 替换后 clang/ninja 已丢失）。**没有自行修工具链**，
  未下载、未安装、未跑恢复脚本。
- 因此下面所有测试用例均为**已写、未跑**：代码走读 + analyze 0 是本次的唯一证据。
  工具链恢复后，总协调补跑时请至少跑：
  `test/wrongbook_page_test.dart`、`test/review_page_test.dart`、
  `test/settings_page_test.dart`（SR2-30 的 SR-P2-50 用例，见下）、
  `test/report_page_test.dart`（SR2-29 牵连 1 个既有用例，见“遗留问题”第 1 条）。

## 产品修复

### SR2-28 — 搜索态缝隙拖拽拒收（修法 (a)）

- `lib/modules/wrongbook/wrongbook_directory.dart:271-279`
  （`_buildGapTarget` 的 `onWillAcceptWithDetails`）：文件夹搜索有关键词时
  一律返回 `false`，缝隙拖拽拒收；拖到行上移进去、拖到「全部题目」移回顶层不受影响。
- 选 (a) 不选 (b)：换算下标要同时处理顶层与子文件夹两套可见列表，改动面大；
  搜索态本来就是找文件夹而不是调顺序，拒收更符合直觉。
- 测试：`test/wrongbook_page_test.dart:1902`
  「SR2-28 搜索文件夹时缝隙拖拽拒收，顺序不变」——数学顶层加「模拟卷」，
  搜「卷」只剩 试卷 / 模拟卷可见，把「模拟卷」拖到两者之间的缝隙
  （DragTarget 下标 6），断言 `repo.savedFolders` 为空（无任何调序保存）。
  旧代码下该拖拽会把「模拟卷」插到「平时作业」前面并产生保存。

### SR2-29 — 学习报告学科分布扣已掌握（Meng 已定 (a)）

- `lib/modules/report/report_page.dart:182-205`：`_questionsInRange` 增加
  `!_isMastered(q)` 过滤；新增 `_isMastered`（与错题本同义：全部错因都有
  已解决记录且无一到复查；无错因、无记录的题不是已掌握）。分布行直接用
  `qsIn` 计数，改一处即全改；弱点 Top5 本来就跳过已解决/已掌握题，不受影响；
  三个核心数按 `_records` 直接算，不受影响。
- `lib/modules/report/report_page.dart:28-35`（文件头口径注释）同步改写：
  「只收已整理未归档且未掌握的题」。
- 语义变化（Meng 已确认）：已掌握的科分布显示 0 道；分布数 = 该科封面总数。
- **牵连 1 个既有用例（见“遗留问题”第 1 条）**：
  `test/report_page_test.dart` 的「分布只按学科：本周数学 3 · 英语 2 · 政治 3」
  会失败——默认库里的 q4（学术词汇，错因已解决、无复查日）按此口径是已掌握题，
  英语分布应由 2 道变为 1 道。该文件不在本次分工文件内，**未改**，留给总协调处理。

### 月筛选 — `age <= 30` → `age < 30`（Meng 已定）

- `lib/modules/wrongbook/wrongbook_page.dart:606-620`：周/月统一为
  `age >= 0 && age < limit`（周 7 天、月 30 天，均含今天）；注释写明
  「最近 30 天 = 30 天含今天，与周口径一致」。
- `lib/modules/wrongbook/wrongbook_list.dart:286`：筛选项文案
  「最近一月」→「最近 30 天」。
- 报告页「本月」是自然月（当月 1 日起），**不动**。
- 测试：`test/wrongbook_page_test.dart:1991`
  「SR2-76 月筛选 “最近 30 天”：29 天前在内，30 天前在外」（任务清单外增补，
  直接覆盖本次行为变更；与 SR-P2-45 周筛选同款边界写法）。

### SR2-30 — 缓存预览按文件逐个计数（修法 (a)）

- `lib/modules/settings/settings_page.dart:574-598`（`_scanCacheSync` 的 `walk`）：
  遇到名字含 cache / thumb / tmp 的目录时不再 `add()` 整体计 1 个就 `continue`，
  而是递归进入（`insideCacheDir: true`，并按目录名带 `cacheKind`：
  含 thumb 按缩略图计、其余按临时文件计），目录里的文件逐个按类计数，
  目录本身不再单独计 1；普通子目录递归时透传 `insideCacheDir` / `cacheKind`。
  旧代码的 `insideCacheDir` 从未为 `true`，是死参，现已真正用上。
- 自审探针夹具复算（8 个文件各 10 字节）：旧 `temp=3 thumb=1 items=4`；
  新 `temp=6 thumb=2 bytes=80 items=8`（thumb-cache 2 张图计 2 张、
  cache 目录 3 个文件计 3 个、inner-cache 2 个文件计 2 个、deep/x.tmp 计 1 个）。
- 与规定修法 (a) 一致。附带变化：`preview.items` 里不再有目录本身，
  `_clearCache` 只删文件、空缓存目录会留下（下次扫描为 0，无害）；清理计数
  文案「已清理 N 项缓存」现与预览个数一致（以前目录按 1 项、文件按 1 项混计）。
- 既有测试 `test/settings_page_test.dart` 的 SR-P2-50 用例（夹具
  `work/thumb-cache/a.png` + `work/deep/x.tmp`，期望「临时文件 1 个、
  缩略图缓存 1 张」）在新逻辑下仍成立（a.png 在 thumb 目录里计缩略图 1 张，
  x.tmp 计临时 1 个），**未改该测试文件**。但 B5 报告明说该 widget 测试
  「已写，未跑通」——本次同样因 clang 丢失未能跑通，**工具链恢复后必须单跑
  `flutter test test/settings_page_test.dart` 真正跑通一次**（见验证状态）。

### SR2-32 — 学科排序按拼音首字母串排，空名排最后

- `lib/modules/wrongbook/wrongbook_page.dart:163-201`：
  - `_subjectInitial`：空名回退 `''` → `'{'`（排在 Z 之后、最后）。
  - 新增 `_subjectPinyinKey`：学科名逐字转首字母串（拉丁字母取大写，
    映射表内汉字取首字母，**表外汉字仍回退为原字比较——注释写明是码点序、
    不是拼音序**）；空名返回 `''`。
  - `_subjectKeyCompare`：首字母 → 全名拼音首字母串 → 全名，三级比较。
  - 效果：同首字母 S 时「生物」SHENGWU 排在「数学」SHUXUE 前面；
    未映射汉字（首字不在表里）仍排在所有已映射字母之后；空名排最后。
- 未扩映射表：表已覆盖常见学科首字，扩表是无穷尽的活；回退语义已在注释写明。

### SR2-33 — 按组进会话的范围文案按该组写

- `lib/modules/review/review_page.dart:496-520`（`_startSession`）：
  `fromGroup != null` 时 `scopeLabel = '${学科名} · ${错因}'`
  （与 `_scopeLabelForBlocks` 的单科单错因分支同款）；否则仍用
  `_scopeLabelForFilters()`。断点恢复分支不动。
- 测试断言见 SR2-33 测试一节。

## 测试（新增 / 改动）

### SR2-52 — SR-P2-44 组：换科前先设筛选

- `test/wrongbook_page_test.dart:1921`：改动既有
  「SR-P2-44 换科/换文件夹时搜索与筛选清零」用例（未另立新用例）。
  换科前先开筛选面板、把错误类型下拉（`DropdownButton<String>` 第 3 个，
  即筛选面板第 2 个）设为「计算错误」；与搜索「函数极限」无交集、列表为空，
  证明筛选已生效；换科进英语后断言「阅读主旨」「图表作文」可见，
  **且**错误类型下拉值回到 `null`（显示「全部」）。
  注意：筛选面板在换科后仍开着，断言直接读下拉值；`_openList` 等不碰
  `_filterOpen`，面板状态跨科保留。

### SR2-53 — SR-P2-40 组：补竖线用例

- `test/wrongbook_page_test.dart:1832`：「SR2-53 批量加标签：含竖线的新标签
  拦下，不入库不保存」——输入 `新标|签`，断言提示「不能含逗号或竖线」、
  `tagList` 不含该标签、`repo.saved` 为空。与逗号用例同款流程。

### SR2-74 — SR-P2-37 组：补三组用例

- `test/wrongbook_page_test.dart:1690`：同首字母平局——数学（1 天前）
  与生物（10 天前），`subj-asc` 下第一张卡应是生物题（拼音序）；
  旧代码按码点比全名会把数学排前面，用例可抓旧 bug。
- `test/wrongbook_page_test.dart:1726`：未映射汉字——「量子力学」
  （首字「量」不在表里）排在数学之后，第一张卡是数学题。
- `test/wrongbook_page_test.dart:1761`：空名——空名学科排最后，
  第一张卡是数学题；旧代码回退 `''` 会把它置顶，用例可抓旧 bug。
- 三组均用 `filterCause: '概念不清'` 的跨学科列表、点第一张卡断言打开的题 id。

### SR2-75 — review_page_test 的 SR-P2-47 组：未加入盒分行顺序

- `test/review_page_test.dart:931`：「SR2-75 未加入盒按学科分行：
  新学科/未知学科排最后」——学科表追加化学（预设三科之后），
  未加入题再加数学新题、化学新题、未知学科题（`subjectId: 'weird'`，
  不在学科表里）；断言四行纵向顺序：数学新题 < 马原（政治） < 化学新题 <
  未知学科题（以 `getTopLeft().dy` 比较）。未知学科行名回退到数学
  （`Subject.byId` 兜底），但行本身排在最后，用例注释已写明这一点。

### SR2-76 — wrongbook_page_test 的 SR-P2-46 组：两组用例

- `test/wrongbook_page_test.dart:2088`：归档后 `_page` 越界回落——
  12 道题、每页 10 条，到第 2 页后把仅有的 2 道勾上批量归档，
  列表只剩 10 道、1 页，断言显示「共 10 道 · 第 1 / 1 页」
  （`_page` 状态值仍是旧的 1，渲染按 `clamp` 回落），且
  `repo.archivedChanges` 为 2 条。
  **本次无产品代码改动**：`wrongbook_list.dart:8-11` 与已归档视图
  `:1145-1147` 的渲染层早已对 `_page` 做 `clamp`，回落行为本来就有，
  用例是把该行为钉住。
- `test/wrongbook_page_test.dart:2119`：每页条数切换后页码复位——
  到第 2 页后把每页条数 10 → 20，断言「共 12 道 · 第 1 / 1 页」。
  该复位是既有行为（分页器 `onChanged` 里 `_page = 0`），用例钉住它。

### SR2-33 测试

- `test/review_page_test.dart:713`：在既有「按组开始解决」用例里加文案断言——
  点计算错误组的「开始解决」后，会话元信息行应为
  「第 1 / 1 道题 · 数学 · 计算错误」，不再是筛选口径的「全部待解决错因」。

### 测试计数

- wrongbook_page_test 新增 8 个用例（SR2-74 ×3、SR2-53、SR2-28、
  月筛选、SR2-76 ×2），改动 1 个（SR-P2-44，SR2-52）；
  review_page_test 新增 1 个（SR2-75），改动 1 个（按组开始解决，SR2-33）。
- 其余新增用例均未改既有断言；SR-P2-44 用例在原断言基础上追加
  （搜索清零断言仍在）。

## 与规定修法有出入处

- SR2-28 选修法 (a)（搜索态禁用缝隙拖拽），未选 (b)（下标换算）——见上文理由。
- SR2-30 选修法 (a)（递归进目录逐个计数），未选 (b)（改文案为「X 项」）——
  预览文案说的是「X 个/张」，按文件计数才与文案一致。
- SR2-32 平局比较用「首字母 + 全名拼音首字母串」，未映射汉字给确定性回退
  （原字比较 + 注释写明不是拼音序），未扩映射表——见上文理由。
- 月筛选测试是任务清单外增补（直接覆盖本次行为变更），不是清单列出的五项测试之一。
- SR2-76 的两项是纯测试缺口，未改产品代码（渲染层已有 `clamp` 回落；
  每页条数切换复位也是既有行为）。

## 遗留问题（需总协调 / 他人处理）

1. **SR2-29 牵连 1 个既有用例，需改 `test/report_page_test.dart`**
   （不在本次分工文件内，未动）：「分布只按学科：本周数学 3 · 英语 2 ·
   政治 3」——默认库 q4 是已掌握题，新口径下英语分布为 **1 道**，
   用例名与断言需改为「本周数学 3 · 英语 1 · 政治 3」。另建议在该文件补一个
   SR2-29 专用用例（已掌握题不进分布）。其余报告页用例已逐项核对：
   核心数、弱点 Top5、「接下来练什么」、SR-P1-10/11 均不受影响
   （弱点组本来就跳过已解决/已掌握题；核心数按 `_records` 直接算）。
2. **SR2-30 的 `test/settings_page_test.dart` 至今无一次 live widget 运行记录**
   （B5 报告自认「已写，未跑通」，本次因 clang 丢失同样未能跑）：
   工具链恢复后单跑 `flutter test test/settings_page_test.dart`，
   重点看 SR-P2-50 用例；新逻辑下其期望「临时文件 1 个、缩略图缓存 1 张」
   经走读仍成立，但未经真跑验证。
3. **全部 9 个新增/改动用例均未跑过**（环境原因，见验证状态）：
   恢复后除上面两项外，另跑 `test/wrongbook_page_test.dart` 与
   `test/review_page_test.dart`；SR2-52 用例里筛选面板跨科仍开着读下拉值、
   SR2-28 用例里 DragTarget 下标 6 的计数、SR2-76 归档用例里
   `Checkbox.at(1)/at(2)` 的顺序，都是走读推断、未经真跑验证的高风险点，
   失败时优先检查这三处。
4. `_clearCache` 现在只删预览里的文件、空缓存目录会留下（见 SR2-30 一节），
   属可接受的附带变化；如下次扫描仍见空目录残留被用户问起，再议是否顺手清目录。
5. 未动文件：除任务清单 8 个文件外未改任何文件；未提交、未推送；未碰工具链。
