// 十三批 M6：设置页 BigModel key 设置项 widget 测试。
//
// 覆盖：已设置/未设置显示、保存、保存空串视为清除、清除按钮、
// 输入遮蔽（密码式输入框）。用 OcrKeyStore 的内存假后端
// （构造器可传 backend），不碰真实平台通道；key 值本身永不在
// 界面上出现（已设置时也不显示 key）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/settings/settings_page.dart';
import 'package:quiz_master2/services/ocr_key_store.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/theme/app_theme.dart';

/// 内存假后端（与 test/b13_ocr_client_test.dart 的同名假后端同口径）。
/// `valueFor` 只供测试断言“存进去的值是什么”，生产代码不读它。
class _MemoryKeyBackend implements OcrKeyStorageBackend {
  final _map = <String, String>{};

  String? valueFor(String key) => _map[key];

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }

  @override
  Future<bool> containsKey(String key) async => _map.containsKey(key);
}

/// 最小 FakeRepo（settings_page_test.dart 的 FakeSettingsRepo 同口径，
/// 本文件只用 settings / storageUsage / scanOrphans / all 四处）。
class _FakeSettingsRepo extends QuestionRepository {
  _FakeSettingsRepo({AppSettings? settings})
    : settingsValue = settings ?? AppSettings.defaults,
      super(AppDatabase.instance);

  AppSettings settingsValue;

  @override
  Future<AppSettings> settings() async => settingsValue;

  @override
  Future<void> saveSettings(AppSettings s) async {
    settingsValue = s;
  }

  @override
  Future<({int importsBytes, int slicesBytes})> storageUsageBreakdown() async =>
      (importsBytes: 0, slicesBytes: 0);

  @override
  Future<OrphanScan> scanOrphanFiles() async => OrphanScan(const []);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async => [];
}

