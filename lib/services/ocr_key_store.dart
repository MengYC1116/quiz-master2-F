// 十三批 M3：BigModel API Key 的安全存储。
//
// 只做一件事：把用户在设置页自填的 BigModel key 存进平台安全存储，
// 绝不进 SQLite、绝不进日志、绝不进备份。M6 的设置页用本文件读写 key。
//
// 平台后端（flutter_secure_storage 10.3.4，已核实 Windows 支持）：
// - Windows（flutter_secure_storage_windows 4.1.0）：值经 AES-GCM 加密后
//   存文件（应用支持目录，`key.secure`），加密密钥本身存在 Windows
//   凭据管理器（Credential Manager）里；向后兼容时也可直接读写凭据管理器。
// - Android：KeyStore；Linux：libsecret；均由插件按平台分发。
// - Windows 构建前置条件：Visual Studio Build Tools 须装 C++ ATL 库
//   （插件 README 要求；Meng 在 Win11 上构建时若缺 ATL 会编不过 Windows
//   端，与本文件逻辑无关，见 M3 报告）。
//
// 测试：生产默认走 [FlutterSecureStorageBackend]；单测传内存假后端
// （见 test/b13_ocr_client_test.dart 的 _MemoryKeyBackend），不碰
// 平台通道——`flutter test` 里没有平台实现，直接调插件会抛
// MissingPluginException。

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 安全存储后端的最小接口：只覆盖 OcrKeyStore 需要的四个操作。
/// 抽象出来只为可测——生产实现就是 flutter_secure_storage 的薄封装。
abstract class OcrKeyStorageBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<bool> containsKey(String key);
}

/// 生产后端：flutter_secure_storage 的薄封装（无任何额外逻辑）。
class FlutterSecureStorageBackend implements OcrKeyStorageBackend {
  FlutterSecureStorageBackend({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key: key);
}

/// BigModel API Key 的存储（M3 契约，M6 设置页按此接，类名/方法名/键名
/// 冻结——改其中任何一个都要同步改 M6 与本报告的契约节）。
///
/// - 存储键名固定为 [apiKeyStorageKey]（`'bigmodel_api_key'`）。
/// - key 只存一份；[setApiKey] 会去首尾空白，空串视为清除（不存空 key）。
/// - key 值永不打日志：本文件无任何 print/debugPrint，调用方同样不得
///   把返回值写进日志、错误信息或备份。
class OcrKeyStore {
  OcrKeyStore({OcrKeyStorageBackend? backend})
    : _backend = backend ?? FlutterSecureStorageBackend();

  /// 安全存储里的键名（冻结值，M6 按此读，勿改）。
  static const String apiKeyStorageKey = 'bigmodel_api_key';

  final OcrKeyStorageBackend _backend;

  /// 读 key：无 key 返回 null（不是空串）。调用方不得把返回值记日志。
  Future<String?> getApiKey() => _backend.read(apiKeyStorageKey);

  /// 写 key：去首尾空白；空白/空串时改为清除旧 key（不存空 key）。
  Future<void> setApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _backend.delete(apiKeyStorageKey);
      return;
    }
    await _backend.write(apiKeyStorageKey, trimmed);
  }

  /// 是否已存 key（不读出 key 本身，设置页显示“已设置/未设置”用它）。
  Future<bool> hasApiKey() => _backend.containsKey(apiKeyStorageKey);

  /// 清除 key（设置页“清除 key”与换 key 失败回退时用）。
  Future<void> clearApiKey() => _backend.delete(apiKeyStorageKey);
}
