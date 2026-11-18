// 十三批 M3：GLM-OCR 客户端 + OcrKeyStore 单测（假 HTTP 层，不调真实接口）。
// 覆盖：超时、429、5xx、key 缺失、括号校验、白边尺寸、请求形态、错误码表。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:quiz_master2/services/glm_ocr_client.dart';
import 'package:quiz_master2/services/ocr_key_store.dart';

/// 内存假安全存储后端（不碰平台通道）。
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

/// 100x50 红色 PNG（测试切片用）。
Uint8List _redPng({int width = 100, int height = 50}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 30, 30));
  return img.encodePng(image);
}

Future<File> _sliceFile(Directory tmp, {int width = 100, int height = 50}) async {
  final file = File('${tmp.path}/slice-$width.png');
  await file.writeAsBytes(_redPng(width: width, height: height));
  return file;
}

GlmOcrHttpResponse _okResponse({
  String md = '2. 双曲线 \$ 4 x^{2}-y^{2}=4 \$的离心率为\nA. 第一项\nB. 第二项',
  List<Object?> layout = const [
    {
      'bbox_2d': [0, 0, 100, 50],
      'label': 'text',
      'content': '2. 双曲线',
      'index': 0,
    },
  ],
  int totalTokens = 123,
}) => GlmOcrHttpResponse(
  statusCode: 200,
  headers: const {},
  body: jsonEncode({
    'md_results': md,
    'layout_details': layout,
    'usage': {'total_tokens': totalTokens},
  }),
);

