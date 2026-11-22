// 二十七批（D-257）：科目英文名自动翻译（方案三，GLM 翻译，复用 BigModel key）。
// 翻译 HTTP 层全部 mock，不调真实接口；覆盖翻译成功存库、失败回退、
// 手动值不被覆盖、无 key 行为、改名重翻、打开补翻。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_master2/data/database.dart';
import 'package:quiz_master2/data/repository.dart';
import 'package:quiz_master2/models/models.dart';
import 'package:quiz_master2/services/glm_subject_translator.dart';
import 'package:quiz_master2/services/ocr_key_store.dart';
import 'package:quiz_master2/state/repository_provider.dart';
import 'package:quiz_master2/state/subjects_notifier.dart';

class _MemoryKeyBackend implements OcrKeyStorageBackend {
  final _map = <String, String>{};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }

  @override
  Future<bool> containsKey(String key) async => _map.containsKey(key);
}

/// 记下发包层收到的请求，供断言请求形态用；按构造时给的响应回包。
class _CapturingSender {
  _CapturingSender(this.respond);

  final Future<GlmTranslateHttpResponse> Function() respond;
  int calls = 0;
  Uri? lastUri;
  Map<String, String>? lastHeaders;
  String? lastBody;

  Future<GlmTranslateHttpResponse> call(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    calls++;
    lastUri = uri;
    lastHeaders = headers;
    lastBody = body;
    return respond();
  }
}

GlmTranslateHttpResponse _okJson(String content) =>
    GlmTranslateHttpResponse(
      statusCode: 200,
      body: jsonEncode({
        'choices': [
          {
            'message': {'content': content},
          },
        ],
      }),
    );

/// 假翻译器：按表返回值；throwOnTranslate 时抛异常（测“翻译器炸了也不阻塞”）。
class _FakeTranslator extends GlmSubjectTranslator {
  _FakeTranslator({this.results = const {}, this.throwOnTranslate = false});

  final Map<String, String?> results;
  final bool throwOnTranslate;
  int calls = 0;
  final List<String> calledWith = [];

  @override
  Future<String?> translate(String chineseName) async {
    calls++;
    calledWith.add(chineseName);
    if (throwOnTranslate) throw StateError('boom');
    return results[chineseName];
  }
}

/// Notifier 测试用 FakeRepo（只覆盖 Notifier 实际调的方法）。
class _FakeRepo extends QuestionRepository {
  _FakeRepo() : super(AppDatabase.instance);

  List<Subject> subjectsList = List.of(Subject.all);
  List<Question> questions = [];
  List<KnowledgePoint> kps = [];
  List<String> tagsList = [];
  List<Exam> examsList = [];
  List<Folder> savedFolders = [];
  int saveSubjectCalls = 0;

  @override
  Future<List<Subject>> subjects() async => List.of(subjectsList);

  @override
  Future<List<Question>> all({bool includeArchived = false}) async =>
      List.of(questions);

  @override
  Future<List<KnowledgePoint>> knowledgePoints() async => List.of(kps);

  @override
  Future<List<String>> tags() async => List.of(tagsList);

  @override
  Future<List<Exam>> exams() async => List.of(examsList);

  @override
  Future<void> saveSubject(Subject s) async {
    saveSubjectCalls++;
    final i = subjectsList.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      subjectsList[i] = s;
    } else {
      subjectsList.add(s);
    }
  }

  @override
  Future<void> saveFolder(Folder f) async {
    savedFolders.add(f);
  }
}

