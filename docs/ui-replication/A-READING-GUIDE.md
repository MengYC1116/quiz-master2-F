# 怎么读新代码（ARCH-PLAN-A 第 1 阶段）

> 给不熟悉 Riverpod 的读代码的人（Meng / CodeBuddy）：
> A 已全部完成（2026-11-16，Stage 0–4）：9 个页面 + 应用根组件
> 全部收进 Riverpod，`lib/state/` 共 11 个文件；页面只留纯界面
> `setState`，业务状态与业务方法都在 Notifier / Provider 里。
> 这一页只讲“新东西在哪、怎么测”，不讲 Riverpod 教程。

## 一、Provider 在哪

新目录 `lib/state/`，共 11 个文件（A 完成态，Stage 0–4）：

| 文件 | 是什么 | 归属 |
|---|---|---|
| `lib/state/repository_provider.dart` | `repositoryProvider`：数据层入口。默认 `QuestionRepository(AppDatabase.instance)`（与 `app.dart` 根组件用的同一个单例库）；测试用 override 替换它。 | 全应用 |
| `lib/state/settings_notifier.dart` | `settingsProvider` + `SettingsNotifier`：设置状态。状态是 `AppSettings`，唯一真源仍是 SQLite 的 `settings` 表，本 Provider 只做“响应式读取 + 写回”，不另存一份。常驻，不 autoDispose。 | 设置页 / 根组件 |
| `lib/state/home_provider.dart` | `homeProvider`：首页状态（焦点卡、继续上次、学科速览读数）。页面独占，autoDispose。 | 首页 |
| `lib/state/report_provider.dart` | `reportProvider`：学习报告状态。页面独占，autoDispose。 | 学习报告 |
| `lib/state/subjects_notifier.dart` | `subjectsProvider`：学科管理状态（学科 / 知识点树 / 标签 / 试卷）。页面独占，autoDispose。 | 学科管理 |
| `lib/state/wrongbook_notifier.dart` | `wrongbookProvider` + `wrongbookInitialProvider`：错题本状态（书架 / 目录 / 列表、批量操作、文件夹拖动排序）。页面独占，autoDispose。 | 错题本 |
| `lib/state/review_notifier.dart` | `reviewProvider` + `reviewInitialProvider`：复习状态（错因队列、四步会话、自查、复查）。页面独占，autoDispose。 | 复习 |
| `lib/state/organize_notifier.dart` | `organizeProvider`：整理工作台状态（队列、表单、批量操作）。页面独占，autoDispose。 | 整理工作台 |
| `lib/state/detail_notifier.dart` | `detailProvider` + `detailInitialProvider`：题目详情状态（当前题、错因记录、解决记录、编辑表单、重新框选）。页面独占，autoDispose。 | 题目详情 |
| `lib/state/collect_notifier.dart` | `collectProvider`：收集中心状态（任务列表、导入、拆题确认、删除任务）。页面独占，autoDispose；修框状态（框选 / 缩放 / 旋转）是纯 UI 临时状态，留在 `box_editor.dart` 本地，不进 Provider。 | 收集中心 |
| `lib/state/badge_counts_provider.dart` | `badgeCountsProvider` + `BadgeCounts`：左导航三枚角标（收集 / 整理 / 复习）+ 学科速览读数。根节点常驻，**绝不 autoDispose**；只订阅 `DataChangeBus`，见 §六。 | 根组件 |

规则（D-36）：页面独占的 Provider 用 autoDispose（回页重读）；
常驻监听的（`settingsProvider`、`badgeCountsProvider`）不用。
`lib/data/data_change_events.dart` 是纯 Dart 的事件总线（不 import
riverpod），见 §六。

依赖方向（方案 §四白名单）：`flutter_riverpod` 的 import 只出现在
`lib/state/`、`lib/modules/`（页面）、`lib/app.dart`、`lib/main.dart`。
`lib/data/`、`lib/services/` 不 import 它——Repository 不知道 Provider 的存在。

## 二、状态在哪

- **业务设置**（主题 / 字号 / 问候语 / 复习参数 / 错题本默认值 / 启动页）：
  在 `settingsProvider` 里。读用 `ref.watch(settingsProvider)`，
  写用 `ref.read(settingsProvider.notifier).saveSettings(s)`——
  写库成功后 state 才更新，写库失败 state 保持旧值。
