// 十四批 M2：图块坐标换算、筛选、阅读顺序、裁图与 formula_crop 附带修复。
// 纯单测（不碰库、不调真实接口）。样本坐标取真实样本核对值：
// - pad-a30 single01-q2：切片 1235×146、请求图 1975×232、
//   layout text 块 [370, 45, 1605, 187]（padX=370、padY=44）；
// - 政治卷 p01：页 2400×1737、header_image [57, 50, 177, 170]
//   （padX=720、padY=521），只校验换算本身，不是题目插图。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:quiz_master2/modules/ocr/formula_crop.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';

/// layout_details 一页里的一个块（真实 GLM 形状：页是块列表）。
Map<String, Object?> block({
  required List<int> bbox,
  required String label,
  String nativeLabel = 'text',
  required int width,
  required int height,
  int index = 0,
  String content = '',
}) => {
  'bbox_2d': bbox,
  'label': label,
  'native_label': nativeLabel,
  'width': width,
  'height': height,
  'index': index,
  'content': content,
};

GlmOcrRawData raw({
  required String mdResults,
  required List<List<Map<String, Object?>>> pages,
  OcrRequestTransform? transform,
  String? inputHash,
}) => GlmOcrRawData(
  mdResults: mdResults,
  layoutDetails: pages,
  transform: transform,
  inputHash: inputHash,
);

/// 100×50 纯色切片字节（裁图测试用）。
Uint8List sliceBytes({int width = 100, int height = 50}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 30, 40));
  return img.encodePng(image);
}

