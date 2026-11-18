# GPT 关口审材料：quiz-master2 十三批 OCR 实现

> 给主代理的说明（不发给 GPT）：用新对话 https://chatgpt.com/c/6afd45b7-3774-83eb-8cd7-cec9fc0f3e54 发下面正文。**必须先打开思考模式再发**；如果该对话提示上下文已满，另开新对话，第一句先说“请先读一下之前的对话和你的记忆。”再发正文。回复里要确认思考模式是开着的。

---

## 正文

背景：Flutter + SQLite（Drift）个人错题本 quiz-master2，面向大学生。十三批把 GLM-OCR 接入应用：导入时自动识别题干（只识别题干、不识别选项），识别对象是 YOLO 框出的单道题裁剪图（发送前每边加 30% 白边），用户只能看到渲染好的公式，LaTeX 源码绝不外露，渲染失败回退原图；Windows 和安卓走统一路线；API key 由用户在设置里自填。GLM-OCR 是此前尖峰验证的最终选择（6 道单题 6/6 全对，平均 1.1 秒/题；政治 8 页正文错 4 字，全是破折号读成“一”），VL-1.6 只是文档里的备用路线，本批代码里没有实现它；SimpleTex 不用。

请你做关口评审，只评 P0/P1（会丢数据、会错写数据、会卡死主流程、安全漏洞、明显错误逻辑）。品味问题请记为已知局限，不要定为 P0/P1。请逐项给结论，通过就说 PASS，不过就指出具体问题和修法。

### 一、本批改动（M1–M6）

**M1 公式渲染**：加 flutter_math_fork 0.7.4（纯 Dart、KaTeX 子集）。实测：真实 GLM 公式 25/25、类型表（分数/根式/上下标/极限/求和积分/三角/矩阵/cases/\text/\mathbb）22/22；中文行内公式对齐偏差 0.02px；长公式横向滚动包装（裸渲染会抛 overflow）；非法公式自动回退原图、不抛错、不泄漏源码。\textcircled{n} 预处理成 ①–⑳（只在命令位置确定性转换，1–20，超出保留原命令进回退）。统一渲染接口：TextBlock / FormulaBlock / ImageFallbackBlock / CodeBlock（代码段按等宽文本显示）。新文件 lib/modules/ocr/question_content.dart、question_content_renderer.dart。

**M2 数据库 v3→v4 迁移**：questions 加 5 列（ocr_raw、ocr_stem、ocr_split_status 默认“未切分”、ocr_manual_edited、content_version）；新建 ocr_jobs 表 14 字段（id、question_id、crop_path、input_hash、status、attempt_count、available_at、started_at、lease_until、last_error_code、last_error_message、created_at、updated_at、completed_at）+ 2 索引。onUpgrade 用 customStatement 手写 DDL，迁移后与全新 v4 库逐字一致（测试锁定）。备份互通：导出/校验/导入同时接受 sv 2/3/4；校验按每张表的真实主键列（recently_viewed_questions 的主键是 question_id，没有 id 列）。

**M3 OCR 客户端 + 后台队列**：Dart HttpClient 调 POST https://open.bigmodel.cn/api/paas/v4/layout_parsing，body {"model": "glm-ocr", "file": "<data URI>"}，Authorization: Bearer <key>。key 从 flutter_secure_storage 读（键名 bigmodel_api_key，Windows 实现走 AES-GCM + 凭据管理器）。发送前每边 +30% 纯白边（内存里做）；取 md_results 做文本，layout_details 原样存进 ocr_raw；入库前校验 LaTeX 括号平衡。单 worker 顺序处理，并发 1，异步；确认分框后入队；应用启动恢复未完成任务；租约 5 分钟；最多 4 次总请求（首次 + 3 次重试），指数退避 30→60→120 秒封顶 5 分钟；429 优先尊重 Retry-After；只重试网络断开/连接超时/请求超时/429/5xx，key 缺失或无效、图片损坏、参数错误、文件不存在不重试；没 key 只排队（available_at +10 分钟，不记 attempt、不写 failed）；超时连接 15 秒、单次请求 120 秒。应用结果前必查三项：切片 hash 与 input_hash 一致、题目仍存在、content_version 与领取时一致；任一不符不自动覆盖。迟到的 OCR 结果绝不能覆盖用户手动改过的内容：ocr_raw 恒写最新原始结果（JSON 包，内含 has_unseen_candidate 标志），ocr_stem 只在安全时写；判定只用 hasPendingOcrCandidate() 读标志，不比文本。content_version 规则：每次 OCR 自动应用 +1，人工编辑保存时 +1，其他保存不碰。完成/失败后发 DataChangeBus 事件（questions kind）。

