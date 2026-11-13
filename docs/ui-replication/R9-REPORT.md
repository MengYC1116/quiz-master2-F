# R9-REPORT — 学习报告页重建

- 分支：`ui-replication`（基线 `0c81217242c20fa4438e04db4ebabc92f2c0ddd1`）
- 视觉基准：`~/workspace/your_files/quiz-master2-jiao-hu-yuan-xing/quiz-master2-jiao-hu-yuan-xing.html`，SHA256 `18c8c43485a7831cec22e3d4fff659d7ea39754219b391874f0c5a88f50135e1`（动手前已核对一致）
- 状态：完成并验证通过；未 commit、未 push。

## 0. 本轮起点

任务开始时学习报告页是基线实现（`lib/modules/report/report_page.dart` 328 行，Material 风格），与 HTML 学习报告页（`viewReport`，R0 附录 A）有五处结构偏差：

1. 基线弱点按错因 / 知识点单独分组，HTML 按「学科 × 错因 / 学科 × 知识点」分组，行带序号圆、题名明细与计数；
2. 基线弱点组含已解决的错因 / 已解决题的知识点，HTML 只含待解决的；
3. 基线无范围说明、无核心数条（只有三行纯文字）、无「接下来练什么」句式（基线是自创长句），HTML 有 `.rpt-core` 三格数字条 + `.rpt-sug` 一句话；
4. 基线学科分布是自创的「N 道题 · 已解决 N 个错因 · 待解决 N 个错因」，HTML 只有「学科 · N 道错题」纯文字行；
5. 基线点弱点行只传错因 / 知识点进错题本，HTML 打开对应学科那本并按错因 / 知识点筛好。

直接按 HTML 结构重写。环境工具链曾丢失（ninja / GTK 开发包 / xdotool / ImageMagick 不在），按 R0 §7 的办法恢复，见 §7。

## 1. 修改文件清单

| 文件 | 改动 |
|---|---|
| `lib/modules/report/report_page.dart` | 重写（328 → 806 行）：HTML 结构的学习报告页（见 §3）；三个核心数的算式沿用基线不动（见 §3 口径对照表）；弱点与分布按 HTML 口径重算（见 §3）；新增 `_WeakGroup` / `_CoreCell`，页内边距已去掉（`EdgeInsets.zero`，落到 app 壳的 26/30） |
| `lib/app.dart` | 只改 `_goWrongbookFiltered`：加 `subjectId` 参数，点弱点行时同时把学科带进错题本（`_subjectArg`）；其余不动 |
| `lib/theme/design_tokens.dart` | 新增 R9 学习报告度量块 30 个常量：范围条 / 核心数条 / 建议句 / 弱点行 / 两列 / 看更多 / 分布行（见 §3）；其余复用已有 token（分区小标题、按钮、空状态、横幅等） |
| `test/report_page_test.dart` | 新增 22 个测试（456 行，见 §4） |
| `docs/ui-replication/run-shots-r9.sh` | 新增：probe（首页 × 三档字号 + 报告默认态）/ normal（亮/深 × 标准/大/特大 6 张）/ states（本月、本月展开、空态、复查通过率、点行进错题本 5 张） |
| `docs/ui-replication/run-regress-r9.sh` | 新增：首页 → 学习报告 → 点弱点行 → 错题本目录 → 点“全部题目”（按错因筛好的列表）→ 回首页（5 张） |
| `docs/ui-replication/shots/r9/html-shots-r9.cjs` | 新增：Playwright 截 HTML 原型报告页亮/深默认态 + 本月展开 + 空态 + 错误态，共 5 张（只截 `.win` 应用框，截图前去掉介绍头与 toast；空/错态点 proto-bar 状态按钮切换，见 §5 脚本调试记录） |
| `docs/ui-replication/shots/r9/make-compare-r9.py` | 新增：R8 脚本复制，标签字体 Noto Sans CJK |
| `docs/ui-replication/shots/r9/scan-nav.py` | 新增：像素扫描定位——从探针首页截图找左导航各文字行的 Y 中心（导航“学习报告”Y 校准用） |
| `docs/ui-replication/shots/r9/probe-month-scroll.sh` | 新增：一次性探针——打开报告 → 点“本月” → 向下滚 4 次 → 截图（“看更多”按钮坐标校准用） |
| `docs/ui-replication/shots/r9/` | 截图 31 张 PNG（22 张 Flutter + 5 张 HTML + 4 张对照图） |

