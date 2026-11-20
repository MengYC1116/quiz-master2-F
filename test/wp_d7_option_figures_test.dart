// WP-D #7 选项图片锚定（九项修复 REV5，定稿 §7 + 附录 R5/S4/U2）。
// TDD：先写失败测试，再写实现。
//
// 约定：
// - 选项标号形态与 #2 共用（stem_splitter.dart:195-201 的标记形式：
//   括号式 `(A)`/`（A）`、字母+标点 `A.`/`A．`/`A、`/`A)`/`A）`/`A:`/`A：`、
//   裸字母 `A `；全角 Ａ-Ｅ 归一化为 A-E）。
// - 图块归属优先级 P1（md 结构明确关联：引用在标号 div 内，或紧跟标号块后）
//   > P2（页面坐标 + 选项区域，同一 API 像素空间、空间尺寸一致才比）
//   > P3（md 引用顺序 + 选项标号，仅 R5-3 四条件全满足）
//   > P4（无法可靠匹配 → optionLabel null，默认放序列末尾）。
// - 一张图片最多归属一个选项；一个选项可归属多张图片（S4-1）。
// - optionLabel 只解决归属，不独自决定选项内精确位置（R5-4）：位置优先
//   保留可靠的 md 锚点顺序（md 引用相对该选项文本块的位置），无可靠锚点
//   时才统一插在选项标号所在块的紧后方。
// - 无 optionLabel 且无法可靠放置的图块默认放序列末尾（Win11 反馈包 3：
//   不再设独立「未关联图片」区、不再标“位置未确认”，用户自己拖到正确
//   位置）；题干图（md 引用在首个选项标号之前）仍按原 md/text
//   逻辑放置，互不干扰。
// - 坐标约定（U2）：不做 PDF 仿射变换；GLM bbox 单位是送入 API 的图像的
//   像素坐标，换算只有减白边再 clip；PDF 点坐标/MediaBox/CropBox/Rotate/
//   UserUnit 从不进入 OCR 流水线；页面旋转只在渲染时由 pdfrx 应用一次。
// - 已知边界（写进测试名与实现注释，不是静默行为）：纯文本选项（非 div）
//   在 parseQuestionContent 里会合并成一个 TextBlock，块内无逐选项锚点，
//   归属已知但无处可插的图块默认放序列末尾；autoSplit 已把选项切出题干时，
//   题干块里同样没有标号块，图块同样默认放序列末尾（Win11 反馈包 3：
//   不再设未关联区、不再标未确认）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/question_content.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';

/// layout_details 一页里的一个块（与 b14_m2_figures_test.dart 同款 helper）。
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

Map<String, Object?> txt(
  List<int> bbox,
  String content,
  int index,
) => block(bbox: bbox, label: 'text', width: 400, height: 500, index: index, content: content);

Map<String, Object?> pic(List<int> bbox, int index) =>
    block(bbox: bbox, label: 'image', nativeLabel: 'image', width: 400, height: 500, index: index);

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

const transform = OcrRequestTransform(
  srcW: 400,
  srcH: 500,
  reqW: 400,
  reqH: 500,
  padX: 0,
  padY: 0,
);

List<OcrFigure> figuresFor({
  required String md,
  required List<List<Map<String, Object?>>> pages,
}) => buildOcrFigures(
  questionId: 'q1',
  raw: raw(mdResults: md, pages: pages, transform: transform),
  transform: transform,
  slicePath: 'slices/q1.png',
  inputHash: 'h1',
);

/// 单栏标准布局：题干 + A–D 选项文本块（y 递增），供各测试复用。
/// 选项带（行带）：A [60,110)、B [110,160)、C [160,210)、D [210,260)。
List<Map<String, Object?>> standardTexts() => [
  txt([20, 10, 380, 40], '题干文字', 0),
  txt([20, 60, 380, 90], 'A. 甲', 1),
  txt([20, 110, 380, 140], 'B. 乙', 2),
  txt([20, 160, 380, 190], 'C. 丙', 3),
  txt([20, 210, 380, 240], 'D. 丁', 4),
];

/// 各选项图的标准 bbox：中心点落在各自选项行带内。
const aImg = [40, 92, 140, 108];
const bImg = [40, 142, 140, 158];
const cImg = [40, 192, 140, 208];
const dImg = [40, 242, 140, 258];

