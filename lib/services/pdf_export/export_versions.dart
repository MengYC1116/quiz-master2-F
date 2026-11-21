// 十五批 M2-1：导出版本模型（PLAN-15-REV3 §5 M2-1）。
//
// 两版定义：
// - 练习版：题号 + 正文 + 来源，无答案、无解析；答案缺失不影响练习版。
// - 答案版：与练习版同快照、同路线、同题号、同顺序、同可印题目集合；
//   题目正文照常印，答案与解析集中放在全部题目之后（按题号对应）。
// 默认只勾练习版，答案版须用户另外勾选（面板属 M3，本文件只提供
// 版本选择数据模型与生成 API 用的枚举）。
//
// 本文件为纯数据模型，不碰快照、不碰文件系统，M3 面板直接用。
/// 导出版本（练习版 / 答案版）。
enum ExportVersion {
  /// 练习版：题号 + 正文 + 来源，无答案、无解析。
  practice,

  /// 答案版：与练习版同快照、同路线、同题号、同顺序、同可印题目集合；
  /// 题目正文照常印，答案与解析集中放在全部题目之后。
  answer;

  /// 版本中文名（面板与完成界面用）。
  String get label => switch (this) {
        ExportVersion.practice => '练习版',
        ExportVersion.answer => '答案版',
      };

  /// 文件名后缀（答案版 `_答案`，见 PLAN §2 文件名默认规则；
  /// 练习版无后缀）。
  String get fileSuffix => switch (this) {
        ExportVersion.practice => '',
        ExportVersion.answer => '_答案',
      };

  /// 面板上一句话区别说明（PLAN M2-1：不要让用户猜）。
  String get difference => switch (this) {
        ExportVersion.practice => '仅题目，不含答案与解析。',
        ExportVersion.answer => '题目与练习版相同，答案与解析集中放在全部题目之后。',
      };

  /// 默认勾选状态（PLAN M2-1：默认只勾练习版）。
  bool get defaultSelected => switch (this) {
        ExportVersion.practice => true,
        ExportVersion.answer => false,
      };
}

/// 版本选择（M3 面板的状态模型；生成 API 的输入）。
class ExportVersionSelection {
  const ExportVersionSelection({
    this.practice = true,
    this.answer = false,
  });

  /// 默认选择：只勾练习版。
  const ExportVersionSelection.practiceOnly() : this();

  /// 两版都选。
  const ExportVersionSelection.both() : this(practice: true, answer: true);

  /// 是否勾练习版。
  final bool practice;

  /// 是否勾答案版。
  final bool answer;

  /// 至少选了一个版本。
  bool get hasAny => practice || answer;

  /// 选中的版本（按练习版、答案版顺序）。
  List<ExportVersion> get selected => [
        if (practice) ExportVersion.practice,
        if (answer) ExportVersion.answer,
      ];
}
