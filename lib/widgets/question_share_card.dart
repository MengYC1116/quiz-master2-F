// B11-8：导出带答案版的分享卡片（题目图在上、答案/解析在下）。
//
// 纯展示 widget：详情页把它放进弹窗里的 RepaintBoundary，点保存时
// QuestionExportService.captureBoundary 转 PNG。答案/解析为空时该区
// 显示“待补充”，不编造内容。颜色只取 DesignTokens；卡片跟随当前
// 主题（亮/深），与详情页一致。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import 'uikit.dart';

/// 分享卡片：固定内容宽 720（导出 PNG 时按 pixelRatio 2.0 转，
/// 约 1440px 宽，手机上看够清晰）。
class QuestionShareCard extends StatelessWidget {
  const QuestionShareCard({
    super.key,
    required this.sliceBytes,
    required this.title,
    required this.subjectName,
    required this.folderNames,
    required this.errorTypes,
    required this.answer,
    required this.explanation,
  });

  /// 切片 PNG 原始字节（题目图）。
  final Uint8List sliceBytes;

  /// 题名。
  final String title;

  /// 学科名。
  final String subjectName;

  /// 本题所在文件夹名（可空）。
  final List<String> folderNames;

  /// 全部错因名（固定 + 自定义，可空）。
  final List<String> errorTypes;

  /// 答案（可空）；解析（可空）。空时卡片显示“待补充”。
  final String? answer;
  final String? explanation;

  @override
  Widget build(BuildContext context) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final scale = qmScaleOf(context);
    final metaParts = <String>[subjectName];
    if (folderNames.isNotEmpty) metaParts.add(folderNames.join('、'));
    if (errorTypes.isNotEmpty) metaParts.add(errorTypes.join('、'));
    return Container(
      width: 720 * scale,
      color: palette.surface,
      padding: EdgeInsets.all(24 * scale),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            metaParts.join(' ｜ '),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: palette.muted,
              height: 1.4,
            ),
          ),
          SizedBox(height: 8 * scale),
          Text(
            title,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: palette.ink,
              height: 1.4,
            ),
          ),
          SizedBox(height: 16 * scale),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: palette.paper,
              border: Border.all(color: palette.paperLine),
              borderRadius: BorderRadius.circular(10 * scale),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10 * scale),
              child: Image.memory(
                sliceBytes,
                width: double.infinity,
                fit: BoxFit.contain,
              ),
            ),
          ),
          SizedBox(height: 16 * scale),
          Divider(height: 1, color: palette.line),
          SizedBox(height: 16 * scale),
          _textRow(context, '答案', answer),
          SizedBox(height: 12 * scale),
          _textRow(context, '解析', explanation),
          SizedBox(height: 16 * scale),
          Text(
            'quiz-master2 错题本',
            style: TextStyle(fontSize: 12, color: palette.muted, height: 1.4),
          ),
        ],
      ),
    );
  }

  /// “答案 / 解析”各一行：label 13px/700 ink-2，值 15px ink；
  /// 空值显示“待补充”（muted，不编造内容）。
  Widget _textRow(BuildContext context, String label, String? value) {
    final palette = DesignTokens.of(Theme.of(context).brightness);
    final hasValue = (value ?? '').trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: palette.ink2,
            height: 1.4,
          ),
        ),
        SizedBox(height: 4 * qmScaleOf(context)),
        Text(
          hasValue ? value!.trim() : '待补充',
          style: TextStyle(
            fontSize: 15,
            color: hasValue ? palette.ink : palette.muted,
            height: 1.6,
          ),
        ),
      ],
    );
  }
}
