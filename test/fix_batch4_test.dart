// 最终自审修复批四（P2 代码卫生与防御）回归测试。
// FR-13/14/15/30/31 是注释与文档类修法：用源码文本断言锁定（行为无变化，
// 唯一能回归的就是文本本身）；FR-22/32/37/38/39 是行为修法：用内存库 /
// 临时目录做真测试，不碰真实演示库（D-45：种子放测试体内、直接 await）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/converters.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/models/exam_event.dart';
import 'package:quiz_master2/models/models.dart';

String _src(String rel) => File(p.join('lib', rel)).readAsStringSync();

int _count(String haystack, String needle) =>
    needle.allMatches(haystack).length;

Question _q(String id) => Question(
  id: id,
  title: '题 $id',
  subjectId: 'math',
  errorTypes: const ['计算错误'],
  createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
);

Future<String?> _examEventsRaw(QuizDatabase db) async {
  final row = await (db.select(
    db.settings,
  )..where((t) => t.key.equals(AppDatabase.examEventsKey))).getSingleOrNull();
  return row?.value;
}

Future<void> _seedExamEventsRaw(QuizDatabase db, String raw) async {
  await db
      .into(db.settings)
      .insert(
        SettingsCompanion.insert(key: 'examEvents', value: raw),
        mode: InsertMode.insertOrReplace,
      );
}

