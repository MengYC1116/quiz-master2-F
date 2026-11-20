// 十四批 M1：题型分类器测试。
//
// 覆盖：单元（单题信号 17 型 + 反例）、结构（材料混合小题、
// 小问路径四组 + 全同型 + 标记混杂、①② 冲突三组、双栏跨栏、
// 特殊选项符号、OCR 缺失选项）、背景标签（材料/听力/无证据）、
// 来源分离（planClassificationWrite 纯函数 + withManualQuestionType +
// acceptCandidateStem 集成）。
// 测试名不含 LaTeX 源码（M1 同款约定：源码只存在测试数据里，不进名字）。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/question_classifier.dart';
import 'package:quiz_master2/modules/ocr/stem_correction.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';

Question _q(
  String id, {
  String? questionType,
  String questionTypeSource = 'unclassified',
  String questionBackgroundTags = '',
  String questionBackgroundTagsSource = 'unclassified',
  String? ocrRaw,
  int contentVersion = 0,
}) => Question(
  id: id,
  title: '题 $id',
  subjectId: 'math',
  createdAt: DateTime(2026, 11, 8),
  questionType: questionType,
  questionTypeSource: questionTypeSource,
  questionBackgroundTags: questionBackgroundTags,
  questionBackgroundTagsSource: questionBackgroundTagsSource,
  ocrRaw: ocrRaw,
  contentVersion: contentVersion,
);

String _raw(String md) => GlmOcrRawData(
  mdResults: md,
  candidateStatus: OcrCandidateStatus.pending,
).toJsonString();

/// 分类结果的主题型（NULL = 待确认）。
String? _type(String md) => classifyQuestionText(md).questionType;