void main() {
  group('OcrKeyStore（内存假后端）', () {
    test('set/get/has/clear 往返，键名固定为 bigmodel_api_key', () async {
      final store = OcrKeyStore(backend: _MemoryKeyBackend());
      expect(OcrKeyStore.apiKeyStorageKey, 'bigmodel_api_key');
      expect(await store.hasApiKey(), isFalse);
      expect(await store.getApiKey(), isNull);
      await store.setApiKey('  fake-key-123  ');
      expect(await store.getApiKey(), 'fake-key-123');
      expect(await store.hasApiKey(), isTrue);
      await store.clearApiKey();
      expect(await store.getApiKey(), isNull);
      expect(await store.hasApiKey(), isFalse);
    });

    test('空串 set 视为清除，不存空 key', () async {
      final store = OcrKeyStore(backend: _MemoryKeyBackend());
      await store.setApiKey('fake-key');
      await store.setApiKey('   ');
      expect(await store.getApiKey(), isNull);
    });
  });

  group('addWhitePadding（白边）', () {
    test('每边 +30%：100x50 → 160x80，四角纯白、原图居中', () {
      final padded = addWhitePadding(_redPng(width: 100, height: 50));
      final decoded = img.decodeImage(padded)!;
      expect(decoded.width, 160);
      expect(decoded.height, 80);
      // 四角是纯白边。
      for (final (x, y) in [(0, 0), (159, 0), (0, 79), (159, 79)]) {
        final pixel = decoded.getPixel(x, y);
        expect(pixel.r, 255);
        expect(pixel.g, 255);
        expect(pixel.b, 255);
      }
      // 中央仍是原图红色（偏移 30,15 处）。
      final center = decoded.getPixel(30, 15);
      expect(center.r, 200);
      expect(center.g, 30);
      // 白边比例可配：fraction=0 时尺寸不变。
      final noPad = addWhitePadding(_redPng(width: 100, height: 50), fraction: 0);
      expect(img.decodeImage(noPad)!.width, 100);
    });

    test('解不出的字节报 bad_image', () {
      expect(
        () => addWhitePadding(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(
          isA<OcrException>().having((e) => e.code, 'code', OcrErrorCode.badImage),
        ),
      );
    });
  });

  group('hasBalancedLatex（括号校验）', () {
    test('真实 GLM 公式：括号配对', () {
      expect(hasBalancedLatex(r'2. 双曲线 $ 4 x^{2}-y^{2}=4 $的离心率为'), isTrue);
      expect(hasBalancedLatex(r'1. 化简 $ \frac{2+4 \mathrm{i}}{(1+\mathrm{i})^{2}} $的结果是'), isTrue);
      expect(hasBalancedLatex(r'9. 设椭圆 $ \frac{x^{2}}{a^{2}}+\frac{y^{2}}{b^{2}}=1 $'), isTrue);
      expect(hasBalancedLatex('没有公式的中文题干'), isTrue);
      expect(hasBalancedLatex(''), isTrue);
    });

    test('不平衡：缺右括号 / 缺右花括号 / 孤 \$', () {
      expect(hasBalancedLatex(r'$ (x+1 $'), isFalse);
      expect(hasBalancedLatex(r'$ x^{2 $'), isFalse);
      expect(hasBalancedLatex(r'$ \frac{1}{2 $'), isFalse);
      expect(hasBalancedLatex(r'$ x+1 $ $ y+2'), isFalse);
      expect(unbalancedLatexSegments(r'$ (x+1 $'), isNotEmpty);
      // 转义括号不计：\( 不是括号。
      expect(hasBalancedLatex(r'$\text{(注)}$'), isTrue);
    });
  });

  group('GlmOcrClient（假 HTTP 层）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('qm2-m3-client-');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    GlmOcrClient clientWith({
      required GlmOcrRequestSender sender,
      bool withKey = true,
      Duration requestTimeout = const Duration(seconds: 120),
    }) {
      final backend = _MemoryKeyBackend();
      final store = OcrKeyStore(backend: backend);
      if (withKey) {
        // 假 key，只进测试请求头，不连真实服务。
        unawaited(store.setApiKey('fake-test-key'));
      }
      return GlmOcrClient(
        keyStore: store,
        sender: sender,
        requestTimeout: requestTimeout,
      );
    }

    test('成功：取 md_results 做文本，layout_details 原样进 raw，usage 计 tokens', () async {
      Future<GlmOcrHttpResponse> sender(
        Uri uri,
        Map<String, String> headers,
        String body,
      ) async {
        // 请求形态：layout_parsing + glm-ocr + data URI（PNG，白边后）。
        expect(uri.toString(), 'https://open.bigmodel.cn/api/paas/v4/layout_parsing');
        expect(headers['Authorization'], 'Bearer fake-test-key');
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        expect(decoded['model'], 'glm-ocr');
        final file = decoded['file'] as String;
        expect(file.startsWith('data:image/png;base64,'), isTrue);
        // 白边后的图应是 160x80（原图 100x50）。
        final pngBytes = base64Decode(file.split(',').last);
        expect(img.decodeImage(pngBytes)!.width, 160);
        return _okResponse();
      }

      final file = await _sliceFile(tmp);
      final result = await clientWith(sender: sender).recognize(file);
      expect(result.markdown, contains('双曲线'));
      expect(result.totalTokens, 123);
      final raw = result.rawData;
      expect(raw.mdResults, contains('双曲线'));
      expect(raw.layoutDetails.length, 1);
      expect((raw.layoutDetails.first as Map)['bbox_2d'], [0, 0, 100, 50]);
      // raw 包可序列化进 ocr_raw。
      expect(GlmOcrRawData.tryParse(raw.toJsonString())?.mdResults, raw.mdResults);
    });

    test('md_results 是列表时按行拼', () async {
      final client = clientWith(
        sender: (_, _, _) async => GlmOcrHttpResponse(
          statusCode: 200,
          headers: const {},
          body: jsonEncode({
            'md_results': ['第一行', '第二行'],
            'layout_details': [],
          }),
        ),
      );
      final result = await client.recognize(await _sliceFile(tmp));
      expect(result.markdown, '第一行\n第二行');
    });

    test('没 key 不发请求，报 api_key_missing（sender 未被调）', () async {
      var called = false;
      final client = clientWith(
        withKey: false,
        sender: (_, _, _) async {
          called = true;
          return _okResponse();
        },
      );
      await expectLater(
        client.recognize(await _sliceFile(tmp)),
        throwsA(
          isA<OcrException>().having((e) => e.code, 'code', OcrErrorCode.apiKeyMissing),
        ),
      );
      expect(called, isFalse);
    });

    test('401 报 api_key_invalid，不可重试', () async {
      final client = clientWith(
        sender: (_, _, _) async => GlmOcrHttpResponse(
          statusCode: 401,
          headers: const {},
          body: '{"error": "invalid key"}',
        ),
      );
      final error = await _captureError(client, await _sliceFile(tmp));
      expect(error.code, OcrErrorCode.apiKeyInvalid);
      expect(error.retryable, isFalse);
    });

    test('429 报 http_429，可重试，尊重 Retry-After 秒数', () async {
      final client = clientWith(
        sender: (_, _, _) async => GlmOcrHttpResponse(
          statusCode: 429,
          headers: const {'retry-after': '45'},
          body: '',
        ),
      );
      final error = await _captureError(client, await _sliceFile(tmp));
      expect(error.code, OcrErrorCode.http429);
      expect(error.retryable, isTrue);
      expect(error.retryAfter, const Duration(seconds: 45));
    });

    test('500 报 http_5xx，可重试；400 报 bad_params，不可重试', () async {
      final client500 = clientWith(
        sender: (_, _, _) async => GlmOcrHttpResponse(statusCode: 503, headers: const {}, body: ''),
      );
      final e500 = await _captureError(client500, await _sliceFile(tmp));
      expect(e500.code, OcrErrorCode.http5xx);
      expect(e500.retryable, isTrue);

      final client400 = clientWith(
        sender: (_, _, _) async => GlmOcrHttpResponse(statusCode: 400, headers: const {}, body: ''),
      );
      final e400 = await _captureError(client400, await _sliceFile(tmp));
      expect(e400.code, OcrErrorCode.badParams);
      expect(e400.retryable, isFalse);
    });

    test('超时：sender 抛 TimeoutException → timeout，可重试', () async {
      final client = clientWith(
        sender: (_, _, _) => throw TimeoutException('connect timed out'),
      );
      final error = await _captureError(client, await _sliceFile(tmp));
      expect(error.code, OcrErrorCode.timeout);
      expect(error.retryable, isTrue);
    });

    test('超时：请求超过 requestTimeout 也报 timeout', () async {
      final client = clientWith(
        requestTimeout: const Duration(milliseconds: 100),
        sender: (_, _, _) async {
          await Future.delayed(const Duration(seconds: 2));
          return _okResponse();
        },
      );
      final error = await _captureError(client, await _sliceFile(tmp));
      expect(error.code, OcrErrorCode.timeout);
    });

    test('网络断开：SocketException → network，可重试', () async {
      final client = clientWith(
        sender: (_, _, _) => throw const SocketException('Connection reset'),
      );
      final error = await _captureError(client, await _sliceFile(tmp));
      expect(error.code, OcrErrorCode.network);
      expect(error.retryable, isTrue);
    });

    test('200 但缺 md_results → bad_response，不可重试', () async {
      final client = clientWith(
        sender: (_, _, _) async => GlmOcrHttpResponse(
          statusCode: 200,
          headers: const {},
          body: '{"layout_details": []}',
        ),
      );
      final error = await _captureError(client, await _sliceFile(tmp));
      expect(error.code, OcrErrorCode.badResponse);
      expect(error.retryable, isFalse);
    });

    test('切片文件不存在 → file_missing，不发请求', () async {
      final client = clientWith(sender: (_, _, _) async => _okResponse());
      await expectLater(
        client.recognize(File('${tmp.path}/no-such.png')),
        throwsA(
          isA<OcrException>().having((e) => e.code, 'code', OcrErrorCode.fileMissing),
        ),
      );
    });

    test('损坏的图片 → bad_image，不发请求', () async {
      var called = false;
      final client = clientWith(
        sender: (_, _, _) async {
          called = true;
          return _okResponse();
        },
      );
      final bad = File('${tmp.path}/bad.png');
      await bad.writeAsBytes([1, 2, 3, 4, 5]);
      final error = await _captureError(client, bad);
      expect(error.code, OcrErrorCode.badImage);
      expect(called, isFalse);
    });

    test('错误码表：只增不改；可重试的只有 timeout/429/5xx/network/internal', () {
      expect(OcrErrorCode.all, containsAll({
        'api_key_missing',
        'api_key_invalid',
        'timeout',
        'http_429',
        'http_5xx',
        'network',
        'bad_image',
        'bad_params',
        'file_missing',
        'bad_response',
        'question_deleted',
        'hash_mismatch',
        'content_changed',
        'internal',
      }));
      for (final code in OcrErrorCode.all) {
        final retryable = OcrException(code, 'x').retryable;
        expect(
          retryable,
          {'timeout', 'http_429', 'http_5xx', 'network', 'internal'}.contains(code),
          reason: 'code=$code',
        );
      }
    });
  });
}

Future<OcrException> _captureError(GlmOcrClient client, File file) async {
  try {
    await client.recognize(file);
  } on OcrException catch (e) {
    return e;
  }
  fail('应抛 OcrException');
}
