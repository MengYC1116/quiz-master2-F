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
class QuestionContentRenderer extends StatelessWidget {
  const QuestionContentRenderer({
    super.key,
    required this.blocks,
    this.textStyle,
    this.formulaTextStyle,
    this.fallbackImage,
    this.onFormulaFallback,
  });

  final List<QuestionContentBlock> blocks;
  final TextStyle? textStyle;
  final TextStyle? formulaTextStyle;

  /// 公式回退时展示的图片（M5 传入真实裁图）。未传则显示通用占位。
  final Widget? fallbackImage;

  /// 任一公式回退展示后回调（仅成败计数用，不含公式内容）。
  final VoidCallback? onFormulaFallback;

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
        case TextBlock(:final text):
          inlineSpans.add(TextSpan(text: text));
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
