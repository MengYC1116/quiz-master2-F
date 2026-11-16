// B11-2：文件名猜学科 / 猜试卷 + 内容 SHA-256 单元测试（纯逻辑，不碰库）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/import_guess.dart';

void main() {
  group('sha256', () {
    test('空字节摘要是已知的 SHA-256 空串值', () {
      expect(
        sha256HexOfBytes([]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('相同内容摘要相同，不同内容摘要不同', () {
      expect(sha256HexOfBytes([1, 2, 3]), sha256HexOfBytes([1, 2, 3]));
      expect(sha256HexOfBytes([1, 2, 3]), isNot(sha256HexOfBytes([1, 2, 4])));
    });

    test('文件流式摘要与字节摘要一致', () async {
      final tmp = await Directory.systemTemp.createTemp('qm2-b11-hash');
      try {
        final file = File('${tmp.path}/a.jpg');
        await file.writeAsBytes([9, 8, 7, 6, 5]);
        expect(await sha256HexOfFile(file), sha256HexOfBytes([9, 8, 7, 6, 5]));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });

  group('guessSubjectId', () {
    final subjects = Subject.all;

    test('数学关键词：数学 / 高数 / 微积分', () {
      expect(guessSubjectId('数学期中考试.pdf', subjects), 'math');
      expect(guessSubjectId('高数作业3.jpg', subjects), 'math');
      expect(guessSubjectId('微积分习题.png', subjects), 'math');
    });

    test('英语关键词：四级 / 雅思 / CET', () {
      expect(guessSubjectId('英语四级真题.pdf', subjects), 'english');
      expect(guessSubjectId('雅思阅读.jpg', subjects), 'english');
      expect(guessSubjectId('CET-6模拟卷.pdf', subjects), 'english');
    });

    test('政治关键词：马原 / 毛概 / 思政', () {
      expect(guessSubjectId('马原期末.pdf', subjects), 'politics');
      expect(guessSubjectId('毛概作业.jpg', subjects), 'politics');
      expect(guessSubjectId('思政复习资料.pdf', subjects), 'politics');
    });

    test('不分大小写：MATH 命中数学', () {
      expect(guessSubjectId('MATH_hw.jpg', subjects), 'math');
    });

    test('猜不出返回 null', () {
      expect(guessSubjectId('photo.jpg', subjects), isNull);
      expect(guessSubjectId('IMG_20260315.jpg', subjects), isNull);
    });

    test('命中多个学科时取最长关键词：考研英语胜过数学', () {
      expect(guessSubjectId('考研英语数学.pdf', subjects), 'english');
    });

    test('等长命中时按预设顺序：数学胜过英语', () {
      expect(guessSubjectId('数学英语.pdf', subjects), 'math');
    });

    test('自定义学科用学科名本身匹配', () {
      final custom = [
        Subject(
          id: 'japanese',
          name: '日语',
          color: Subject.math.color,
          icon: '日',
        ),
        ...Subject.all,
      ];
      expect(guessSubjectId('日语五十音.jpg', custom), 'japanese');
    });

    test('完整路径也只看文件名', () {
      expect(guessSubjectId('/Users/a/Downloads/数学错题.jpg', subjects), 'math');
    });
  });

  group('guessCommonSubjectId', () {
    final subjects = Subject.all;

    test('全部猜到同一学科才返回', () {
      expect(guessCommonSubjectId(['数学期中.pdf', '高数作业.jpg'], subjects), 'math');
    });

    test('猜得不一致返回 null', () {
      expect(guessCommonSubjectId(['数学期中.pdf', '英语作业.jpg'], subjects), isNull);
    });

    test('有一个猜不出返回 null', () {
      expect(guessCommonSubjectId(['数学期中.pdf', 'photo.jpg'], subjects), isNull);
    });
  });

  group('guessExamName', () {
    test('日期 + 学科去掉，剩试卷名', () {
      expect(guessExamName('2026-03-数学期中考试.pdf'), '期中考试');
      expect(guessExamName('2026年3月数学期中.pdf'), '期中');
    });

    test('“试卷”通用词去掉', () {
      expect(guessExamName('高数期末试卷.pdf'), '期末');
    });

    test('“真题”保留', () {
      expect(guessExamName('英语四级真题.pdf'), '真题');
    });

    test('“作业3”保留', () {
      expect(guessExamName('数学作业3.jpg'), '作业3');
    });

    test('英文名保留原大小写，去掉年份', () {
      expect(guessExamName('Math_Midterm_2026.pdf'), 'Midterm');
    });

    test('猜不出返回 null：只剩学科 / 只剩照片 / 只剩页码', () {
      expect(guessExamName('数学.pdf'), isNull);
      expect(guessExamName('photo.jpg'), isNull);
      expect(guessExamName('2026-03-15 数学第3页.jpg'), isNull);
    });
  });
}