void main() {
  group('M1 分类器：单题信号', () {
    test('单选：A–E 分行', () {
      expect(
        _type('下列说法正确的是：\nA. 苹果\nB. 香蕉\nC. 橙子\nD. 葡萄'),
        'choice_single',
      );
    });

    test('单选：A–E 行内（双栏分隔；行内 A 前须 ≥2 空格，见切分器合同）', () {
      expect(
        _type('下列说法正确的是：  A. 苹果  B. 香蕉  C. 橙子  D. 葡萄'),
        'choice_single',
      );
    });

    test('多选：题干含“多选”', () {
      expect(
        _type('以下哪些是水果？（多选）\nA. 苹果\nB. 香蕉\nC. 橙子\nD. 葡萄'),
        'choice_multi',
      );
    });

    test('不定项：题干含“不定项”', () {
      expect(
        _type('不定项选择题：下列说法中正确的是\nA. 苹果\nB. 香蕉\nC. 橙子\nD. 葡萄'),
        'choice_variable',
      );
    });

    test('判断：判断关键词 + √×', () {
      expect(
        _type('判断下列说法的正误，正确的打√，错误的打×：地球是圆的。'),
        'true_false',
      );
    });

    test('填空：连续下划线空白', () {
      expect(_type('____ 是中国的首都，请在横线上填空。'), 'fill_blank');
    });

    test('填空反例：正文单下划线强调不判填空', () {
      expect(_type('请标出 _重要_ 的部分'), isNull);
    });

    test('计算：动词 + 数学结构', () {
      expect(_type('求 2 + 3 × 4 的值。'), 'calculation');
    });

    test('计算反例：只有动词、无数学结构 → 待确认', () {
      expect(_type('请计算下列问题'), isNull);
    });

    test('证明：动词 + 数学结构', () {
      expect(_type('已知 a² + b² = c²，证明该三角形是直角三角形。'), 'proof');
    });

    test('简答：主观作答动词', () {
      expect(_type('请简述牛顿第一定律的内容。'), 'short_answer');
    });

    test('论述：论述 + 成段论证要求', () {
      expect(_type('试论述改革开放的意义，不少于500字。'), 'essay');
    });

    test('名词解释归 short_answer', () {
      expect(_type('名词解释：商品。'), 'short_answer');
    });

    test('匹配：连线', () {
      expect(_type('请将下列左栏与右栏配对连线：'), 'matching');
    });

    test('排序：按时间顺序排列', () {
      expect(_type('请按时间顺序排列下列事件：辛亥革命、五四运动、新中国成立。'), 'ordering');
    });

    test('编程：代码块 + 编写指令', () {
      expect(
        _type('请编写一个函数实现冒泡排序：\n```python\ndef bubble_sort(arr):\n    pass\n```'),
        'programming',
      );
    });

    test('实验分析：实验 + 数据/结论', () {
      expect(_type('某实验测得以下数据，请分析实验结果并得出结论。'), 'experiment_analysis');
    });

    test('翻译：翻译 + 语种', () {
      expect(_type('请将下列句子翻译成英文：我爱学习。'), 'translation');
    });

    test('写作：作文 + 字数要求', () {
      expect(_type('请以《我的家乡》为题，写一篇不少于600字的作文。'), 'writing');
    });

    test('无信号 → 待确认，不硬猜', () {
      expect(_type('这是一段没有明显特征的文字。'), isNull);
    });

    test('冲突：计算 + 证明同时成立 → 待确认', () {
      expect(_type('已知 x² = 4，求 x 的值并证明你的结论。'), isNull);
    });

    test('D-118：主观作答是兜底——“分析 + 计算”只定计算，不冲突', () {
      expect(_type('请分析并计算 2 + 3 × 4 的值。'), 'calculation');
    });
  });

  group('M1 分类器：结构', () {
    test('材料混合小题：单选 + 判断 + 简答 → 待确认 + 提示拆框 + 材料标签', () {
      final c = classifyQuestionText(
        '阅读下列材料，回答下列问题：\n'
        '（1）请选择下列说法正确的是：\nA. 苹果\nB. 香蕉\n'
        '（2）请判断下列说法的正误，对的打√，错的打×：地球是圆的。\n'
        '（3）请简述牛顿第一定律的内容。',
      );
      expect(c.questionType, isNull);
      expect(c.questionTypeSource, 'unclassified');
      expect(c.suggestSplit, isTrue);
      expect(c.backgroundTags, '材料');
    });

    test('小问路径：单选 + 简答 → 待确认 + 提示拆框', () {
      final c = classifyQuestionText(
        '（1）请选择下列说法正确的是：\nA. 苹果\nB. 香蕉\n'
        '（2）请简述光合作用的过程。',
      );
      expect(c.questionType, isNull);
      expect(c.suggestSplit, isTrue);
    });

    test('小问路径：判断 + 论述 → 待确认 + 提示拆框', () {
      final c = classifyQuestionText(
        '（1）请判断下列说法的正误，对的打√，错的打×：水在100℃沸腾。\n'
        '（2）试论述改革开放的意义，不少于500字。',
      );
      expect(c.questionType, isNull);
      expect(c.suggestSplit, isTrue);
    });

    test('小问路径：单选 + 填空 → 待确认 + 提示拆框', () {
      final c = classifyQuestionText(
        '（1）请选择下列说法正确的是：\nA. 苹果\nB. 香蕉\n'
        '（2）____ 是中国的首都，请填空。',
      );
      expect(c.questionType, isNull);
      expect(c.suggestSplit, isTrue);
    });

    test('小问路径：部分小问判不出（无设问线索）→ 待确认 + 提示拆框', () {
      final c = classifyQuestionText(
        '（1）请选择下列说法正确的是：\nA. 苹果\nB. 香蕉\n'
        '（2）这是一段没有明显特征的文字。',
      );
      expect(c.questionType, isNull);
      expect(c.suggestSplit, isTrue);
    });

    test('小问路径：全同型 → 该型，不提示拆框', () {
      final c = classifyQuestionText(
        '（1）请选择下列说法正确的是：\nA. 苹果\nB. 香蕉\n'
        '（2）请选择下列说法错误的是：\nA. 苹果\nB. 香蕉',
      );
      expect(c.questionType, 'choice_single');
      expect(c.suggestSplit, isFalse);
    });

    test('小问路径：标记混杂（（1）（2）+（一）（二））→ 待确认 + 提示拆框', () {
      final c = classifyQuestionText(
        '（1）请选择下列说法正确的是：\nA. 苹果\nB. 香蕉\n'
        '（2）请简述光合作用的过程。\n'
        '（一）请解释光合作用的过程。\n'
        '（二）请分析光合作用的意义。',
      );
      expect(c.questionType, isNull);
      expect(c.suggestSplit, isTrue);
    });

    test('①② 冲突：①②③④ 选择题不进小问路径', () {
      final c = classifyQuestionText(
        '下列说法正确的是\n①苹果\n②香蕉\n③橙子\n④葡萄',
      );
      expect(c.questionType, 'choice_single');
      expect(c.suggestSplit, isFalse);
    });

    test('①② 冲突：材料 ①② 小问不判选择项（全同型简答）', () {
      final c = classifyQuestionText(
        '阅读下列材料，回答下列问题：\n'
        '①请简述牛顿第一定律的内容。\n'
        '②请解释光合作用的过程。',
      );
      expect(c.questionType, 'short_answer');
      expect(c.suggestSplit, isFalse);
      expect(c.backgroundTags, '材料');
    });

    test('①② 冲突：普通计算题（1）（2）不标“材料”', () {
      final c = classifyQuestionText(
        '计算下列各题：\n（1）求 2 + 3 × 4 的值。\n（2）求 5 × 6 - 7 的值。',
      );
      expect(c.questionType, 'calculation');
      expect(c.backgroundTags, isEmpty);
    });

    test('双栏选项跨栏：A/B 同行、C/D 下一行仍定单选', () {
      expect(
        _type('下列说法正确的是：\nA. 苹果  B. 香蕉\nC. 橙子  D. 葡萄'),
        'choice_single',
      );
    });

    test('特殊选项符号：（A）（B）（C）（D）', () {
      expect(
        _type('下列说法正确的是：\n（A）苹果\n（B）香蕉\n（C）橙子\n（D）葡萄'),
        'choice_single',
      );
    });

    test('特殊选项符号：A）B）C）D）', () {
      expect(
        _type('下列说法正确的是：\nA）苹果\nB）香蕉\nC）橙子\nD）葡萄'),
        'choice_single',
      );
    });

    test('特殊选项符号：A、B、C、D、', () {
      expect(
        _type('下列说法正确的是：\nA、苹果\nB、香蕉\nC、橙子\nD、葡萄'),
        'choice_single',
      );
    });

    test('特殊选项符号：全角 ＡＢＣＤ', () {
      expect(
        _type('下列说法正确的是：\nＡ. 苹果\nＢ. 香蕉\nＣ. 橙子\nＤ. 葡萄'),
        'choice_single',
      );
    });

    test('OCR 缺失选项：题干无选项标记 → 待确认，不判选择题', () {
      expect(_type('下列说法正确的是：苹果很好吃，香蕉也很甜。'), isNull);
    });
  });

  group('M1 分类器：背景标签', () {
    test('材料：引导语 + 其后设问', () {
      final c = classifyQuestionText(
        '阅读下列材料，根据材料回答问题：请简述改革开放的意义。',
      );
      expect(c.backgroundTags, '材料');
      expect(c.backgroundTagsSource, 'auto');
    });

    test('听力：听对话 + 回答', () {
      final c = classifyQuestionText('听力：请听对话，回答下列问题：你喜欢什么运动？');
      expect(c.backgroundTags, contains('听力'));
      expect(c.backgroundTagsSource, 'auto');
    });

    test('无可靠证据 → 不打标签', () {
      final c = classifyQuestionText('请阅读下列短文，完成下列各题：');
      expect(c.backgroundTags, isEmpty);
      expect(c.backgroundTagsSource, 'unclassified');
    });

    test('案例/阅读/完形/图表/实验场景仅保留枚举、不自动赋值', () {
      // “实验场景”：有“实验”无分析/设计/数据等结构时，不自动打任何标签。
      final c = classifyQuestionText('实验器材如图所示。');
      expect(c.backgroundTags, isEmpty);
      expect(c.questionType, isNull);
    });
  });

  group('M1 来源分离：planClassificationWrite', () {
    QuestionClassification choice({
      String? type = 'choice_single',
      String tags = '',
    }) => QuestionClassification(
      questionType: type,
      questionTypeSource: type == null ? 'unclassified' : 'auto',
      backgroundTags: tags,
      backgroundTagsSource: tags.isEmpty ? 'unclassified' : 'auto',
      reason: 'test',
    );

    test('两字段都自动：都写', () {
      final w = planClassificationWrite(
        currentTypeSource: 'auto',
        currentTagsSource: 'auto',
        classification: choice(tags: '材料'),
      );
      expect(w.writeType, isTrue);
      expect(w.questionType, 'choice_single');
      expect(w.questionTypeSource, 'auto');
      expect(w.writeTags, isTrue);
      expect(w.backgroundTags, '材料');
      expect(w.backgroundTagsSource, 'auto');
    });

    test('背景标签 manual：背景不变，主题型仍可自动更新', () {
      final w = planClassificationWrite(
        currentTypeSource: 'auto',
        currentTagsSource: 'manual',
        classification: choice(tags: '材料'),
      );
      expect(w.writeType, isTrue);
      expect(w.questionType, 'choice_single');
      expect(w.writeTags, isFalse);
    });

    test('主题型 manual：主题型不变，背景标签仍可自动更新', () {
      final w = planClassificationWrite(
        currentTypeSource: 'manual',
        currentTagsSource: 'auto',
        classification: choice(tags: '材料'),
      );
      expect(w.writeType, isFalse);
      expect(w.writeTags, isTrue);
      expect(w.backgroundTags, '材料');
    });

    test('两字段都 manual：都不写', () {
      final w = planClassificationWrite(
        currentTypeSource: 'manual',
        currentTagsSource: 'manual',
        classification: choice(),
      );
      expect(w.writeType, isFalse);
      expect(w.writeTags, isFalse);
    });

    test('未定型也写回：NULL + unclassified 覆盖旧自动分类', () {
      final w = planClassificationWrite(
        currentTypeSource: 'auto',
        currentTagsSource: 'auto',
        classification: choice(type: null),
      );
      expect(w.writeType, isTrue);
      expect(w.questionType, isNull);
      expect(w.questionTypeSource, 'unclassified');
    });
  });

  group('M1 来源分离：withManualQuestionType', () {
    test('值变化：source=manual，content_version +1', () {
      final q = _q('q1', questionType: 'choice_single', contentVersion: 3);
      final u = withManualQuestionType(q, 'calculation');
      expect(u.questionType, 'calculation');
      expect(u.questionTypeSource, 'manual');
      expect(u.contentVersion, 4);
    });

    test('值不变：只翻来源保护位，不递增版本', () {
      final q = _q(
        'q1',
        questionType: 'choice_single',
        questionTypeSource: 'auto',
        contentVersion: 3,
      );
      final u = withManualQuestionType(q, 'choice_single');
      expect(u.questionType, 'choice_single');
      expect(u.questionTypeSource, 'manual');
      expect(u.contentVersion, 3);
    });

    test('人工指定待确认：NULL + manual，值变了 +1', () {
      final q = _q('q1', questionType: 'choice_single', contentVersion: 3);
      final u = withManualQuestionType(q, null);
      expect(u.questionType, isNull);
      expect(u.questionTypeSource, 'manual');
      expect(u.contentVersion, 4);
    });
  });

  group('M1 来源分离：acceptCandidateStem 集成', () {
    test('背景 manual：重跑后背景不变，主题型仍自动更新', () async {
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final q = _q(
        'q1',
        questionType: 'short_answer',
        questionTypeSource: 'auto',
        questionBackgroundTags: '案例',
        questionBackgroundTagsSource: 'manual',
        ocrRaw: _raw('下列说法正确的是：\nA. 苹果\nB. 香蕉'),
        contentVersion: 5,
      );
      await AppDatabase.upsertQuestionInto(db, q);
      final repo = QuestionRepository(AppDatabase.instance);
      final updated = (await acceptCandidateStem(repo, q)).question;
      expect(updated.questionType, 'choice_single');
      expect(updated.questionTypeSource, 'auto');
      expect(updated.questionBackgroundTags, '案例');
      expect(updated.questionBackgroundTagsSource, 'manual');
      expect(updated.contentVersion, 6);
    });

    test('人工改题型后重跑：主题型不变，背景标签仍自动更新', () async {
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final q = _q(
        'q1',
        questionType: 'calculation',
        questionTypeSource: 'manual',
        ocrRaw: _raw(
          '阅读下列材料，根据材料回答问题：请选择下列说法正确的是：\nA. 苹果\nB. 香蕉',
        ),
        contentVersion: 2,
      );
      await AppDatabase.upsertQuestionInto(db, q);
      final repo = QuestionRepository(AppDatabase.instance);
      final updated = (await acceptCandidateStem(repo, q)).question;
      expect(updated.questionType, 'calculation');
      expect(updated.questionTypeSource, 'manual');
      expect(updated.questionBackgroundTags, '材料');
      expect(updated.questionBackgroundTagsSource, 'auto');
      expect(updated.contentVersion, 3);
    });

    test('人工指定待确认后重跑：仍为 NULL', () async {
      final db = await AppDatabase.openForTest();
      AppDatabase.useDatabaseForTest(db);
      addTearDown(() async => AppDatabase.resetForTest());
      final q = _q(
        'q1',
        questionType: null,
        questionTypeSource: 'manual',
        ocrRaw: _raw('下列说法正确的是：\nA. 苹果\nB. 香蕉'),
        contentVersion: 2,
      );
      await AppDatabase.upsertQuestionInto(db, q);
      final repo = QuestionRepository(AppDatabase.instance);
      final updated = (await acceptCandidateStem(repo, q)).question;
      expect(updated.questionType, isNull);
      expect(updated.questionTypeSource, 'manual');
      expect(updated.contentVersion, 3);
    });
  });
}
