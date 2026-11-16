// ARCH-PLAN-B 第 2 阶段：持久化恢复日志（restore journal）模块。
//
// 依据：docs/ui-replication/ARCH-PLAN-B-DRIFT-DRAFT.md v9 §四
// “文件系统与数据库协同操作协议”第 5 条“持久化恢复日志”全文
// （B-NEW-07 / B-NEW-09 / B-NEW-11 / B-NEW-14 / B-NEW-16 / B-NEW-17）。
//
// 要点：
// - 日志文件是数据目录下的独立文件 `restore-journal.json`（不放在数据库内），
//   至少记录恢复任务 ID、原正式文件目录的备份位置（rollback 目录）、
//   staging 目录位置、数据库原始快照位置、当前切换阶段、恢复最终状态。
// - 五步原子更新：① 写同目录临时日志 → ② 读回校验 → ③ fsync 临时文件
//   → ④ 同一文件系统内的原子替换 → ⑤ fsync 父目录。直接覆盖写正式日志禁止。
// - 五阶段状态机：PREPARING → SNAPSHOT_READY → FILES_SWITCHING →
//   DATABASE_RESTORING → COMMITTED。门禁：只有确认原始数据库快照完整、
//   可恢复，且日志已按原子更新规则写入并校验通过之后，才允许修改正式文件目录。
// - 校验和算法：SHA-256（package:crypto），对除 checksum 外全部字段按固定键序
//   （formatVersion / taskId / rollbackDir / stagingDir / snapshotPath /
//   stage / status）组成的规范 JSON 的 UTF-8 字节求摘要，十六进制小写。
//   校验失败即视为损坏。
// - 故障保证范围（B-NEW-16）：只覆盖进程强制终止（kill、任务管理器结束进程、
//   系统注销等进程级中断），不承诺突然断电（断电、操作系统崩溃）后的完整回滚。
//   本模块所有“持久化”措辞均按此范围解释。
// - rollback 目录必须与正式目录位于同一文件系统（硬性要求，见
//   [_assertSameFilesystem] 的断言与注释；本模块不另写目录逻辑）。
//
// 本文件是纯 Dart，不 import flutter / riverpod（lib/data/ 白名单）。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'journal_ffi.dart';

/// 恢复日志文件名（数据目录下）。
const String restoreJournalFileName = 'restore-journal.json';

/// ReplaceFileW 的备份文件名：与正式日志同卷，固定不变。
const String restoreJournalBackupFileName = 'restore-journal.json.bak';

/// 临时日志文件名（与正式日志同目录、同文件系统）。
const String restoreJournalTmpFileName = 'restore-journal.json.tmp';

/// 当前日志格式版本。格式版本不匹配即视为损坏。
const int restoreJournalFormatVersion = 1;

/// 恢复日志损坏：JSON 解析失败、格式版本不匹配、必填字段缺失、校验和不符。
/// 调用方据此停在恢复检查阶段并明确提示用户、保留现场，不得静默继续、
/// 不得按损坏日志执行回滚。
class JournalCorruptException implements Exception {
  JournalCorruptException(this.message, {this.path});
  final String message;
  final String? path;
  @override
  String toString() =>
      'JournalCorruptException: $message${path == null ? '' : '（$path）'}';
}

/// 日志更新中止：原子替换失败且按磁盘实际状态分派后仍无法完成本次更新。
/// 此时原日志（正式路径或备份位置的）已保留或已恢复，调用方不得进入
/// 下一恢复阶段。
class JournalUpdateException implements Exception {
  JournalUpdateException(this.message, {this.lastErrorCode});
  final String message;

  /// 最后一次原子替换调用返回的错误码（0 表示调用自称成功但文件没动，
  /// 见 B-NEW-17 / Win11 实测；仅供排障参考，不用于推断文件位置）。
  final int? lastErrorCode;
  @override
  String toString() => 'JournalUpdateException: $message';
}

