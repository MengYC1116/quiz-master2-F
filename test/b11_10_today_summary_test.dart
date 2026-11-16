// Batch 11 第 10 项：整理队列为空时的“今日小结”行（最小版）。
// 覆盖三段：
// 1. 口径纯函数（settings 值 `yyyy-MM-dd|N` 的读 / +1）；
// 2. 真库：未整理→已整理的跃迁才 +1（新行直接已整理、重复保存不计；
//    跨天读 0；经仓库读同一数）；
// 3. Widget：队列已空才显示该行，两个数按假实现的值拼出来；队列非空
//    与从未有题时不显示；确认最后一道后空状态出现该行。
// 口径（写死，见 db_settings.dart 的 organizedToday* 注释）：
// N1 = 当天（本地日期）内经整理确认（含队列批量确认）由未整理变为
// 已整理的题数；N2 = 待复习题数，与首页焦点卡 / 复习角标同一口径
// （repo.dueToday：手动加入、已整理、未治愈或到复查时间，数题不数
// 错因）。只这一行，不加本周累计与连续天数。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';

import 'organize_page_test.dart'
    show FakeOrganizeRepo, pumpOrganize, q, threeQuestionRepo;

void main() {
  group('B11-10 今日小结：口径纯函数', () {
    final today = DateTime(2026, 11, 15, 10, 30);
    final tomorrow = DateTime(2026, 11, 16, 9, 0);

    test('无行 / 空串 / 坏值都读 0', () {
      expect(organizedTodayCountFromValue(null, today), 0);
      expect(organizedTodayCountFromValue('', today), 0);
      expect(organizedTodayCountFromValue('abc', today), 0);
      expect(organizedTodayCountFromValue('2026-11-15|x', today), 0);
      expect(organizedTodayCountFromValue('2026-11-15|3|4', today), 0);
    });

    test('当天的值读出 N；昨天的按 0 读', () {
      expect(organizedTodayCountFromValue('2026-11-15|3', today), 3);
      expect(organizedTodayCountFromValue('2026-11-14|5', today), 0);
      expect(organizedTodayCountFromValue('2026-11-15|3', tomorrow), 0);
    });

    test('+1：无行从 1 起；当天接着加；跨天从 1 重新计', () {
      expect(bumpOrganizedTodayValue(null, today), '2026-11-15|1');
      expect(
        bumpOrganizedTodayValue('2026-11-15|3', today),
        '2026-11-15|4',
      );
      expect(
        bumpOrganizedTodayValue('2026-11-14|5', today),
        '2026-11-15|1',
      );
      expect(
        bumpOrganizedTodayValue('坏值', today),
        '2026-11-15|1',
      );
    });
  });

  group('B11-10 今日小结：真库跃迁计数', () {
    Question dbQuestion(String id, {bool isOrganized = false}) => Question(
          id: id,
          title: '题 $id',
          subjectId: 'math',
          createdAt: DateTime(2026, 11, 15),
          isOrganized: isOrganized,
        );

    test('未整理→已整理 +1；重复保存不计；第二道再 +1', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(() async => db.close());
      final repo = QuestionRepository(AppDatabase.instance);
      // openForTest 只建表不设单例：仓储读要走单例，先指过去。
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());

      await AppDatabase.upsertQuestionInto(db, dbQuestion('q1'));
      expect(await repo.organizedTodayCount(), 0);
      await AppDatabase.upsertQuestionInto(
        db,
        dbQuestion('q1', isOrganized: true),
      );
      expect(await repo.organizedTodayCount(), 1);
      // 已整理题的重复保存（改答案）不计。
      await AppDatabase.upsertQuestionInto(
        db,
        dbQuestion('q1', isOrganized: true),
      );
      expect(await repo.organizedTodayCount(), 1);
      await AppDatabase.upsertQuestionInto(db, dbQuestion('q2'));
      await AppDatabase.upsertQuestionInto(
        db,
        dbQuestion('q2', isOrganized: true),
      );
      expect(await repo.organizedTodayCount(), 2);
    });

    test('新行直接以已整理入库不是一次整理动作，不计', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(() async => db.close());
      await AppDatabase.upsertQuestionInto(
        db,
        dbQuestion('q1', isOrganized: true),
      );
      expect(
        await AppDatabase.loadOrganizedTodayFrom(db),
        0,
      );
    });

    test('跨天读 0；指定 now 可读昨天的数', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(() async => db.close());
      final today = DateTime(2026, 11, 15, 10, 0);
      final yesterday = DateTime(2026, 11, 14, 10, 0);
      await AppDatabase.bumpOrganizedTodayInto(db, now: yesterday);
      await AppDatabase.bumpOrganizedTodayInto(db, now: yesterday);
      expect(
        await AppDatabase.loadOrganizedTodayFrom(db, now: yesterday),
        2,
      );
      expect(
        await AppDatabase.loadOrganizedTodayFrom(db, now: today),
        0,
      );
    });
  });

  group('B11-10 今日小结行（widget）', () {
    testWidgets('队列已空：显示“今天整理了 3 道、待复习 2 道”',
        (tester) async {
      final repo = FakeOrganizeRepo(
        questions: [q('q1', '函数极限', isOrganized: true)],
        folderList: const [],
      )
        ..organizedTodayValue = 3
        ..dueTodayValue = [
          q('d1', '导数综合', isOrganized: true),
          q('d2', '阅读主旨', subjectId: 'english', isOrganized: true),
        ];
      await pumpOrganize(tester, repo: repo);
      expect(find.text('都整理完了，去复习吧'), findsOneWidget);
      expect(find.text('今天整理了 3 道、待复习 2 道'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('队列非空时不显示小结行', (tester) async {
      await pumpOrganize(tester, repo: threeQuestionRepo());
      expect(find.textContaining('今天整理了'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('从未有题时不显示小结行', (tester) async {
      await pumpOrganize(
        tester,
        repo: FakeOrganizeRepo(questions: [], folderList: []),
      );
      expect(find.text('没有待整理的题目'), findsOneWidget);
      expect(find.textContaining('今天整理了'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('确认最后一道后，空状态出现小结行', (tester) async {
      final repo = FakeOrganizeRepo(
        questions: [q('q1', '函数极限')],
        folderList: const [
          Folder(id: 'f1', name: '试卷', subjectId: 'math'),
          Folder(id: 'f2', name: '平时作业', subjectId: 'math'),
        ],
      );
      await pumpOrganize(tester, repo: repo);
      await tester.ensureVisible(find.text('平时作业').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('平时作业').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认整理，去下一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认整理，去下一道'));
      await tester.pumpAndSettle();
      expect(find.text('都整理完了，去复习吧'), findsOneWidget);
      // 假实现返回 0 / 空，所以行显示 0 道、0 道；真实计数由真库
      // 用例覆盖（跃迁才 +1）。
      expect(find.text('今天整理了 0 道、待复习 0 道'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
