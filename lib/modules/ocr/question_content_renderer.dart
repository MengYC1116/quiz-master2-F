// M1 十三批公式渲染器 POC（2026-11-18）。
//
// 统一渲染接口骨架（给 M5 用）：按段类型分发，渲染实现可替换。
// 当前渲染后端：flutter_math_fork 0.7.4（纯 Dart KaTeX 子集）。
// 覆盖率实测见 test/m1_formula_renderer_test.dart 与
// ~/workspace/batch13-work/M1-RENDERER-POC.md。
//
// 铁律：
// - LaTeX 绝不外露：错误回调不展示 fork 默认的报错文本（它含源码与错误
//   信息），一律换成 [ImageFallbackBlock] 的原图占位；不打含 latex 的日志。
// - 渲染失败自动回退原图，不抛异常、不留空白、不阻断其余段落显示。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as fw;
import 'package:flutter_math_fork/flutter_math.dart';

import '../../data/database.dart';
import 'question_content.dart';

/// 十四批 M2：配图图块的图片展示。按 [cropPath]（数据目录相对路径）
/// 读裁图；文件不存在或读不到时显示占位，不抛异常。位置未确认时
/// 在图下方明确标注“位置未确认”。
class FigureImageView extends StatelessWidget {
  const FigureImageView({
    super.key,
    required this.cropPath,
    this.unconfirmed = false,
  });

  final String cropPath;
  final bool unconfirmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final abs = AppDatabase.resolveDataPath(cropPath);
    final file = abs == null ? null : File(abs);
    return Container(
      key: ValueKey('figure-image-$cropPath'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (file != null && file.existsSync())
            Image.file(file, fit: BoxFit.contain)
          else
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_outlined, size: 18),
                SizedBox(width: 6),
                Text('题目配图（图片缺失）'),
              ],
            ),
          if (unconfirmed)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '位置未确认',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }
}

/// 公式原图回退占位。M5 接入时用 [fallbackImage] 传入真实裁图
/// （GLM layout_details 坐标裁出的公式小图，裁不到用整张题切片）；
/// 未传入时显示通用占位，不展示任何公式源码与错误信息。
class FormulaImageFallback extends StatelessWidget {
  const FormulaImageFallback({
    super.key,
    this.fallbackImage,
    this.cropPath,
  });

  final Widget? fallbackImage;
  final String? cropPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('m1-image-fallback'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: fallbackImage ??
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_outlined,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              const Text('公式原图'),
            ],
          ),
    );
  }
}

/// 单个公式段的渲染器：成功显示公式，解析/构建失败自动换原图回退。
///
/// [onFallbackShown] 在回退实际展示后（下一帧）回调一次，供 M5 统计
/// 渲染失败率；回调里只有成败，不含公式内容。
class FormulaView extends StatelessWidget {
  const FormulaView({
    super.key,
    required this.latex,
    this.displayMode = false,
    this.textStyle,
    this.fallbackImage,
    this.cropPath,
    this.onFallbackShown,
  });

  /// 内部数据：仅供渲染器使用，不得展示、复制、打日志。
  final String latex;
  final bool displayMode;
  final TextStyle? textStyle;
  final Widget? fallbackImage;
  final String? cropPath;
  final VoidCallback? onFallbackShown;

  @override
  Widget build(BuildContext context) {
    final math = Math.tex(
      latex,
      mathStyle: displayMode ? MathStyle.display : MathStyle.text,
      textStyle: textStyle ?? DefaultTextStyle.of(context).style,
      // 关键：覆盖 fork 默认回调（它会把含源码的错误文本显示出来）。
      // 失败信号不在 build 期间直接回调（调用方可能 setState），
      // 而是排到下一帧；回调里只有成败，不含公式内容。
      onErrorFallback: (_) {
        final notify = onFallbackShown;
        if (notify != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => notify());
        }
        return FormulaImageFallback(
          fallbackImage: fallbackImage,
          cropPath: cropPath,
        );
      },
    );
    if (displayMode) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: math,
      );
    }
    return math;
  }
}

/// 按段类型分发渲染题目内容。
///
/// - 连续的行内段（TextBlock + 行内 FormulaBlock）拼成一段 RichText，
///   行内公式用 WidgetSpan（PlaceholderAlignment.middle）与中文对齐。
/// - 独立公式（displayMode）单独成行，横向可滚动，防长公式溢出。
/// - CodeBlock 按等宽文本显示；ImageFallbackBlock 显示原图占位。
/// - TableBlock（WP-C #6）：Flutter Table 绘制，横向空间不足时横向滚动；
///   单元格文本自动换行；列宽按内容自适应（IntrinsicColumnWidth，单列最宽
///   [_kMaxTableColumnWidth]，超出横向滚动；定稿未决事项 1，实施方定一版，
///   截图验收时确认）；单元格垂直居中对齐；居中表格包在 Center 里。
/// - HeadingBlock（WP-C #6）：1 级 20 / 2 级 18 / 3 级 16，加粗
///   （标题字号在页面标题 24 与正文 15 之间，按现有标题字号取档）。
class QuestionContentRenderer extends StatelessWidget {
  const QuestionContentRenderer({
    super.key,
    required this.blocks,
    this.textStyle,
    this.formulaTextStyle,
    this.fallbackImage,
    this.onFormulaFallback,
  });

  /// 单列表格列宽上限（逻辑像素）。单元格内容超宽时换行，列不再加宽，
  /// 整表超宽时横向滚动（见 [_buildTableBlock]）。
  static const double kMaxTableColumnWidth = 220;

