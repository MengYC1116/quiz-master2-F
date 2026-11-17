// 学科首字母 / 拼音排序的唯一实现（FR-08：整理页与错题本共用）。
//
// 按学科名算，不按 id 写死——新学科不再一律落到 'S'（数学档）。
// 拼音表原在 `wrongbook_notifier.dart`（SR2-32），FR-08 抽到此处，
// 两处（整理页 `_sorted` / 队列弹窗 `_filtered`、错题本
// `subjectInitial` / `subjectPinyinKey` / `subjectKeyCompare`）
// 均调这里；改表只改一处。

/// 学科名首字 → 拼音首字母（常见学科首字；拉丁字母开头直接取大写；
/// 表外汉字回退为该字本身，仍可区分排序，不再统一落到同一档）。
const pinyinInitials = {
  '数': 'S',
  '英': 'Y',
  '政': 'Z',
  '语': 'Y',
  '文': 'W',
  '化': 'H',
  '物': 'W',
  '生': 'S',
  '地': 'D',
  '历': 'L',
  '史': 'S',
  '外': 'W',
  '体': 'T',
  '音': 'Y',
  '美': 'M',
  '计': 'J',
  '高': 'G',
  '大': 'D',
  '普': 'P',
  '专': 'Z',
  '马': 'M',
  '思': 'S',
  '法': 'F',
  '经': 'J',
  '管': 'G',
  '工': 'G',
  '农': 'N',
  '医': 'Y',
  '药': 'Y',
  '心': 'X',
  '教': 'J',
  '育': 'Y',
  '科': 'K',
  '技': 'J',
  '信': 'X',
  '电': 'D',
  '机': 'J',
  '土': 'T',
  '建': 'J',
  '交': 'J',
  '商': 'S',
  '金': 'J',
  '财': 'C',
  '会': 'K',
  '审': 'S',
  '统': 'T',
  '概': 'G',
  '率': 'L',
  '线': 'X',
  '代': 'D',
  '微': 'W',
  '积': 'J',
  '分': 'F',
  '函': 'H',
  '导': 'D',
  '极': 'J',
  '限': 'X',
  '复': 'F',
  '变': 'B',
  '常': 'C',
  '偏': 'P',
  '军': 'J',
  '哲': 'Z',
  '逻': 'L',
  '伦': 'L',
  '日': 'R',
  '德': 'D',
  '毛': 'M',
  '中': 'Z',
  '形': 'X',
  '操': 'C',
  '离': 'L',
  '网': 'W',
  '据': 'J',
  '云': 'Y',
  '智': 'Z',
  '能': 'N',
  '自': 'Z',
  '动': 'D',
  '控': 'K',
  '仪': 'Y',
  '传': 'C',
  '感': 'G',
  '环': 'H',
  '资': 'Z',
  '源': 'Y',
  '矿': 'K',
  '测': 'C',
  '汽': 'Q',
  '航': 'H',
  '天': 'T',
  '海': 'H',
  '护': 'H',
  '临': 'L',
  '影': 'Y',
  '营': 'Y',
  '材': 'C',
};

/// 学科名首字母（SR2-32 口径）：空名回退 '{'（排在 Z 之后、最后）。
String subjectInitialForName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '{';
  final first = trimmed[0];
  if (first.codeUnitAt(0) < 128) return first.toUpperCase();
  return pinyinInitials[first] ?? first;
}

/// 学科名逐字转首字母串（SR2-32：同首字母平局按它排，不再按 Unicode
/// 码点比全名——“生物” SHENGWU 排在“数学” SHUXUE 前面才是拼音序）。
/// 表外汉字仍回退为原字比较（码点序，不是拼音序）；拉丁字母直接取大写。
/// 空名返回 ''，与回退到 '{' 的首字母一致排最后。
String subjectPinyinKeyForName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '';
  final buf = StringBuffer();
  for (var i = 0; i < trimmed.length; i++) {
    final ch = trimmed[i];
    if (ch.codeUnitAt(0) < 128) {
      buf.write(ch.toUpperCase());
    } else {
      buf.write(pinyinInitials[ch] ?? ch);
    }
  }
  return buf.toString();
}

/// 两学科名比较：首字母 → 全名拼音首字母串 → 原名（码点序兜底）。
int compareSubjectNames(String a, String b) {
  final c = subjectInitialForName(a).compareTo(subjectInitialForName(b));
  if (c != 0) return c;
  final k = subjectPinyinKeyForName(a).compareTo(subjectPinyinKeyForName(b));
  if (k != 0) return k;
  return a.compareTo(b);
}