- **考试事件列表**：懒加载的页面本地展示状态（只在考试组打开时读），
  但增删改同样走 Notifier 的 `addExamEvent` / `renameExamEvent` /
  `changeExamEventDate` / `deleteExamEvent`（不直接调 `repo`）。
- **页面本地 State**（不进 Provider）：折叠组展开/收起、输入框内容、
  迁移进度、缓存预览、恢复待确认文件等纯界面临时状态，仍在
  各页的 State 里；路由、Navigator、提醒弹窗等应用级临时状态
  仍在 `QuizMasterApp` 的 State 里。角标不在应用 State 里——
  见 `badgeCountsProvider`（§六）。
- **各页的业务状态**：每页一个 Notifier / Provider（见 §一的表），
  状态唯一真源仍是 SQLite，Provider 只做响应式读取 + 写回，
  不另存一份、不改 Schema、不增删功能。改动口全部是具名方法
  （不用泛型 `update(copyWith)`）。文本控制器留页面本地；
  切题 / 刷新时 Notifier 把 `formResetKey` 加一，页面按它变化、
  下一帧把控制器文本按当前题重建（整理页、详情页同款）。
- **角标**：Stage 4 已接管到 `DataChangeBus` +
  `badgeCountsProvider`（见 §六）；`badgeVersion` /
  `_refreshBadges` 手动链已删除。

## 三、谁在读同一个 Provider

- `lib/main.dart`：`runApp` 外包一层 `ProviderScope`，整应用共用一个容器。
- `lib/app.dart`：根组件是 `ConsumerStatefulWidget`，`build` 里
  `ref.watch(settingsProvider)` 拿主题 / 深浅色 / 字号；设置首次读到时
  解析一次启动路由（`_onSettingsReady`：`lastRoute` + `startupPage`，
  只跑一次，之后改设置不再重解析；用户在它执行前已点导航时不抢路由，
  见 `_userNavigated` 注释）。
- `lib/modules/settings/settings_page.dart`：`ConsumerStatefulWidget`，
  `build` 里 `ref.watch(settingsProvider)` 读设置；`_apply` 只调
  `notifier.saveSettings(s)`，不再自己 `setState`——Provider 重建会把
  新值带回来（`_s` 是 Provider 值的本地镜像，build 里同步）。
- 其他 8 个页面：全部已迁移（Stage 2–3），外壳是 `StatefulWidget`、
  只包一层 `ProviderScope(overrides: [repositoryProvider.overrideWithValue(widget.repo)])`
  （有初始入参的页另加 `XxxInitialProvider` 的 override，见
  `wrongbook` / `review` / `detail`）；内层是 `ConsumerStatefulWidget`，
  业务经 Notifier 方法交回去，`setState` 只剩纯界面状态。
  构造参数不变（`repo` + 回调），widget 测试无需改包裹 / 注入方式。
- 根组件另 `ref.watch(badgeCountsProvider)` 拿三枚角标（stale-while-reloading：
  `.value ?? BadgeCounts.zero`）。

## 四、测试怎么注入

核心就一条：**替换 `repositoryProvider`，不替换 Notifier 本身**
（方案 §三：`overrideWith` 是提供替代 Notifier 的手段，不是绕过
Repository 注入的捷径）。

### 单测（不启动 widget）

```dart
final container = ProviderContainer.test(
  overrides: [repositoryProvider.overrideWithValue(fakeRepo)],
);
addTearDown(container.dispose);
final notifier = container.read(settingsProvider.notifier);
// 调方法：notifier.greetingToSave(...) / notifier.addExamEvent(...)
// 等 Provider 的值：await container.read(settingsProvider.future);
```

见 `test/settings_controller_test.dart`（Stage 0 的 13 个单测已按此迁移，
另新增 3 个 Provider 行为测试：build 读库 / saveSettings 写库并更新
state / reloadSettings 重读）。

### Widget 测试（设置页 / 整应用）