ProviderContainer _container(
  _FakeRepo repo,
  GlmSubjectTranslator translator,
) {
  final c = ProviderContainer.test(
    overrides: [
      repositoryProvider.overrideWithValue(repo),
      subjectTranslatorProvider.overrideWithValue(translator),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// 等条件成立（后台补翻是 unawaited 的，测最终态时轮询等它落库）。
Future<void> _waitFor(
  bool Function() cond, {
  String description = 'condition',
}) async {
  for (var i = 0; i < 50; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for $description');
}

void main() {
  group('二十七批：GLM 翻译客户端（D-257）', () {
    test('翻译成功：返回英文名；请求走 chat completions + glm-4-flash', () async {
      final backend = _MemoryKeyBackend();
      await OcrKeyStore(backend: backend).setApiKey('fake-key-123');
      final sender = _CapturingSender(() async => _okJson('Advanced Mathematics'));
      final translator = GlmSubjectTranslator(
        keyStore: OcrKeyStore(backend: backend),
        sender: sender.call,
      );
      expect(await translator.translate('高等数学'), 'Advanced Mathematics');
      expect(sender.calls, 1);
      expect(sender.lastUri, GlmSubjectTranslator.endpoint);
      expect(sender.lastUri.toString(), contains('chat/completions'));
      expect(sender.lastHeaders!['Authorization'], 'Bearer fake-key-123');
      final body = jsonDecode(sender.lastBody!) as Map<String, dynamic>;
      expect(body['model'], 'glm-4-flash');
      expect(body['temperature'], 0);
      final messages = body['messages'] as List;
      expect((messages.single as Map)['content'], contains('高等数学'));
      expect((messages.single as Map)['content'], contains('only'));
    });

    test('清洗：去空白与引号、只要第一行', () async {
      final backend = _MemoryKeyBackend();
      await OcrKeyStore(backend: backend).setApiKey('fake-key-123');
      String content = '  "Data Structures"  ';
      var translator = GlmSubjectTranslator(
        keyStore: OcrKeyStore(backend: backend),
        sender: (_, __, ___) async => _okJson(content),
      );
      expect(await translator.translate('数据结构'), 'Data Structures');
      content = 'Chemistry\nSome explanation here';
      translator = GlmSubjectTranslator(
        keyStore: OcrKeyStore(backend: backend),
        sender: (_, __, ___) async => _okJson(content),
      );
      expect(await translator.translate('化学'), 'Chemistry');
    });

    test('无 key：返回 null，不发请求', () async {
      final sender = _CapturingSender(() async => _okJson('Chemistry'));
      final translator = GlmSubjectTranslator(
        keyStore: OcrKeyStore(backend: _MemoryKeyBackend()),
        sender: sender.call,
      );
      expect(await translator.translate('化学'), isNull);
      expect(sender.calls, 0);
    });

    test('空名：返回 null，不发请求', () async {
      final backend = _MemoryKeyBackend();
      await OcrKeyStore(backend: backend).setApiKey('fake-key-123');
      final sender = _CapturingSender(() async => _okJson('Chemistry'));
      final translator = GlmSubjectTranslator(
        keyStore: OcrKeyStore(backend: backend),
        sender: sender.call,
      );
      expect(await translator.translate('   '), isNull);
      expect(sender.calls, 0);
    });

    test('HTTP 401/500：返回 null', () async {
      final backend = _MemoryKeyBackend();
      await OcrKeyStore(backend: backend).setApiKey('fake-key-123');
      for (final status in [401, 403, 429, 500]) {
        final translator = GlmSubjectTranslator(
          keyStore: OcrKeyStore(backend: backend),
          sender: (_, __, ___) async => GlmTranslateHttpResponse(
            statusCode: status,
            body: '{}',
          ),
        );
        expect(await translator.translate('化学'), isNull, reason: '$status');
      }
    });

    test('响应异常：非 JSON / 缺 choices / 内容非文本 / 仍含中文 → null', () async {
      final backend = _MemoryKeyBackend();
      await OcrKeyStore(backend: backend).setApiKey('fake-key-123');
      final bodies = [
        'not json',
        '{}',
        '{"choices": []}',
        '{"choices": [{"message": {"content": 123}}]}',
        jsonEncode({
          'choices': [
            {
              'message': {'content': '化学'},
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'message': {'content': '  '},
            },
          ],
        }),
      ];
      for (final body in bodies) {
        final translator = GlmSubjectTranslator(
          keyStore: OcrKeyStore(backend: backend),
          sender: (_, __, ___) async =>
              GlmTranslateHttpResponse(statusCode: 200, body: body),
        );
        expect(await translator.translate('化学'), isNull, reason: body);
      }
    });

    test('发包层抛超时/断网：返回 null', () async {
      final backend = _MemoryKeyBackend();
      await OcrKeyStore(backend: backend).setApiKey('fake-key-123');
      final translator = GlmSubjectTranslator(
        keyStore: OcrKeyStore(backend: backend),
        sender: (_, __, ___) async => throw TimeoutException('t'),
      );
      expect(await translator.translate('化学'), isNull);
    });
  });

  group('二十七批：学科管理自动翻译（D-257）', () {
    test('新建学科：翻译成功 → 英文名存库（manual=false）', () async {
      final repo = _FakeRepo();
      final translator = _FakeTranslator(results: {'化学': 'Chemistry'});
      final c = _container(repo, translator);
      final n = c.read(subjectsProvider.notifier);
      await n.load();
      final r = await n.addSubject('化学');
      expect(r.saved, isTrue);
      await _waitFor(
        () => repo.subjectsList.any(
          (s) => s.name == '化学' && s.englishName == 'Chemistry',
        ),
        description: 'chemistry translated',
      );
      final chem = repo.subjectsList.firstWhere((s) => s.name == '化学');
      expect(chem.englishNameManual, isFalse);
      expect(translator.calledWith, contains('化学'));
    });

    test('翻译失败（返回 null）：学科照常新建，英文名留空', () async {
      final repo = _FakeRepo();
      final translator = _FakeTranslator(results: {});
      final c = _container(repo, translator);
      final n = c.read(subjectsProvider.notifier);
      await n.load();
      final r = await n.addSubject('化学');
      expect(r.saved, isTrue);
      await _waitFor(
        () => repo.subjectsList.any((s) => s.name == '化学'),
        description: 'chemistry created',
      );
      final chem = repo.subjectsList.firstWhere((s) => s.name == '化学');
      expect(chem.englishName, isNull);
      expect(translator.calls, greaterThanOrEqualTo(1));
    });

    test('翻译器抛异常也不阻塞建学科', () async {
      final repo = _FakeRepo();
      final translator = _FakeTranslator(throwOnTranslate: true);
      final c = _container(repo, translator);
      final n = c.read(subjectsProvider.notifier);
      await n.load();
      final r = await n.addSubject('化学');
      expect(r.saved, isTrue);
      await _waitFor(
        () => repo.subjectsList.any((s) => s.name == '化学'),
        description: 'chemistry created',
      );
      expect(
        repo.subjectsList.firstWhere((s) => s.name == '化学').englishName,
        isNull,
      );
    });

    test('无 key：真实翻译器返回 null，不调发包层', () async {
      final repo = _FakeRepo();
      var senderCalls = 0;
      final realTranslator = GlmSubjectTranslator(
        keyStore: OcrKeyStore(backend: _MemoryKeyBackend()),
        sender: (_, __, ___) async {
          senderCalls++;
          return _okJson('Chemistry');
        },
      );
      final c = _container(repo, realTranslator);
      final n = c.read(subjectsProvider.notifier);
      await n.load();
      await n.addSubject('化学');
      await _waitFor(
        () => repo.subjectsList.any((s) => s.name == '化学'),
        description: 'chemistry created',
      );
      expect(senderCalls, 0);
      expect(
        repo.subjectsList.firstWhere((s) => s.name == '化学').englishName,
        isNull,
      );
    });

    test('手动值不被覆盖：有 manual 英文名的学科不翻译', () async {
      final repo = _FakeRepo();
      repo.subjectsList.add(
        Subject(
          id: 'chem',
          name: '化学',
          color: const Color(0xFF7C3AED),
          icon: '化',
          englishName: 'My Chemistry',
          englishNameManual: true,
        ),
      );
      final translator = _FakeTranslator(results: {'化学': 'Chemistry'});
      final c = _container(repo, translator);
      final n = c.read(subjectsProvider.notifier);
      await n.load();
      await n.backfillEnglishNames();
      expect(translator.calledWith, isNot(contains('化学')));
      final chem = repo.subjectsList.firstWhere((s) => s.id == 'chem');
      expect(chem.englishName, 'My Chemistry');
    });

    test('改名重翻：旧英文名清空，新名重新翻译', () async {
      final repo = _FakeRepo();
      repo.subjectsList.add(
        Subject(
          id: 'chem',
          name: '化学',
          color: const Color(0xFF7C3AED),
          icon: '化',
          englishName: 'Chemistry',
          englishNameManual: false,
        ),
      );
      final translator = _FakeTranslator(results: {'物理': 'Physics'});
      final c = _container(repo, translator);
      final n = c.read(subjectsProvider.notifier);
      await n.load();
      final r = await n.renameSubject('chem', '物理');
      expect(r.saved, isTrue);
      await _waitFor(
        () => repo.subjectsList.any(
          (s) => s.id == 'chem' && s.englishName == 'Physics',
        ),
        description: 'physics translated after rename',
      );
      expect(translator.calledWith, contains('物理'));
    });

    test('改名手动值不动：手动填过的英文名不随改名重翻', () async {
      final repo = _FakeRepo();
      repo.subjectsList.add(
        Subject(
          id: 'chem',
          name: '化学',
          color: const Color(0xFF7C3AED),
          icon: '化',
          englishName: 'My Chemistry',
          englishNameManual: true,
        ),
      );
      final translator = _FakeTranslator(results: {'物理': 'Physics'});
      final c = _container(repo, translator);
      final n = c.read(subjectsProvider.notifier);
      await n.load();
      final r = await n.renameSubject('chem', '物理');
      expect(r.saved, isTrue);
      await n.backfillEnglishNames();
      expect(translator.calledWith, isNot(contains('物理')));
      final chem = repo.subjectsList.firstWhere((s) => s.id == 'chem');
      expect(chem.englishName, 'My Chemistry');
    });

    test('预设三科不翻译：存值缺失也不翻', () async {
      final repo = _FakeRepo();
      // 模拟从老库恢复的预设行：英文名缺失。
      repo.subjectsList = [
        Subject(
          id: 'math',
          name: '数学',
          color: const Color(0xFF2E7CF6),
          icon: '数',
        ),
      ];
      final translator = _FakeTranslator(results: {'数学': 'Mathematics'});
      final c = _container(repo, translator);
      final n = c.read(subjectsProvider.notifier);
      await n.load();
      await n.backfillEnglishNames();
      expect(translator.calledWith, isNot(contains('数学')));
      expect(repo.subjectsList.single.englishName, isNull);
    });

    test('打开补翻：同一打开内失败只试一次，下次打开再试', () async {
      final repo = _FakeRepo();
      repo.subjectsList.add(
        Subject(
          id: 'chem',
          name: '化学',
          color: const Color(0xFF7C3AED),
          icon: '化',
        ),
      );
      final translator = _FakeTranslator(results: {});
      final c = _container(repo, translator);
      final n = c.read(subjectsProvider.notifier);
      await n.load();
      await n.backfillEnglishNames();
      expect(translator.calls, 1);
      // 同一打开再调一次：不重复试。
      await n.backfillEnglishNames();
      expect(translator.calls, 1);
      // 下次打开（新 Notifier）：再试一次。
      final c2 = _container(repo, translator);
      final n2 = c2.read(subjectsProvider.notifier);
      await n2.load();
      await n2.backfillEnglishNames();
      expect(translator.calls, 2);
    });

  });
}
