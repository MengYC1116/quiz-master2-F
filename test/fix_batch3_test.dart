// 修复批三（P2 页面与文案）回归测试：FR-08 共享拼音排序 + FR-34 重框
// 确认按钮文案 + FR-35 重叠横幅无重复短语。
//
// FR-08 的 Notifier 层测试在 `organize_notifier_test.dart` /
// `wrongbook_notifier_test.dart`（各用其 FakeRepo）；FR-09/16 在
// `detail_page_test.dart`；FR-10 在 `review_page_test.dart`；
// FR-18 在 `report_page_test.dart`；FR-11/12/17 由既有测试改断言锁定。
// D-45：种子放测试体内、repo 调用直接 await，不用 runAsync。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/collect/collect_page.dart';
import 'package:quiz_master2/services/yolo_onnx_service.dart';
import 'package:quiz_master2/state/subject_sort.dart';
import 'package:quiz_master2/theme/app_theme.dart';

void main() {
  group('FR-08 共享拼音排序（subject_sort.dart）', () {
    test('新学科按名取首字母：化学 H、物理 W，不再一律 S', () {
      expect(subjectInitialForName('化学'), 'H');
      expect(subjectInitialForName('物理'), 'W');
      expect(subjectInitialForName('数学'), 'S');
      expect(subjectInitialForName('英语'), 'Y');
      expect(subjectInitialForName('政治'), 'Z');
    });

    test('空名回退 {、拉丁字母取大写、表外汉字回退原字', () {
      expect(subjectInitialForName(''), '{');
      expect(subjectInitialForName('   '), '{');
      expect(subjectInitialForName('Math'), 'M');
      expect(subjectPinyinKeyForName(''), '');
    });

    test('同首字母按拼音串排：生物 SW 在数学 S学 前', () {
      // 拼音串是逐字首字母（不是全拼音）：“生物”→ SW；“学”不在表里，
      // 回退原字，“数学”→ S学。'W'(0x57) < '学'(0x5B66)，生物仍排前面。
      expect(subjectPinyinKeyForName('生物'), 'SW');
      expect(subjectPinyinKeyForName('数学'), 'S学');
      expect(compareSubjectNames('生物', '数学'), lessThan(0));
      expect(compareSubjectNames('化学', '数学'), lessThan(0));
      expect(compareSubjectNames('数学', '英语'), lessThan(0));
      expect(compareSubjectNames('数学', '数学'), 0);
    });
  });

  group('FR-34/35 修框编辑器文案', () {
    late Directory testTmp;
    late String pagePngPath;

    setUpAll(() async {
      testTmp = await Directory.systemTemp.createTemp('qm2-fix-batch3-');
      pagePngPath = '${testTmp.path}/page.png';
      File(pagePngPath).writeAsBytesSync(base64Decode(_kPagePngBase64));
    });

    Future<void> openEditor(
      WidgetTester tester, {
      required BoxEditorMode mode,
      required Map<int, List<QuestionBox>> boxes,
      String? reworkQuestionId,
    }) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  await showBoxEditorDialog(
                    context: context,
                    fileName: 'test.pdf',
                    pageImagePath: pagePngPath,
                    page: 1,
                    pageCount: 1,
                    subjectName: '数学',
                    taskId: 'task-test',
                    mode: mode,
                    initialBoxesByPage: boxes,
                    reworkQuestionId: reworkQuestionId,
                    yoloService: _EmptyYolo(),
                  );
                },
                child: const Text('打开修框'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开修框'));
      await tester.pumpAndSettle();
    }

    testWidgets('FR-34：重框模式确认按钮是“确认重新框选”', (tester) async {
      await openEditor(
        tester,
        mode: BoxEditorMode.rework,
        reworkQuestionId: 'q1',
        boxes: {
          1: [_box(id: 'box-1', questionId: 'q1')],
        },
      );
      expect(find.text('确认重新框选'), findsOneWidget);
      expect(find.text('确认修框，去整理'), findsNothing);
      expect(find.textContaining('确认修框，拆成'), findsNothing);
    });

    testWidgets('FR-34：草稿模式单框仍是“确认修框，去整理”', (tester) async {
      await openEditor(
        tester,
        mode: BoxEditorMode.draft,
        boxes: {
          1: [_box(id: 'box-1')],
        },
      );
      expect(find.text('确认修框，去整理'), findsOneWidget);
      expect(find.text('确认重新框选'), findsNothing);
    });

    testWidgets('FR-35：重叠横幅标题“框重叠”+正文点名，无“有框重叠了”', (tester) async {
      await openEditor(
        tester,
        mode: BoxEditorMode.draft,
        boxes: {
          1: [
            _box(id: 'box-1', x: 0.2, y: 0.2),
            _box(id: 'box-2', x: 0.3, y: 0.25),
          ],
        },
      );
      // 横幅是 Text.rich（标题 + 正文同一 Text，批一 FR-03 同款做法），
      // 须用 textContaining；操作说明默认折叠，不会多命中一个“框重叠”。
      expect(find.textContaining('框重叠'), findsOneWidget);
      expect(find.textContaining('第 1、2 道题的框叠在一起，请调开再确认。'), findsOneWidget);
      expect(find.textContaining('有框重叠了'), findsNothing);
    });
  });
}

/// 1×1 白色 PNG（页图占位，与 b8_345_box_interaction_test.dart 同款）。
const _kPagePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

QuestionBox _box({
  required String id,
  String? questionId,
  double x = 0.2,
  double y = 0.2,
  double w = 0.4,
  double h = 0.3,
}) => QuestionBox(
  id: id,
  layer: 1,
  type: 'question',
  x: x,
  y: y,
  w: w,
  h: h,
  page: 1,
  origin: 'manual',
  questionId: questionId,
);

/// 桩检测：不跑真实模型，返回空框（不走 fallback，不落占位框）。
class _EmptyYolo extends YoloOnnxService {
  @override
  Future<DetectionResult> detectPage({
    required String imagePath,
    required int page,
  }) async => const DetectionResult(boxes: [], usedFallback: false);
}