/// 恢复的五个阶段（B-NEW-11）。
enum RestoreStage {
  /// 准备阶段：尚未完成；不允许修改正式数据；原正式数据仍完整。
  /// 启动时发现此阶段的未完成日志，可清理未完成准备材料（staging 目录、
  /// 临时文件）或按规则继续准备，不得要求用尚不存在的快照回滚。
  preparing,

  /// 原始快照已确认完整、可恢复，日志已可靠持久化；尚未切换；
  /// 可以安全启动回滚流程。
  snapshotReady,

  /// 正式文件切换中；按 rollback 目录与 staging 目录的实际状态恢复原目录。
  filesSwitching,

  /// 数据库恢复中；按原始快照恢复数据库，同时恢复原目录。
  databaseRestoring,

  /// 恢复已完成；不再回滚，按规则清理残留快照与 rollback 材料。
  committed,
}

/// 恢复的最终状态。
enum RestoreStatus {
  /// 进行中（未完成）。
  inProgress,

  /// 已完成。
  completed,

  /// 已失败（整体视为未发生，原数据与原文件集已回滚回来）。
  failed,
}

/// 一条恢复日志。全部字段均为必填（空串即视为缺失，校验不通过）。
class RestoreJournal {
  RestoreJournal({
    this.formatVersion = restoreJournalFormatVersion,
    required this.taskId,
    required this.rollbackDir,
    required this.stagingDir,
    required this.snapshotPath,
    required this.stage,
    required this.status,
    String? checksum,
  }) : checksum =
           checksum ??
           _computeChecksum(
             formatVersion: formatVersion,
             taskId: taskId,
             rollbackDir: rollbackDir,
             stagingDir: stagingDir,
             snapshotPath: snapshotPath,
             stage: stage,
             status: status,
           );

