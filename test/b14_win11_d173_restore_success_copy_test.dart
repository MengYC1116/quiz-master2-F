// D-173：恢复成功文案只在真有未完成会话时才提“已清除未完成的复习会话”。
// (a) 文案分支：restoreSuccessMessage 四种组合；
// (b) 信号：SettingsNotifier.hasUnfinishedReviewSession 读 review_state
// 快照行（有可恢复快照 → true，没有或空 → false）。
// 页面接线（恢复前查、恢复后按分支拼文案）只有三行，不另做 widget 测试；
// 恢复本身仍按十四批 M2（P1-6）清掉 review_state，行为不变（见
// test/b14_m2_backup_test.dart 与 test/b2_restore_flow_test.dart）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/settings/settings_page.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/settings_notifier.dart';

class FakeSessionRepo extends QuestionRepository {
  FakeSessionRepo({this.session}) : super(AppDatabase.instance);

  /// 可恢复的会话快照；null = 没有未完成会话。
  ReviewSessionState? session;

  @override
  Future<AppSettings> settings() async => AppSettings.defaults;

  @override
  Future<ReviewSessionState?> reviewState() async => session;
}

SettingsNotifier makeNotifier(FakeSessionRepo repo) {
  final container = ProviderContainer.test(
    overrides: [repositoryProvider.overrideWithValue(repo)],
  );
  addTearDown(container.dispose);
  return container.read(settingsProvider.notifier);
}

ReviewSessionState _session() => ReviewSessionState(
  queue: const [
    ReviewQueueItem(questionId: 'q1', cause: '计算错误'),
  ],
  position: 0,
  updatedAt: DateTime(2026, 11, 20),
);

void main() {
  group('restoreSuccessMessage 文案分支', () {
    test('有会话、无警告：提已清除未完成的复习会话', () {
      expect(
        restoreSuccessMessage(hadUnfinishedSession: true, warnings: const []),
        '恢复成功，已清除未完成的复习会话',
      );
    });

    test('有会话、有警告：会话提示在前，警告照旧追加', () {
      expect(
        restoreSuccessMessage(
          hadUnfinishedSession: true,
          warnings: const ['图块 a.png 缺失'],
        ),
        '恢复成功，已清除未完成的复习会话；图块 a.png 缺失',
      );
    });

    test('无会话、无警告：只说恢复成功，不提会话', () {
      expect(
        restoreSuccessMessage(hadUnfinishedSession: false, warnings: const []),
        '恢复成功',
      );
    });

    test('无会话、有警告：只说恢复成功，警告照旧追加', () {
      expect(
        restoreSuccessMessage(
          hadUnfinishedSession: false,
          warnings: const ['图块 a.png 缺失', '图块 b.png 不可读'],
        ),
        '恢复成功；图块 a.png 缺失；图块 b.png 不可读',
      );
    });
  });

  group('hasUnfinishedReviewSession 信号', () {
    test('review_state 有快照行 → true', () async {
      final notifier = makeNotifier(FakeSessionRepo(session: _session()));
      expect(await notifier.hasUnfinishedReviewSession(), isTrue);
    });

    test('review_state 无行 → false', () async {
      final notifier = makeNotifier(FakeSessionRepo());
      expect(await notifier.hasUnfinishedReviewSession(), isFalse);
    });
  });
}