未动：其他八页主体、`lib/data`、`lib/models` 的业务语义、`pubspec.lock`、数据库 Schema、`app_icon.ico`；R0 §6-B 业务问题、R8 未解决问题均未顺手改；导航选中项黑/白 pill 是 R2 外壳既有行为（见 §6 第 9 条），R9 未动 `app_shell.dart`。

## 2. git diffstat

R1–R9 均未提交，`git diff --stat` 为相对基线的累计值（11 个已追踪文件，+11899/−4414）。R9 直接相关的部分：

```
lib/modules/report/report_page.dart | 675 +++++----（基线 328 行重写 → 806 行；R1–R8 未动过此文件，全部是 R9）
lib/theme/design_tokens.dart         | 未追踪新文件（R1 建；R9 加 30 个报告度量常量）
test/report_page_test.dart          | 456 行（未追踪新文件，22 个测试）
lib/app.dart                         | R9 只改 _goWrongbookFiltered 一处（+subjectId 参数，约 +7/−5；
                                     | 其余 diff 为 R1–R8 累计值）
docs/ui-replication/               | 未追踪（R9 新增 run-shots-r9.sh / run-regress-r9.sh / shots/r9）
```

## 3. 结构与 token 来源

- **页结构（HTML 顺序）**：标题 `学习报告`（24px/800，无 psub——R0 附录 A2 定为设计说明，R8 同款做法只留标题）→ 时间范围条（`QmSegmented` 本周/本月/全部 + 范围说明 `本周 · 11-9 ~ 11-13 · 数字按这个时间段算`）→ `有没有效果`（核心数条）→ `接下来练什么`（一句话，无按钮）→ 弱在哪（两列：最常错的 5 个原因 / 最常错的 5 个知识点）→ `错在哪个学科（只按学科看）`（纯文字行）。窗口宽 ≤1102px 时两列变单列（与整理工作台共用 `organizeGridBreakpoint` 同一断点值，widget 测试覆盖 900px 窄窗口）。
- **核心数条**（`.rpt-core` / `.rpt-num`）：上边 2px line、下边 1px line、格间 1px 左边；数字 30px/800、标签 14px/700、小字 12.5px muted。已解决小字用真实 `cureChecks` 设置值（默认 2 次，与 HTML 文案一致）；复查小字用真实 `recheckIntervalDays`（默认 7 天）与真实复查次数；无复查记录时数字显示 `—`（HTML 写法，基线是“暂无复查记录”文字）。
- **弱点行**（`.rpt-row`）：序号圆 26px（accent-soft 底 / accent-text 字）、标题 `学科 · 错因/知识点`（学科名 800 号 subjectInk 色）、明细题名用 `、` 连接（单行省略）、计数 `N 道题` / `还没解决 N 道`（800）、`›` 文字符号；整行可点（InkWell，悬停 surface-2）。知识点明细是 `学科 › 章节 · 题名`。各显示 5 条，超 5 条出 `看更多（共 N 个）`小按钮，展开后变 `收起`；切换范围时收起（HTML 行为）。
- **点行跳转**：回调加 `subjectId`，`app.dart` 同时把学科带进错题本；错题本以 `initialSubjectId` 进对应学科的目录页、错因/知识点筛选预置，进列表后生效（R6 既有行为，回归截图验证：点数学·计算错误 → 数学目录页 → 点“全部题目” → 筛选（已选 1），只剩定积分题）。
- **空态**：没有任何错因记录时出 `QmEmptyState`（小伙伴 + `还没有复习记录，先去复习吧` + 说明 + `去复习`）；**错误态**：加载抛错时出 `QmBanner` error `报告数据读取失败，已显示上次成功加载的内容。可重启应用后重试。`（可点“知道了”关闭，留住上次成功加载的内容，与 HTML 错误横幅同文案）。
- **Token 来源**：全部颜色取自 `DesignTokens`（深色纸面 `#D8DCE2`、深色主色 `#7FA8D0`，D1/D2 已确认）；组件全部用 UI Kit；文字符号（`›`）不用图标字体；缩放唯一映射 1.00/1.15/1.30，字号只在 app.dart TextScaler 处乘一次，布局尺寸按 `qmScaleOf` 乘一次，不用 Transform.scale；`secttl` 字距沿用 R3/R4 的 `letterSpacing: 0.08` 写法（见 §6 第 12 条）。

### 口径对照（HTML vs Flutter R9）

