# Batch 6 P1 文档口径修复报告（执行员 B-docs：SR2-8 / SR2-9 / SR2-10）

- 分支：`ui-replication`；工作树 `~/workspace/quiz-master2-UI`
- 范围：纯文档改动，未动任何代码；未提交、未推送。
- 依据：`docs/ui-replication/SELF-REVIEW-2.md` 的 SR2-8、SR2-9、SR2-10 各节。
- 日期：2026-11-15

## SR2-8 — 超限口径：只改了决定文档的两处 + 同文件多出的一处

旧说法：“PDF 上限 50MB、图片上限 20MB，超限只提示不硬性拦截 / 不硬拦”。
新说法（与 Batch 5 SR-P1-14 代码一致）：“PDF 50MB / 图片 20MB，超限硬判进失败任务（可先压缩再重选）”。

| 文件:行 | 改动 |
|---|---|
| `docs/quiz-master2-mo-kuai-bian-jie-hua-fen.md:85`（§4.2） | “超限只提示不硬性拦截”→“超限硬判进失败任务（可先压缩再重选）” |
| `docs/decision-log.md:134`（D-15） | “超限只提示不硬拦”→“超限硬判进失败任务，可先压缩再重选” |
| `docs/代码地图.md:477`（收集页 `enqueue` 流程说明） | “PDF 超 50MB、图片超 20MB 只提示不硬拦”→ 同上硬判口径。任务书只列了 :118，但同一文件的同一旧说法顺手一并改了，未碰其他执行员的文件 |

核对证据（只读代码，未改代码）：

- 硬判：`lib/services/import_service.dart:213-225`，注释“SR-P1-14：图片与 PDF 同款硬判，不再只提示不执行”；超限任务进 `failed`，失败文案为“请拆成多个小 PDF 再导入”/“请压缩到 20MB 以内再导入”。文档写的“可先压缩再重选”是该文案的概括，口径一致。
- 事前提示仍在：`import_service.dart:148-152` `oversizeHint()` 未动，现文案为“文件较大（X MB），超过 Y MB 上限，导入会失败。”——这是选文件时的事前提示，与导入时的硬判不冲突，本次未把“提示”改没（四处改动均未触及该定位，边界文档 §4.2 本来也没有写提示句）。

## SR2-9 — `demoQuestions()` 已删：三处文档同步

新说法（三处统一）：“`demoQuestions()` 已于 Batch 5（SR-P2-13）删除；演示题的唯一合法来源是 v1 老库（已整体删除，不迁移）”；`demoExams()` / `demoKnowledgePoints()` 仍在 `_seed` 里用的说法保留不变。

| 文件:行 | 改动 |
|---|---|
| `docs/decision-log.md:35-37`（D-04 末尾补注） | 删“`demoQuestions()` 仅作定义保留，目前没有任何生产调用方”，改写为已删 + 唯一合法来源是 v1 老库；保留“上面 9 道题是演示库 v1（老库）的口径，不是新库的初始内容” |
| `README.md:61-64` | 删“数学/英语/政治各 3 道大学题（`demoQuestions()`，共 9 道）”，改写为已删 + 演示试卷/知识点树（`demoExams()` / `demoKnowledgePoints()`）仍在；保留“新库建库时不预置演示题（§6 第 1 条），种子只写学科/文件夹/标签/试卷/知识点树” |
| `docs/代码地图.md:118`（§2 `demo_data.dart` 行） | 同上改写；保留“新库建库时**不**预置演示题（§6 第 1 条）；种子只写学科、文件夹、标签、试卷、知识点树” |

核对证据（只读代码，未改代码）：

- `lib/data/demo_data.dart:3-8` 注释即 SR-P2-13 的删除说明，与新写口径逐字一致；全仓 `grep demoQuestions lib/` 除该注释外 0 命中。
- `demoExams()` / `demoKnowledgePoints()` 仍在：`lib/data/demo_data.dart:11,54` 有定义，`lib/data/db_schema.dart:272,279` 在 `_seed` 里调用。

## SR2-10 — D-23 两处旧句改写（其余历史句未动）

