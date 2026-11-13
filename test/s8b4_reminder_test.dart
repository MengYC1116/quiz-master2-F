// S8 B4.1：复查提醒触发条件（纯函数 + 仓库计数）。
// 用 FakeRepo，不碰真实数据库。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/recheck_reminder.dart';

class B41FakeRepo extends QuestionRepository {
  B41FakeRepo() : super(AppDatabase.instance);

  List<Question> questions = [];
  List<CauseRecord> records = [];

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      questions;

  @override
  Future<List<CauseRecord>> causeRecords() async => records;
}

Question _q(String id, {bool joined = true, bool organized = true}) =>
    Question(
      id: id,
      title: '题 $id',
      subjectId: 'math',
      createdAt: DateTime(2026, 11, 1),
      isOrganized: organized,
      reviewJoined: joined,
      sliceKind: 'material',
      sliceText: '题',
    );

CauseRecord _r(String qid,
        {CauseStatus status = CauseStatus.solved, DateTime? recheckDate}) =>
    CauseRecord(
      questionId: qid,
      cause: '概念不清',
      subjectId: 'math',
      status: status,
      solvedCount: 2,
      recheckDate: recheckDate,
      joinedAt: DateTime(2026, 11, 1),
    );

void main() {
  group('shouldShowRecheckReminder', () {
    // 当天 20:00 提醒；演示库里 q-eng-1 有 1 个到复查时间的错因。
    const time = '20:00';
    final after = DateTime(2026, 11, 13, 20, 30);
    final before = DateTime(2026, 11, 13, 19, 30);

    test('开关关掉不提醒', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: false,
              notifyTime: time,
              dueRecheckCount: 1,
              now: after),
          isFalse);
    });

    test('没有到复查时间的错因不提醒', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 0,
              now: after),
          isFalse);
    });

    test('还没到当日提醒时间不提醒', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 1,
              now: before),
          isFalse);
    });

    test('到了提醒时间就提醒', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 1,
              now: after),
          isTrue);
    });

    test('整点那一刻也算到点', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 1,
              now: DateTime(2026, 11, 13, 20, 0)),
          isTrue);
    });

    test('今天已提醒过不再弹', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 1,
              now: after,
              lastRemindedDate: '2026-11-13'),
          isFalse);
    });

    test('昨天提醒过、今天没提醒过，到了时间就弹', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: time,
              dueRecheckCount: 1,
              now: after,
              lastRemindedDate: '2026-11-12'),
          isTrue);
    });

    test('提醒时间写坏了按默认 20:00 算', () {
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: 'abc',
              dueRecheckCount: 1,
              now: DateTime(2026, 11, 13, 19, 0)),
          isFalse);
      expect(
          shouldShowRecheckReminder(
              notifyEnabled: true,
              notifyTime: 'abc',
              dueRecheckCount: 1,
              now: DateTime(2026, 11, 13, 21, 0)),
          isTrue);
    });
  });

  group('parseNotifyTime / recheckReminderDateString', () {
    test('正常解析与回落', () {
      expect(parseNotifyTime('20:00'), (hour: 20, minute: 0));
      expect(parseNotifyTime('08:30'), (hour: 8, minute: 30));
      expect(parseNotifyTime('25:00'), (hour: 20, minute: 0));
      expect(parseNotifyTime(''), (hour: 20, minute: 0));
    });

    test('日期串格式 yyyy-MM-dd', () {
      expect(recheckReminderDateString(DateTime(2026, 11, 3, 9, 5)),
          '2026-11-03');
    });
  });

  group('recheckDueCauseCount', () {
    test('只数已加入复习、已整理的题上已解决且到复查日的错因', () async {
      final repo = B41FakeRepo()
        ..questions = [
          _q('q1'),
          _q('q2', joined: false),
          _q('q3', organized: false),
        ]
        ..records = [
          // q1：1 个到复查日（昨天）+ 1 个复查日在明天 → 只数 1 个。
          _r('q1', recheckDate: DateTime.now().subtract(
              const Duration(days: 1))),
          _r('q1', recheckDate: DateTime.now().add(const Duration(days: 1))),
          // q1 上未解决的错因（有复查日也不算：isRecheckDue 要求已解决）。
          _r('q1', status: CauseStatus.pending,
              recheckDate: DateTime.now().subtract(
                  const Duration(days: 1))),
          // q2 未加入复习、q3 未整理 → 都不数。
          _r('q2', recheckDate: DateTime.now().subtract(
              const Duration(days: 1))),
          _r('q3', recheckDate: DateTime.now().subtract(
              const Duration(days: 1))),
        ];
      expect(await repo.recheckDueCauseCount(), 1);
    });
  });
}
