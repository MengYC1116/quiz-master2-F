// 十四批 M2：题目内容版本管理规则（递增矩阵）。
// 全部保存路径汇合于 upsertQuestionIntoImpl 的中央版本权威；
// 本文件按方案表格逐项断言：哪些变 +1 content、哪些只 +1 answer、
// 哪些不动、同一事务只 +1、无变化不递增。
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/drift/quiz_database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/modules/ocr/ocr_figures.dart';
import 'package:quiz_master2/modules/ocr/stem_correction.dart';
import 'package:quiz_master2/services/glm_ocr_client.dart';

void main() {
  late QuizDatabase db;
  late QuestionRepository repo;

  Future<Question> insert(Question q) async {
    await AppDatabase.upsertQuestionInto(db, q);
    return q;
  }

  Future<Question> reload(String id) async => (await repo.questionById(id))!;

  Question base(String id, {int contentVersion = 0, int answerVersion = 1}) =>
      Question(
        id: id,
        title: '题 $id',
        subjectId: 'math',
        createdAt: DateTime(2026, 11, 18),
        ocrStem: '旧题干',
        contentVersion: contentVersion,
        answerVersion: answerVersion,
      );

  setUp(() async {
    db = await AppDatabase.openForTest();
    AppDatabase.useDatabaseForTest(db);
    repo = QuestionRepository(AppDatabase.instance);
  });

  test('题干文字变化 → content +1，answer 不动', () async {
    await insert(base('q1', contentVersion: 3, answerVersion: 2));
    await repo.save((await reload('q1')).copyWith(ocrStem: '新题干'));
    final stored = await reload('q1');
    expect(stored.contentVersion, 4);
    expect(stored.answerVersion, 2);
  });

  test('同一事务改多个内容字段 → content 只 +1', () async {
    await insert(base('q1', contentVersion: 3));
    final q = await reload('q1');
    await repo.save(
      q.copyWith(
        ocrStem: '新题干',
        questionType: '选择题',
        ocrSplitStatus: '已拆分',
      ),
    );
    expect((await reload('q1')).contentVersion, 4);
  });

  test('无变化重新保存 → 两个版本都不递增', () async {
    await insert(base('q1', contentVersion: 3, answerVersion: 2));
    final q = await reload('q1');
    await repo.save(q);
    final stored = await reload('q1');
    expect(stored.contentVersion, 3);
    expect(stored.answerVersion, 2);
  });

  test('答案/解析/correct_option/option_labels 变化 → 只 +1 answer', () async {
    await insert(base('q1', contentVersion: 3, answerVersion: 2));
    final q = await reload('q1');
    await repo.save(
      q.copyWith(
        answer: '新答案',
        explanation: '新解析',
        correctOption: 'B',
        optionLabels: ['A', 'B', 'C', 'D'],
      ),
    );
    final stored = await reload('q1');
    expect(stored.contentVersion, 3);
    expect(stored.answerVersion, 3);
  });

  test('答案侧与内容侧同改 → 各 +1 一次', () async {
    await insert(base('q1', contentVersion: 3, answerVersion: 2));
    final q = await reload('q1');
    await repo.save(q.copyWith(ocrStem: '新题干', answer: '新答案'));
    final stored = await reload('q1');
    expect(stored.contentVersion, 4);
    expect(stored.answerVersion, 3);
  });

  test('题型变化 → content +1（question_type 例外）', () async {
    await insert(base('q1', contentVersion: 3));
    final q = await reload('q1');
    await repo.save(q.copyWith(questionType: '填空题'));
    expect((await reload('q1')).contentVersion, 4);
  });

  test('归类字段变化（文件夹/考试）→ 两个版本都不动', () async {
    await insert(base('q1', contentVersion: 3, answerVersion: 2));
    final q = await reload('q1');
    await repo.save(
      q.copyWith(
        folderIds: ['f1', 'f2'],
        examId: 'exam-1',
      ),
    );
    final stored = await reload('q1');
    expect(stored.contentVersion, 3);
    expect(stored.answerVersion, 2);
  });

  test('图块新增 → content +1；顺序改变 → content +1；内容相同重排无 → 不动', () async {
    await insert(base('q1', contentVersion: 3));
    final figureJson =
        '[{"id":"figure-q1-0","slice_path":"slices/q1.png","input_hash":"h1",'
        '"sequence_index":0,"anchor_source":"fallback","anchor_ref":"",'
        '"bbox_2d":[10,5,60,25],"space_width":100,"space_height":50,'
        '"transform":{"src_w":100,"src_h":50,"req_w":100,"req_h":50,"pad_x":0,"pad_y":0},'
        '"src_rect":{"x":10,"y":5,"w":50,"h":20},"crop_path":"slices/q1-fig-a.png"}]';
    await repo.save((await reload('q1')).copyWith(ocrFigures: figureJson));
    expect((await reload('q1')).contentVersion, 4);
    // 图块删除（deleteFigureFromQuestion 纯函数预 +1，落库归一化为恰好 +1）。
    final withFigure = await reload('q1');
    final without = deleteFigureFromQuestion(withFigure, 'figure-q1-0');
    expect(without.contentVersion, 5); // 纯函数预 +1
    await repo.save(without);
    expect((await reload('q1')).contentVersion, 5); // 落库只 +1 一次
    // 相同图块内容重新保存 → 不动。
    await repo.save((await reload('q1')).copyWith(ocrFigures: '[]'));
    expect((await reload('q1')).contentVersion, 5);
  });

  test('图块顺序改变 → content +1', () async {
    OcrFigure figure(String id, int seq, String crop) => OcrFigure(
      id: id,
      slicePath: 'slices/q1.png',
      inputHash: 'h1',
      sequenceIndex: seq,
      anchorSource: 'fallback',
      anchorRef: '',
      bbox2d: const [10, 5, 60, 25],
      spaceWidth: 100,
      spaceHeight: 50,
      transform: const OcrRequestTransform(
        srcW: 100,
        srcH: 50,
        reqW: 100,
        reqH: 50,
        padX: 0,
        padY: 0,
      ),
      srcRect: const SrcRect(x: 10, y: 5, width: 50, height: 20),
      cropPath: crop,
    );
    final two = encodeOcrFigures([
      figure('figure-q1-0', 0, 'slices/q1-fig-a.png'),
      figure('figure-q1-1', 1, 'slices/q1-fig-b.png'),
    ]);
    await insert(base('q1', contentVersion: 3));
    await repo.save((await reload('q1')).copyWith(ocrFigures: two));
    expect((await reload('q1')).contentVersion, 4);
    final swapped = encodeOcrFigures([
      figure('figure-q1-1', 0, 'slices/q1-fig-b.png'),
      figure('figure-q1-0', 1, 'slices/q1-fig-a.png'),
    ]);
    await repo.save((await reload('q1')).copyWith(ocrFigures: swapped));
    expect((await reload('q1')).contentVersion, 5);
  });

  test('候选状态变化（pending→ignored）→ content +1（可见状态）', () async {
    final raw = GlmOcrRawData(
      mdResults: '题干',
      layoutDetails: const [],
      candidateStatus: OcrCandidateStatus.pending,
    );
    await insert(
      base('q1', contentVersion: 2).copyWith(ocrRaw: raw.toJsonString()),
    );
    final dismissed = dismissOcrCandidateFlag(await reload('q1'));
    await repo.save(dismissed);
    expect((await reload('q1')).contentVersion, 3);
  });

  test('仅技术元数据变化（usage/token）→ 不递增', () async {
    final raw = GlmOcrRawData(
      mdResults: '题干',
      layoutDetails: const [],
      usage: const {'total_tokens': 10},
    );
    await insert(
      base('q1', contentVersion: 3, answerVersion: 2)
          .copyWith(ocrRaw: raw.toJsonString()),
    );
    final changed = GlmOcrRawData(
      mdResults: '题干',
      layoutDetails: const [],
      usage: const {'total_tokens': 99},
    );
    await repo.save(
      (await reload('q1')).copyWith(ocrRaw: changed.toJsonString()),
    );
    final stored = await reload('q1');
    expect(stored.contentVersion, 3);
    expect(stored.answerVersion, 2);
    // 新元数据本身写进去了，只是版本不动。
    expect(
      GlmOcrRawData.tryParse(stored.ocrRaw)!.usage['total_tokens'],
      99,
    );
  });

  test('切片路径变化（重框）→ content +1；同路径重写 → 不动', () async {
    await insert(
      base('q1', contentVersion: 3).copyWith(
        slicePath: 'slices/q1-v1.png',
        sliceWidth: 100,
        sliceHeight: 50,
      ),
    );
    await repo.save(
      (await reload('q1')).copyWith(slicePath: 'slices/q1-v2.png'),
    );
    expect((await reload('q1')).contentVersion, 4);
    // 同路径、同尺寸重新保存 → 不动。
    await repo.save(await reload('q1'));
    expect((await reload('q1')).contentVersion, 4);
  });
}