| 项 | HTML 口径 | Flutter R9 | 状态 |
|---|---|---|---|
| 已解决错因 | 错因已解决且解决日期（cured）在范围内 | 已解决且 `lastCheck` 在范围内（模型无 cured 字段，以 `lastCheck` 为近似；复查通过也会刷新 `lastCheck`） | 近似，见 §6 第 4 条 |
| 待解决错因 | 范围内收集题目的待解决错因 | 全部未解决记录，不按范围过滤 | 基线口径，R0 §6-B-1 待裁决，**未动** |
| 复查通过率 | 范围内 note 以「复查」开头的记录中已解决占比 | 范围内全部已判定自查记录（`review_history` 无备注字段） | 近似，见 §6 第 4 条 |
| 本周 | 今天往前 7 天 | 本周一到今天（基线口径） | 待裁决，见 §6 第 3 条 |
| 弱点原因组 | 学科 × 错因，只含待解决；无记录的错因默认待解决 | 同 HTML（R9 按 HTML 改；基线是按错因分组且含已解决记录） | 已对齐 |
| 弱点知识点组 | 范围内题目、全部错因已解决才排除 | 同 HTML；无错因的题不计入（HTML 字面代码会把它计入，见 §6 第 6 条）；已删知识点的组跳过（见 §6 第 7 条） | 已对齐，2 处有意偏差 |
| 学科分布 | 范围内收集的题目数 / 学科 | 同 HTML（基线是全部有记录的题目，不按范围） | 已对齐 |
| 接下来练什么 | `先解决{学科}的{错因}。`，无待解决时 `这段时间没有待解决的错因，先去复习页把到期的复查做完。` | 同 HTML（基线是自创长句） | 已对齐 |
| 排序 | 题数降序 → 学科顺序 → 错因/知识点中文拼音序 | 题数降序 → 学科顺序 → 码点序（Dart 无中文拼音排序） | 仅并列时顺序不同，见 §6 第 5 条 |

## 4. 测试与构建结果

- `flutter analyze`：**No issues found!**
- `flutter test` 全量：**231/231 通过**（基线 209 + R9 新增 22）。
- `flutter build linux --release`：**成功**，产物 `build/linux/x64/release/bundle/quiz_master2`。
- Flutter/Dart 3.47.9 / 3.13.7，路径 `~/workspace/flutter-install/flutter/bin/flutter`。
- R9 新增 22 个测试（`FakeReportRepo` 全内存覆盖 causeRecords/all/knowledgePoints/settings/reviewHistory，日期一律相对今天取）：核心数（已解决 1 · 待解决 4 · 通过率 67% + 小字）、无复查记录时 `—`、范围说明文案、原因组学科 × 错因分组 + 已解决不出现、知识点组矛盾观 2 道排第一 + 已解决题的知识点不出现、看更多展开 7 条/收起回 5 条、点原因行带学科 + 错因、点知识点行带学科 + 知识点、切“全部”重算（旧题进来、概念不清变 2 道）、分布只按学科、接下来练什么只有一句话无按钮、切换范围收起已展开列表、空态去复习、加载失败横幅 + 关闭、无旧翻卡文案/无导出/无 Icon、亮/深 × 三档无溢出、窄窗口 900px 单列无溢出。

### 本轮发现并已修的两个真问题

1. **核心数格间分隔线不可见**：初版用无高 `Container(width: 1)` 作竖线，Row 里高为 0，分隔线不显示。修复：改为第 2/3 格容器左 border（代码复读发现，修后截图确认）。
2. **测试期望错误**（测试问题，非产品问题）：折叠态只渲染 5 行，断言“概念不清出现 2 次”在折叠态下不成立（政治那组在第 7 行未渲染）。修复：先点“看更多”展开再断言。

## 5. 截图对照（Xvfb 1280×720，真实库 9 题、7 条错因记录、review_history 为空）

截图目录 `docs/ui-replication/shots/r9/`（31 张 PNG：22 张 Flutter + 5 张 HTML + 4 张对照图）。HTML 原型是静态演示数据（9 道题、DEMO_TODAY 2026-11-11），与真实库数字/题名/错因不同——对照只看结构/样式/文案，不逐数比对。真实库本周（周一 11-09 ~ 今天 11-13）数字：已解决 1 · 待解决 6 · 通过率 —；弱点原因 3 行（数学·计算错误 / 英语·方法不会 / 政治·方法不会）、知识点 3 行（数学·定积分应用 / 英语·图表作文 / 政治·矛盾观）；分布数学 1 · 英语 1 · 政治 1；本月原因 8 行、知识点 7 行（矛盾观 2 道排第一），分布各 3 道。

