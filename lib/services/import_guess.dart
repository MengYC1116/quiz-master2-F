// B11-2：批量导入辅助——文件名猜学科 / 猜试卷 + 文件内容 SHA-256。
//
// 只做建议、不做决定：猜学科只用来预填收集页的学科下拉框，用户随时
// 可改；猜试卷只在批量队列行上显示一行建议，整理时仍由用户在整理
// 工作台选 / 新建试卷，不写库、不静默指定。
// 内容哈希只用来比对“已经导入过”（与既有文件名口径并列），确认重导
// 的流程不变（见 ImportService.checkContentDuplicates）。
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/models.dart';

/// 学科关键词（大学三科预设；自定义学科用学科名本身匹配，见
/// [guessSubjectId]）。只列 2 字以上的词，避免单字误撞。
const _subjectKeywords = <String, List<String>>{
  'math': [
    '数学',
    '高数',
    '高等数学',
    '微积分',
    '线性代数',
    '概率论',
    '数理统计',
    '离散数学',
    '复变函数',
    'math',
    'calculus',
    'algebra',
    'probability',
  ],
  'english': [
    '英语',
    '四级',
    '六级',
    '雅思',
    '托福',
    '专四',
    '专八',
    '考研英语',
    'cet',
    'cet4',
    'cet6',
    'english',
    'ielts',
    'toefl',
  ],
  'politics': [
    '政治',
    '马原',
    '毛概',
    '思政',
    '近代史',
    '纲要',
    '形势与政策',
    '马克思',
    '毛泽东',
    'politics',
    'marx',
  ],
};

/// 预设三科的固定顺序（同名次命中时按此顺序取胜，不按文件名位置）。
int? _presetOrder(String id) => switch (id) {
  'math' => 0,
  'english' => 1,
  'politics' => 2,
  _ => null,
};

/// 猜试卷名时去掉的通用词（去掉后剩下的才是试卷名候选）。
const _genericExamWords = [
  '试卷',
  '错题',
  '错题集',
  '错题本',
  '扫描',
  '扫描件',
  '图片',
  '照片',
  'scan',
  'photo',
  'img',
  'pic',
];

String _baseName(String path) {
  final slash = path.replaceAll('\\', '/');
  final parts = slash.split('/');
  return parts.isEmpty ? path : parts.last;
}

String _withoutExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/// 按文件名猜学科：返回学科 id，猜不出返回 null。
///
/// 规则：文件名（不分大小写）含某学科关键词即命中，命中多个学科时
/// 取最长关键词者；等长时按预设顺序 数学 / 英语 / 政治，再按学科
/// 列表顺序。自定义学科用学科名本身作关键词（不少于 2 字）。
String? guessSubjectId(String fileNameOrPath, List<Subject> subjects) {
  final lower = _baseName(fileNameOrPath).toLowerCase();
  String? bestId;
  var bestLen = 0;
  var bestOrder = 1 << 30;
  for (var i = 0; i < subjects.length; i++) {
    final subject = subjects[i];
    final keywords = <String>{
      subject.name.toLowerCase(),
      ...?_subjectKeywords[subject.id],
    };
    var matchLen = 0;
    for (final keyword in keywords) {
      if (keyword.length < 2) continue;
      if (lower.contains(keyword) && keyword.length > matchLen) {
        matchLen = keyword.length;
      }
    }
    if (matchLen == 0) continue;
    final order = _presetOrder(subject.id) ?? (100 + i);
    if (matchLen > bestLen || (matchLen == bestLen && order < bestOrder)) {
      bestId = subject.id;
      bestLen = matchLen;
      bestOrder = order;
    }
  }
  return bestId;
}

/// 一批文件共用的学科猜测：全部文件猜到同一学科才返回它；
/// 有任何一个猜不出、或猜得不一致，返回 null（不预填，等用户选）。
String? guessCommonSubjectId(
  List<String> fileNamesOrPaths,
  List<Subject> subjects,
) {
  String? common;
  for (final name in fileNamesOrPaths) {
    final guessed = guessSubjectId(name, subjects);
    if (guessed == null) return null;
    if (common == null) {
      common = guessed;
    } else if (common != guessed) {
      return null;
    }
  }
  return common;
}

String _removeWord(String text, String word) {
  if (RegExp(r'^[a-z0-9]+$').hasMatch(word)) {
    return text.replaceAll(RegExp(word, caseSensitive: false), ' ');
  }
  return text.replaceAll(word, ' ');
}

/// 按文件名猜试卷名：返回建议的试卷名，猜不出返回 null。
///
/// 做法：去掉扩展名 → 全局去掉日期（2026-03-15 / 2026年3月 / 20260315）
/// → 按分隔符分词 → 丢掉纯数字词（2026 / 03 / 15）、“第 N 页 /
/// 第 N 题”、含学科关键词与通用词（试卷 / 错题 / 扫描 …）的部分 →
/// 剩下的词拼起来（不少于 2 字）原样返回，不改写、不入库。
String? guessExamName(String fileNameOrPath) {
  var stem = _withoutExtension(_baseName(fileNameOrPath));
  // 中文日期单独一条（2026年3月 / 2026年3月15日）：通用式
  // `\d{4}[-./年]\d{1,2}...` 在“月”后无数字时会只吃掉“2026年3”、
  // 剩下“月”，所以先把中文日期整段去掉。
  stem = stem.replaceAll(
    RegExp(r'\d{4}年\d{1,2}月(\d{1,2}日?)?'),
    ' ',
  );
  stem = stem.replaceAll(
    RegExp(r'\d{4}[-./]\d{1,2}([-./]\d{1,2})?'),
    ' ',
  );
  stem = stem.replaceAll(RegExp(r'\d{8}'), ' ');
  final kept = <String>[];
  for (final token in stem.split(RegExp(r'[ \-_·,，。()\[\]（）]+'))) {
    var t = token;
    if (t.isEmpty) continue;
    // 先去掉学科关键词与通用词，再判丢弃——“数学第3页”去完
    // “数学”才露出“第3页”，先判会漏网。
    for (final keywords in _subjectKeywords.values) {
      for (final keyword in keywords) {
        t = _removeWord(t, keyword);
      }
    }
    for (final word in _genericExamWords) {
      t = _removeWord(t, word);
    }
    t = t.trim();
    if (t.isEmpty) continue;
    // 纯数字词（日期残段 2026 / 03 / 15）丢掉；单独的“3”留下
    //（“作业3”里的 3 不是独立词，不受影响）。
    if (RegExp(r'^\d+$').hasMatch(t) && t.length >= 2) continue;
    // 第 N 页 / 第 N 题 / p3 之类的位置标记丢掉。
    if (RegExp(r'^第\d+[页题]$').hasMatch(t)) continue;
    if (RegExp(r'^p\d+$', caseSensitive: false).hasMatch(t)) continue;
    kept.add(t);
  }
  final result = kept.join(' ');
  if (result.length < 2) return null;
  return result;
}

/// 字节的 SHA-256 十六进制摘要。
String sha256HexOfBytes(List<int> bytes) => sha256.convert(bytes).toString();

/// 文件的 SHA-256 十六进制摘要（流式读，不整文件进内存）。
Future<String> sha256HexOfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
