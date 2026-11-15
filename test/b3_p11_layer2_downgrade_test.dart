// B3 P1-1 二层切片降级 + QuestionSlice errorBuilder 回归测试。
//
// P1-1（Meng 已定：二层暂缓，不接线）：真实题（空 sliceText）不再从空
// 文字推导假 region——regionsOfQuestion 返回空列表，整理页随之隐藏
// region 开关、只留整题切片；演示题 / 老题的推导规则不变。
// QuestionSlice：slice 文件存在但解码失败时走 errorBuilder，显示与
// 文件缺失同一口径的缺图占位（学科图标 + 学科 · 题型 + 「图片缺失，
// 可重新导入/重新框选」），不再显示 Flutter 的报错占位。
// SR-P1-15：CompactSliceThumb 同款修复——Image.file 补 errorBuilder，
// 复用紧凑失败占位（学科图标 + 「加载失败」），回归用例在本文件
// 'CompactSliceThumb errorBuilder' 组。
//
// 夹具：test/fixtures/slice-narrow-500x120.png（有效 PNG）；损坏文件
// 在测试里现写临时文件。B3-P01：slicePath 不再用绝对路径
// （resolveDataPath 已拒绝绝对路径）；三个用例的文件都放进
// testDataDirectory 下的 slices/，slicePath 用相对路径。
// FakeAsync 下真实图片解码等不到完成（见
// b2_win11bug_organize_test 的注释），挂着待解码 Image.file 的用例
// 用 [_pumpSliceWithDecode]：在 runAsync 内反复 pump + 真实延时推进
// （collect_page_test 的 tapConfirmAndWait 同款做法）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/theme/app_theme.dart';
import 'package:quiz_master2/widgets/widgets.dart';

Question _question({
  String sliceText = '',
  String sliceKind = 'material',
  String? slicePath,
  String? sourcePath,
}) => Question(
  id: 'q-b3',
  title: '测试题',
  subjectId: 'math',
  sliceKind: sliceKind,
  sliceText: sliceText,
  slicePath: slicePath,
  sourcePath: sourcePath,
  createdAt: DateTime(2026, 11, 8),
);

/// 缺图用例专用：不挂 Image.file，普通 pump 即可。
Future<void> _pumpSlice(WidgetTester tester, Question q) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: QuestionSlice(question: q),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 真实图片 IO + 解码须在 runAsync 内反复 pump + 真实延时推进
/// （collect_page_test 的 tapConfirmAndWait 同款做法）：测试体在
/// fake async zone 里，真实解码等不到完成，挂着待解码 Image.file
/// 的 pumpAndSettle 会一直等不到 settle 而挂住（实测有效图 /
/// 损坏图都在 pumpAndSettle 上挂住）。普通 pump 不等 settle，不挂
/// （scratch 验证过）；所以挂载用普通 pump 在 runAsync 外做，
/// 解码推进用 runAsync 内的 pump + 真实延时循环。注意 pumpWidget
/// 不能放进 runAsync（实测在里面挂住），只把 pump 放进去。
/// 缺图用例（不挂 Image）走普通 [_pumpSlice]。
Future<void> _pumpSliceWithDecode(WidgetTester tester, Question q) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: QuestionSlice(question: q),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(() async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  });
  await tester.pump();
  await tester.pump();
}

/// [_pumpSliceWithDecode] 的 CompactSliceThumb 版（SR-P1-15）：挂载与
/// 解码推进规则相同，只把 body 换成 64×48 的紧凑缩略图。
Future<void> _pumpThumbWithDecode(WidgetTester tester, Question q) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(scale: 1.0),
      home: Scaffold(
        body: Center(child: CompactSliceThumb(question: q)),
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(() async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  });
  await tester.pump();
  await tester.pump();
}