| 文件:行 | 改动 |
|---|---|
| `docs/decision-log.md:225-227`（D-23 推理约定） | “模型缺失、加载失败或图片文件不存在时回退占位（一页一个整题框），不抛错” → “模型缺失、加载失败或图片文件不存在时返回空框 + `usedFallback: true`，不回占位框，不抛错” |
| `docs/decision-log.md:251-256`（D-23 导入流程段） | “导入流程仍只存文件名（`CollectTask.fileName` 为显示名，未改 Schema）：`detectPage` 按传入路径找文件，找得到跑真实推理，找不到回占位。真实文件落盘 / PDF 渲染仍是待办，见 YOLO 报告。” → “导入已真实落盘（`imports/<task-id>/`，`collect_tasks.source_path` 写库内副本的相对路径，`CollectTask.fileName` 只做显示名）：`detectPage` 按传入路径找文件，找得到跑真实推理，找不到返回空框 + `usedFallback: true`。PDF 由 `pdf_render_service.dart` 按页渲染，见 YOLO 报告。” |

改动说明：第二处把“仍只存文件名”整句换掉——按现行代码 `fileName` 只做显示名仍真，但“只存文件名”已假（`source_path` 写库内副本相对路径），故把真的一半（显示名）保留进新句、假的一半删掉。D-23 其余历史句（如第 2 层暂缓原因、再接入路径）未动。

核对证据（只读代码，未改代码）：

- 空框 + `usedFallback: true`：`lib/services/yolo_onnx_service.dart:45`（“不抛错、不回占位框、不卡住收集流程”）、`:131-132,147,166,180`。
- 真实落盘：`lib/services/import_service.dart:14-20`（§1.4：文件复制进数据目录 `imports/<task-id>/`，`source_path` 写库内副本相对路径，`file_name` 只做显示名；PDF 整本渲染到 `imports/<task-id>/pages/page-001.png`…）。
- PDF 按页渲染：`lib/services/pdf_render_service.dart`（pdfrx_engine / PDFium）。

## 全局核对（grep，改后）

- 旧说法清除：对四份文件 grep `只提示不硬|不硬拦|不硬性拦截|仅作定义保留|回退占位|回占位|仍是待办|目前没有生产调用方` —— 0 命中，只剩一行新写法的误报（`decision-log.md:227` “不回占位框”，属新口径本身）。
- 新说法就位：`硬判进失败任务` 3 处（边界 :85、D-15 :134、代码地图 :477）；`已于 Batch 5（SR-P2-13）删除` 3 处（D-04、README、代码地图 :118）；`usedFallback: true` 2 处（D-23 :227、:255）；`导入已真实落盘` 1 处（D-23 :252）。
- 未改坏其他表述：`demoExams()` / `demoKnowledgePoints()` 仍在的说法在 README :63 与代码地图 :118 均保留；D-23 的 `QuestionBox` 接口、`clampToPage`、第 2 层暂缓段落未动；四份文件均为 UTF-8、无换行符改动。
- 未跑 flutter（纯文档任务）；`git diff` 中四份文件另有大段改动是开工前工作树里已有的其他执行员未提交改动，本次只动了上表所列的 8 处（7 处任务书列明 + 代码地图 :477 顺带）。

## 遗留问题

1. 历史报告里的同款旧说法未动（非 operative 文档，有意保留）：`docs/ui-replication/P0B2-P1-REPORT.md`（“`demoQuestions()` 现无调用方，仅定义保留”）、`B3-DOCS.md`、`SELF-REVIEW-DOCS.md:134-136`、`SELF-REVIEW-DATA.md:109-112`、`SELF-REVIEW-SERVICES.md:25-27`、`S8A4-BANNER-REPORT.md:24`（引用的旧横幅文案“仍可继续导入”）。这些是当时的审查/阶段报告，改写会篡改历史记录；若协调员认为需要统一口径，应另立一项处理，不宜由本次文档修复顺带改。
2. D-07（`decision-log.md:67-71`）仍写“先用占位服务（一页一个整题框……）”，但该条已明确标注“已被 D-23 取代（2026-11-13），仅留作历史”，故未动。
3. “可先压缩再重选”是文档概括：代码的失败文案分两种——PDF 提示“拆成多个小 PDF 再导入”，图片提示“压缩到 20MB 以内再导入”。若后续要逐字精确，可把两处文档改为分述，但当前概括与代码无冲突。
