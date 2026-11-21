// 十五批修复批 P0-3b：答案版本复核——单次读行（D-186）。
//
// 覆盖：_freezeExport 把 step 2 的原始读行结果传给 fromSelection，
// 取消快照内部的二次 fetch。计数证明：2 道题一次 generate 的
// fetchQuestion 调用数 = 4（step 2 读 2 + 终态复核重读 2），
// 修前为 6；终态复核的第三次重读保留，不取消。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/export_question_record.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/pdf_export_service.dart';

import 'b15_m1b_fake_source.dart';

/// 计数桩：统计 fetchQuestion 调用次数（Fake 的 fetchQuestions
/// 内部逐题调 fetchQuestion，批量读也按题计）。
class _CountingSource extends FakeExportQuestionSource {
  int fetchQuestionCalls = 0;

  @override
  Future<ExportQuestionRecord?> fetchQuestion(String id) async {
    fetchQuestionCalls++;
    return super.fetchQuestion(id);
  }
}

Future<Uint8List> _fontBytes() async =>
    File('assets/fonts/NotoSansSC-Regular.ttf').readAsBytes();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  var counter = 0;

  setUp(() {
    tempRoot =
        Directory(
          '${Directory.current.path}/../flutter-test-tmp/m1e-fix-p03b-t${counter++}',
        )..createSync(recursive: true);
  });

  tearDown(() {
    try {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  void addARecords(_CountingSource source, List<String> ids) {
    final bytes = makePng(2126, 530);
    for (final id in ids) {
      source.records[id] = ExportQuestionRecord(
        id: id,
        title: '题 $id',
        subjectId: 'math',
        slicePath: 'slices/$id.png',
        sliceWidth: 2126,
        sliceHeight: 530,
        contentVersion: 0,
      );
      source.slices[id] = bytes;
    }
  }

  group('P0-3b 单次读行（D-186）', () {
    test('服务级：2 道题 generate 只读 4 次（step 2 读 2 + 终态复核 2）', () async {
      final source = _CountingSource();
      addARecords(source, const ['q0', 'q1']);
      final svc = PdfExportService(
        source: source,
        hasApiKey: () async => false,
        fontBytesLoader: _fontBytes,
        tempRoot: tempRoot,
      );
      final result = await svc.generate(
        ids: const ['q0', 'q1'],
        excluded: const [],
        filterText: '全部',
        sortText: '默认',
      );
      expect(result.report.completeCount, 2);
      expect(result.report.conservationError(), isNull);
      // 修前：step 2 读 2 + 快照阶段一二次 fetch 2 + 终态复核 2 = 6。
      // 修后：快照阶段一复用 step 2 的记录，二次 fetch 取消 = 4。
      expect(source.fetchQuestionCalls, 4);
    });

    test('快照级：传 recordsById 时阶段一零读行，只剩终态复核 2 次', () async {
      final source = _CountingSource();
      addARecords(source, const ['q0', 'q1']);
      final snapshot = await ExportSnapshot.fromSelection(
        ids: const ['q0', 'q1'],
        excluded: const [],
        route: ExportRoute.a,
        filterText: '全部',
        sortText: '默认',
        source: source,
        tempRoot: tempRoot,
        recordsById: {
          'q0': source.records['q0'],
          'q1': source.records['q1'],
        },
      );
      addTearDown(() async {
        await snapshot.dispose();
      });
      expect(snapshot.entries.length, 2);
      expect(source.fetchQuestionCalls, 2);
    });

    test('快照级对照：不传 recordsById 时阶段一读 2 次 + 终态复核 2 次', () async {
      final source = _CountingSource();
      addARecords(source, const ['q0', 'q1']);
      final snapshot = await ExportSnapshot.fromSelection(
        ids: const ['q0', 'q1'],
        excluded: const [],
        route: ExportRoute.a,
        filterText: '全部',
        sortText: '默认',
        source: source,
        tempRoot: tempRoot,
      );
      addTearDown(() async {
        await snapshot.dispose();
      });
      expect(snapshot.entries.length, 2);
      expect(source.fetchQuestionCalls, 4);
    });
  });
}