| 截图 | 对照结论 |
|---|---|
| `report-light/dark-standard.png` | ✓ 标题 + 范围条 + 范围说明 + 核心数条（1 / 6 / —）+ 建议句 `先解决数学的计算错误。` + 两列弱点 + 分布行，与 HTML 结构一致；差异：HTML 标题下有设计说明副标题，Flutter 无（R0 附录 A2 + R8 同款做法）；HTML 本周 0 / 8 / —，Flutter 1 / 6 / —（数据与待解决口径不同，见 §3）；HTML 本周 5 行 + 看更多，Flutter 3 行无看更多（范围内题数不同）。 |
| `report-light/dark-large.png`、`report-light/dark-extraLarge.png` | ✓ 三档无溢出；特大档核心数小字换两行、弱点明细省略号正常；特大档左导航学科速览数字换两行、政治行底部裁切（R6 同款既有行为，非 R9 引入）。 |
| `report-month-light-standard.png` / `report-month-expanded-light-standard.png` | ✓ 本月 8 行原因 + 7 行知识点，各显示 5 条 + `看更多（共 8 个）` / `看更多（共 7 个）`；展开后 8 / 7 行全出 + `收起`（左列收起在首屏外，需滚动看，截图里右列收起可见）。与 HTML 本月展开结构一致；差异：并列行顺序不同（HTML 拼音序，Flutter 码点序，见 §6 第 5 条）；HTML 本月 1 / 10 / —，Flutter 1 / 6 / —（待解决口径不同）。 |
| `report-empty-light-standard.png` | ✓ 空态：小伙伴 + `还没有复习记录，先去复习吧` + 说明 + `去复习`，与 HTML 空态结构一致（HTML 空态标题下副标题更短，Flutter 无副标题）。靠临时 `DELETE FROM cause_records` 拍，拍完已恢复。 |
| `report-rate-light-standard.png` | ✓ 通过率 67% + 小字 `复查 3 次，通过 2 次（已解决满 7 天回来复查）`。靠临时插 3 条本周内自查记录拍，拍完已恢复；HTML 演示库无复查记录，无 HTML 对照。 |
| `report-row-to-wrongbook-dark-standard.png` | ✓ 点本周第一行（数学·计算错误）打开数学那本的目录页；回归里再点“全部题目”进列表，筛选（已选 1），只剩定积分题。 |
| `regress/regress-home.png`、`regress-report.png`、`regress-wrongbook.png`、`regress-wrongbook-list.png`、`regress-back-home.png` | ✓ 首页 → 学习报告 → 点弱点行 → 数学错题本目录 → 按错因筛好的列表 → 回首页链路正常；本回归不改库。 |
| `html-report-light/dark.png`、`html-report-month-expanded-light.png`、`html-report-empty-light.png`、`html-report-error-light.png` | ✓ Playwright 截的 HTML 原型报告页（只截 `.win` 应用框，无介绍头、无 toast）。 |
| `compare-default-light/dark.png`、`compare-month-expanded.png`、`compare-empty.png` | ✓ HTML（上）/ Flutter（下）并排对照 4 张。结构/样式/文案一致；剩余差异见本表各行与 §6。Flutter 错误态无真实窗口截图（见 §6 第 8 条），故无 error 对照图。 |

### 截图脚本的坐标校准（教训，写给后续轮次）

- **像素扫描定位法**（R7 定下，R8/R9 再验证）：不要凭缩放后的截图目测。本轮实测中心（标准档 1280×720）：导航“学习报告”Y 312 / 大 341 / 特大 389（`scan-nav.py` 找导航文字带；与 R8 的复习 Y 271/294/334 互相印证）；范围条“本月”段 (344,88)（选中段底色包围盒推算）；本周第一行弱点 (700,407)（行分隔线 439/502/565 定出行高 63）；“看更多”两枚在首屏外——须先向下滚 4 次（每滚约 56px）再点，滚后坐标左 (318,508) / 右 (837,513)（边框像素扫描实测）。
- **“看更多”在首屏外**：本月 5 行弱点占满首屏，按钮在 y≈717 附近、只露 3px，目测不到；须滚动后按扫描坐标点，脚本里已写死“滚 4 次再点”。
- **HTML 截图脚本的状态切换**（`html-shots-r9.cjs` 调试记录）：`render` 不是全局量（原型脚本作用域），`page.evaluate(() => { state='empty'; render(); })` 抛 `ReferenceError: render is not defined`；改成在隐藏介绍头之前点 proto-bar 的 `button[data-state="empty"/"error"]`。
- **Playwright 环境**：与 R8 相同（浏览器在 `~/workspace/.playwright-browsers`，`PLAYWRIGHT_BROWSERS_PATH` 须显式设；模块在 npx 缓存）。
- **工具链恢复**（VM 换机后 ninja / GTK 开发包 / xdotool / ImageMagick 丢失）：`apt-get update` 约 11 分钟（一个 backports 源连不上，用旧索引继续）；`libgtk-3-dev` 因 `libzstd1` hatch1 版本冲突装不上，沿用 R0 的 `apt-get download` + `dpkg-deb -x` 办法，但**目标须是 `/` 而不是 R0 写明的 `/usr`**——deb 内路径是 `./usr/...`，解到 `/usr` 会变成 `/usr/usr`，R0 报告里的写法不准确，R9 实测纠正。另：不要用 `pkill -f quiz_master2` 清理——会匹配到自己的 shell 命令行而自杀；一律按 PID 清理（脚本里已是 PID 方式）。