/// 全部选项图的 md 引用（P1 邻接形态：引用紧跟各自标号 div 之后）。
const mdAllP1 =
    '题干文字\n\n'
    '<div>A. 甲</div>\n![](page=0,bbox=[40, 92, 140, 108])\n'
    '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])\n'
    '<div>C. 丙</div>\n![](page=0,bbox=[40, 192, 140, 208])\n'
    '<div>D. 丁</div>\n![](page=0,bbox=[40, 242, 140, 258])';

/// 与 mdAllP1 对应的题干（splitStem 剥掉引用行后的形态）。
const stemAllDivs =
    '题干文字\n\n<div>A. 甲</div>\n<div>B. 乙</div>\n<div>C. 丙</div>\n<div>D. 丁</div>';

/// 把 buildContentBlocks 的输出读成可断言的序列：
/// `TEXT:xxx` / `FIG:yyy`（`:unconfirmed` 后缀是数据层标记，界面不再显示）。
List<String> describe(List<QuestionContentBlock> blocks) => [
  for (final b in blocks)
    switch (b) {
      TextBlock(:final text) => 'TEXT:${text.replaceAll('\n', '\\n')}',
      FigureBlock(:final figureId, :final unconfirmed) =>
        'FIG:$figureId${unconfirmed ? ':unconfirmed' : ''}',
      _ => 'OTHER:${b.runtimeType}',
    },
];

/// 在输出序列里找某图块的位置。
int indexOfFig(List<String> desc, String figureId) =>
    desc.indexWhere((s) => s.startsWith('FIG:$figureId'));