**M4 题干切分（保守启发式，纯函数 splitStem）**：标记格式 A. A． A、 A) A） (A) （A） 全角Ａ，选项支持 A–E；只有 A→B 顺序明确、格式一致、标记后有实际内容、A 在选项起始位置（行首/≥2 空格栏位/括号式前有空白）、B 在 A 之后 2 行内，才切；C/D/E 是更强证据但非必要；只出现 A 不切；多个候选切分点标“存在歧义”、整段保留；没选项标记整段当题干；①②③④、(1)(2)、( ) 空格不参与切分；开头题号不盲删。存原始 OCR + 题干 + 切分状态（未切分/自动切分/存在歧义/人工调整）。

**M5 纠错 UI（整理工作台 + 详情页，共用一套编辑器）**：整理页在切片图正下方、详情页在题目图下方，原地展开不跳页。按钮“编辑题干”（主操作）+“重新识别”（次要）。状态 7 态推导：已手动修改 > 识别中（无 key 时绝不显示，改显示“等待设置 API Key”）> 稍后自动重试 > 等待识别 > 识别失败 > 识别完成；候选标志另显“有新的识别结果”横幅。编辑器：普通文字直接改；公式块可看、可删、可恢复为原图（按 layout_details bbox 裁公式小图，裁不到用整张切片）；代码段等宽、缩进保留；重新识别产生新候选，用户预览新旧再确认替换；正在编辑时 OCR 回来了不许强行刷掉编辑器，只显横幅。保存规则：人工编辑保存（版本+1、人工标记、切分“人工调整”、清候选）；接受候选（重跑 splitStem 写回切分、人工标记保持 1、版本+1、清标志）；忽略候选只清标志、版本+1。活页内刷新守门：编辑中题的事件绝不调 refresh()/loadForm()/load()，只无状态取候选、只显横幅；别题只刷 OCR 状态行，表单值与 formResetKey 不动。详情页重新框选成功后自动为新切片建 OCR 任务（fire-and-forget，旧结果由哈希校验丢弃）。

**M6 设置**：设置页“数据”组末尾加 BigModel key 项：密码式输入框 + 保存/清除 + “已设置/未设置”状态行（只调 hasApiKey()，不调用 getApiKey()，key 值永不显示、不记日志）；空串保存视为清除；保存后立即清空输入框；存入非空 key 后调 worker 的 kick() 唤醒。

### 二、测试证据

- 全量测试 **1644/1644**（基线 1438 + 新增 206：M1 69 + M2 新 17 + M3 37 + M4 34 + M5 41 + M6 8），flutter analyze 0 问题，Linux Release 构建通过，演示库 md5 不变（标准 v1，9 道题）。
- 真机调用验证（helper 走代理认证，2 次）：单题 1.9 秒/289 tokens、英语题 1.2 秒/107 tokens，md 与尖峰首轮逐字一致。
- 泄漏检查通过：无硬编码 key；getApiKey() 只在客户端拼 Authorization 头与队列判有无 key 处调用，设置页不调用；复制只走 PNG 字节；ocr_raw 只内部解析；VL-1.6 仅 2 处注释提到报告文件名、无实现；SimpleTex 0 命中。

### 三、已知局限（不用定为 P0/P1，除非你认为它们实际是）

1. GLM 已知弱点：破折号读成“一”（政治腿 4 错全是它），不做后处理，靠纠错入口兜底。
2. 一框两题（如双栏听力 Q6+Q7 在一个框里）切分判“存在歧义”、整段保留，等上游拆框或人工处理。
3. 实测 GLM 样本里没有 formula 块，公式恢复为原图通常走整张切片回退，不是裁出的公式小图。
4. 渲染只在 Linux 上实测；\text{} 里中文、①②③④ 字形、长公式滚动手感、深色主题须 Win11/安卓真机目视。
5. 保存 key 后 kick worker 的整条链路未做端到端单测（测试环境下 worker 未启动），待真机观察。
6. Ratex（Rust 公式渲染）未 POC：flutter_math_fork 覆盖率已够，触发条件未满足。

### 四、请重点看的点

1. 候选机制（ocr_raw 包内 has_unseen_candidate 标志 + hasPendingOcrCandidate 判定）有没有丢候选、误报候选、或让 OCR 结果覆盖人工编辑的漏洞？
2. 队列的租约、退避、错误分类、hash 三项校验有没有竞态或死任务（永远跑不完也永远不失败的任务）？
3. 切分保守策略有没有误删题干的场景？“存在歧义”整段保留会不会让选项混进题干显示？
4. 守门规则有没有漏掉的刷新路径（编辑中表单被重置）？重框自动重识别 fire-and-forget 会不会静默丢任务？
5. key 与 LaTeX 有没有泄漏路径（日志、报错、复制、备份、状态显示）？
6. v3→v4 迁移与备份互通（sv 2/3/4）有没有丢数据或把坏备份放行的口子？
7. flutter_secure_storage 10.3.4 在 Windows 上的使用有没有问题（Win11 构建须装 C++ ATL 库已确认）？

请逐条回答，给出明确结论：PASS，或 P0/P1 + 具体修法。
