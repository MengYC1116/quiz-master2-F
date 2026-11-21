// 十五批 M1-B：快照工厂 + 一致性 + 哈希分类 + 互斥测试
// （M1-DESIGN.md §2/§6，D-178/D-179）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/services/pdf_export/export_route.dart';
import 'package:quiz_master2/services/pdf_export/export_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/slice_snapshot.dart';
import 'package:quiz_master2/services/pdf_export/slice_write_guard.dart';
import 'package:quiz_master2/services/pdf_export/snapshot_exceptions.dart';

import 'b15_m1b_fake_source.dart';

void main() {
  late Directory tempRoot;
  late FakeExportQuestionSource source;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('b15-m1b-snap-');
    source = FakeExportQuestionSource();
    SliceSnapshot.debugOnTempCopied = null;
  });

  tearDown(() async {
    SliceSnapshot.debugOnTempCopied = null;
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<ExportSnapshot> buildA(
    List<String> ids, {
    List<ExcludedQuestion> excluded = const [],
  }) {
    return ExportSnapshot.fromSelection(
      ids: ids,
      excluded: excluded,
      route: ExportRoute.a,
      filterText: '全部',
      sortText: '默认排序',
      source: source,
      tempRoot: tempRoot,
    );
  }

  Future<ExportSnapshot> buildC(
    List<String> ids, {
    List<ExcludedQuestion> excluded = const [],
  }) {
    return ExportSnapshot.fromSelection(
      ids: ids,
      excluded: excluded,
      route: ExportRoute.c,
      filterText: '全部',
      sortText: '默认排序',
      source: source,
      tempRoot: tempRoot,
    );
  }

  void addSliceQuestion(String id, {int w = 200, int h = 100}) {
    final bytes = makePng(w, h);
    source.records[id] = choiceRecord(id: id, sliceWidth: w, sliceHeight: h);
    source.slices[id] = bytes;
  }

  group('50 道上限 enforcement（§2 第 3 点）', () {
    test('快照拒超限：51 道抛 ArgumentError，不截断', () async {
      final ids = List.generate(51, (i) => 'q$i');
      for (final id in ids) {
        addSliceQuestion(id);
      }
      await expectLater(
        () => buildA(ids),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('单次最多导出 50 道题'),
          ),
        ),
      );
      // 不截断：超限时不建快照、不留临时目录。
      expect(tempRoot.listSync(), isEmpty);
    });

    test('恰好 50 道通过', () async {
      final ids = List.generate(50, (i) => 'q$i');
      for (final id in ids) {
        addSliceQuestion(id);
      }
      final snap = await buildA(ids);
      expect(snap.questionCount, 50);
      expect(snap.selectedCount, 50);
      await snap.dispose();
    });

    test('空选中抛 ArgumentError', () async {
      expect(
        () => buildA(const []),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('重复 ID 抛 ArgumentError', () async {
      addSliceQuestion('q1');
      expect(
        () => buildA(const ['q1', 'q1']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('排除题不在选中内抛 ArgumentError', () async {
      addSliceQuestion('q1');
      expect(
        () => buildA(
          const ['q1'],
          excluded: const [ExcludedQuestion(id: 'qX', reason: '用户主动排除')],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('跳过题占名额：50 道选中含 1 道跳过，不补入第 51 道', () async {
      final ids = List.generate(50, (i) => 'q$i');
      for (final id in ids) {
        addSliceQuestion(id);
      }
      // q0 的切片不可用 → C 路线下图块缺失但正文仍可印；
      // 用 A 路线验证更直接：q0 无切片 → BROKEN，占名额。
      source.slices.remove('q0');
      final snap = await buildA(ids);
      expect(snap.questionCount, 50);
      expect(snap.selectedCount, 50);
      expect(snap.brokenCount, 1);
      expect(snap.printableCount, 49);
      // 快照只含选中的 50 道，没有第 51 道。
      expect(snap.questionIds, ids);
      await snap.dispose();
    });
  });

  group('A 路线快照：复制 + 哈希 + 清理', () {
    test('切片流式复制到临时目录，哈希一致', () async {
      addSliceQuestion('q1', w: 300, h: 200);
      final snap = await buildA(const ['q1']);
      final entry = snap.entries.single;
      expect(entry.outcome, SnapshotOutcome.ready);
      expect(entry.sliceCopy, isNotNull);
      expect(
        entry.sliceCopy!.sourceHash,
        entry.sliceCopy!.tempHash,
      );
      expect(entry.sliceCopy!.dimensions.width, 300);
      expect(entry.sliceCopy!.dimensions.height, 200);
      final tempFile = File(
        '${snap.tempDir.path}/slices/0-q1.png',
      );
      expect(tempFile.existsSync(), isTrue);
      expect(
        tempFile.readAsBytesSync(),
        source.slices['q1'],
      );
      await snap.dispose();
      expect(snap.tempDir.existsSync(), isFalse);
    });

    test('源切片缺失 → BROKEN 占位，继续其余题', () async {
      addSliceQuestion('q1');
      source.records['q2'] = choiceRecord(id: 'q2');
      // q2 无切片字节。
      final snap = await buildA(const ['q1', 'q2']);
      expect(snap.entries[0].outcome, SnapshotOutcome.ready);
      expect(snap.entries[1].outcome, SnapshotOutcome.broken);
      expect(snap.brokenCount, 1);
      expect(snap.printableCount, 1);
      expect(snap.questionCount, 2);
      await snap.dispose();
    });

    test('源切片不是合法 PNG → BROKEN，不整单中止', () async {
      addSliceQuestion('q1');
      source.records['q2'] = choiceRecord(id: 'q2');
      source.slices['q2'] = makePngHeadOnly(100, 100).sublist(0, 20);
      final snap = await buildA(const ['q1', 'q2']);
      expect(snap.entries[1].outcome, SnapshotOutcome.broken);
      expect(snap.printableCount, 1);
      await snap.dispose();
    });

    test('任务结束清理整个临时目录', () async {
      addSliceQuestion('q1');
      final snap = await buildA(const ['q1']);
      final dir = snap.tempDir;
      expect(dir.existsSync(), isTrue);
      await snap.dispose();
      expect(dir.existsSync(), isFalse);
    });
  });

  group('快照冻结（生成中改筛选/改题不影响）', () {
    test('快照后改源行与切片，快照值与临时副本不变', () async {
      addSliceQuestion('q1');
      addSliceQuestion('q2');
      final snap = await buildC(const ['q1', 'q2']);
      final frozenStem = snap.entries[0].ocrContent!.stemText;
      // 快照后改源：换题干、换切片、抬版本。
      source.records['q1'] = choiceRecord(
        id: 'q1',
        ocrStem: '改过的题干',
        contentVersion: 99,
      );
      source.slices['q1'] = makePng(400, 300);
      // 冻结内容不受影响（题干值已冻结在快照内）。
      expect(snap.entries[0].ocrContent!.stemText, frozenStem);
      expect(snap.entries[0].ocrContent!.stemText, '求下列各题的值');
      await snap.dispose();
    });

    test('A 路线：快照后换切片，临时副本仍是快照时刻的字节', () async {
      addSliceQuestion('q1');
      final original = source.slices['q1']!;
      final snap = await buildA(const ['q1']);
      source.slices['q1'] = makePng(400, 300);
      final tempBytes = File(
        '${snap.tempDir.path}/slices/0-q1.png',
      ).readAsBytesSync();
      expect(tempBytes, original);
      expect(snap.entries.single.sourceHash, isNotNull);
      await snap.dispose();
    });
  });

  group('快照一致性（D-178：终态复核）', () {
    test('两题之间切片重框 → 整单失效 + 清理临时目录', () async {
      addSliceQuestion('q1');
      addSliceQuestion('q2');
      // 第 2 次 openSliceBytes 调用（q2 复制时）把 q1 的切片换掉，
      // 模拟“第 1 题复制完后用户重框该题切片”。
      source.onOpenSlice = (callIndex, record) {
        if (callIndex == 2) {
          source.slices['q1'] = makePng(400, 300);
        }
      };
      await expectLater(
        () => buildA(const ['q1', 'q2']),
        throwsA(
          isA<SnapshotChangedException>().having(
            (e) => e.message,
            'message',
            '快照期间题目内容发生变化，请重试',
          ),
        ),
      );
      // 整单失效后临时目录已清理（tempRoot 下无残留）。
      expect(tempRoot.listSync(), isEmpty);
    });

    test('两题之间备份恢复（整批切片替换）→ 整单失效', () async {
      addSliceQuestion('q1');
      addSliceQuestion('q2');
      source.onOpenSlice = (callIndex, record) {
        if (callIndex == 2) {
          // 模拟备份恢复整目录替换：两题切片全换。
          source.slices['q1'] = makePng(111, 111);
          source.slices['q2'] = makePng(222, 222);
        }
      };
      await expectLater(
        () => buildC(const ['q1', 'q2']),
        throwsA(isA<SnapshotChangedException>()),
      );
      expect(tempRoot.listSync(), isEmpty);
    });

    test('两题之间文件替换（同名文件内容变）→ 整单失效', () async {
      addSliceQuestion('q1');
      addSliceQuestion('q2');
      source.onOpenSlice = (callIndex, record) {
        if (callIndex == 2) {
          // q1 已复制完（第 1 次调用），此时替换 q1 的同名文件内容：
          // 尺寸不变，只在末尾补一个字节（哈希变，IHDR 仍合法）。
          final old = source.slices['q1']!;
          source.slices['q1'] = Uint8List.fromList([...old, 0x00]);
        }
      };
      await expectLater(
        () => buildA(const ['q1', 'q2']),
        throwsA(isA<SnapshotChangedException>()),
      );
    });

    test('内容版本变化 → 整单失效', () async {
      addSliceQuestion('q1');
      addSliceQuestion('q2');
      source.onOpenSlice = (callIndex, record) {
        if (callIndex == 2) {
          // q1 行内容版本抬升（纠错保存），切片不变。
          source.records['q1'] = choiceRecord(id: 'q1', contentVersion: 7);
        }
      };
      await expectLater(
        () => buildA(const ['q1', 'q2']),
        throwsA(isA<SnapshotChangedException>()),
      );
    });

    test('快照期间无变化 → 正常完成', () async {
      addSliceQuestion('q1');
      addSliceQuestion('q2');
      final snap = await buildA(const ['q1', 'q2']);
      expect(snap.questionCount, 2);
      expect(snap.printableCount, 2);
      await snap.dispose();
    });

    test('快照完成后才变化 → 不影响已冻结的快照', () async {
      addSliceQuestion('q1');
      final original = source.slices['q1']!;
      final snap = await buildA(const ['q1']);
      // 快照完成后源变化：快照条目与临时副本保持冻结值。
      source.slices['q1'] = makePng(400, 300);
      source.records['q1'] = choiceRecord(id: 'q1', contentVersion: 5);
      expect(snap.entries.single.sourceHash, isNotNull);
      final tempBytes = File(
        '${snap.tempDir.path}/slices/0-q1.png',
      ).readAsBytesSync();
      expect(tempBytes, original);
      await snap.dispose();
    });
  });

  group('哈希失败分类（D-179）', () {
    test('源切片损坏归题目级：BROKEN，不整单中止', () async {
      addSliceQuestion('q1');
      source.records['q2'] = choiceRecord(id: 'q2');
      source.slices['q2'] = makePngHeadOnly(100, 100).sublist(0, 10);
      final snap = await buildA(const ['q1', 'q2']);
      expect(snap.entries[1].outcome, SnapshotOutcome.broken);
      expect(snap.printableCount, 1);
      await snap.dispose();
    });

    test('临时副本哈希不一致归整单失败（写盘后被改写）', () async {
      addSliceQuestion('q1');
      SliceSnapshot.debugOnTempCopied = (target) async {
        // 模拟外部改写临时副本：复核哈希必然不一致。
        await target.writeAsBytes(makePng(50, 50));
      };
      await expectLater(
        () => buildA(const ['q1']),
        throwsA(isA<SnapshotIntegrityException>()),
      );
      expect(tempRoot.listSync(), isEmpty);
    });

    test('verifyTempCopy：副本被改后核对返回 false', () async {
      final dir = await tempRoot.createTemp('verify-');
      final file = File('${dir.path}/copy.png');
      final bytes = makePng(100, 80);
      await file.writeAsBytes(bytes);
      final goodHash = hashBytes(bytes);
      expect(
        await SliceSnapshot.verifyTempCopy(
          tempFile: file,
          expectedHash: goodHash,
        ),
        isTrue,
      );
      await file.writeAsBytes(makePng(101, 80));
      expect(
        await SliceSnapshot.verifyTempCopy(
          tempFile: file,
          expectedHash: goodHash,
        ),
        isFalse,
      );
      expect(
        await SliceSnapshot.verifyTempCopy(
          tempFile: File('${dir.path}/missing.png'),
          expectedHash: goodHash,
        ),
        isFalse,
      );
    });
  });

  group('SliceWriteGuard 互斥', () {
    test('同一把锁串行化：快照在持锁期间等待，释锁后继续', () async {
      addSliceQuestion('q1');
      final guard = SliceWriteGuard.instance;
      final release = Completer<void>();
      // 先占住锁（不释放）。
      final holder = guard.withLock(() => release.future);
      var snapshotDone = false;
      final snapFuture = buildA(const ['q1']).then((snap) {
        snapshotDone = true;
        return snap;
      });
      // 等快照启动（临时目录已建，说明已进入构建阶段）再断言它在
      // 取锁处挂起；只用 microtask，不依赖真实时间。
      for (var i = 0; i < 200 && tempRoot.listSync().isEmpty; i++) {
        await Future.microtask(() {});
      }
      expect(tempRoot.listSync(), isNotEmpty);
      expect(snapshotDone, isFalse);
      release.complete();
      await holder;
      final snap = await snapFuture;
      expect(snapshotDone, isTrue);
      expect(snap.questionCount, 1);
      await snap.dispose();
    });

    test('两个 withLock 按序执行，不交错', () async {
      final guard = SliceWriteGuard.instance;
      final order = <int>[];
      await Future.wait([
        guard.withLock(() async {
          order.add(1);
        }),
        guard.withLock(() async {
          order.add(2);
        }),
      ]);
      expect(order, [1, 2]);
    });
  });

  group('C 路线快照：跳过与冻结', () {
    test('无 OCR 结果的题记 SKIPPED，快照其余题继续', () async {
      addSliceQuestion('q1');
      source.records['q2'] = choiceRecord(id: 'q2', ocrRaw: null);
      source.slices['q2'] = makePng(200, 100);
      final snap = await buildC(const ['q1', 'q2']);
      expect(snap.entries[0].outcome, SnapshotOutcome.ready);
      expect(snap.entries[1].outcome, SnapshotOutcome.skipped);
      expect(snap.entries[1].skipReason, '无 OCR 结果');
      expect(snap.skippedCount, 1);
      expect(snap.printableCount, 1);
      await snap.dispose();
    });

    test('行已删除的题记 SKIPPED（题目不存在）', () async {
      addSliceQuestion('q1');
      final snap = await buildC(const ['q1', 'q-missing']);
      expect(snap.entries[1].outcome, SnapshotOutcome.skipped);
      expect(snap.entries[1].skipReason, '题目不存在');
      await snap.dispose();
    });

    test('快照记录 route 与筛选条件（冻结）', () async {
      addSliceQuestion('q1');
      final snap = await buildC(const ['q1']);
      expect(snap.route, ExportRoute.c);
      expect(snap.filterText, '全部');
      expect(snap.sortText, '默认排序');
      expect(snap.questionIds, const ['q1']);
      await snap.dispose();
    });

    test('排除题不计入快照题数，但计入选中题数', () async {
      addSliceQuestion('q1');
      addSliceQuestion('q2');
      final snap = await buildA(
        const ['q1', 'q2'],
        excluded: const [ExcludedQuestion(id: 'q2', reason: '用户主动排除')],
      );
      expect(snap.questionCount, 1);
      expect(snap.selectedCount, 2);
      expect(snap.excluded.length, 1);
      expect(snap.questionIds, const ['q1']);
      expect(snap.conservationError(), isNull);
      await snap.dispose();
    });
  });
}
