// Batch 11 第 4 项：整理工作台“上一道”（最小版）。
// 注：按钮本身在 R5 已存在（_workActs 的上一道 / 下一道；_goTo 切题时
// 经 _trySaveCurrent 自动保存、再 _loadForm 重建表单，队列顺序本身不
// 动；第一道时 onPressed 为 null，_QmPressable 按 disabled 处理：
// 透明度 .45、不可点、不可聚焦）。本文件钉住第 4 项的验收行为：
// 第一道时禁用、到第二道后启用、点回第一道已填内容原样。
// 内容往返的完整覆盖另见 organize_page_test.dart 的 SR2-6
// （改表单 → 下一道 → 上一道 → 保存草稿）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/widgets/uikit.dart';

import 'organize_page_test.dart' show pumpOrganize, threeQuestionRepo;

void main() {
  group('B11-4 整理返回上一道', () {
    QmButton prevButton(WidgetTester tester) =>
        tester.widget<QmButton>(find.widgetWithText(QmButton, '上一道'));

    QmButton nextButton(WidgetTester tester) =>
        tester.widget<QmButton>(find.widgetWithText(QmButton, '下一道'));

    /// 与 SR2-6 组同款：改当前题表单（选文件夹「平时作业」+ 填答案）。
    Future<void> editCurrentForm(WidgetTester tester) async {
      await tester.ensureVisible(find.text('平时作业').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('平时作业').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('答案 · 解析 · 笔记（可选）'));
      await tester.pumpAndSettle();
      final answerField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '还没想好可留空',
      );
      await tester.enterText(answerField, '答案：1');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('队列'));
      await tester.pumpAndSettle();
    }

    testWidgets('第一道时“上一道”禁用，点按不切题；“下一道”启用',
        (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      expect(find.textContaining('数学 · 函数极限'), findsOneWidget);
      expect(prevButton(tester).onPressed, isNull);
      expect(nextButton(tester).onPressed, isNotNull);
      // 禁用态点按无反应：仍在第一道，也没产生保存。
      await tester.ensureVisible(find.text('上一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上一道'));
      await tester.pumpAndSettle();
      expect(find.textContaining('数学 · 函数极限'), findsOneWidget);
      expect(repo.saved, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('到第二道后“上一道”启用；点回第一道，改动内容原样',
        (tester) async {
      final repo = threeQuestionRepo();
      await pumpOrganize(tester, repo: repo);
      await editCurrentForm(tester);
      await tester.ensureVisible(find.text('下一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一道'));
      await tester.pumpAndSettle();
      expect(find.textContaining('数学 · 导数综合'), findsOneWidget);
      expect(prevButton(tester).onPressed, isNotNull);
      await tester.ensureVisible(find.text('上一道'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上一道'));
      await tester.pumpAndSettle();
      expect(find.textContaining('数学 · 函数极限'), findsOneWidget);
      // 切回来后表单仍是改动后的值（文件夹已选，必填已齐）。
      expect(find.textContaining('本题必填已齐'), findsOneWidget);
      // 切题时自动保存已落盘：答案与文件夹都在。
      final saves = repo.saved.where((x) => x.id == 'q1').toList();
      expect(saves, isNotEmpty);
      expect(saves.last.folderIds, contains('f2'));
      expect(saves.last.answer, '答案：1');
      // 回到第一道后“上一道”再次禁用。
      expect(prevButton(tester).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