```dart
await tester.pumpWidget(
  ProviderScope(
    overrides: [repositoryProvider.overrideWithValue(fakeRepo)],
    child: MaterialApp(home: Scaffold(body: SettingsPage())),
  ),
);
```

- 设置页直 pump 的测试（`settings_page_test.dart`、`p0b1`、`p0b2`、
  `b11_9`、`s8a5`）都已按此改：`SettingsPage` 不再接 `repo` /
  `settings` / `onSettingsChanged` 构造参数；保存的观察点从
  `onSettingsChanged` 回调改到 FakeRepo 的 `settings()` /
  `saveSettings()`（记录每一次保存），断言口径不变。
- 整应用测试（`b8_1_subject_refresh_flow_test.dart`、`b9_3`、`b9_1`）：
  只在 `QuizMasterApp` 外包一层 `ProviderScope`，其余不动；
  Provider 默认接单例库，测试用的内存库照常经
  `AppDatabase.useDatabaseForTest` 注入。

### autoDispose 单测的两条铁律（D-36、D-42）

- 页面独占的 Provider 是 autoDispose：单测里裸 `container.read`
  不保活，Provider 会在约一帧后销毁、首查还没落定——必须
  `container.listen(provider, (_, _) {})` 保活再等首查。
  生产侧不受影响（页面用 `ref.watch`）。
- `build()` 里 `Future.microtask(load)` 的首查可能在页面已离开、
  Provider 已销毁后才跑：`load()` 顶部先判 `_disposed` 再碰
  `ref`；长流程方法在入口处一次性捕获 `repo`，之后不再
  `ref.read`，否则切页快时抛 `UnmountedRefException`。
  批量方法另用 `DataChangeBus.scope()` 包起来只发一个事件。

## 五、恢复备份后设置怎么刷新

恢复可能覆盖整个设置表：设置页确认恢复后调一次
`notifier.reloadSettings()`，从库里重读，根组件与设置页同时看到
恢复后的设置（Stage 0 是 `loadSettings()` + `_apply()` 两步，
现合并为一次 `reloadSettings()`；`loadSettings()` 已删除）。

## 六、写方法 → 变更事件映射表（Stage 4）

角标只订阅 `DataChangeBus`（`lib/data/data_change_events.dart`），
事件只由数据层在**写入成功后**发出，Repository 不持有 Ref、不
import riverpod。`badgeCountsProvider`
（`lib/state/badge_counts_provider.dart`，根节点常驻、绝不
autoDispose）收到含 `badges` 的事件才重读角标计数；`homeProvider`
（`lib/state/home_provider.dart`，D-94）收到含 `recentlyViewed`
的事件才重读首页历史；其余 kind
只供以后各页订阅（A 完成时各页仍自己 `load()`，不订阅事件——
详情页复习记录订阅 `reviewRecords` 是方案的终态，A 收尾时未接线，
已立为单独事项，见 §七，不在 A 内做）。FR-31（2026-11-17）明确：
截至本批，除 `badges` 与 `recentlyViewed` 外的四种 kind（questions /
subjects / reviewRecords / settings）没有任何订阅方；将来加订阅方时把该页的
刷新时序纳入回归。
事件只描述“什么变了”，不携带新数据——订阅方收到后自己重读
SQLite。订阅在初始查询之前建立（先订阅、后首查），`ref.onDispose`
取消订阅；`badgeCountsProvider` 靠 `ref.invalidateSelf()` +
Riverpod 自身的失效语义处理并发重查，未另写代次号（方案 §四
第 3 条的代次号是设计建议，实现侧以 Riverpod 语义替代，B 组
单测“初始化期间写入最终计入”覆盖该场景）。

规则：

- 一次写入只发一个带完整 kind 集的事件；`questionId` 只在事件
  影响单题时有，多题 / 批量 / 恢复时为空。
- 批量提交用 `DataChangeBus.scope()` 包起来：作用域内多次 emit
  缓冲，退出时合并成一个事件（kind 取并集；只有恰好缓冲了一个
  事件时保留其 `questionId`）；作用域内一个事件都没发则不发；
  体内抛错后缓冲的事件仍发出，异常继续外传。
- 写失败 / 回滚不发事件；`recordSelfCheck` 判 `unsure` 不发
  （不计一次自查）。