  final List<QuestionContentBlock> blocks;
  final TextStyle? textStyle;
  final TextStyle? formulaTextStyle;

  /// 公式回退时展示的图片（M5 传入真实裁图）。未传则显示通用占位。
  final Widget? fallbackImage;

  /// 任一公式回退展示后回调（仅成败计数用，不含公式内容）。
  final VoidCallback? onFormulaFallback;

  /// 把一段行内 run 转成 InlineSpan：普通 run 出 TextSpan；
  /// 上下标 run（字号约 70%）出 WidgetSpan + 基线偏移（S7-2）。
  InlineSpan _runSpan(TextRun run, TextStyle base) {
    final style = base.copyWith(
      fontWeight: run.bold ? FontWeight.bold : null,
      fontStyle: run.italic ? FontStyle.italic : null,
    );
    if (run.script == 0) {
      return TextSpan(text: run.text, style: style);
    }
    final baseSize = base.fontSize ?? 14.0;
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Transform.translate(
        offset: Offset(
          0,
          run.script == 1 ? -baseSize * 0.35 : baseSize * 0.2,
        ),
        child: Text(
          run.text,
          style: style.copyWith(fontSize: baseSize * 0.7),
        ),
      ),
    );
  }

  /// 表格块：横向滚动 + 内容自适应列宽 + 单元格垂直居中。
  /// 空表（零行，或全部行零列）渲染为空，不建 Table。
  Widget _buildTableBlock(BuildContext context, TableBlock block) {
    if (block.rows.isEmpty || block.rows.first.isEmpty) {
      return const SizedBox.shrink();
    }
    final table = Table(
      border: TableBorder.all(color: Theme.of(context).colorScheme.outline),
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        for (final row in block.rows)
          TableRow(
            children: [
              for (final cell in row)
                // 注意：Flutter 自带的 TableCell widget 与模型 TableCell
                // （question_content.dart，R4-1 定名）重名，此处用 fw 前缀
                // 明确指 widget；模型类型不加前缀。
                fw.TableCell(
                  verticalAlignment: TableCellVerticalAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: kMaxTableColumnWidth,
                      ),
                      child: QuestionContentRenderer(
                        blocks: cell.children,
                        textStyle: textStyle,
                        formulaTextStyle: formulaTextStyle,
                        fallbackImage: fallbackImage,
                        onFormulaFallback: onFormulaFallback,
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
    final scrolled = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: table,
    );
    if (!block.centered) return scrolled;
    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: constraints.maxWidth.isFinite ? constraints.maxWidth : null,
          child: Center(child: scrolled),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectiveTextStyle =
        textStyle ?? DefaultTextStyle.of(context).style;
    final children = <Widget>[];
    var inlineSpans = <InlineSpan>[];

    void flushInline() {
      if (inlineSpans.isEmpty) return;
      children.add(
        RichText(
          text: TextSpan(style: effectiveTextStyle, children: inlineSpans),
        ),
      );
      inlineSpans = <InlineSpan>[];
    }

    for (final block in blocks) {
      switch (block) {
        case TextBlock(:final text, :final runs):
          // 有样式 run 时按 run 出 span；无 run 时是纯文本段（旧行为）。
          if (runs == null) {
            inlineSpans.add(TextSpan(text: text));
          } else {
            for (final run in runs) {
              inlineSpans.add(_runSpan(run, effectiveTextStyle));
            }
          }
        case FormulaBlock(:final latex, :final displayMode):
          if (displayMode) {
            flushInline();
            children.add(
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: FormulaView(
                  latex: latex,
                  displayMode: true,
                  textStyle: formulaTextStyle ?? effectiveTextStyle,
                  fallbackImage: fallbackImage,
                  onFallbackShown: onFormulaFallback,
                ),
              ),
            );
          } else {
            inlineSpans.add(
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: FormulaView(
                  latex: latex,
                  textStyle: formulaTextStyle ?? effectiveTextStyle,
                  fallbackImage: fallbackImage,
                  onFallbackShown: onFormulaFallback,
                ),
              ),
            );
          }
        case ImageFallbackBlock():
          flushInline();
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: FormulaImageFallback(
                fallbackImage: fallbackImage,
                cropPath: block.cropPath,
              ),
            ),
          );
        case CodeBlock(:final code):
          flushInline();
          children.add(
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  code,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
          );
        case FigureBlock(:final cropPath, :final unconfirmed):
          // 十四批 M2：配图图块段。裁图按相对路径从数据目录读；读不到
          // 时显示占位（不留空白、不阻断其余段落显示）。位置未确认的
          // 图块必须明确标注，绝不静默当成已确认顺序展示。
          flushInline();
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: FigureImageView(
                cropPath: cropPath,
                unconfirmed: unconfirmed,
              ),
            ),
          );
        case TableBlock():
          // WP-C #6：表格块（单元格内按 Column 依次渲染 children，
          // 见 [_buildTableBlock]；嵌套表格已在解析层展平，不会到这里）。
          flushInline();
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _buildTableBlock(context, block),
            ),
          );
        case HeadingBlock(:final text, :final level):
          // WP-C #6：标题块，1 级 20 / 2 级 18 / 3 级 16，加粗。
          flushInline();
          final size = switch (level) {
            1 => 20.0,
            2 => 18.0,
            _ => 16.0,
          };
          children.add(
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(
                text,
                style: effectiveTextStyle.copyWith(
                  fontSize: size,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
      }
    }
    flushInline();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