void main() {
  group('§7.3：选项归属与插入', () {
    test('A/B/C/D 各自一张图片 → 各跟在各自标号后', () {
      final figs = figuresFor(
        md: mdAllP1,
        pages: [
          [...standardTexts(), pic(aImg, 5), pic(bImg, 6), pic(cImg, 7), pic(dImg, 8)],
        ],
      );
      expect(figs.length, 4);
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'B', 'C', 'D']);
      final desc = describe(
        buildContentBlocks(stemMarkdown: stemAllDivs, figures: figs, mdResults: mdAllP1),
      );
      expect(desc, [
        'TEXT:题干文字\\n\\n',
        'TEXT:A. 甲',
        'FIG:figure-q1-0',
        'TEXT:B. 乙',
        'FIG:figure-q1-1',
        'TEXT:C. 丙',
        'FIG:figure-q1-2',
        'TEXT:D. 丁',
        'FIG:figure-q1-3',
      ]);
    });

    test('一个选项包含两张图片 → 两张都跟在该标号后（md 顺序）', () {
      // A 有两图：图1 紧跟 A div（P1），图2 在 A 段内、但 bbox 在任何
      // 选项行带之外（P2 够不着，只能走 P3 区间映射）。
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 92, 140, 108])\n![](page=0,bbox=[300, 300, 380, 320])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])\n'
          '<div>C. 丙</div>\n![](page=0,bbox=[40, 192, 140, 208])\n'
          '<div>D. 丁</div>\n![](page=0,bbox=[40, 242, 140, 258])';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            ...standardTexts(),
            pic(aImg, 5),
            pic(const [300, 300, 380, 320], 6),
            pic(bImg, 7),
            pic(cImg, 8),
            pic(dImg, 9),
          ],
        ],
      );
      expect(figs.length, 5);
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'A', 'B', 'C', 'D']);
      final desc = describe(
        buildContentBlocks(stemMarkdown: stemAllDivs, figures: figs, mdResults: md),
      );
      // 两张 A 图都在 A 标号后、B 标号前，且保持 md 顺序。
      expect(indexOfFig(desc, 'figure-q1-0'), greaterThan(desc.indexWhere((s) => s == 'TEXT:A. 甲')));
      expect(indexOfFig(desc, 'figure-q1-1'), greaterThan(indexOfFig(desc, 'figure-q1-0')));
      expect(indexOfFig(desc, 'figure-q1-1'), lessThan(desc.indexWhere((s) => s == 'TEXT:B. 乙')));
    });

    test('R5-4：图片在选项文字之前（引用在标号 div 内）→ 跟在标号块后', () {
      const md =
          '题干文字\n\n'
          '<div>A. ![](page=0,bbox=[40, 92, 140, 108]) 文字</div>\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])';
      const stem = '题干文字\n\n<div>A. 文字</div>\n<div>B. 乙</div>';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 文字', 1),
            txt([20, 110, 380, 140], 'B. 乙', 2),
            pic(aImg, 3),
            pic(bImg, 4),
          ],
        ],
      );
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'B']);
      final desc = describe(
        buildContentBlocks(stemMarkdown: stem, figures: figs, mdResults: md),
      );
      expect(desc, [
        'TEXT:题干文字\\n\\n',
        'TEXT:A. 文字',
        'FIG:figure-q1-0',
        'TEXT:B. 乙',
        'FIG:figure-q1-1',
      ]);
    });

    test('R5-4 例：A. 第一段 / 图片 / 第二段，引用在第二段之后 → 图留在第二段之后，不提到 A. 紧后', () {
      const md =
          '题干文字\n\n'
          '<div>A. 第一段</div>\n\n<div>第二段</div>\n\n![](page=0,bbox=[40, 92, 140, 108])\n\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])\n'
          '<div>C. 丙</div>\n![](page=0,bbox=[40, 192, 140, 208])\n'
          '<div>D. 丁</div>\n![](page=0,bbox=[40, 242, 140, 258])';
      const stem =
          '题干文字\n\n<div>A. 第一段</div>\n\n<div>第二段</div>\n\n<div>B. 乙</div>\n<div>C. 丙</div>\n<div>D. 丁</div>';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            ...standardTexts(),
            pic(aImg, 5),
            pic(bImg, 6),
            pic(cImg, 7),
            pic(dImg, 8),
          ],
        ],
      );
      expect(figs.first.optionLabel, 'A');
      final desc = describe(
        buildContentBlocks(stemMarkdown: stem, figures: figs, mdResults: md),
      );
      // 图在“第二段”之后、B 之前；绝不在“A. 第一段”紧后。
      expect(desc, [
        'TEXT:题干文字\\n\\n',
        'TEXT:A. 第一段',
        'TEXT:第二段',
        'FIG:figure-q1-0',
        'TEXT:B. 乙',
        'FIG:figure-q1-1',
        'TEXT:C. 丙',
        'FIG:figure-q1-2',
        'TEXT:D. 丁',
        'FIG:figure-q1-3',
      ]);
    });

    test('Markdown 没有选项标号 → 无锚点图片默认放序列末尾，不作任何未确认标注', () {
      final figs = figuresFor(
        md: '题干文字',
        pages: [
          [pic(const [10, 60, 60, 80], 0)],
        ],
      );
      expect(figs.length, 1);
      expect(figs.single.anchorSource, 'fallback');
      expect(figs.single.optionLabel, isNull);
      final desc = describe(
        buildContentBlocks(
          stemMarkdown: '题干文字\n\n第二段',
          figures: figs,
          mdResults: '题干文字',
        ),
      );
      // 无区标题块；图在序列末尾（数据层仍记未确认，界面不标注）。
      expect(desc, ['TEXT:题干文字\\n\\n第二段', 'FIG:figure-q1-0:unconfirmed']);
    });

    test('无标号但 md 锚点可靠的题干图仍按 md 位置放，不进未关联区', () {
      final figs = figuresFor(
        md: '第一段\n\n![](page=0,bbox=[10, 60, 60, 80])\n\n第二段',
        pages: [
          [pic(const [10, 60, 60, 80], 0)],
        ],
      );
      expect(figs.single.anchorSource, 'md');
      expect(figs.single.optionLabel, isNull);
      final desc = describe(
        buildContentBlocks(
          stemMarkdown: '第一段\n\n第二段',
          figures: figs,
          mdResults: '第一段\n\n![](page=0,bbox=[10, 60, 60, 80])\n\n第二段',
        ),
      );
      // md 锚定的题干图按 md 位置放，不默认堆到末尾。
      expect(desc.last, 'FIG:figure-q1-0');
    });

    test('标号缺失一个（无 C）：其余 P1 关联正常，缺失项的图片默认放序列末尾', () {
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 92, 140, 108])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])\n'
          '<div>乙的第二段</div>\n![](page=0,bbox=[300, 300, 380, 320])\n'
          '<div>D. 丁</div>\n![](page=0,bbox=[40, 242, 140, 258])';
      const stem =
          '题干文字\n\n<div>A. 甲</div>\n<div>B. 乙</div>\n<div>乙的第二段</div>\n<div>D. 丁</div>';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 甲', 1),
            txt([20, 110, 380, 140], 'B. 乙', 2),
            txt([20, 210, 380, 240], 'D. 丁', 3),
            pic(aImg, 4),
            pic(bImg, 5),
            pic(const [300, 300, 380, 320], 6),
            pic(dImg, 7),
          ],
        ],
      );
      // P3 被序列不完整挡住；P1 的三张正常归属；第四张（B 段后、行带外）
      // 无可靠关联 → null。
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'B', null, 'D']);
      final desc = describe(
        buildContentBlocks(stemMarkdown: stem, figures: figs, mdResults: md),
      );
      expect(desc, [
        'TEXT:题干文字\\n\\n',
        'TEXT:A. 甲',
        'FIG:figure-q1-0',
        'TEXT:B. 乙',
        'FIG:figure-q1-1',
        'TEXT:乙的第二段',
        'TEXT:D. 丁',
        'FIG:figure-q1-3',
        'FIG:figure-q1-2:unconfirmed',
      ]);
    });

    test('标号顺序错误（A、C、B、D）：P1 关联仍各归其主，纯顺序映射被挡、默认放序列末尾', () {
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 92, 140, 108])\n'
          '<div>C. 丙</div>\n![](page=0,bbox=[40, 192, 140, 208])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])\n'
          '<div>乙的第二段</div>\n![](page=0,bbox=[300, 300, 380, 320])\n'
          '<div>D. 丁</div>\n![](page=0,bbox=[40, 242, 140, 258])';
      const stem =
          '题干文字\n\n<div>A. 甲</div>\n<div>C. 丙</div>\n<div>B. 乙</div>\n<div>乙的第二段</div>\n<div>D. 丁</div>';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            ...standardTexts(),
            pic(aImg, 5),
            pic(cImg, 6),
            pic(bImg, 7),
            pic(const [300, 300, 380, 320], 8),
            pic(dImg, 9),
          ],
        ],
      );
      // 顺序错乱 → P3 整体不启用；紧跟标号的四张走 P1；段后那张无关联。
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'C', 'B', null, 'D']);
      final desc = describe(
        buildContentBlocks(stemMarkdown: stem, figures: figs, mdResults: md),
      );
      expect(desc.last, 'FIG:figure-q1-3:unconfirmed');
      expect(indexOfFig(desc, 'figure-q1-0'), greaterThan(desc.indexWhere((s) => s == 'TEXT:A. 甲')));
      expect(indexOfFig(desc, 'figure-q1-1'), greaterThan(desc.indexWhere((s) => s == 'TEXT:C. 丙')));
      expect(indexOfFig(desc, 'figure-q1-2'), greaterThan(desc.indexWhere((s) => s == 'TEXT:B. 乙')));
      expect(indexOfFig(desc, 'figure-q1-4'), greaterThan(desc.indexWhere((s) => s == 'TEXT:D. 丁')));
    });

    test('两个选项相邻图片 → 各归其主', () {
      // A 图底边与 B 图顶边只差 2px，但中心点各在自家行带内。
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 100, 140, 112])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 114, 140, 126])';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 甲', 1),
            txt([20, 110, 380, 140], 'B. 乙', 2),
            pic(const [40, 100, 140, 112], 3),
            pic(const [40, 114, 140, 126], 4),
          ],
        ],
      );
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'B']);
    });

    test('题干图片与选项图片混合 → 题干图按原逻辑，选项图按选项关联，互不干扰', () {
      const md =
          '题干文字\n\n![](page=0,bbox=[10, 45, 60, 58])\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 92, 140, 108])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])\n'
          '<div>C. 丙</div>\n![](page=0,bbox=[40, 192, 140, 208])\n'
          '<div>D. 丁</div>\n![](page=0,bbox=[40, 242, 140, 258])';
      const stem = '题干文字\n\n<div>A. 甲</div>\n<div>B. 乙</div>\n<div>C. 丙</div>\n<div>D. 丁</div>';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 甲', 1),
            txt([20, 110, 380, 140], 'B. 乙', 2),
            txt([20, 160, 380, 190], 'C. 丙', 3),
            txt([20, 210, 380, 240], 'D. 丁', 4),
            pic(const [10, 45, 60, 58], 5),
            pic(aImg, 6),
            pic(bImg, 7),
            pic(cImg, 8),
            pic(dImg, 9),
          ],
        ],
      );
      // 题干图是首个 md 引用（在首个标号之前），不归属任何选项。
      expect(figs.map((f) => f.optionLabel).toList(), [null, 'A', 'B', 'C', 'D']);
      final desc = describe(
        buildContentBlocks(stemMarkdown: stem, figures: figs, mdResults: md),
      );
      expect(desc, [
        'TEXT:题干文字\\n\\n',
        'FIG:figure-q1-0',
        'TEXT:A. 甲',
        'FIG:figure-q1-1',
        'TEXT:B. 乙',
        'FIG:figure-q1-2',
        'TEXT:C. 丙',
        'FIG:figure-q1-3',
        'TEXT:D. 丁',
        'FIG:figure-q1-4',
      ]);
    });

    test('坐标系错位样本（bbox 经裁剪偏移）：诊断先报坐标系问题，不放宽阈值硬匹配', () {
      // layout 块 bbox 被整体下移 100px，与 md 引用 bbox 对不上：
      // 去重失败 → 无 md 锚点；P2 按错位坐标会指向 D，但坐标系已存疑，
      // 不得据此归属。
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 92, 140, 108])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 甲', 1),
            txt([20, 110, 380, 140], 'B. 乙', 2),
            // 真实位置应在 B 行带（y 142–158），错位后落在 D 区域。
            pic(const [40, 242, 140, 258], 3),
            pic(const [40, 292, 140, 308], 4),
          ],
        ],
      );
      expect(figs.map((f) => f.optionLabel).toList(), [null, null]);
      final diag = diagnoseFigures(
        figures: figs,
        stemMarkdown: stemAllDivs,
        mdResults: md,
      );
      expect(diag.length, 2);
      // 诊断必须报出 md 引用 bbox 无对应 layout 块（坐标系存疑）。
      expect(diag[0]['coordinate_issue'], isNotNull);
      expect((diag[0]['coordinate_issue'] as String).isNotEmpty, isTrue);
    });
  });

  group('R5-5：补充场景', () {
    test('同一选项两张图、两图之间有文字 → 两图分列文字两侧，都在该选项内', () {
      const md =
          '题干文字\n\n'
          '<div>A. 第一段</div>\n![](page=0,bbox=[40, 92, 140, 108])\n'
          '<div>第二段</div>\n![](page=0,bbox=[300, 300, 380, 320])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])\n'
          '<div>C. 丙</div>\n![](page=0,bbox=[40, 192, 140, 208])\n'
          '<div>D. 丁</div>\n![](page=0,bbox=[40, 242, 140, 258])';
      const stem =
          '题干文字\n\n<div>A. 第一段</div>\n\n<div>第二段</div>\n\n<div>B. 乙</div>\n<div>C. 丙</div>\n<div>D. 丁</div>';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            ...standardTexts(),
            pic(aImg, 5),
            pic(const [300, 300, 380, 320], 6),
            pic(bImg, 7),
            pic(cImg, 8),
            pic(dImg, 9),
          ],
        ],
      );
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'A', 'B', 'C', 'D']);
      final desc = describe(
        buildContentBlocks(stemMarkdown: stem, figures: figs, mdResults: md),
      );
      expect(desc, [
        'TEXT:题干文字\\n\\n',
        'TEXT:A. 第一段',
        'FIG:figure-q1-0',
        'TEXT:第二段',
        'FIG:figure-q1-1',
        'TEXT:B. 乙',
        'FIG:figure-q1-2',
        'TEXT:C. 丙',
        'FIG:figure-q1-3',
        'TEXT:D. 丁',
        'FIG:figure-q1-4',
      ]);
    });

    test('md 引用顺序与页面视觉顺序不一致 → 以 md 顺序为准，不按 y1 猜', () {
      // md 顺序 A 图在前、B 图在后；页面上 A 图在下方、B 图在上方。
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 242, 140, 258])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 92, 140, 108])';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 甲', 1),
            txt([20, 110, 380, 140], 'B. 乙', 2),
            pic(const [40, 242, 140, 258], 3),
            pic(const [40, 92, 140, 108], 4),
          ],
        ],
      );
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'B']);
      expect(figs[0].bbox2d, [40, 242, 140, 258]);
      expect(figs[1].bbox2d, [40, 92, 140, 108]);
    });

    test('题干图、选项图、未关联图混合 → 各按其道（未关联图默认放序列末尾）', () {
      const md =
          '题干文字\n\n![](page=0,bbox=[10, 45, 60, 58])\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 92, 140, 108])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])\n'
          '<div>C. 丙</div>\n<div>丙的第二段</div>\n![](page=0,bbox=[300, 300, 380, 320])';
      const stem = '题干文字\n\n<div>A. 甲</div>\n<div>B. 乙</div>\n<div>C. 丙</div>\n<div>丙的第二段</div>';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 甲', 1),
            txt([20, 110, 380, 140], 'B. 乙', 2),
            txt([20, 160, 380, 190], 'C. 丙', 3),
            pic(const [10, 45, 60, 58], 4),
            pic(aImg, 5),
            pic(bImg, 6),
            pic(const [300, 300, 380, 320], 7),
          ],
        ],
      );
      // 序列 A、B、C 不完整 → P3 不启用；C 段后的图无 P1/P2 → 未关联。
      expect(figs.map((f) => f.optionLabel).toList(), [null, 'A', 'B', null]);
      final desc = describe(
        buildContentBlocks(stemMarkdown: stem, figures: figs, mdResults: md),
      );
      expect(desc, [
        'TEXT:题干文字\\n\\n',
        'FIG:figure-q1-0',
        'TEXT:A. 甲',
        'FIG:figure-q1-1',
        'TEXT:B. 乙',
        'FIG:figure-q1-2',
        'TEXT:C. 丙',
        'TEXT:丙的第二段',
        'FIG:figure-q1-3:unconfirmed',
      ]);
    });

    test('同一选项标号重复出现 → 该标号锚点歧义，其图默认放序列末尾，其余正常', () {
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 92, 140, 108])\n'
          '<div>A. 甲又出现</div>\n![](page=0,bbox=[40, 142, 140, 158])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 192, 140, 208])';
      const stem = '题干文字\n\n<div>A. 甲</div>\n<div>A. 甲又出现</div>\n<div>B. 乙</div>';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 甲', 1),
            txt([20, 110, 380, 140], 'A. 甲又出现', 2),
            txt([20, 160, 380, 190], 'B. 乙', 3),
            pic(aImg, 4),
            pic(bImg, 5),
            pic(cImg, 6),
          ],
        ],
      );
      // P1 仍按邻接给出 A/A/B；但 A 标号在题干块里出现两次，插入锚点
      // 歧义 → 两张 A 图进未关联区，B 图正常跟在 B 后。
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'A', 'B']);
      final desc = describe(
        buildContentBlocks(stemMarkdown: stem, figures: figs, mdResults: md),
      );
      expect(desc, [
        'TEXT:题干文字\\n\\n',
        'TEXT:A. 甲',
        'TEXT:A. 甲又出现',
        'TEXT:B. 乙',
        'FIG:figure-q1-2',
        'FIG:figure-q1-0:unconfirmed',
        'FIG:figure-q1-1:unconfirmed',
      ]);
    });

    test('md 有标号、部分标号无对应图片引用 → 不崩溃，现有图仍可归属', () {
      // 只有一张图，无 md 引用，bbox 中心在 A 行带内 → P2 归属 A。
      final figs = figuresFor(
        md: mdAllP1,
        pages: [
          [...standardTexts(), pic(aImg, 5)],
        ],
      );
      expect(figs.length, 1);
      expect(figs.single.optionLabel, 'A');
      final desc = describe(
        buildContentBlocks(stemMarkdown: stemAllDivs, figures: figs, mdResults: mdAllP1),
      );
      expect(desc, [
        'TEXT:题干文字\\n\\n',
        'TEXT:A. 甲',
        'FIG:figure-q1-0',
        'TEXT:B. 乙',
        'TEXT:C. 丙',
        'TEXT:D. 丁',
      ]);
    });

    test('有图片引用但无对应选项标号 → 该图默认放序列末尾，其余正常', () {
      // 只有 A、B 两个标号（序列不完整 → P3 不启用）；第三张图的引用
      // 在 B 之后、非邻接、行带外 → 无任何可靠关联。
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 92, 140, 108])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])\n'
          '<div>乙的第二段</div>\n![](page=0,bbox=[300, 300, 380, 320])';
      const stem = '题干文字\n\n<div>A. 甲</div>\n<div>B. 乙</div>\n<div>乙的第二段</div>';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 甲', 1),
            txt([20, 110, 380, 140], 'B. 乙', 2),
            pic(aImg, 3),
            pic(bImg, 4),
            pic(const [300, 300, 380, 320], 5),
          ],
        ],
      );
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'B', null]);
      final desc = describe(
        buildContentBlocks(stemMarkdown: stem, figures: figs, mdResults: md),
      );
      expect(desc.last, 'FIG:figure-q1-2:unconfirmed');
    });

    test('坐标系一致但页面方向旋转（视觉上下颠倒）→ 不做旋转处理，md 结构仍正确归属', () {
      // 视觉上 A 图在下、B 图在上（形如旋转 180° 后的 y 顺序），
      // 但 md 引用紧跟各自标号 → P1 按 md 结构归属，不猜旋转。
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n![](page=0,bbox=[40, 242, 140, 258])\n'
          '<div>B. 乙</div>\n![](page=0,bbox=[40, 92, 140, 108])';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 甲', 1),
            txt([20, 110, 380, 140], 'B. 乙', 2),
            pic(const [40, 242, 140, 258], 3),
            pic(const [40, 92, 140, 108], 4),
          ],
        ],
      );
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'B']);
      final diag = diagnoseFigures(
        figures: figs,
        stemMarkdown: stemAllDivs,
        mdResults: md,
      );
      // 诊断写明旋转假设：逐图不做旋转处理（U2）。
      expect(diag[0]['rotation_note'], isNotNull);
    });

    test('选项文字与图片分属不同 OCR 区域 → md 邻接仍可归属，不依赖坐标靠近', () {
      // A 选项文字在第 0 页，A 图片在第 1 页（不同 layout 页）：
      // P2 跨页够不着，但 md 引用紧跟 A 标号 → P1 归属 A。
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n![](page=1,bbox=[40, 92, 140, 108])\n'
          '<div>B. 乙</div>\n![](page=1,bbox=[40, 142, 140, 158])';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            txt([20, 10, 380, 40], '题干文字', 0),
            txt([20, 60, 380, 90], 'A. 甲', 1),
            txt([20, 110, 380, 140], 'B. 乙', 2),
          ],
          [pic(aImg, 0), pic(bImg, 1)],
        ],
      );
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'B']);
    });

    test('P3 纯顺序映射：引用集中在标号之后、无邻接、无坐标 → 按 md 顺序对应标号', () {
      // 4 张图的引用全部排在 4 个标号文本之后（与末标号之间隔着一段
      // 非标号文字，无一紧跟标号），bbox 全部在行带之外（P2 够不着）；
      // 序列完整、引用唯一、无夹杂 → P3 按 md 顺序一一对应 A/B/C/D。
      const md =
          '题干文字\n\n'
          '<div>A. 甲</div>\n<div>B. 乙</div>\n<div>C. 丙</div>\n<div>D. 丁</div>\n\n'
          '<div>附图如下</div>\n\n'
          '![](page=0,bbox=[300, 300, 380, 320])\n'
          '![](page=0,bbox=[300, 330, 380, 350])\n'
          '![](page=0,bbox=[300, 360, 380, 380])\n'
          '![](page=0,bbox=[300, 390, 380, 410])';
      final figs = figuresFor(
        md: md,
        pages: [
          [
            ...standardTexts(),
            pic(const [300, 300, 380, 320], 5),
            pic(const [300, 330, 380, 350], 6),
            pic(const [300, 360, 380, 380], 7),
            pic(const [300, 390, 380, 410], 8),
          ],
        ],
      );
      expect(figs.map((f) => f.optionLabel).toList(), ['A', 'B', 'C', 'D']);
    });

    test('P2 坐标匹配：无 md 引用时，中心点落在选项行带内即归属该选项', () {
      final figs = figuresFor(
        md: '题干文字',
        pages: [
          [
            ...standardTexts(),
            pic(bImg, 5),
          ],
        ],
      );
      expect(figs.length, 1);
      expect(figs.single.anchorSource, 'text');
      expect(figs.single.optionLabel, 'B');
    });
  });

  group('图块建模与诊断', () {
    test('optionLabel 编解码往返；旧 JSON 无该键 → null；非法值 → null', () {
      final figs = figuresFor(md: mdAllP1, pages: [
        [...standardTexts(), pic(aImg, 5), pic(bImg, 6), pic(cImg, 7), pic(dImg, 8)],
      ]);
      final json = encodeOcrFigures(figs);
      final parsed = parseOcrFigures(json);
      expect(parsed.map((f) => f.optionLabel).toList(), ['A', 'B', 'C', 'D']);
      // 旧 JSON（无 option_label 键）仍可解析，归属为 null。
      const legacy =
          '[{"id":"figure-q1-0","slice_path":"slices/q1.png","sequence_index":0,'
          '"anchor_source":"fallback","anchor_ref":"","bbox_2d":[10,5,60,25],'
          '"transform":{"src_w":100,"src_h":50,"req_w":100,"req_h":50,"pad_x":0,"pad_y":0},'
          '"src_rect":{"x":10,"y":5,"w":50,"h":20},"crop_path":""}]';
      expect(parseOcrFigures(legacy).single.optionLabel, isNull);
      // 非法值不抛错、不污染。
      final bad = json.replaceFirst('"option_label":"A"', '"option_label":"Z"');
      expect(parseOcrFigures(bad).first.optionLabel, isNull);
    });

    test('sameFiguresIgnoringCrop：optionLabel 变化即不同；copyWith 保留归属', () {
      final figs = figuresFor(md: mdAllP1, pages: [
        [...standardTexts(), pic(aImg, 5), pic(bImg, 6), pic(cImg, 7), pic(dImg, 8)],
      ]);
      final same = figuresFor(md: mdAllP1, pages: [
        [...standardTexts(), pic(aImg, 5), pic(bImg, 6), pic(cImg, 7), pic(dImg, 8)],
      ]);
      expect(sameFiguresIgnoringCrop(figs, same), isTrue);
      final relabeled = [
        figs[0].copyWith(optionLabel: 'B'),
        ...figs.sublist(1),
      ];
      expect(sameFiguresIgnoringCrop(figs, relabeled), isFalse);
      expect(figs[0].copyWith(cropPath: 'slices/new.png').optionLabel, 'A');
    });

    test('R5-1 诊断记录字段齐全（随图块数据可取用，供 Win11 真机补做 live 诊断）', () {
      final figs = figuresFor(md: mdAllP1, pages: [
        [...standardTexts(), pic(aImg, 5), pic(bImg, 6), pic(cImg, 7), pic(dImg, 8)],
      ]);
      final diag = diagnoseFigures(
        figures: figs,
        stemMarkdown: stemAllDivs,
        mdResults: mdAllP1,
      );
      expect(diag.length, 4);
      final first = diag[0];
      expect(first['figure_id'], 'figure-q1-0');
      expect(first['bbox_2d'], [40, 92, 140, 108]);
      expect(first['bbox_unit'], contains('像素'));
      expect(first['coordinate_system'], contains('PNG'));
      expect(first['slice_path'], 'slices/q1.png');
      expect(first['input_hash'], 'h1');
      expect(first['pad_x'], 0);
      expect(first['pad_y'], 0);
      expect(first['md_ref_raw'], '![](page=0,bbox=[40, 92, 140, 108])');
      expect(first['anchor_source'], 'md');
      expect(first['md_order'], 0);
      expect(first['option_label'], 'A');
      expect(first['stem_start_in_md'], 0);
      expect(first['insertion_index'], isNotNull);
      expect(first['in_unassociated_zone'], isFalse);
      expect(first['coordinate_issue'], isNull);
    });

    test('多张未锚定图都在序列末尾，无区标题块', () {
      final figs = figuresFor(
        md: '题干文字',
        pages: [
          [pic(const [10, 60, 60, 80], 0), pic(const [70, 60, 120, 80], 1)],
        ],
      );
      final desc = describe(
        buildContentBlocks(stemMarkdown: '题干文字', figures: figs, mdResults: '题干文字'),
      );
      expect(desc, ['TEXT:题干文字', 'FIG:figure-q1-0:unconfirmed', 'FIG:figure-q1-1:unconfirmed']);
    });

    test('标号块不在题干里（autoSplit 已切掉选项）→ 归属已知但无处可插，默认放序列末尾', () {
      // 直接构造带 optionLabel 的图块，题干里没有任何标号块。
      const fig = OcrFigure(
        id: 'figure-q1-0',
        slicePath: 'slices/q1.png',
        inputHash: 'h1',
        sequenceIndex: 0,
        anchorSource: 'md',
        anchorRef: '1',
        bbox2d: [40, 142, 140, 158],
        spaceWidth: 400,
        spaceHeight: 500,
        transform: transform,
        srcRect: SrcRect(x: 40, y: 142, width: 100, height: 16),
        cropPath: '',
        optionLabel: 'B',
      );
      final desc = describe(
        buildContentBlocks(
          stemMarkdown: '题干文字',
          figures: const [fig],
          mdResults: '题干文字\n\n<div>A. 甲</div>\n<div>B. 乙</div>\n![](page=0,bbox=[40, 142, 140, 158])',
        ),
      );
      expect(desc, ['TEXT:题干文字', 'FIG:figure-q1-0:unconfirmed']);
    });
  });
}