## 6. 未解决问题

1. **Win11 字体/DPI/窗口尺寸待真机复核，Linux 结果不替代 Win11 验收。** 尤其 Linux 回退字体（Noto Sans/Serif CJK）与 Win11 的微软雅黑/等线行高度量不同，各处 12.5–15px 小字与标签需真机确认无裁切；1280×720 以外窗口尺寸也须真机复核；Windows Release 构建须在 Meng 的 Win11 机器上验证。
2. **待解决错因不按范围过滤**（R0 §6-B-1）：基线口径，R9 未动，等负责人裁决。后果：切范围时“待解决错因”数字不变（本周也显示 6），而弱点与分布会变。
3. **本周定义**：基线是本周一到今天，HTML 是今天往前 7 天；R9 沿用基线，等负责人裁决。周一当天两者一致，其余六天范围说明里的起止日不同。
4. **已解决与通过率是近似口径**：模型无 cured 日期字段，以 `lastCheck` 近似（复查通过会刷新 `lastCheck`，原解决日期丢失）；`review_history` 无复查备注字段，通过率以全部已判定自查记录近似复查记录。真要精确须加字段（改 Schema，不在本轮范围）。
5. **并列排序**：题数相同、同学科时，HTML 按中文拼音序，Flutter 按码点序（Dart 无中文拼音排序）；只影响并列行的先后，不影响 Top 5 的集合。
6. **无错因题目的知识点不计入弱点**：HTML 字面代码会把无错因题的知识点计入弱点 KP（`qcs.length &&` 守卫）；R9 按 HTML 注释“全部错因已解决才排除”的本意排除——无错因的题无错可解，列入“还没解决 N 道”没有意义。如负责人要字面行为，改一行即可。
7. **已删知识点的组跳过**：题目仍引用已删知识点 id 时，R9 跳过该组；基线显示“待补充”一行（多个已删点会坍成一行）。
8. **错误态真实截图不可触发**：加载失败横幅只在 widget 测试覆盖（FakeRepo 抛错），真实应用内无故障注入入口，故无真实窗口错误态截图（同 R8）。
9. **导航选中项呈纯黑（亮色）/纯白（深色）**：R8 截图里同样存在，是 R2 外壳既有行为——代码写的是 `palette.accent` 底，实际渲染却是纯黑/纯白（疑似点击后的焦点高亮盖住底色，原因未定）。R9 未动 `app_shell.dart`，留待另查。
10. **左导航学科速览数字换行**（R6 §6.6 同款既有行为，非 R9 引入）；特大档政治行底部裁切。
11. **标题下无副标题**：HTML 有“只回答三个问题…”副标题，Flutter 未抄（R0 附录 A2 定为设计说明，R8 同款做法）。
12. **分区小标题字距**：沿用 R3/R4 的 `letterSpacing: 0.08` 写法（CSS `.08em` 在 13px 字号下应为约 1px，沿用既有写法保跨页一致）。
13. **R0 §6-B 其余业务问题未动**：学科管理新增学科不同步到首页 / 导航速览（`Subject.all` 写死三科）；设置“启动页”未被消费；通知提醒无调度实现；备份导出不含 4 张表。
14. **分页 / 真实 YOLO / 真实图片切片 / 系统拖放仍未验证**（R9 范围外既有项）。

## 7. 验收后状态

- 真实库已恢复原状：9 道题、7 条错因记录、`review_history` 为空、`review_state` 为空，`themeMode=dark`、`fontSize=standard`；截图备份 `.qm2-r9-backup.db` 已删除；临时清的 `cause_records`、临时插的 `review_history` 均已随备份恢复；`/tmp` 里的临时库备份已删；回归脚本不改库。
- 未 commit、未 push。