void main() {
  group('FR-13 首页过期注释：D-06 旧优先级规则不再出现在注释里', () {
    test('注释写“取消优先级，按最后活动”，不再写“复习 > 整理 > 收集优先级”', () {
      final src = _src('modules/home/home_page.dart');
      expect(src, contains('取消优先级，按最后活动'));
      expect(src, isNot(contains('复习 > 整理 > 收集优先级')));
    });
  });

  group('FR-14 详情页 _reworkBoxes 文档注释不再重复粘贴', () {
    test('“§1.5.1 重新框选：加载同页全部 1 层框”只出现一次', () {
      final src = _src('modules/detail/question_detail_page.dart');
      expect(
        _count(src, '§1.5.1 重新框选：加载同页全部 1 层框'),
        1,
      );
      // 保留的那份带“确认后的重裁……在 Notifier 里”的后半句。
      expect(src, contains('确认后的重裁 / 事务 / rename 在 Notifier 里'));
    });
  });

  group('FR-15 三处弹窗控制器有释放路径，不再泄漏', () {
    test('详情页：_askText / 新建知识点控制器改字段持有，dispose 覆盖', () {
      final detail = _src('modules/detail/question_detail_page.dart');
      // 字段持有：开新弹窗前释放上一个，页面 dispose 释放最后一个。
      expect(detail, contains('TextEditingController? _askTextCtrl;'));
      expect(detail, contains('TextEditingController? _newKpNameCtrl;'));
      expect(detail, contains('_askTextCtrl?.dispose();'));
      expect(detail, contains('_newKpNameCtrl?.dispose();'));
    });

    test('错题本：批量加标签控制器改字段持有，dispose 覆盖', () {
      final wrongbook = _src('modules/wrongbook/wrongbook_page.dart');
      expect(wrongbook, contains('TextEditingController? _batchAddTagCtrl;'));
      expect(wrongbook, contains('_batchAddTagCtrl?.dispose();'));
    });
  });

  group('FR-22 deleteOrphanFiles：freedBytes 只计删成功的文件', () {
    test('正常删除：freedBytes 等于实际字节数', () async {
      final tmp = await Directory.systemTemp.createTemp('fr22-ok-');
      addTearDown(() => tmp.delete(recursive: true));
      final db = await AppDatabase.openForTest();
      addTearDown(db.close);
      final f = File(p.join(tmp.path, 'slices', 'a.png'))
        ..createSync(recursive: true);
      await f.writeAsBytes(List.filled(123, 7));
      final r = await AppDatabase.deleteOrphanFiles(
        ['slices/a.png'],
        dataDir: tmp.path,
        db: db,
      );
      expect(r.deletedCount, 1);
      expect(r.freedBytes, 123);
      expect(await f.exists(), isFalse);
    });

    test('删除失败不计 freed：先记大小、移入回收站成功后再计入（源码顺序锁定）', () {
      // 直接让文件删失败的注入在当前环境做不到（root 绕过权限位、
      // overlayfs 不支持 chattr +i）：此处锁两点——(a) 成功路径的
      // 数字准确（上一项）；(b) 源码里 `freed += size` 在
      // 移入回收站成功之后，且旧写法 `freed += f.lengthSync()`
      // 已不存在，移入失败进 `if (!moved) continue;` 时 freed
      // 不会被提前计入。
      // WP-C #8（U3-2）：孤儿删除由直接物理删改为移入回收站，
      // 物理删除走 `_moveFileToTrashLocked`（已持锁内部函数，
      // P2 约束 1），顺序锁定随之改到该调用；FR-22 的不变量
      // （只计成功移除的文件）不变。
      // 注意：`freed += size;` 在本文件另有一处（回收站清扫，
      // 402 行附近），故从移入调用处起向后搜，只锁
      // deleteOrphanFilesImpl 循环内的这一处顺序。
      final src = _src('data/db_orphans.dart');
      expect(src, isNot(contains('freed += f.lengthSync()')));
      final sizeAt = src.indexOf('final size = f.lengthSync();');
      final movedAt = src.indexOf('await _moveFileToTrashLocked(');
      expect(sizeAt, greaterThan(0));
      expect(movedAt, greaterThan(sizeAt));
      final notMovedAt = src.indexOf('if (!moved) continue;', movedAt);
      final freedAt = src.indexOf('freed += size;', movedAt);
      expect(notMovedAt, greaterThan(movedAt));
      expect(freedAt, greaterThan(notMovedAt));
    });
  });

  group('FR-30 三个死方法已删除，指南对照表已修正', () {
    test('db_questions.dart 里不再有三者', () {
      final src = _src('data/db_questions.dart');
      expect(src, isNot(contains('deleteCauseRecordsForQuestion')));
      expect(src, isNot(contains('deleteCauseRecord(')));
      expect(src, isNot(contains('addCauseCheckHistory')));
    });

    test('指南不再称 addCauseCheckHistory 仅测试播种用，改记 FR-30 已删', () {
      final guide = File(
        p.join('docs', 'ui-replication', 'A-READING-GUIDE.md'),
      ).readAsStringSync();
      expect(guide, isNot(contains('addCauseCheckHistory / ensureCauseRecords')));
      expect(guide, contains('FR-30 已删'));
      // syncCauseRecords 本身还在（是 deleteCauseRecordsForQuestion
      // 删掉后剩下的那一行），对照表仍有它。
      expect(guide, contains('`syncCauseRecords` | 不发'));
    });
  });

  group('FR-31 事件 kind 订阅口径（D-94 后：订阅方共两个）', () {
    test('data_change_events.dart 头注释写明两个订阅方与预留口径', () {
      final src = _src('data/data_change_events.dart');
      // 十二批 D-94：homeProvider 成为第二个订阅方（只消费
      // recentlyViewed），“当前唯一订阅方”旧口径作废，头注释已改写
      // 为“订阅方共两个”；其余四种 kind 仍无订阅方。
      expect(src, contains('订阅方共两个'));
      expect(src, contains('`badgeCountsProvider` 只消费'));
      expect(
        src,
        contains('`homeProvider` 只消费 `DataChangeKind.recentlyViewed`'),
      );
      expect(src, contains('其余四种 kind'));
      expect(src, contains('为将来订阅方预留'));
    });

    test('指南 §六写明截至 FR-31 其余四种 kind 无订阅方', () {
      final guide = File(
        p.join('docs', 'ui-replication', 'A-READING-GUIDE.md'),
      ).readAsStringSync();
      expect(guide, contains('FR-31（2026-11-17）明确'));
    });
  });

  group('FR-32 编解码双实现对照：同一批边界输入过两套解码结果相等', () {
    const stringListInputs = [
      '',
      '[]',
      '["a","b"]',
      '["a",1,null,"b"]',
      'not-json',
      '[1,2]',
      '{"a":1}',
      '["a",]',
      '["", "x"]',
    ];
    test('StringList：decodeStringList 与 StringListConverter.fromSql', () {
      const converter = StringListConverter();
      for (final input in stringListInputs) {
        expect(
          AppDatabase.decodeStringList(input),
          converter.fromSql(input),
          reason: 'input=$input',
        );
      }
      // null 只过 codec 一侧（Converter 入参非空）：空集合。
      expect(AppDatabase.decodeStringList(null), isEmpty);
      // 编码一侧也一致：空列表写 '[]'。
      expect(AppDatabase.encodeStringList([]), converter.toSql([]));
      expect(
        AppDatabase.encodeStringList(['a', 'b']),
        converter.toSql(['a', 'b']),
      );
    });

    const queueInputs = [
      '',
      '[]',
      '[{"q":"q1","c":"计算错误"}]',
      '[{"q":"q1"}]',
      '[{"q":1,"c":"x"}]',
      'not-json',
      '[{"q":"q1","c":"x"},42,"s"]',
      '[{"q":"","c":""}]',
    ];
    test('Queue：decodeQueue 与 QueueConverter.fromSql', () {
      const converter = QueueConverter();
      for (final input in queueInputs) {
        expect(
          AppDatabase.decodeQueue(input),
          converter.fromSql(input),
          reason: 'input=$input',
        );
      }
      expect(AppDatabase.decodeQueue(null), isEmpty);
      const queue = [
        ReviewQueueItem(questionId: 'q1', cause: '计算错误'),
      ];
      expect(AppDatabase.encodeQueue(queue), converter.toSql(queue));
      expect(AppDatabase.encodeQueue([]), converter.toSql([]));
    });

    const rotationsInputs = [
      '',
      '{}',
      '{"1":90}',
      '{"1":90.5}',
      '{"x":90}',
      '{"1":"90"}',
      'not-json',
      '{"1":90,"2":180}',
      '{"01":45}',
      '{"-1":90}',
    ];
    test('Rotations：decodeRotations 与 RotationsConverter.fromSql', () {
      const converter = RotationsConverter();
      for (final input in rotationsInputs) {
        expect(
          AppDatabase.decodeRotations(input),
          converter.fromSql(input),
          reason: 'input=$input',
        );
      }
      expect(AppDatabase.decodeRotations(null), isEmpty);
      // 编码一侧：Converter 写 '{"1":90}'（codec 无 encodeRotations，
      // 以 jsonEncode 的规范形状对照）。
      expect(converter.toSql({1: 90}), jsonEncode({'1': 90}));
    });

    test('Remedy：decodeRemedyList 与 decodeStringList 同构', () {
      for (final input in stringListInputs) {
        expect(
          AppDatabase.decodeRemedyList(input),
          AppDatabase.decodeStringList(input),
          reason: 'input=$input',
        );
      }
    });
  });

  group('FR-37 批量删题整批事务（内存库）', () {
    test('成功：三道全删，错因记录与切片文件一并清理', () async {
      final tmp = await Directory.systemTemp.createTemp('fr37-ok-');
      addTearDown(() async {
        AppDatabase.testDataDirectory = null;
        await tmp.delete(recursive: true);
      });
      AppDatabase.testDataDirectory = tmp.path;
      final db = await AppDatabase.openForTest();
      addTearDown(db.close);
      for (final id in ['q1', 'q2', 'q3']) {
        await AppDatabase.upsertQuestionInto(
          db,
          _q(id).copyWith(slicePath: 'slices/$id.png'),
        );
        final slice = File(p.join(tmp.path, 'slices', '$id.png'))
          ..createSync(recursive: true);
        await slice.writeAsString('slice-$id');
      }
      await AppDatabase.deleteQuestionsBatchFrom(db, ['q1', 'q2', 'q3']);
      for (final id in ['q1', 'q2', 'q3']) {
        final row = await (db.select(
          db.questions,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        expect(row, isNull, reason: id);
        expect(
          await File(p.join(tmp.path, 'slices', '$id.png')).exists(),
          isFalse,
          reason: id,
        );
      }
    });

    test('中途失败整批回滚：触发器让 q2 的错因记录删失败，三道全在', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(db.close);
      for (final id in ['q1', 'q2', 'q3']) {
        await AppDatabase.upsertQuestionInto(db, _q(id));
      }
      // q2 有一条错因记录；触发器在删它时炸——事务内先删的 q1 必须回滚。
      await db
          .into(db.causeRecords)
          .insert(
            CauseRecordsCompanion.insert(
              questionId: 'q2',
              cause: '计算错误',
              subjectId: 'math',
              joinedAt: 1000,
            ),
          );
      await db.customStatement(
        "CREATE TRIGGER fr37_fail BEFORE DELETE ON cause_records "
        "WHEN OLD.question_id = 'q2' "
        "BEGIN SELECT RAISE(ABORT, 'fr37-injected-failure'); END;",
      );
      await expectLater(
        AppDatabase.deleteQuestionsBatchFrom(db, ['q1', 'q2', 'q3']),
        throwsA(isA<Exception>()),
      );
      for (final id in ['q1', 'q2', 'q3']) {
        final row = await (db.select(
          db.questions,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        expect(row, isNotNull, reason: id);
      }
      final causes = await (db.select(
        db.causeRecords,
      )..where((t) => t.questionId.equals('q2'))).get();
      expect(causes, hasLength(1));
    });

    test('空批：直接返回，不抛错、不发事件', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(db.close);
      await AppDatabase.upsertQuestionInto(db, _q('q1'));
      await AppDatabase.deleteQuestionsBatchFrom(db, []);
      final row = await (db.select(
        db.questions,
      )..where((t) => t.id.equals('q1'))).getSingleOrNull();
      expect(row, isNotNull);
    });
  });

  group('FR-38/FR-39 考试事件：同一事务改原始 JSON 行', () {
    const badRowRaw =
        '[{"id":"e1","name":"高考","date":"2026-12-20"},'
        '{"id":"e2","name":12345,"date":"not-a-date"}]';

    test('FR-39 保存新场：坏行原样保留在库里，读出时仍跳过它', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(db.close);
      await _seedExamEventsRaw(db, badRowRaw);
      await AppDatabase.saveExamEventFrom(
        db,
        ExamEvent(id: 'e3', name: '期末', date: DateTime(2026, 12, 25)),
      );
      final raw = await _examEventsRaw(db);
      expect(raw, isNotNull);
      final list = jsonDecode(raw!) as List;
      expect(list, hasLength(3));
      // 坏行原样保留（id e2、name 仍是数字 12345、日期仍是非法串）。
      expect(list[1], {'id': 'e2', 'name': 12345, 'date': 'not-a-date'});
      expect(list[2]['id'], 'e3');
      // 读侧仍跳过坏行，只读出两场好行。
      final events = await AppDatabase.loadExamEventsFrom(db);
      expect(events.map((e) => e.id), ['e1', 'e3']);
    });

    test('FR-39 删除一场：只删目标行，坏行与另一场好行原样保留', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(db.close);
      await _seedExamEventsRaw(db, badRowRaw);
      await AppDatabase.deleteExamEventFrom(db, 'e1');
      final raw = await _examEventsRaw(db);
      final list = jsonDecode(raw!) as List;
      expect(list, hasLength(1));
      expect(list[0], {'id': 'e2', 'name': 12345, 'date': 'not-a-date'});
      expect(await AppDatabase.loadExamEventsFrom(db), isEmpty);
    });

    test('FR-39 改名目标行：其余好行的未知字段原样保留', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(db.close);
      await _seedExamEventsRaw(
        db,
        '[{"id":"e1","name":"高考","date":"2026-12-20","note":"别动我"},'
        '{"id":"e2","name":"期末","date":"2026-12-25"}]',
      );
      await AppDatabase.saveExamEventFrom(
        db,
        ExamEvent(id: 'e2', name: '期末改名', date: DateTime(2026, 12, 25)),
      );
      final list = jsonDecode((await _examEventsRaw(db))!) as List;
      // e1 行（含未知字段 note）原样保留；e2 行被新值覆盖。
      expect(list[0]['note'], '别动我');
      expect(list[1], {'id': 'e2', 'name': '期末改名', 'date': '2026-12-25'});
    });

    test('FR-38 并发写不丢改动：同时新增两场 + 删一场，三处全生效', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(db.close);
      await AppDatabase.saveExamEventFrom(
        db,
        ExamEvent(id: 'e1', name: '高考', date: DateTime(2026, 12, 20)),
      );
      await Future.wait([
        AppDatabase.saveExamEventFrom(
          db,
          ExamEvent(id: 'e2', name: '期末', date: DateTime(2026, 12, 25)),
        ),
        AppDatabase.saveExamEventFrom(
          db,
          ExamEvent(id: 'e3', name: '月考', date: DateTime(2026, 12, 10)),
        ),
        AppDatabase.deleteExamEventFrom(db, 'e1'),
      ]);
      final events = await AppDatabase.loadExamEventsFrom(db);
      expect(events.map((e) => e.id).toSet(), {'e2', 'e3'});
    });

    test('FR-38 同 id 并发改名：不丢另一场，只剩最后一次的改名结果', () async {
      final db = await AppDatabase.openForTest();
      addTearDown(db.close);
      await AppDatabase.saveExamEventFrom(
        db,
        ExamEvent(id: 'e1', name: '高考', date: DateTime(2026, 12, 20)),
      );
      await AppDatabase.saveExamEventFrom(
        db,
        ExamEvent(id: 'e2', name: '期末', date: DateTime(2026, 12, 25)),
      );
      await Future.wait([
        AppDatabase.saveExamEventFrom(
          db,
          ExamEvent(id: 'e1', name: '高考A', date: DateTime(2026, 12, 20)),
        ),
        AppDatabase.saveExamEventFrom(
          db,
          ExamEvent(id: 'e1', name: '高考B', date: DateTime(2026, 12, 20)),
        ),
      ]);
      final events = await AppDatabase.loadExamEventsFrom(db);
      expect(events.map((e) => e.id).toSet(), {'e1', 'e2'});
      expect(events.firstWhere((e) => e.id == 'e1').name, '高考B');
    });
  });
}
