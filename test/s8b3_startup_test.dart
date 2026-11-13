// B3：启动页设置生效（见 lib/app.dart resolveStartupRoute、
// lib/data/database.dart loadLastRoute/saveLastRoute）。
//
// 测两层：
// 1. 纯函数 resolveStartupRoute：任务要求的四种情形 + 边界；
// 2. settings 表 key `lastRoute` 的存取往返：复用 settings 表，
//    saveSettings（全量写 AppSettings.toMap）不能误删它。
// 整应用 QuizMasterApp 在 widget 测试里 pumpAndSettle 永不静止
// （应用内有持续 Timer），按仓库惯例不直接测整应用；启动恢复
// 的端到端行为以 Linux 真机截图为直接证据
// （见 docs/ui-replication/S8B3-STARTUP-REPORT.md §5）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/app.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';

void main() {
  group('resolveStartupRoute', () {
    test("'last' + 存过某顶级路由 → 恢复该路由", () {
      expect(resolveStartupRoute('last', '/organize'), '/organize');
      expect(resolveStartupRoute('last', '/settings'), '/settings');
      expect(resolveStartupRoute('last', '/review'), '/review');
    });

    test("'last' + 9 个顶级路由都可恢复", () {
      for (final r in topLevelRoutes) {
        expect(resolveStartupRoute('last', r), r, reason: r);
      }
    });

    test("'home' + 存过某路由 → 落首页", () {
      expect(resolveStartupRoute('home', '/organize'), '/home');
      expect(resolveStartupRoute('home', '/settings'), '/home');
    });

    test("'last' + 存的是详情路由 → 回落首页（题目可能已被删）", () {
      expect(resolveStartupRoute('last', '/question/q-m1'), '/home');
      expect(resolveStartupRoute('last', '/question/abc'), '/home');
    });

    test("'last' + 存值非法/为空/无存值 → 回落首页", () {
      expect(resolveStartupRoute('last', null), '/home');
      expect(resolveStartupRoute('last', ''), '/home');
      expect(resolveStartupRoute('last', '   '), '/home');
      expect(resolveStartupRoute('last', '/nope'), '/home');
      expect(resolveStartupRoute('last', 'organize'), '/home');
    });

    test("startupPage 非法值 → 回落首页", () {
      expect(resolveStartupRoute('bogus', '/organize'), '/home');
      expect(resolveStartupRoute('', '/organize'), '/home');
    });

    test('存值两侧空白被 trim 后仍可恢复', () {
      expect(resolveStartupRoute('last', '  /review  '), '/review');
    });
  });

  group('lastRoute 持久化（settings 表 key）', () {
    // 直接读写真实演示库的 settings 表（只碰 `lastRoute` 一个 key），
    // 先读原值、finally 原样恢复，不污染演示数据。
    final repo = QuestionRepository(AppDatabase.instance);

    test('存取往返 + saveSettings 不误删', () async {
      final beforeSettings = await repo.settings();
      final beforeRoute = await repo.lastRoute();
      try {
        await repo.saveLastRoute('/home');
        expect(await repo.lastRoute(), '/home');
        await repo.saveLastRoute('/organize');
        expect(await repo.lastRoute(), '/organize');
        await repo.saveLastRoute('/review');
        expect(await repo.lastRoute(), '/review');

        // 全量保存设置（AppSettings.toMap 的已知键）后 lastRoute 还在。
        await repo.saveSettings(
          AppSettings.defaults.copyWith(startupPage: 'last'),
        );
        expect(await repo.lastRoute(), '/review');
        expect((await repo.settings()).startupPage, 'last');
      } finally {
        await repo.saveSettings(beforeSettings);
        // 原先无存值时写回 '/home'：与无 key 等价（都回落首页），
        // 只是不留“删 key”的接口，见 database.dart。
        await repo.saveLastRoute(beforeRoute ?? '/home');
      }
    });
  });
}
