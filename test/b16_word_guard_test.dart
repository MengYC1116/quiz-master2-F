// 十六批 C：guard 与上限（WORD-DESIGN.md §6，D-202）。
//
// 80/150 Mpx 边界、单图 12 Mpx 警告、50 道硬上限（含跳过题占名额、
// 无第 51 道补入）、混合状态计数守恒。复用 PDF ContentGuard，
// 不另起 WordGuard。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/content_guard.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart'
    show ExportGuardRejectException;
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';

import 'b16_word_test_helpers.dart';

void main() {
  late Directory tempRoot;
  late FakeExportQuestionSource source;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b16-word-guard-');
    source = FakeExportQuestionSource();
  });

  tearDown(() async {
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  /// 加一道只有 IHDR 的“大尺寸”题（声明尺寸大、字节只有 33 字节；
  /// 盘点按声明尺寸估算，A 路线增强时解不出 → BROKEN，不影响
  /// guard 边界断言）。
  void addHeadOnlyQuestion(String id, int w, int h) {
    source.records[id] = choiceRecord(
      id: id,
      sliceWidth: w,
      sliceHeight: h,
    );
    source.slices[id] = makePngHeadOnly(w, h);
  }

  group('guard 与上限（D-202）', () {
    test('80/150 Mpx 边界：80.0 不警告、80.1 软警告、150.0 不拒绝、150.1 硬拒绝',
        () {
      ContentGuardResult at(double total) => ContentGuard.evaluate(
        [
          GuardRasterItem(
            questionId: 'q0',
            title: '题',
            rasterMpx: total,
          ),
        ],
        isEstimate: true,
      );
      expect(at(80.0).isSoftWarning, isFalse);
      expect(at(80.0).isHardReject, isFalse);
      expect(at(80.1).isSoftWarning, isTrue);
      expect(at(150.0).isHardReject, isFalse);
      expect(at(150.0).isSoftWarning, isTrue);
      expect(at(150.1).isHardReject, isTrue);
    });

    test('服务级软警告：18 道 4000×4000 题约 81 Mpx，照常生成', () async {
      for (var i = 0; i < 18; i++) {
        addHeadOnlyQuestion('q$i', 4000, 4000);
      }
      final service = makeWordService(source, tempRoot, hasKey: false);
      final result = await generateWord(
        service,
        [for (var i = 0; i < 18; i++) 'q$i'],
      );
      expect(result.estimatedGuard.isSoftWarning, isTrue);
      expect(result.estimatedGuard.totalRasterMpx, greaterThan(80));
      expect(result.report.selectedCount, 18);
    });

    test('服务级硬拒绝：34 道 4000×4000 题约 154 Mpx，整单中止', () async {
      for (var i = 0; i < 34; i++) {
        addHeadOnlyQuestion('q$i', 4000, 4000);
      }
      final service = makeWordService(source, tempRoot, hasKey: false);
      await expectLater(
        () => generateWord(
          service,
          [for (var i = 0; i < 34; i++) 'q$i'],
        ),
        throwsA(isA<ExportGuardRejectException>()),
      );
    });

    test('单图 12 Mpx 警告：2126×8000 切片上限后约 17 Mpx，记警告不阻断',
        () async {
      addHeadOnlyQuestion('q0', 2126, 8000);
      final service = makeWordService(source, tempRoot, hasKey: false);
      final result = await generateWord(service, ['q0']);
      expect(result.estimatedGuard.singleImageWarnings.length, 1);
      expect(
        result.estimatedGuard.singleImageWarnings.single.questionId,
        'q0',
      );
      expect(result.estimatedGuard.isHardReject, isFalse);
      expect(result.report.brokenCount, 1);
    });

    test('50 道硬上限：51 道拒收；50 道含 1 道排除，不补入第 51 道',
        () async {
      for (var i = 0; i < 51; i++) {
        addChoiceQuestion(source, 'q$i');
      }
      final service = makeWordService(source, tempRoot, hasKey: true);
      await expectLater(
        () => generateWord(
          service,
          [for (var i = 0; i < 51; i++) 'q$i'],
        ),
        throwsA(isA<ArgumentError>()),
      );
      // 50 道含 1 道用户排除：选中 50（排除题仍占名额）、快照 49、
      // 印出 49，不补入第 51 道（排除题不在快照条目里，不计入
      // snapshotCount / skippedCount，只计入 selectedCount 与
      // excludedCount）。
      final result = await generateWord(
        service,
        [for (var i = 0; i < 50; i++) 'q$i'],
        excluded: const [ExcludedQuestion(id: 'q49', reason: '用户排除')],
      );
      expect(result.report.selectedCount, 50);
      expect(result.report.snapshotCount, 49);
      expect(result.report.excludedCount, 1);
      expect(result.report.completeCount, 49);
      expect(result.report.skippedCount, 0);
    });

    test('计数守恒：COMPLETE + BROKEN + SKIPPED + 排除混合', () async {
      // q0：2000×1000 切片（有效分辨率约 282 DPI，不低清）→ COMPLETE；
      // q1：切片不可用 → BROKEN；q2：用户排除（占名额，不进快照条目）；
      // q3：库里无此题 → SKIPPED（题目不存在）。
      addChoiceQuestion(source, 'q0', w: 2000, h: 1000);
      addChoiceQuestion(source, 'q1');
      source.unavailableSlices.add('q1');
      addChoiceQuestion(source, 'q2');
      final service = makeWordService(source, tempRoot, hasKey: false);
      final result = await generateWord(
        service,
        ['q0', 'q1', 'q2', 'q3'],
        excluded: const [ExcludedQuestion(id: 'q2', reason: '用户排除')],
      );
      final report = result.report;
      expect(report.selectedCount, 4);
      expect(report.snapshotCount, 3);
      expect(report.excludedCount, 1);
      expect(report.completeCount, 1);
      expect(report.brokenCount, 1);
      expect(report.skippedCount, 1);
      // generateVersions 正常返回即守恒核对已通过（对不上会整单失败）。
      expect(report.entries.length, 3);
    });
  });
}