| Repository 写方法 | 发出的 kind 集 | 备注 |
|---|---|---|
| `save` / `archive` / `toggleFavorite`（→ `upsertQuestion`） | `{badges, questions}` + 题 id |  |
| `delete`（→ `deleteQuestion`） | `{badges, questions, reviewRecords}` + 题 id | 同事务删该题的错因记录与复习历史 |
| `deleteQuestions`（→ `deleteQuestionsBatch`，FR-37） | `{badges, questions, reviewRecords}`，题 id 为空 | 整批一个事务；中途失败整批回滚 |
| `saveRemedy`（→ `updateCauseRemedy`） | `{badges, reviewRecords}` + 题 id |  |
| `setReviewJoined` | `{badges, reviewRecords}` + 题 id | 仅写入成功时；`ok=false` 不发 |
| `recordSelfCheck`（→ `recordSelfCheckTxn`） | `{badges, reviewRecords}` + 题 id | 仅结果不是 `unsure` 时 |
| `joinReviewBatch` / `cancelReviewBatch` | 一次合并 `{badges, reviewRecords}`，题 id 为空 | `scope` 合并；全跳过 / 全失败时不发 |
| `confirmSplit` | `{badges, questions}` |  |
| `replaceQuestionBoxes` / `replaceQuestionBoxesAndSlice` | `{questions}` + 题 id | 原 bump 是防御性的，框本身不计角标 |
| `saveCollectTask`（→ `upsertCollectTask`） | `{badges}` | 仅新建任务或状态变化时（节流保留）；同状态重复保存不发 |
| `deleteCollectTask` | `{badges, questions, reviewRecords}` | 超集：可能连带删一道未整理题 |
| `saveSubject`（→ `upsertSubject`） | `{badges, subjects}` |  |
| `deleteSubject` | `{badges, subjects, questions, reviewRecords}` | 删该科的题、错因记录、任务、文件夹、知识点 |
| `saveFolder`（→ `upsertFolder`） | `{subjects}` | 文件夹本身不计角标 |
| `deleteFolder` | `{badges, subjects, questions, reviewRecords}` | 超集：可能连带删题 |
| `addTag`（→ `insertTag`） | `{subjects}` |  |
| `renameTag` / `deleteTag` | `{subjects, questions}` | 同时改写题目行的标签 |
| `addExam`（→ `insertExam`）/ `renameExam` | `{subjects}` |  |
| `deleteExam` | `{subjects, questions}` | 同时改写题目行的考试 |
| `addKnowledgePoint`（→ `insertKnowledgePoint`）/ `renameKnowledgePoint` / `renameChapter` | `{subjects}` |  |
| `deleteKnowledgePoint` / `deleteChapter` | `{subjects, questions}` | 同时改写题目行的知识点 |
| `saveSettings` | `{settings}` |  |
| `saveExamEvent` / `deleteExamEvent`（→ `saveExamEventFrom` / `deleteExamEventFrom`，FR-38/39） | `{settings}` | 同一事务内改原始 JSON 行；并发写不丢改动、坏行原样保留 |
| `saveBackupFailed` | `{settings}` |  |
| `importBackupJson` / `importBackupZip` / `importBackupZipFile` | 一次含全部六种 kind，题 id 为空 | `importBackupZipFile` 转调 `importBackupZip`，不另发；D-94：恢复覆盖最近查看表，`recentlyViewed` 也在内 |
| `recordQuestionViewed`（→ `AppDatabase.recordQuestionViewed` 扩展方法，D-94） | `{recentlyViewed}` + 题 id | 仅写库成功后发；写库抛错不发；可单测版 `recordQuestionViewedIntoImpl` 不发（纯写库） |
| `syncCauseRecords` | 不发 | 调用方的 `save` 覆盖角标 |
| `saveDraftBoxes` | 不发 | 草稿框不影响角标 |
| `saveReviewState` / `clearReviewState` | 不发 | 仅复习会话内 |
| `saveLastRoute` / `saveLastRecheckReminderDate` / `saveRecentTask` / `saveSetting` | 不发 | 路由记忆 / 提醒日期 / 最近任务标记 |
| `migrateToDirectory` / `setCustomDataDirectory` / `cleanOrphans` | 不发 | 无数据内容变化 / 仅文件操作 |
| `ensureCauseRecords` | 不发 | 仅测试播种用（`test/p2_json_fields_test.dart`），Repository 不暴露、生产不调用；`recordSelfCheckTxn` 事务内写历史不经过它；FR-30 已删 `addCauseCheckHistory` / `deleteCauseRecordsForQuestion` / `deleteCauseRecord`（全仓零调用的死代码） |
| `bumpOrganizedToday`（今日小结计数） | 不另发 | 搭在 `upsertQuestion` 的写路径内，随 `{badges, questions}` 事件一起发出；计数本身不影响角标 |