Future<void> _pumpSettings(
  WidgetTester tester, {
  required OcrKeyStore keyStore,
  String? initialOpenGroup,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _FakeSettingsRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: AppTheme.light(scale: 1.0),
        home: Scaffold(
          body: SettingsPage(
            key: UniqueKey(),
            keyStore: keyStore,
            initialOpenGroup: initialOpenGroup,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDataGroup(WidgetTester tester) async {
  await tester.ensureVisible(find.text('数据').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('数据').first);
  await tester.pumpAndSettle();
}

/// 数据组很长，BigModel key 行在组末尾、720 高视口外：操作前先
/// 把目标滚进视口（与 openGroup 的 ensureVisible 同一做法）。
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('M6 设置页 BigModel key', () {
    testWidgets('数据组默认折叠，打开后才出现 BigModel key 行', (tester) async {
      final store = OcrKeyStore(backend: _MemoryKeyBackend());
      await _pumpSettings(tester, keyStore: store);
      expect(find.text('BigModel key'), findsNothing);
      await _openDataGroup(tester);
      expect(find.text('BigModel key'), findsOneWidget);
    });

    testWidgets('未设置：显示“未设置”', (tester) async {
      final store = OcrKeyStore(backend: _MemoryKeyBackend());
      await _pumpSettings(tester, keyStore: store);
      await _openDataGroup(tester);
      expect(find.text('状态：未设置'), findsOneWidget);
      expect(find.text('状态：已设置'), findsNothing);
    });

    testWidgets('已设置：显示“已设置”，且 key 值本身绝不出现', (tester) async {
      final backend = _MemoryKeyBackend();
      final store = OcrKeyStore(backend: backend);
      await store.setApiKey('test-key-abc-123');
      await _pumpSettings(tester, keyStore: store);
      await _openDataGroup(tester);
      expect(find.text('状态：已设置'), findsOneWidget);
      expect(find.text('状态：未设置'), findsNothing);
      // key 值不在界面上任何地方（不在状态行、不在输入框里）。
      expect(find.text('test-key-abc-123'), findsNothing);
      expect(find.textContaining('test-key-abc-123'), findsNothing);
    });

    testWidgets('输入框是密码式遮蔽：obscureText，输入的 key 不以明文出现',
        (tester) async {
      final store = OcrKeyStore(backend: _MemoryKeyBackend());
      await _pumpSettings(tester, keyStore: store);
      await _openDataGroup(tester);
      await _reveal(tester, find.byKey(const Key('bigmodel-key-field')));
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('bigmodel-key-field')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.obscureText, isTrue);
      await tester.enterText(
        find.byKey(const Key('bigmodel-key-field')),
        'secret-key-xyz',
      );
      await tester.pumpAndSettle();
      // 注意：find.text 也会命中 EditableText 自身的 controller 文本，
      // 所以“不明文显示”不能用 find.text 断言——真正起遮蔽作用的是
      // obscureText（上面已断言）；这里断言没有任何普通 Text 控件
      // 把 key 渲染出来，且输入后仍保持遮蔽。
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data == 'secret-key-xyz',
        ),
        findsNothing,
      );
      final fieldAfter = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('bigmodel-key-field')),
          matching: find.byType(TextField),
        ),
      );
      expect(fieldAfter.obscureText, isTrue);
      expect(fieldAfter.controller?.text, 'secret-key-xyz');
    });

    testWidgets('保存：去首尾空白后存入，状态变“已设置”，输入框清空',
        (tester) async {
      final backend = _MemoryKeyBackend();
      final store = OcrKeyStore(backend: backend);
      await _pumpSettings(tester, keyStore: store);
      await _openDataGroup(tester);
      await _reveal(tester, find.byKey(const Key('bigmodel-key-field')));
      await tester.enterText(
        find.byKey(const Key('bigmodel-key-field')),
        '  new-key-xyz  ',
      );
      await _reveal(tester, find.byKey(const Key('bigmodel-key-save')));
      await tester.tap(find.byKey(const Key('bigmodel-key-save')));
      await tester.pumpAndSettle();
      expect(await store.hasApiKey(), isTrue);
      expect(
        backend.valueFor(OcrKeyStore.apiKeyStorageKey),
        'new-key-xyz',
      );
      expect(find.text('状态：已设置'), findsOneWidget);
      // 保存后输入框清空，key 不滞留；界面上也找不到 key 明文。
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('bigmodel-key-field')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller?.text, isEmpty);
      expect(find.text('new-key-xyz'), findsNothing);
    });

    testWidgets('保存空串视为清除：已设置的 key 被清掉，状态回“未设置”',
        (tester) async {
      final store = OcrKeyStore(backend: _MemoryKeyBackend());
      await store.setApiKey('old-key');
      await _pumpSettings(tester, keyStore: store);
      await _openDataGroup(tester);
      expect(find.text('状态：已设置'), findsOneWidget);
      // 输入框留空点保存（OcrKeyStore 契约：空串视为清除）。
      await _reveal(tester, find.byKey(const Key('bigmodel-key-save')));
      await tester.tap(find.byKey(const Key('bigmodel-key-save')));
      await tester.pumpAndSettle();
      expect(await store.hasApiKey(), isFalse);
      expect(find.text('状态：未设置'), findsOneWidget);
    });

    testWidgets('清除按钮：清掉已存 key，状态回“未设置”', (tester) async {
      final store = OcrKeyStore(backend: _MemoryKeyBackend());
      await store.setApiKey('old-key');
      await _pumpSettings(tester, keyStore: store);
      await _openDataGroup(tester);
      expect(find.text('状态：已设置'), findsOneWidget);
      await _reveal(tester, find.byKey(const Key('bigmodel-key-clear')));
      await tester.tap(find.byKey(const Key('bigmodel-key-clear')));
      await tester.pumpAndSettle();
      expect(await store.hasApiKey(), isFalse);
      expect(find.text('状态：未设置'), findsOneWidget);
      expect(find.text('old-key'), findsNothing);
    });

    testWidgets('initialOpenGroup=data 时直接展开数据组并读到状态',
        (tester) async {
      final store = OcrKeyStore(backend: _MemoryKeyBackend());
      await store.setApiKey('seeded-key');
      await _pumpSettings(
        tester,
        keyStore: store,
        initialOpenGroup: 'data',
      );
      expect(find.text('BigModel key'), findsOneWidget);
      expect(find.text('状态：已设置'), findsOneWidget);
    });
  });
}
