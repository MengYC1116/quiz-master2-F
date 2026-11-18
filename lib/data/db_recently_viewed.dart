// 十二批功能 4（D-91）：首页历史——最近查看的题。
// 与 database.dart 同一库（part of），共享库私有成员。
// 新表 recently_viewed_questions（question_id TEXT PRIMARY KEY,
// viewed_at INTEGER NOT NULL，毫秒时间戳）：同一题只留一条，
// viewed_at 更新为最后一次浏览时间；最多留最新 30 条。
// 本文件只管这张表：记录 + 读最新 30 条（联表 questions，
// 已删题内联跳过）。读/写都走 Drift 类型化查询，不写 SQL 字符串。

part of 'database.dart';

/// 十二批功能 4：首页历史最多保留的条数（D-91：最近 30 道）。
const int recentlyViewedMaxEntries = 30;

/// 十二批功能 4：记一次查看（可单测版，直接对传入的库句柄写，
// 不碰单例）。同一题只留一条：同 question_id 再次记录时
// viewed_at 更新为最后一次；写完后剪到最新 30 条（按 viewed_at
// 倒序留前 30，多的删掉）。[viewedAtMillis] 仅供测试定时间，
// 生产调用不传（取当前毫秒时间戳）。
Future<void> recordQuestionViewedIntoImpl(
  QuizDatabase db,
  String questionId, {
  int? viewedAtMillis,
}) async {
  final now = viewedAtMillis ?? DateTime.now().millisecondsSinceEpoch;
  await db.transaction(() async {
    await db
        .into(db.recentlyViewedQuestions)
        .insert(
          RecentlyViewedQuestionsCompanion.insert(
            questionId: questionId,
            viewedAt: now,
          ),
          mode: InsertMode.insertOrReplace,
        );
    // 剪到最新 30 条：按 viewed_at 倒序，30 名开外的删掉。
    // viewed_at 相同的边界并列时顺序由库定——同毫秒内连看两题
    // 的先后本就无意义，不影响“最新 30 条”的口径。
    final rows =
        await (db.select(db.recentlyViewedQuestions)..orderBy([
              (t) => OrderingTerm(
                expression: t.viewedAt,
                mode: OrderingMode.desc,
              ),
            ]))
            .get();
    if (rows.length > recentlyViewedMaxEntries) {
      for (final stale in rows.sublist(recentlyViewedMaxEntries)) {
        await (db.delete(db.recentlyViewedQuestions)..where(
              (t) => t.questionId.equals(stale.questionId),
            ))
            .go();
      }
    }
  });
}

/// 十二批功能 4：读最近查看的题（可单测版，直接对传入的库句柄读，
// 不碰单例）。内联 questions：已删的题没有联表行，自然跳过；
// 最新在前，上限 30 条。已归档 / 已掌握的题照常返回（详情页
// 自己处理归档显示，读侧不过滤）。
Future<List<({Question question, DateTime viewedAt})>>
recentlyViewedQuestionsIntoImpl(QuizDatabase db) async {
  final query = db.select(db.recentlyViewedQuestions).join([
    innerJoin(
      db.questions,
      db.questions.id.equalsExp(db.recentlyViewedQuestions.questionId),
    ),
  ]);
  query.orderBy([
    OrderingTerm(
      expression: db.recentlyViewedQuestions.viewedAt,
      mode: OrderingMode.desc,
    ),
  ]);
  query.limit(recentlyViewedMaxEntries);
  final rows = await query.get();
  return rows
      .map(
        (row) => (
          question: _questionFromDb(row.readTable(db.questions)),
          viewedAt: DateTime.fromMillisecondsSinceEpoch(
            row.readTable(db.recentlyViewedQuestions).viewedAt,
          ),
        ),
      )
      .toList();
}

extension AppDatabaseRecentlyViewed on AppDatabase {
  /// 十二批功能 4：记一次查看（同一题只留一条，时间更新为最后一次；
  /// 超过 30 条时剪掉最旧的）。详情页打开成功后调（见
  /// `DetailNotifier.load`，调用方包 try/catch，记录失败不拖垮加载）。
  /// D-94：写库成功后发一次 `recentlyViewed` 事件（写后发，不是写前；
  /// 写库抛错时不发），首页收到后重读历史。`emit` 本身不抛；
  /// 订阅方回调里调 `HomeNotifier.load()`，`load()` 自己有 try/catch，
  /// 订阅侧异常不反噬到这里。
  Future<void> recordQuestionViewed(
    String questionId, {
    int? viewedAtMillis,
  }) async {
    final d = await db;
    await AppDatabase.recordQuestionViewedInto(
      d,
      questionId,
      viewedAtMillis: viewedAtMillis,
    );
    DataChangeBus.instance.emit(
      DataChangeEvent(
        kinds: {DataChangeKind.recentlyViewed},
        questionId: questionId,
      ),
    );
  }

  /// 十二批功能 4：读最近查看的题（最新在前，最多 30 条；
  /// 已删题跳过；已归档 / 已掌握的题照常返回）。
  Future<List<({Question question, DateTime viewedAt})>>
  recentlyViewedQuestions() async =>
      AppDatabase.recentlyViewedQuestionsFrom(await db);
}