收尾核对（2026-11-16，D-44）：全仓 30 处 `emit` 逐处核对，
与上表 1:1 对应，无遗漏、无多余；D-94（2026-11-18）：`emit`
处现为 34 处——D-94 只新增 1 处（`recordQuestionViewed` 扩展方法），
备份两处是原有 emit 的 kind 集补齐（五类→六类），上表已同步。`flutter_riverpod` 的 import
只出现在 `lib/state/`、`lib/modules/`、`lib/app.dart`、`lib/main.dart`
（`lib/data/` 只有 `data_change_events.dart` 注释里提到该词，
不是 import）；旧 `_refreshBadges` / `badgeVersion` /
`bumpBadgeVersion` 只剩注释提及，无代码残留。

**D-43 决定（Meng，2026-11-16 16:16，选项 A：接受现状）**：
纯时间驱动的复查到期（无写入）不再随切导航刷新角标，只在下一次
数据事件或应用重启时才刷新。数据变动仍是实时的——写库成功后角标
马上重算，不用切页面。不实现前台恢复重读，不加定时轮询。
详情见 `docs/decision-log.md` D-43 末尾的决定条目。

D-42 同款隐患（`Future.microtask(load)` + 方法内多次 `ref.read`，
页面已离开、Provider 已销毁后抛 `UnmountedRefException`）已按
同一模式修完 8 个已迁移页面的 Notifier：`load()` 顶部先判
`_disposed` 再碰 `ref`；方法入口一次性捕获 `repo`，之后不再
`ref.read`；批量方法另用 `scope` 包起来只发一个事件。

## 七、收尾状态（A 完成，2026-11-16，D-44）

- Stage 0（D-33）→ Stage 1（D-34）→ Stage 2（D-35，D-36 回归修）
  → Stage 3（D-37 复习、D-40 整理、D-41 详情、D-42 收集）
  → Stage 4（D-43 角标接管）→ 收尾（D-44，本条），业务阶段
  全部完成；A+B 期间新功能 / 新设计冻结，未动 pubspec、
  未动 SQLite Schema、未增删功能。
- 收尾验收：`flutter analyze` 0 问题；串行全量测试 1174/1174
  （日志 `~/workspace/a-wrapup-full.log`）；Linux Release 构建
  通过（日志见 D-44）；演示库跑前已备份、跑后核对，结果见 D-44。
- D-43 决定已定（Meng 2026-11-16 16:16，选项 A 接受现状），
  决定记在 `docs/decision-log.md` D-43 末尾。
- **代码未推**：等 Meng 批准才推（由协调员统一报总账）。
  B 的任何阶段均未开始；B Stage 2 仍等 Win11 真机验证，永不跳过。
- 未做事项（单独立项，不在 A 内）：详情页复习记录订阅
  `reviewRecords` 事件——方案的终态，A 收尾时未接线。
  方案见 D-44：详情页 `DetailNotifier` 在 `build()` 里先订阅
  后首查，收到含 `reviewRecords` 且 `questionId` 等于当前题的
  事件时只重读 `records` / `history`（不调全量 `load()`，
  避免冲掉编辑中的表单值与触发切片自愈）；`ref.onDispose`
  取消订阅。做之前先回答：当前单页导航下，详情页打开时没有
  外部写入方会改这道题的复习记录（唯一的写入方就是详情页自己，
  写完已调 `load()`），订阅的实际收益约等于零——是否值得为
  “终态完整”冒编辑态竞态的风险，由 Meng 定。