void main() {
  group('regionsOfQuestion：P1-1 降级', () {
    test('真实题（空 sliceText）返回空列表，不再推导假 region', () {
      expect(regionsOfQuestion(_question(sliceText: '')), isEmpty);
    });

    test('只有空白字符的 sliceText 也返回空列表', () {
      expect(regionsOfQuestion(_question(sliceText: '  \n ')), isEmpty);
    });

    test('演示题：含填空标记有 stem + option；图表题有 figure', () {
      expect(
        regionsOfQuestion(
          _question(sliceText: '题：lim(x→0) sin 3x / x 的值是（　）'),
        ),
        ['stem', 'option'],
      );
      expect(
        regionsOfQuestion(_question(sliceText: '题干文字', sliceKind: 'chart')),
        ['stem', 'figure'],
      );
      expect(
        regionsOfQuestion(
          _question(sliceText: '题干文字', sliceKind: 'function'),
        ),
        ['stem'],
      );
    });
  });

  group('QuestionSlice errorBuilder', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('b3-slice-');
      await Directory('${tempDir.path}/slices').create(recursive: true);
      // 注意：所有真实文件 IO 必须在 setUp 里做——testWidgets 体跑在
      // fake async zone 里，直接 await 真实 IO 等不到完成而挂住
      // （实测 createTemp / writeAsBytes 在体里都会挂；setUp 在
      // fake zone 外跑，不受影响。collect_page_test 的 setUpAll
      // 同款做法）。
      await File(
        '${tempDir.path}/slices/bad.png',
      ).writeAsBytes(utf8.encode('this is not a png'));
      final fixture = File('test/fixtures/slice-narrow-500x120.png');
      expect(fixture.existsSync(), isTrue);
      await fixture.copy('${tempDir.path}/slices/good.png');
      AppDatabase.testDataDirectory = tempDir.path;
    });

    tearDown(() async {
      AppDatabase.testDataDirectory = null;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    testWidgets('损坏的切片文件：解码失败显示「图片缺失」，不报 Flutter 占位', (
      tester,
    ) async {
      final q = _question(
        slicePath: 'slices/bad.png',
        sourcePath: 'imports/task/original.png',
      );
      await _pumpSliceWithDecode(tester, q);
      expect(find.text('图片缺失，可重新导入/重新框选'), findsOneWidget);
      expect(find.text('数学 · 材料题'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('文件缺失：同一口径的缺图占位（对照）', (tester) async {
      final q = _question(
        slicePath: 'slices/gone.png',
        sourcePath: 'imports/task/original.png',
      );
      await _pumpSlice(tester, q);
      expect(find.text('图片缺失，可重新导入/重新框选'), findsOneWidget);
      expect(find.text('数学 · 材料题'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有效切片：正常显示图片，不显示缺图占位', (tester) async {
      final q = _question(
        slicePath: 'slices/good.png',
        sourcePath: 'imports/task/original.png',
      );
      await _pumpSliceWithDecode(tester, q);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('图片缺失，可重新导入/重新框选'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('CompactSliceThumb errorBuilder', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('b5-p1-15-');
      await Directory('${tempDir.path}/slices').create(recursive: true);
      // 与 QuestionSlice 组同款夹具：损坏文件现写，有效文件拷 fixture。
      await File(
        '${tempDir.path}/slices/bad.png',
      ).writeAsBytes(utf8.encode('this is not a png'));
      final fixture = File('test/fixtures/slice-narrow-500x120.png');
      expect(fixture.existsSync(), isTrue);
      await fixture.copy('${tempDir.path}/slices/good.png');
      AppDatabase.testDataDirectory = tempDir.path;
    });

    tearDown(() async {
      AppDatabase.testDataDirectory = null;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    testWidgets('损坏的切片文件：解码失败显示“加载失败”占位', (tester) async {
      final q = _question(
        slicePath: 'slices/bad.png',
        sourcePath: 'imports/task/original.png',
      );
      await _pumpThumbWithDecode(tester, q);
      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('数'), findsOneWidget);
      // 注意：errorBuilder 是在 Image 内部渲染占位，Image widget 本身
      // 仍在树上（与 QuestionSlice 缺图分支不挂 Image 不同），所以
      // 不断言 findsNothing；占位文案 + 无异常即证明走了 errorBuilder。
      expect(tester.takeException(), isNull);
    });

    testWidgets('有效切片：正常显示图片，不显示失败占位（对照）', (tester) async {
      final q = _question(
        slicePath: 'slices/good.png',
        sourcePath: 'imports/task/original.png',
      );
      await _pumpThumbWithDecode(tester, q);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('加载失败'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
