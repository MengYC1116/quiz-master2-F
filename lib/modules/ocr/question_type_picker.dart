// 十四批 M1：题型 chip + 选择器（整理页与详情页共用）。
//
// 题型 chip：显示当前主题型（NULL 显示“待确认”），点开选择器改；
// 改后写 question_type_source='manual'（见 [withManualQuestionType]）。
// 背景标签 v1 不做任何 UI、不做筛选（PLAN-14-REV4.3 M1 P1-1），
// 本文件只处理主题型。
// 风格：minimalist × professional + 年轻学习伙伴感；复用 QmChip，
// 不做卡片堆叠/数据墙/渐变/玻璃。

import 'package:flutter/material.dart';

import '../../theme/design_tokens.dart';
import '../../widgets/uikit.dart';
import 'question_classifier.dart';

/// 题型 chip：选中态（有题型）用 accent 填充；待确认用未选中态。
/// 点开选择器改题型。
Widget questionTypeChip({
  required String? type,
  required VoidCallback onTap,
}) {
  return QmChip(
    label: questionTypeDisplay(type),
    selected: type != null,
    onTap: onTap,
  );
}

/// 选择题型弹窗。
/// 返回：选中的题型值；'' 表示用户选了“待确认”；null 表示取消未选。
Future<String?> showQuestionTypePicker(
  BuildContext context,
  String? current,
) {
  final palette = DesignTokens.of(Theme.of(context).brightness);
  Widget row(String? value, String label) {
    final selected = value == current;
    return InkWell(
      onTap: () => Navigator.of(context).pop(value ?? ''),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  color: selected ? palette.accentText : palette.ink,
                ),
              ),
            ),
            if (selected)
              Text(
                '✓',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: palette.accentText,
                ),
              ),
          ],
        ),
      ),
    );
  }

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('选择题型', style: TextStyle(fontSize: 16)),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      contentPadding: EdgeInsets.zero,
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row(null, '待确认'),
            const Divider(height: 1),
            for (final v in questionTypeValues) row(v, questionTypeLabels[v]!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}