void main() {
  group('坐标换算 convertApiBboxToSrc', () {
    test('真实样本 single01-q2：加白边请求换算后几乎整张切片', () {
      const transform = OcrRequestTransform(
        srcW: 1235,
        srcH: 146,
        reqW: 1975,
        reqH: 232,
        padX: 370,
        padY: 44,
      );
      final rect = convertApiBboxToSrc(
        bbox: const [370, 45, 1605, 187],
        spaceWidth: 1975,
        spaceHeight: 232,
        transform: transform,
      );
      expect(rect, isNotNull);
      expect(rect!.x, 0);
      expect(rect.y, 1);
      expect(rect.width, 1235);
      expect(rect.height, 142);
    });

    test('真实样本 p01 header_image：换算后越界裁剪到零面积，弃用', () {
      const transform = OcrRequestTransform(
        srcW: 2400,
        srcH: 1737,
        reqW: 3840,
        reqH: 2779,
        padX: 720,
        padY: 521,
      );
      final rect = convertApiBboxToSrc(
        bbox: const [57, 50, 177, 170],
        spaceWidth: 3840,
        spaceHeight: 2779,
        transform: transform,
      );
      // 该样本只校验换算本身：块在加白边后完全落在白边里，
      // 不是题目插图，不裁图、不猜。
      expect(rect, isNull);
    });

    test('未加白边请求：padX=padY=0，坐标原样', () {
      const transform = OcrRequestTransform(
        srcW: 100,
        srcH: 50,
        reqW: 100,
        reqH: 50,
        padX: 0,
        padY: 0,
      );
      final rect = convertApiBboxToSrc(
        bbox: const [10, 5, 60, 25],
        spaceWidth: 100,
        spaceHeight: 50,
        transform: transform,
      );
      expect(rect, isNotNull);
      expect(rect!.x, 10);
      expect(rect.y, 5);
      expect(rect.width, 50);
      expect(rect.height, 20);
    });

    test('同一组 bbox：加白边与未加白边请求都裁出正确区域', () {
      // 同一只题在两种请求下：加白边时请求图 160×80（pad 30/15），
      // 未加白边时请求图就是切片 100×50。两组 bbox 指向同一源区域。
      const padded = OcrRequestTransform(
        srcW: 100,
        srcH: 50,
        reqW: 160,
        reqH: 80,
        padX: 30,
        padY: 15,
      );
      const plain = OcrRequestTransform(
        srcW: 100,
        srcH: 50,
        reqW: 100,
        reqH: 50,
        padX: 0,
        padY: 0,
      );
      final fromPadded = convertApiBboxToSrc(
        bbox: const [40, 20, 90, 45],
        spaceWidth: 160,
        spaceHeight: 80,
        transform: padded,
      );
      final fromPlain = convertApiBboxToSrc(
        bbox: const [10, 5, 60, 30],
        spaceWidth: 100,
        spaceHeight: 50,
        transform: plain,
      );
      expect(fromPadded, isNotNull);
      expect(fromPlain, isNotNull);
      expect(fromPadded, fromPlain);
      expect(fromPadded!.x, 10);
      expect(fromPadded.y, 5);
      expect(fromPadded.width, 50);
      expect(fromPadded.height, 25);
    });

    test('边界/越界/零面积：部分越界裁剪，宽高 <2px 或零面积弃用', () {
      const transform = OcrRequestTransform(
        srcW: 100,
        srcH: 50,
        reqW: 160,
        reqH: 80,
        padX: 30,
        padY: 15,
      );
      // 部分越界：x1 < padX，裁剪后从 0 开始。
      final clipped = convertApiBboxToSrc(
        bbox: const [20, 20, 90, 45],
        spaceWidth: 160,
        spaceHeight: 80,
        transform: transform,
      );
      expect(clipped, isNotNull);
      expect(clipped!.x, 0);
      expect(clipped.width, 60);
      // 零面积。
      expect(
        convertApiBboxToSrc(
          bbox: const [40, 20, 40, 45],
          spaceWidth: 160,
          spaceHeight: 80,
          transform: transform,
        ),
        isNull,
      );
      // 宽 < 2px。
      expect(
        convertApiBboxToSrc(
          bbox: const [40, 20, 41, 45],
          spaceWidth: 160,
          spaceHeight: 80,
          transform: transform,
        ),
        isNull,
      );
      // 高 < 2px。
      expect(
        convertApiBboxToSrc(
          bbox: const [40, 20, 90, 21],
          spaceWidth: 160,
          spaceHeight: 80,
          transform: transform,
        ),
        isNull,
      );
    });

    test('块空间尺寸与本次请求对不上：安全弃用，不猜', () {
      const transform = OcrRequestTransform(
        srcW: 100,
        srcH: 50,
        reqW: 160,
        reqH: 80,
        padX: 30,
        padY: 15,
      );
      // 块声称在 200×100 的空间里，与本次请求 160×80 不符。
      expect(
        convertApiBboxToSrc(
          bbox: const [40, 20, 90, 45],
          spaceWidth: 200,
          spaceHeight: 100,
          transform: transform,
        ),
        isNull,
      );
      // 允差 ±2px 内放行。
      expect(
        convertApiBboxToSrc(
          bbox: const [40, 20, 90, 45],
          spaceWidth: 161,
          spaceHeight: 79,
          transform: transform,
        ),
        isNotNull,
      );
      // 元数据缺失：transform 为 null 直接弃用。
      expect(
        convertApiBboxToSrc(
          bbox: const [40, 20, 90, 45],
          spaceWidth: 160,
          spaceHeight: 80,
          transform: null,
        ),
        isNull,
      );
    });
  });

  group('图块筛选 buildOcrFigures', () {
    const transform = OcrRequestTransform(
      srcW: 100,
      srcH: 50,
      reqW: 100,
      reqH: 50,
      padX: 0,
      padY: 0,
    );

    test('准入白名单：image/figure/illustration/chart/diagram 成块', () {
      for (final native in [
        'image',
        'figure',
        'illustration',
        'chart',
        'diagram',
      ]) {
        final figures = buildOcrFigures(
          questionId: 'q1',
          raw: raw(
            mdResults: '题干',
            pages: [
              [
                block(
                  bbox: [10, 5, 60, 25],
                  label: 'image',
                  nativeLabel: native,
                  width: 100,
                  height: 50,
                ),
              ],
            ],
            transform: transform,
          ),
          transform: transform,
          slicePath: 'slices/q1.png',
          inputHash: 'h1',
        );
        expect(figures.length, 1, reason: native);
        expect(figures.single.anchorSource, 'fallback');
      }
    });

    test('排除集：header_image/doc_title/logo/watermark/page_number/decoration/cover 一律排除', () {
      for (final native in [
        'header_image',
        'doc_title',
        'logo',
        'watermark',
        'page_number',
        'decoration',
        'cover',
      ]) {
        final figures = buildOcrFigures(
          questionId: 'q1',
          raw: raw(
            mdResults: '题干',
            pages: [
              [
                block(
                  bbox: [10, 5, 60, 25],
                  label: 'image',
                  nativeLabel: native,
                  width: 100,
                  height: 50,
                ),
              ],
            ],
            transform: transform,
          ),
          transform: transform,
          slicePath: 'slices/q1.png',
          inputHash: 'h1',
        );
        expect(figures, isEmpty, reason: native);
      }
    });

    test('政治卷 header_image 样本不成块（只用于坐标换算校验）', () {
      final figures = buildOcrFigures(
        questionId: 'p01',
        raw: raw(
          mdResults: '![](page=0,bbox=[57, 50, 177, 170])\n\n题干',
          pages: [
            [
              block(
                bbox: [57, 50, 177, 170],
                label: 'image',
                nativeLabel: 'header_image',
                width: 2400,
                height: 1737,
              ),
            ],
          ],
          transform: const OcrRequestTransform(
            srcW: 2400,
            srcH: 1737,
            reqW: 3840,
            reqH: 2779,
            padX: 720,
            padY: 521,
          ),
        ),
        transform: const OcrRequestTransform(
          srcW: 2400,
          srcH: 1737,
          reqW: 3840,
          reqH: 2779,
          padX: 720,
          padY: 521,
        ),
        slicePath: 'slices/p01.png',
        inputHash: 'hp01',
      );
      expect(figures, isEmpty);
    });

    test('label 不是 image 不成块；无准入块时列表为空，不生成占位', () {
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '题干',
          pages: [
            [
              block(
                bbox: [10, 5, 60, 25],
                label: 'text',
                nativeLabel: 'image',
                width: 100,
                height: 50,
                content: '文字',
              ),
            ],
          ],
          transform: transform,
        ),
        transform: transform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      expect(figures, isEmpty);
      expect(encodeOcrFigures(figures), '[]');
    });

    test('同一 bbox 去重：md 引用与 layout 块相同只生成一个，以 layout 为准', () {
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '题干\n\n![](page=0,bbox=[10, 5, 60, 25])\n\n后文',
          pages: [
            [
              block(
                bbox: [10, 5, 60, 25],
                label: 'image',
                nativeLabel: 'image',
                width: 100,
                height: 50,
              ),
            ],
          ],
          transform: transform,
        ),
        transform: transform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      expect(figures.length, 1);
      expect(figures.single.anchorSource, 'md');
      expect(figures.single.anchorRef, '0');
      expect(figures.single.srcRect.x, 10);
    });

    test('元数据缺失时安全弃用图块', () {
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '题干',
          pages: [
            [
              block(
                bbox: [10, 5, 60, 25],
                label: 'image',
                nativeLabel: 'image',
                width: 100,
                height: 50,
              ),
            ],
          ],
        ),
        transform: null,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      expect(figures, isEmpty);
    });
  });

  group('图块阅读顺序', () {
    const transform = OcrRequestTransform(
      srcW: 200,
      srcH: 100,
      reqW: 200,
      reqH: 100,
      padX: 0,
      padY: 0,
    );

    test('md 引用锚定：按 md 引用出现顺序，不按 y1', () {
      // 两图 y1 相反：先出现的 md 引用在下方图上。
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults:
              '上文\n\n![](page=0,bbox=[10, 60, 60, 80])\n\n中段\n\n![](page=0,bbox=[10, 10, 60, 30])\n\n下文',
          pages: [
            [
              block(
                bbox: [10, 10, 60, 30],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
              ),
              block(
                bbox: [10, 60, 60, 80],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
              ),
            ],
          ],
          transform: transform,
        ),
        transform: transform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      expect(figures.length, 2);
      expect(figures[0].bbox2d, [10, 60, 60, 80]);
      expect(figures[0].anchorSource, 'md');
      expect(figures[0].anchorRef, '0');
      expect(figures[1].bbox2d, [10, 10, 60, 30]);
      expect(figures[1].anchorRef, '1');
      expect(figures[0].sequenceIndex, 0);
      expect(figures[1].sequenceIndex, 1);
    });

    test('文本块坐标映射：锚定到同一栏内上方最近文本块', () {
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '题干文字',
          pages: [
            [
              block(
                bbox: [10, 10, 90, 20],
                label: 'text',
                width: 200,
                height: 100,
                index: 0,
                content: '上段',
              ),
              block(
                bbox: [10, 25, 60, 45],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
                index: 1,
              ),
              block(
                bbox: [10, 50, 90, 60],
                label: 'text',
                width: 200,
                height: 100,
                index: 2,
                content: '下段',
              ),
            ],
          ],
          transform: transform,
        ),
        transform: transform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      expect(figures.length, 1);
      expect(figures.single.anchorSource, 'text');
      expect(figures.single.anchorRef, 'text-0');
    });

    test('双栏左→右：不做全局 y1 排序', () {
      // 左栏图 y1=60，右栏图 y1=25：全局 y1 会把右栏排前面，
      // 双栏口径是左栏在前。
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '题干文字',
          pages: [
            [
              block(
                bbox: [10, 10, 90, 20],
                label: 'text',
                width: 200,
                height: 100,
                index: 0,
                content: '左上',
              ),
              block(
                bbox: [10, 40, 90, 50],
                label: 'text',
                width: 200,
                height: 100,
                index: 1,
                content: '左下',
              ),
              block(
                bbox: [110, 10, 190, 20],
                label: 'text',
                width: 200,
                height: 100,
                index: 2,
                content: '右上',
              ),
              block(
                bbox: [110, 40, 190, 50],
                label: 'text',
                width: 200,
                height: 100,
                index: 3,
                content: '右下',
              ),
              block(
                bbox: [10, 60, 60, 80],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
                index: 4,
              ),
              block(
                bbox: [110, 25, 160, 45],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
                index: 5,
              ),
            ],
          ],
          transform: transform,
        ),
        transform: transform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      expect(figures.length, 2);
      // 左栏图在前（锚到左下 text-1），右栏图在后（锚到右上 text-2）。
      expect(figures[0].bbox2d, [10, 60, 60, 80]);
      expect(figures[0].anchorRef, 'text-1');
      expect(figures[1].bbox2d, [110, 25, 160, 45]);
      expect(figures[1].anchorRef, 'text-2');
    });

    test('单栏 y1：有文本块跨中线时当单栏，按 y1 排', () {
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '题干文字',
          pages: [
            [
              block(
                bbox: [10, 10, 190, 20],
                label: 'text',
                width: 200,
                height: 100,
                index: 0,
                content: '通栏',
              ),
              block(
                bbox: [10, 60, 60, 80],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
                index: 1,
              ),
              block(
                bbox: [10, 25, 60, 45],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
                index: 2,
              ),
            ],
          ],
          transform: transform,
        ),
        transform: transform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      expect(figures.length, 2);
      expect(figures[0].bbox2d, [10, 25, 60, 45]);
      expect(figures[1].bbox2d, [10, 60, 60, 80]);
    });

    test('锚定失败：无文本块时记 fallback、排末尾（数据层记未确认，界面不标注）', () {
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '题干文字',
          pages: [
            [
              block(
                bbox: [10, 10, 60, 30],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
              ),
            ],
          ],
          transform: transform,
        ),
        transform: transform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      expect(figures.length, 1);
      expect(figures.single.anchorSource, 'fallback');
      expect(figures.single.unconfirmed, isTrue);
    });
  });

  group('裁图 cropFigurePng', () {
    test('区域合法：裁出对应尺寸的 PNG', () {
      final bytes = sliceBytes(width: 100, height: 50);
      final cropped = cropFigurePng(
        sliceBytes: bytes,
        rect: const SrcRect(x: 10, y: 5, width: 50, height: 20),
      );
      expect(cropped, isNotNull);
      final decoded = img.decodeImage(cropped!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 50);
      expect(decoded.height, 20);
    });

    test('区域非法/解不出：返回 null', () {
      final bytes = sliceBytes(width: 100, height: 50);
      expect(
        cropFigurePng(
          sliceBytes: bytes,
          rect: const SrcRect(x: 80, y: 5, width: 50, height: 20),
        ),
        isNull,
      );
      expect(
        cropFigurePng(
          sliceBytes: Uint8List.fromList([1, 2, 3]),
          rect: const SrcRect(x: 0, y: 0, width: 10, height: 10),
        ),
        isNull,
      );
    });
  });

  group('展示与渲染插入', () {
    const transform = OcrRequestTransform(
      srcW: 200,
      srcH: 100,
      reqW: 200,
      reqH: 100,
      padX: 0,
      padY: 0,
    );

    test('重框后旧图块不展示，hasStale 为真', () {
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '题干',
          pages: [
            [
              block(
                bbox: [10, 5, 60, 25],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
              ),
            ],
          ],
          transform: transform,
        ),
        transform: transform,
        slicePath: 'slices/q1-v1.png',
        inputHash: 'h1',
      );
      expect(figures.length, 1);
      // 同一切片：展示。
      final current = currentFiguresForDisplay(
        figures,
        slicePath: 'slices/q1-v1.png',
        inputHash: 'h1',
      );
      expect(current.figures.length, 1);
      expect(current.hasStale, isFalse);
      // 重框换了版本化路径：旧图块不展示，hasStale。
      final afterRebox = currentFiguresForDisplay(
        figures,
        slicePath: 'slices/q1-v2.png',
        inputHash: 'h2',
      );
      expect(afterRebox.figures, isEmpty);
      expect(afterRebox.hasStale, isTrue);
      // 同路径但 hash 变了（同路径重写）：也不展示。
      final samePathNewHash = currentFiguresForDisplay(
        figures,
        slicePath: 'slices/q1-v1.png',
        inputHash: 'h2',
      );
      expect(samePathNewHash.figures, isEmpty);
      expect(samePathNewHash.hasStale, isTrue);
    });

    test('buildContentBlocks：图块插入内容序列，fallback 排末尾并标未确认', () {
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '第一段\n\n![](page=0,bbox=[10, 60, 60, 80])\n\n第二段',
          pages: [
            [
              block(
                bbox: [10, 60, 60, 80],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
              ),
            ],
          ],
          transform: transform,
        ),
        transform: transform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      expect(figures.length, 1);
      final blocks = buildContentBlocks(
        stemMarkdown: '第一段\n\n第二段',
        figures: figures,
        mdResults: '第一段\n\n![](page=0,bbox=[10, 60, 60, 80])\n\n第二段',
      );
      // 题干解析为单文本块；md 锚定的图块按 md 引用偏移插入其后。
      expect(blocks.length, 2);
      expect(blocks[0], isA<TextBlock>());
      expect(blocks[1], isA<FigureBlock>());
      expect((blocks[1] as FigureBlock).unconfirmed, isFalse);
      // fallback 图块排在内容序列末尾（数据层仍记未确认，界面不标注）。
      final fallbackFigures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '题干',
          pages: [
            [
              block(
                bbox: [10, 60, 60, 80],
                label: 'image',
                nativeLabel: 'image',
                width: 200,
                height: 100,
              ),
            ],
          ],
          transform: transform,
        ),
        transform: transform,
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      expect(fallbackFigures.single.unconfirmed, isTrue);
      final fallbackBlocks = buildContentBlocks(
        stemMarkdown: '第一段\n\n第二段',
        figures: fallbackFigures,
        mdResults: '题干',
      );
      expect(fallbackBlocks.last, isA<FigureBlock>());
      expect((fallbackBlocks.last as FigureBlock).unconfirmed, isTrue);
    });

    test('编解码往返：parse/encode 保持字段', () {
      final figures = buildOcrFigures(
        questionId: 'q1',
        raw: raw(
          mdResults: '题干',
          pages: [
            [
              block(
                bbox: [10, 5, 60, 25],
                label: 'image',
                nativeLabel: 'chart',
                width: 100,
                height: 50,
              ),
            ],
          ],
          transform: const OcrRequestTransform(
            srcW: 100,
            srcH: 50,
            reqW: 100,
            reqH: 50,
            padX: 0,
            padY: 0,
          ),
        ),
        transform: const OcrRequestTransform(
          srcW: 100,
          srcH: 50,
          reqW: 100,
          reqH: 50,
          padX: 0,
          padY: 0,
        ),
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
      );
      final json = encodeOcrFigures(figures);
      final parsed = parseOcrFigures(json);
      expect(parsed.length, 1);
      expect(parsed.single.id, 'figure-q1-0');
      expect(parsed.single.slicePath, 'slices/q1.png');
      expect(parsed.single.inputHash, 'h1');
      expect(parsed.single.srcRect, isNotNull);
      expect(parseOcrFigures('不是 JSON'), isEmpty);
      expect(parseOcrFigures(''), isEmpty);
      expect(encodeOcrFigures(const []), '[]');
    });
  });

  group('formula_crop 附带修复', () {
    test('加白边请求：平移公式裁出正确区域（旧只缩放会偏）', () {
      // 切片 100×50，加白边请求 160×80（padX=30, padY=15）。
      // formula 块在请求坐标 [40, 20, 90, 45] → 源 [10, 5, 60, 30]。
      // 旧实现只缩放（×100/160）会得到 x=25，偏 15px。
      final bytes = sliceBytes(width: 100, height: 50);
      final rawJson =
          '{"md_results":"题干","layout_details":[[{"bbox_2d":[40,20,90,45],"label":"formula","native_label":"formula","width":160,"height":80,"index":0}]],"transform":{"src_w":100,"src_h":50,"req_w":160,"req_h":80,"pad_x":30,"pad_y":15}}';
      final cropped = cropFormulaImageBytes(
        sliceBytes: bytes,
        ocrRaw: rawJson,
        formulaIndex: 0,
      );
      expect(cropped, isNotNull);
      final decoded = img.decodeImage(cropped!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 50);
      expect(decoded.height, 25);
    });

    test('旧包无 transform 且尺寸一致：按未加白边处理；尺寸不一致则弃用', () {
      final bytes = sliceBytes(width: 100, height: 50);
      // 块空间 100×50 与切片一致 → pad 0。
      const rawNoTransform =
          '{"md_results":"题干","layout_details":[[{"bbox_2d":[10,5,60,30],"label":"formula","native_label":"formula","width":100,"height":50,"index":0}]]}';
      final cropped = cropFormulaImageBytes(
        sliceBytes: bytes,
        ocrRaw: rawNoTransform,
        formulaIndex: 0,
      );
      expect(cropped, isNotNull);
      expect(img.decodeImage(cropped!)!.width, 50);
      // 块空间 160×80 与切片 100×50 不一致 → 不猜，返回 null。
      const rawMismatch =
          '{"md_results":"题干","layout_details":[[{"bbox_2d":[40,20,90,45],"label":"formula","native_label":"formula","width":160,"height":80,"index":0}]]}';
      expect(
        cropFormulaImageBytes(
          sliceBytes: bytes,
          ocrRaw: rawMismatch,
          formulaIndex: 0,
        ),
        isNull,
      );
    });

    test('无 formula 块：恒返回 null', () {
      final bytes = sliceBytes(width: 100, height: 50);
      expect(
        cropFormulaImageBytes(
          sliceBytes: bytes,
          ocrRaw: '{"md_results":"题干","layout_details":[[]]}',
          formulaIndex: 0,
        ),
        isNull,
      );
    });
  });
}