  /// 从 JSON 读出并校验；任一校验不过即抛 [JournalCorruptException]。
  factory RestoreJournal.fromJson(Map<String, dynamic> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw JournalCorruptException('恢复日志缺少必填字段：$key');
      }
      return value;
    }

    final formatVersion = json['formatVersion'];
    if (formatVersion is! int) {
      throw JournalCorruptException('恢复日志缺少必填字段：formatVersion');
    }
    if (formatVersion != restoreJournalFormatVersion) {
      throw JournalCorruptException(
        '恢复日志格式版本不匹配：期望 $restoreJournalFormatVersion，实际 $formatVersion',
      );
    }
    RestoreStage parseStage(String value) {
      for (final stage in RestoreStage.values) {
        if (stage.name == value) return stage;
      }
      throw JournalCorruptException('恢复日志的 stage 非法：$value');
    }

    RestoreStatus parseStatus(String value) {
      for (final status in RestoreStatus.values) {
        if (status.name == value) return status;
      }
      throw JournalCorruptException('恢复日志的 status 非法：$value');
    }

    final journal = RestoreJournal(
      formatVersion: formatVersion,
      taskId: requiredString('taskId'),
      rollbackDir: requiredString('rollbackDir'),
      stagingDir: requiredString('stagingDir'),
      snapshotPath: requiredString('snapshotPath'),
      stage: json['stage'] is String
          ? parseStage(json['stage'] as String)
          : throw JournalCorruptException('恢复日志缺少必填字段：stage'),
      status: json['status'] is String
          ? parseStatus(json['status'] as String)
          : throw JournalCorruptException('恢复日志缺少必填字段：status'),
      checksum: json['checksum'] is String
          ? json['checksum'] as String
          : throw JournalCorruptException('恢复日志缺少必填字段：checksum'),
    );
    if (journal.checksum !=
        _computeChecksum(
          formatVersion: journal.formatVersion,
          taskId: journal.taskId,
          rollbackDir: journal.rollbackDir,
          stagingDir: journal.stagingDir,
          snapshotPath: journal.snapshotPath,
          stage: journal.stage,
          status: journal.status,
        )) {
      throw JournalCorruptException('恢复日志校验和不符，内容可能已损坏');
    }
    return journal;
  }

  static String _computeChecksum({
    required int formatVersion,
    required String taskId,
    required String rollbackDir,
    required String stagingDir,
    required String snapshotPath,
    required RestoreStage stage,
    required RestoreStatus status,
  }) {
    // 规范 JSON：键序固定，不含 checksum 本身。
    final canonical = jsonEncode({
      'formatVersion': formatVersion,
      'taskId': taskId,
      'rollbackDir': rollbackDir,
      'stagingDir': stagingDir,
      'snapshotPath': snapshotPath,
      'stage': stage.name,
      'status': status.name,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  final int formatVersion;
  final String taskId;

  /// 原正式文件目录的备份位置（rollback 目录，如 `imports-rollback/<id>/`）。
  final String rollbackDir;

  /// staging 目录位置（如 `restore-staging/<id>/`）。
  final String stagingDir;

  /// 数据库原始快照位置。
  final String snapshotPath;
  final RestoreStage stage;
  final RestoreStatus status;

  /// SHA-256 校验和（见文件头注释）。
  final String checksum;

  RestoreJournal copyWith({
    String? taskId,
    String? rollbackDir,
    String? stagingDir,
    String? snapshotPath,
    RestoreStage? stage,
    RestoreStatus? status,
  }) => RestoreJournal(
    formatVersion: formatVersion,
    taskId: taskId ?? this.taskId,
    rollbackDir: rollbackDir ?? this.rollbackDir,
    stagingDir: stagingDir ?? this.stagingDir,
    snapshotPath: snapshotPath ?? this.snapshotPath,
    stage: stage ?? this.stage,
    status: status ?? this.status,
  );

  Map<String, dynamic> toJson() => {
    'formatVersion': formatVersion,
    'taskId': taskId,
    'rollbackDir': rollbackDir,
    'stagingDir': stagingDir,
    'snapshotPath': snapshotPath,
    'stage': stage.name,
    'status': status.name,
    'checksum': checksum,
  };

  /// 规范 JSON 文本（写盘用；与 [toJson] 同内容，键序固定）。
  String toCanonicalJson() => jsonEncode(toJson());
}

/// 原子替换函数签名（与 [atomicReplaceFile] 同形）。
/// 返回 0 表示成功，否则为平台错误码（Windows 为 Win32 错误码，
/// Linux 为 errno）。注入用：测试以此模拟 ReplaceFileW 的
/// 1176 / 1177 / 1178 三种部分失败状态。
typedef AtomicReplaceFn = Future<int> Function({
  required String target,
  required String replacement,
  required String backup,
});

/// 父目录 fsync 函数签名（与 [fsyncParentDir] 同形）。
/// 返回 null 表示成功，否则为错误码。注入用：测试以此模拟 fsync 失败。
typedef FsyncParentFn = int? Function(Directory dir);

/// 恢复日志存储：原子更新 + 启动恢复定位。
///
/// 构造函数接受可注入的 [replaceFile]（默认用 [atomicReplaceFile] 的
/// 真实实现），这样测试才能模拟三种错误状态——测试时让注入的 fake
/// 返回对应错误码并预先摆好该状态对应的磁盘布局，验证代码按实际磁盘
/// 状态分派、而不是按错误码分派（B-NEW-17 的核心要求）。
class RestoreJournalStore {
  RestoreJournalStore({
    required this.dataDir,
    AtomicReplaceFn? replaceFile,
    FsyncParentFn? fsyncParent,
  }) : _replaceFile = replaceFile ?? _defaultReplace,
       _fsyncParent = fsyncParent ?? fsyncParentDir;

  static Future<int> _defaultReplace({
    required String target,
    required String replacement,
    required String backup,
  }) => atomicReplaceFile(
    target: target,
    replacement: replacement,
    backup: backup,
  );

  /// 数据目录：正式日志、备份、临时日志三者同处此目录（同文件系统）。
  final Directory dataDir;

  final AtomicReplaceFn _replaceFile;
  final FsyncParentFn _fsyncParent;

  File get formalFile => File(p.join(dataDir.path, restoreJournalFileName));
  File get backupFile =>
      File(p.join(dataDir.path, restoreJournalBackupFileName));
  File get tmpFile => File(p.join(dataDir.path, restoreJournalTmpFileName));

  /// 校验一段 JSON（格式版本 / 必填字段 / 校验和）；不过即抛
  /// [JournalCorruptException]。
  RestoreJournal validateJson(Map<String, dynamic> json) =>
      RestoreJournal.fromJson(json);

  /// 读一个日志文件并校验；文件缺失或任一校验不过即抛
  /// [JournalCorruptException]（不返回 null、不静默放过）。
  Future<RestoreJournal> validateFile(File file) async {
    String text;
    try {
      text = await file.readAsString();
    } catch (e) {
      throw JournalCorruptException('恢复日志读不出来：$e', path: file.path);
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw JournalCorruptException('恢复日志不是合法 JSON（内容可能写了一半）', path: file.path);
    }
    if (decoded is! Map<String, dynamic>) {
      throw JournalCorruptException('恢复日志格式不对：顶层不是对象', path: file.path);
    }
    try {
      return RestoreJournal.fromJson(decoded);
    } on JournalCorruptException catch (e) {
      throw JournalCorruptException(e.message, path: file.path);
    }
  }

  /// 首次创建：正式日志尚不存在时，临时日志写完校验通过后用同卷
  /// rename 安装为正式日志。不得用 ReplaceFileW（其替换目标必须是
  /// 已存在文件）。正式日志已存在时抛 [JournalUpdateException]
  /// （更新走 [updateStage]）。
  Future<RestoreJournal> writeInitial(RestoreJournal journal) async {
    _assertSameFilesystem(journal);
    if (formalFile.existsSync()) {
      throw JournalUpdateException('正式日志已存在，首次创建不适用，须改走 updateStage');
    }
    // 残留 tmp（上次首次创建中断）：直接丢弃后重写——首次创建无旧日志
    // 可保，且启动恢复（locateAndRecover）本应在启动时先处理过残留；
    // 这里不按残留 tmp 安装，避免把未知来源的日志当成本次任务的日志。
    if (tmpFile.existsSync()) {
      try {
        await tmpFile.delete();
      } catch (_) {}
    }
    await _writeTmp(journal);
    // 正式路径无旧文件，同卷 rename 即完成安装（Linux rename(2) /
    // Windows MoveFile 目标不存在时均可直接安装）。
    await tmpFile.rename(formalFile.path);
    _fsyncParentBestEffort();
    return validateFile(formalFile);
  }

  /// 五步原子更新：① 写 tmp → ② 读回校验 → ③ fsync tmp →
  /// ④ 原子替换 → ⑤ fsync 父目录（失败只记不阻断）。
  /// 成功后返回正式日志读回校验后的内容；替换失败时按磁盘实际状态
  /// 分派处理（见 [_handleReplaceFailure]），处理后仍无法完成则抛
  /// [JournalUpdateException]（原日志已保留），损坏则抛
  /// [JournalCorruptException]。
  Future<RestoreJournal> updateStage(RestoreJournal journal) async {
    _assertSameFilesystem(journal);
    await _writeTmp(journal);
    final code = await _replaceFile(
      target: formalFile.path,
      replacement: tmpFile.path,
      backup: backupFile.path,
    );
    if (code != 0) {
      await _handleReplaceFailure(code, journal);
    }
    _fsyncParentBestEffort();
    final installed = await validateFile(formalFile);
    // 关键防线（Win11 实测：错误码读到 0 但文件根本没动）：只校验
    // “正式日志完整”不够，必须确认正式日志就是本次要写入的那一份，
    // 否则一次自称成功的替换可能悄悄什么都没换。
    if (installed.checksum != journal.checksum) {
      throw JournalUpdateException(
        '原子替换返回成功，但正式日志内容与本次写入不一致（仍是旧版本），'
        '本次更新中止，原日志保留',
        lastErrorCode: code,
      );
    }
    return installed;
  }

  /// 只写临时日志并完成“写 → 读回校验 → fsync tmp”三步，不替换正式日志。
  /// 供崩溃模拟测试使用（“临时已写、替换尚未完成时杀掉”的中断场景）。
  Future<void> writeTemp(RestoreJournal journal) async {
    await _writeTmp(journal);
  }

  /// 启动恢复：按“正式 → 备份 → 临时”顺序定位并恢复有效日志。
  ///
  /// - 正式日志存在且完整有效：返回它；残留 tmp 直接丢弃——本次更新
  ///   未完成替换（正式仍是上次已提交的阶段），安装 tmp 会谎称下一
  ///   阶段已完成（该阶段的操作尚未执行）。
  /// - 正式日志存在但损坏：抛 [JournalCorruptException]，停下并保留
  ///   现场，不 fallback 到备份（损坏原因须人工核对，静默用备份会
  ///   掩盖“正式日志为何损坏”）。
  /// - 正式日志缺失：按 1178 语义按磁盘实际状态分派——临时新日志有效
  ///   则安装为正式日志（完成被中断的替换，备份位置的原日志保留）；
  ///   临时损坏则丢弃临时、从备份恢复原日志；两者皆无则从备份恢复；
  ///   三处均无有效日志时返回 null（无进行中的恢复，正常启动）；
  ///   临时损坏且无备份可恢复时抛 [JournalCorruptException]。
  /// 返回 null 表示三处均无日志文件；返回的日志一定是校验通过的有效日志。
  Future<RestoreJournal?> locateAndRecover() async {
    if (formalFile.existsSync()) {
      final journal = await validateFile(formalFile);
      if (tmpFile.existsSync()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      return journal;
    }
    final backupExists = backupFile.existsSync();
    final tmpExists = tmpFile.existsSync();
    if (!backupExists && !tmpExists) return null;
    if (tmpExists) {
      try {
        await validateFile(tmpFile);
        // 临时新日志有效：正式路径无旧文件，同卷 rename 即完成安装。
        await tmpFile.rename(formalFile.path);
        return await validateFile(formalFile);
      } on JournalCorruptException {
        // 临时损坏：丢弃；有备份则继续从备份恢复，无备份则无有效日志。
        try {
          await tmpFile.delete();
        } catch (_) {}
        if (!backupExists) {
          throw JournalCorruptException(
            '正式日志缺失，临时日志损坏且无备份可恢复，'
            '不得按猜测状态继续启动恢复',
          );
        }
      }
    }
    if (backupExists) {
      await _restoreBackupToFormal();
      return validateFile(formalFile);
    }
    throw JournalCorruptException('正式日志、备份、临时日志均无有效日志');
  }

  // -- 内部步骤 --

  /// 写 tmp → 读回校验 → fsync tmp 文件。
  Future<void> _writeTmp(RestoreJournal journal) async {
    await tmpFile.writeAsString(journal.toCanonicalJson(), flush: true);
    await validateFile(tmpFile);
    final raf = await tmpFile.open(mode: FileMode.append);
    try {
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  /// 父目录 fsync：失败只记不阻断（B-NEW-16：只保证进程终止，不承诺断电）。
  void _fsyncParentBestEffort() {
    try {
      _fsyncParent(dataDir);
    } catch (_) {
      // 仅记录、不阻断：fsync 的返回值本身已被调用方忽略，
      // 这里只兜住 FFI 层抛出的异常。
    }
  }

  /// 从备份位置把原日志恢复到正式路径并校验。
  /// 备份损坏时抛 [JournalCorruptException]（不猜测、不继续）。
  Future<void> _restoreBackupToFormal() async {
    await validateFile(backupFile);
    await backupFile.rename(formalFile.path);
    await validateFile(formalFile);
  }

  /// 替换失败后的分派处理（B-NEW-17）。
  ///
  /// 只按磁盘实际状态分派，不按错误码分派：实测错误码可能为 0 但文件
  /// 根本没动，1177 也须先核查位置再决定按 1176 还是 1178 处理。
  /// 正常返回表示本次更新已完成（正式日志就是要写入的那一份）；
  /// 抛 [JournalUpdateException] 表示本次更新中止（原日志已保留或
  /// 已从备份恢复，调用方不得进入下一恢复阶段）。
  Future<void> _handleReplaceFailure(int code, RestoreJournal journal) async {
    final formalExists = formalFile.existsSync();
    final backupExists = backupFile.existsSync();
    final tmpExists = tmpFile.existsSync();

    if (formalExists) {
      // 1176 语义：原日志仍在正式路径、临时新日志仍在临时位置。
      if (!tmpExists) {
        throw JournalUpdateException(
          '原子替换失败（错误码 $code），正式日志仍在且完整，'
          '临时日志已不在，本次更新中止，原日志保留',
          lastErrorCode: code,
        );
      }
      try {
        await validateFile(tmpFile);
      } on JournalCorruptException {
        // 临时校验不通过：丢弃临时、保留原日志。
        try {
          await tmpFile.delete();
        } catch (_) {}
        throw JournalUpdateException(
          '原子替换失败（错误码 $code），临时新日志校验不通过，'
          '已丢弃临时日志，原日志保留，本次更新中止',
          lastErrorCode: code,
        );
      }
      // 临时完整：重试一次 ReplaceFileW（仍带备份路径）。
      final retryCode = await _replaceFile(
        target: formalFile.path,
        replacement: tmpFile.path,
        backup: backupFile.path,
      );
      if (retryCode == 0) return;
      throw JournalUpdateException(
        '原子替换失败（错误码 $code），重试一次仍失败'
        '（错误码 $retryCode），本次更新中止，原日志保留',
        lastErrorCode: retryCode,
      );
    }

    // 正式路径暂时不存在。
    if (!backupExists && !tmpExists) {
      throw JournalCorruptException(
        '原子替换失败（错误码 $code）后正式日志、备份、临时日志均缺失，'
        '无法确认日志位置，不得继续',
      );
    }
    if (tmpExists) {
      // 1178 语义：原日志在备份、替换文件在临时、正式路径暂时不存在。
      try {
        await validateFile(tmpFile);
      } on JournalCorruptException {
        // 临时校验不通过：丢弃临时，从备份恢复原日志并校验。
        try {
          await tmpFile.delete();
        } catch (_) {}
        if (!backupExists) {
          throw JournalCorruptException(
            '原子替换失败（错误码 $code）后临时日志损坏且无备份可恢复，'
            '不得继续',
          );
        }
        await _restoreBackupToFormal();
        throw JournalUpdateException(
          '原子替换失败（错误码 $code），临时新日志校验不通过，'
          '已丢弃临时日志并从备份恢复原日志，本次更新中止',
          lastErrorCode: code,
        );
      }
      // 临时完整：正式路径无旧文件，同卷 rename 即完成安装。
      await tmpFile.rename(formalFile.path);
      await validateFile(formalFile);
      return;
    }
    // 正式缺失、临时也不在、备份在：从备份恢复原日志，本次更新中止。
    await _restoreBackupToFormal();
    throw JournalUpdateException(
      '原子替换失败（错误码 $code）后正式日志缺失、临时日志也不在，'
      '已从备份恢复原日志，本次更新中止',
      lastErrorCode: code,
    );
  }

  /// 同一文件系统约束（B-NEW-07 / v7 修订，硬性要求）：
  /// rollback 目录必须位于正式目录所在的同一文件系统，否则目录重命名
  /// 会退化为复制 + 删除，无法保证原子性。本模块不另写目录逻辑，
  /// 只在断言里体现——调用方须把 rollback 目录建在数据目录内
  /// （同盘同文件系统）；相对路径视为数据目录内的相对位置，不另校验。
  void _assertSameFilesystem(RestoreJournal journal) {
    assert(
      !p.isAbsolute(journal.rollbackDir) ||
          p.isWithin(dataDir.path, journal.rollbackDir),
      'rollbackDir 必须与正式日志目录位于同一文件系统（数据目录内）：'
      '${journal.rollbackDir}',
    );
  }
}
