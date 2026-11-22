// 二十七批 D-257：科目英文名自动翻译（方案三，GLM 翻译，复用 BigModel key）。
//
// 只做一件事：把中文学科名翻成英文名（chat completions，glm-4-flash，
// temperature 0），供学科管理在新建/改名/打开补翻时调。书封只读存好的
// englishName，不调本文件。
//
// 调用形态（探针 ~/workspace/batch27-work/tmp/glm_translate_probe.py
// 2026-11-22 实测：高等数学 → Advanced Mathematics 2.15 秒，
// 数据结构 → Data Structures 2.04 秒）：
//   POST https://open.bigmodel.cn/api/paas/v4/chat/completions
//   body {"model": "glm-4-flash", "messages": [{"role": "user",
//     "content": "Translate this Chinese university subject name to English. Reply with the English name only, no explanation: <中文名>"}],
//     "temperature": 0, "max_tokens": 30}
//   header Authorization: Bearer <key>
//   200 响应 choices[0].message.content 即英文名。
//
// 铁律（与 GlmOcrClient 同款）：
// - key 只从 [OcrKeyStore] 读，绝不写进代码、日志、错误信息、请求体以外
//   的任何地方；本文件无任何 print/debugPrint。
// - 任何失败（无 key、无网、超时、接口报错、响应异常）都返回 null，
//   不抛异常——调用方把 null 当“没翻出来”处理，不阻塞建学科。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ocr_key_store.dart';

/// 翻译 HTTP 往返（可注入的发包层，单测用假实现；与 GlmOcrClient 同款）。
class GlmTranslateHttpResponse {
  GlmTranslateHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// 发包函数签名：`sender(uri, headers, body)` 返回状态码 + 体。
typedef GlmTranslateRequestSender =
    Future<GlmTranslateHttpResponse> Function(
      Uri uri,
      Map<String, String> headers,
      String body,
    );

/// GLM 学科名翻译客户端（chat completions，glm-4-flash）。
class GlmSubjectTranslator {
  GlmSubjectTranslator({
    OcrKeyStore? keyStore,
    GlmTranslateRequestSender? sender,
    this.connectTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 30),
  }) : _keyStore = keyStore ?? OcrKeyStore(),
       // _sender 是私有字段，初始化形参会改名，外部 `sender:` 传参点会断。
       // ignore: prefer_initializing_formals
       _sender = sender;

  /// 接口地址（BigModel chat completions，勿改成 layout_parsing）。
  static final Uri endpoint = Uri.parse(
    'https://open.bigmodel.cn/api/paas/v4/chat/completions',
  );

  static const String model = 'glm-4-flash';

  /// 连接超时（短文本调用，10 秒足够）。
  final Duration connectTimeout;

  /// 单次请求超时（实测 1–2 秒；30 秒是上限兜底）。
  final Duration requestTimeout;

  final OcrKeyStore _keyStore;

  /// 注入的发包层（单测用假实现）；null 时走 [_defaultSender]。
  final GlmTranslateRequestSender? _sender;

  /// 翻译中文学科名；任何失败都返回 null（不抛异常）。
  Future<String?> translate(String chineseName) async {
    try {
      final name = chineseName.trim();
      if (name.isEmpty) return null;
      final apiKey = await _keyStore.getApiKey();
      if (apiKey == null || apiKey.isEmpty) return null;
      final body = jsonEncode({
        'model': model,
        'messages': [
          {
            'role': 'user',
            'content':
                'Translate this Chinese university subject name to English. '
                'Reply with the English name only, no explanation: $name',
          },
        ],
        'temperature': 0,
        'max_tokens': 30,
      });
      final GlmTranslateHttpResponse response;
      try {
        response = await (_sender ?? _defaultSender)(
          endpoint,
          {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body,
        ).timeout(requestTimeout);
      } on TimeoutException {
        return null;
      } on SocketException {
        return null;
      } on HttpException {
        return null;
      }
      if (response.statusCode != 200) return null;
      return _clean(_extractContent(response.body));
    } catch (_) {
      // 读 key、发包、解析任一步抛异常都当没翻出来（不阻塞建学科）。
      return null;
    }
  }

  /// 从 chat completions 响应里取 choices[0].message.content；取不到返回 null。
  static String? _extractContent(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return null;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final first = choices.first;
      if (first is! Map<String, Object?>) return null;
      final message = first['message'];
      if (message is! Map<String, Object?>) return null;
      final content = message['content'];
      if (content is! String) return null;
      return content;
    } catch (_) {
      return null;
    }
  }

  /// 清洗翻译结果：只要第一行、去首尾空白与包着的引号；空串或仍含中文
  /// （没翻出来）返回 null。
  static String? _clean(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    final nl = text.indexOf('\n');
    if (nl >= 0) text = text.substring(0, nl).trim();
    text = text
        .replaceAll(RegExp(r'''^["'“‘]+|["'”’]+$'''), '')
        .trim();
    if (text.isEmpty) return null;
    // 还含中文就说明没翻出来。
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) return null;
    return text;
  }

  /// 默认发包层：dart:io HttpClient（无第三方 http 依赖；与
  /// GlmOcrClient._defaultSender 同款超时强关）。
  Future<GlmTranslateHttpResponse> _defaultSender(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = connectTimeout;
    try {
      return await _sendWithClient(
        client,
        uri,
        headers,
        body,
      ).timeout(requestTimeout, onTimeout: () {
        client.close(force: true);
        throw TimeoutException('翻译请求超时', requestTimeout);
      });
    } finally {
      client.close();
    }
  }

  /// 用给定 client 发一次请求并读完响应体（超时强关由外层控；
  /// 本函数不自己包 timeout）。
  static Future<GlmTranslateHttpResponse> _sendWithClient(
    HttpClient client,
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    final request = await client.postUrl(uri);
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.add(utf8.encode(body));
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    return GlmTranslateHttpResponse(
      statusCode: response.statusCode,
      body: responseBody,
    );
  }
}
