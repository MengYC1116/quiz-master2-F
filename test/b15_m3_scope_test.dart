// 十五批 M3：范围筛选 + 50 道上限选择状态（M1-DESIGN.md §2，D-168）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/pdf_export/export_scope.dart';

Question sq(
  String id, {
  String subjectId = 'math',
  List<String> folderIds = const [],
  String? examId,
  List<String> errorTypes = const [],
  List<String> knowledgePointIds = const [],
  DateTime? createdAt,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: subjectId,
  folderIds: folderIds,
  examId: examId,
  errorTypes: errorTypes,
  knowledgePointIds: knowledgePointIds,
  createdAt: createdAt ?? DateTime(2026, 11, 20),
);

void main() {
  group('范围筛选 applyExportScopeFilter', () {
    final base = [
      sq('q1', subjectId: 'math', folderIds: ['f1'], examId: 'e1',
          errorTypes: ['计算错误'], knowledgePointIds: ['k1']),
      sq('q2', subjectId: 'math', folderIds: ['f1c'],
          knowledgePointIds: ['k2']),
      sq('q3', subjectId: 'english', folderIds: ['f2'], examId: 'e1'),
      sq('q4', subjectId: 'math', folderIds: ['f9'],
          createdAt: DateTime(2026, 11, 1)),
    ];
    final folders = [
      const Folder(id: 'f1', name: '试卷', subjectId: 'math'),
      const Folder(id: 'f1c', name: '子卷', subjectId: 'math', parentId: 'f1'),
      const Folder(id: 'f2', name: '作业', subjectId: 'english'),
      const Folder(id: 'f9', name: '其他', subjectId: 'math'),
    ];

    test('空条件 = 不圈定，返回全部', () {
      expect(
        applyExportScopeFilter(base, folders, const ExportScopeFilter()),
        hasLength(4),
      );
    });

    test('学科筛选', () {
      final out = applyExportScopeFilter(
        base,
        folders,
        const ExportScopeFilter(subjectId: 'english'),
      );
      expect(out.map((q) => q.id), ['q3']);
    });

    test('文件夹筛选含子文件夹子树', () {
      final out = applyExportScopeFilter(
        base,
        folders,
        const ExportScopeFilter(folderId: 'f1'),
      );
      expect(out.map((q) => q.id), ['q1', 'q2']);
    });

    test('考试 + 错因 + 知识点筛选', () {
      expect(
        applyExportScopeFilter(
          base,
          folders,
          const ExportScopeFilter(examId: 'e1'),
        ).map((q) => q.id),
        ['q1', 'q3'],
      );
      expect(
        applyExportScopeFilter(
          base,
          folders,
          const ExportScopeFilter(causeName: '计算错误'),
        ).map((q) => q.id),
        ['q1'],
      );
      expect(
        applyExportScopeFilter(
          base,
          folders,
          const ExportScopeFilter(kpId: 'k2'),
        ).map((q) => q.id),
        ['q2'],
      );
    });

    test('时间筛选：最近一周含今天（age < 7），最近 30 天（age < 30）', () {
      final now = DateTime(2026, 11, 21);
      final week = applyExportScopeFilter(
        base,
        folders,
        const ExportScopeFilter(timeRange: 'week'),
        now: now,
      );
      expect(week.map((q) => q.id), ['q1', 'q2', 'q3']);
      final month = applyExportScopeFilter(
        base,
        folders,
        const ExportScopeFilter(timeRange: 'month'),
        now: now,
      );
      expect(month.map((q) => q.id), ['q1', 'q2', 'q3', 'q4']);
    });

    test('范围摘要：未设条件为“全部题目”，否则按段拼接', () {
      expect(
        exportScopeSummaryText(filter: const ExportScopeFilter()),
        '全部题目',
      );
      expect(
        exportScopeSummaryText(
          filter: const ExportScopeFilter(
            subjectId: 'math',
            causeName: '计算错误',
            timeRange: 'week',
          ),
          subjectName: '数学',
        ),
        '学科：数学；错因：计算错误；时间：最近一周',
      );
    });
  });

  group('50 道上限 ExportSelection', () {
    test('范围 ≤ 50：默认全选，无提示，计数“已选 N / 50 道”', () {
      final sel = ExportSelection(
        rangeIds: ['q1', 'q2', 'q3'],
      );
      expect(sel.selectedCount, 3);
      expect(sel.initialNotice, isNull);
      expect(sel.countText, '已选 3 / 50 道');
    });

    test('范围 60 道：默认只选中前 50 道 + 明示提示', () {
      final ids = List.generate(60, (i) => 'q$i');
      final sel = ExportSelection(rangeIds: ids);
      expect(sel.selectedCount, 50);
      expect(sel.selectedIds, ids.take(50).toSet());
      expect(
        sel.initialNotice,
        '范围共 60 道，已按当前排序选中前 50 道，'
        '其余题目未选中。你可以调整本次选择。',
      );
      expect(sel.countText, '已选 50 / 50 道');
    });

    test('点选第 51 道拒绝 + 提示“单次最多导出 50 道题”，选择不变', () {
      final ids = List.generate(60, (i) => 'q$i');
      final sel = ExportSelection(rangeIds: ids);
      final msg = sel.toggle('q50');
      expect(msg, '单次最多导出 50 道题');
      expect(sel.selectedCount, 50);
      expect(sel.isSelected('q50'), isFalse);
      // 取消一题后再点选同一题可以选上。
      expect(sel.toggle('q0'), isNull);
      expect(sel.toggle('q50'), isNull);
      expect(sel.selectedCount, 50);
    });

    test('已手动选部分题再点全选 = 替换为当前范围前 50 道', () {
      final ids = List.generate(60, (i) => 'q$i');
      final sel = ExportSelection(rangeIds: ids);
      sel.selectNone();
      sel.toggle('q55');
      sel.toggle('q59');
      expect(sel.selectedCount, 2);
      final notice = sel.selectAll();
      expect(sel.selectedCount, 50);
      expect(sel.selectedIds, ids.take(50).toSet());
      expect(notice, contains('范围共 60 道'));
    });

    test('确认前断言：超限返回阻断原因（正常流程不可达）', () {
      final sel = ExportSelection(rangeIds: ['q1']);
      sel.selectedIds.addAll(List.generate(60, (i) => 'x$i'));
      expect(sel.capViolation(), '单次最多导出 50 道题');
    });
  });
}
