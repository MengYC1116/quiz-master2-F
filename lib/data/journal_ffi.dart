// ARCH-PLAN-B 第 2 阶段：恢复日志的平台原子替换 + 父目录 fsync（FFI 封装）。
//
// 背景（B-NEW-14 / B-NEW-17，见 docs/ui-replication/ARCH-PLAN-B-DRIFT-DRAFT.md
// §四“文件系统与数据库协同操作协议”第 5 条，以及 B-SPIKE-REPORT.md 第 6 条）：
// - Dart 的 File.rename 在 Win11 上替换已存在目标会抛错（errno 5 拒绝访问），
//   绝对不能当原子替换用；Linux 上经尖峰验证（200 次往返）是原子的（rename(2)）。
// - Windows 走 kernel32 的 ReplaceFileW，每次调用必须传备份文件路径
//   （固定为与正式日志同卷的 restore-journal.json.bak，不得传空）。
// - “先删旧日志、再普通重命名新日志”的两步方式禁止。
// - 父目录 fsync：纯 Dart 打不开目录（errno 21）；Windows 上用
//   GENERIC_READ|GENERIC_WRITE 打开目录句柄（FILE_FLAG_BACKUP_SEMANTICS）
//   再调 FlushFileBuffers（实测只用 GENERIC_READ 会报错误 5）；Linux 上
//   用 FFI 调 libc 的 open(O_RDONLY|O_DIRECTORY) + fsync。
// - 故障保证范围（B-NEW-16）：只覆盖进程强制终止，不承诺断电恢复；
//   fsync 失败只记录、不阻断本次日志更新。
//
// 本文件是纯 Dart（dart:ffi + package:ffi），不 import flutter / riverpod。

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Windows：kernel32 绑定
// ---------------------------------------------------------------------------

const int _genericRead = 0x80000000;
const int _genericWrite = 0x40000000;
const int _fileShareRead = 0x00000001;
const int _fileShareWrite = 0x00000002;
const int _fileShareDelete = 0x00000004;
const int _openExisting = 3;
const int _fileFlagBackupSemantics = 0x02000000;

// HANDLE 无效值（(HANDLE)-1）。
const int _invalidHandleValue = -1;

typedef _ReplaceFileWNative = ffi.Int32 Function(
  ffi.Pointer<Utf16> lpReplacedFileName,
  ffi.Pointer<Utf16> lpReplacementFileName,
  ffi.Pointer<Utf16> lpBackupFileName,
  ffi.Uint32 dwReplaceFlags,
  ffi.Pointer<ffi.Void> lpExclude,
  ffi.Pointer<ffi.Void> lpReserved,
);
typedef _ReplaceFileWDart = int Function(
  ffi.Pointer<Utf16> lpReplacedFileName,
  ffi.Pointer<Utf16> lpReplacementFileName,
  ffi.Pointer<Utf16> lpBackupFileName,
  int dwReplaceFlags,
  ffi.Pointer<ffi.Void> lpExclude,
  ffi.Pointer<ffi.Void> lpReserved,
);

typedef _CreateFileWNative = ffi.IntPtr Function(
  ffi.Pointer<Utf16> lpFileName,
  ffi.Uint32 dwDesiredAccess,
  ffi.Uint32 dwShareMode,
  ffi.Pointer<ffi.Void> lpSecurityAttributes,
  ffi.Uint32 dwCreationDisposition,
  ffi.Uint32 dwFlagsAndAttributes,
  ffi.Pointer<ffi.Void> hTemplateFile,
);
typedef _CreateFileWDart = int Function(
  ffi.Pointer<Utf16> lpFileName,
  int dwDesiredAccess,
  int dwShareMode,
  ffi.Pointer<ffi.Void> lpSecurityAttributes,
  int dwCreationDisposition,
  int dwFlagsAndAttributes,
  ffi.Pointer<ffi.Void> hTemplateFile,
);

typedef _FlushFileBuffersNative = ffi.Int32 Function(ffi.IntPtr hFile);
typedef _FlushFileBuffersDart = int Function(int hFile);

typedef _CloseHandleNative = ffi.Int32 Function(ffi.IntPtr hObject);
typedef _CloseHandleDart = int Function(int hObject);

typedef _GetLastErrorNative = ffi.Uint32 Function();
typedef _GetLastErrorDart = int Function();

class _Kernel32 {
  _Kernel32._(
    this.replaceFile,
    this.createFile,
    this.flushFileBuffers,
    this.closeHandle,
    this.getLastError,
  );

  factory _Kernel32.load() {
    final lib = ffi.DynamicLibrary.open('kernel32.dll');
    return _Kernel32._(
      lib.lookupFunction<_ReplaceFileWNative, _ReplaceFileWDart>(
        'ReplaceFileW',
      ),
      lib.lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW'),
      lib.lookupFunction<_FlushFileBuffersNative, _FlushFileBuffersDart>(
        'FlushFileBuffers',
      ),
      lib.lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle'),
      lib.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
        'GetLastError',
      ),
    );
  }

  final _ReplaceFileWDart replaceFile;
  final _CreateFileWDart createFile;
  final _FlushFileBuffersDart flushFileBuffers;
  final _CloseHandleDart closeHandle;
  final _GetLastErrorDart getLastError;
}

_Kernel32? _kernel32;

/// Windows 上 ReplaceFileW 的部分失败状态（B-NEW-17）：
/// 1175 ERROR_UNABLE_TO_REMOVE_REPLACED、
/// 1176 ERROR_UNABLE_TO_MOVE_REPLACEMENT、
/// 1177 ERROR_UNABLE_TO_MOVE_REPLACEMENT_2。
/// 调用方（restore_journal.dart）不得只凭错误码推断文件位置，
/// 必须先实地核查正式日志、备份、临时三处文件的实际状态再分派。
const int errorUnableToRemoveReplaced = 1175;
const int errorUnableToMoveReplacement = 1176;
const int errorUnableToMoveReplacement2 = 1177;

// ---------------------------------------------------------------------------
// Linux：libc 绑定（只用于父目录 fsync；原子替换走 Dart File.rename）
// ---------------------------------------------------------------------------

// Linux x86_64 / aarch64：O_DIRECTORY = 00200000（八进制）= 0x10000。
const int _oDirectory = 0x10000;

typedef _OpenNative = ffi.Int32 Function(
  ffi.Pointer<Utf8> pathname,
  ffi.Int32 flags,
);
typedef _OpenDart = int Function(ffi.Pointer<Utf8> pathname, int flags);

typedef _FsyncNative = ffi.Int32 Function(ffi.Int32 fd);
typedef _FsyncDart = int Function(int fd);

typedef _CloseNative = ffi.Int32 Function(ffi.Int32 fd);
typedef _CloseDart = int Function(int fd);

typedef _ErrnoLocationNative = ffi.Pointer<ffi.Int32> Function();
typedef _ErrnoLocationDart = ffi.Pointer<ffi.Int32> Function();

class _Libc {
  _Libc._(this.open, this.fsync, this.close, this.errnoLocation);

  factory _Libc.load() {
    ffi.DynamicLibrary lib;
    try {
      lib = ffi.DynamicLibrary.open('libc.so.6');
    } on ArgumentError {
      // 回退：进程已加载的符号（Dart VM 进程内一般可解析 open/fsync）。
      lib = ffi.DynamicLibrary.process();
    }
    _ErrnoLocationDart? errnoLocation;
    try {
      errnoLocation = lib
          .lookupFunction<_ErrnoLocationNative, _ErrnoLocationDart>(
            '__errno_location',
          );
    } catch (_) {
      errnoLocation = null;
    }
    return _Libc._(
      lib.lookupFunction<_OpenNative, _OpenDart>('open'),
      lib.lookupFunction<_FsyncNative, _FsyncDart>('fsync'),
      lib.lookupFunction<_CloseNative, _CloseDart>('close'),
      errnoLocation,
    );
  }

  final _OpenDart open;
  final _FsyncDart fsync;
  final _CloseDart close;
  final _ErrnoLocationDart? errnoLocation;

  int get errno => errnoLocation?.call().value ?? 1;
}

_Libc? _libc;

// ---------------------------------------------------------------------------
// 对外接口
// ---------------------------------------------------------------------------

/// 原子替换 [target] 为 [replacement] 的内容。
///
/// - Windows：调 ReplaceFileW（[backup] 必须是非空的同卷备份路径，
///   固定为与正式日志同卷的 `restore-journal.json.bak`）；返回 0 表示
///   成功，否则返回 Win32 错误码。注意：错误码只能说明“调用失败”，
///   不能说明文件实际在哪——实测出现过错误码为 0 但文件根本没动，
///   调用方必须先实地核查三处文件状态再按 B-NEW-17 分派。
/// - Linux / 其他：同文件系统 `rename(2)`（Dart File.rename，尖峰
///   200 次往返验证为原子替换）；成功返回 0，失败返回 errno（取不到
///   则返回 1）。[backup] 在此路径下不使用（rename 不需要备份文件），
///   但为与 Windows 保持同一签名仍要求传入。
/// - “先删旧日志、再普通重命名新日志”的两步方式禁止，本函数不提供。
Future<int> atomicReplaceFile({
  required String target,
  required String replacement,
  required String backup,
}) async {
  if (Platform.isWindows) {
    final kernel32 = _kernel32 ??= _Kernel32.load();
    final replacedPtr = target.toNativeUtf16();
    final replacementPtr = replacement.toNativeUtf16();
    final backupPtr = backup.toNativeUtf16();
    try {
      final ok = kernel32.replaceFile(
        replacedPtr,
        replacementPtr,
        backupPtr,
        0,
        ffi.nullptr,
        ffi.nullptr,
      );
      if (ok != 0) return 0;
      // 失败后立即取错误码（其间不调任何其他 Win32 API）。
      return kernel32.getLastError();
    } finally {
      malloc.free(replacedPtr);
      malloc.free(replacementPtr);
      malloc.free(backupPtr);
    }
  }
  try {
    await File(replacement).rename(target);
    return 0;
  } on FileSystemException catch (e) {
    return e.osError?.errorCode ?? 1;
  }
}

/// 对 [dir] 所在的目录做 fsync（持久化目录项变更）。
///
/// 返回 null 表示成功；否则返回错误码（Windows 为 Win32 错误码，
/// Linux 为 errno）。调用方只记录、不阻断本次日志更新（B-NEW-16：
/// 故障保证只覆盖进程强制终止，不承诺断电恢复）。
///
/// - Windows：用 GENERIC_READ|GENERIC_WRITE + FILE_FLAG_BACKUP_SEMANTICS
///   打开目录句柄再调 FlushFileBuffers（实测只用 GENERIC_READ 打开会
///   报错误 5；见 win11-verify-result.txt 第 5 项）。
/// - Linux：FFI 调 libc 的 open(O_RDONLY|O_DIRECTORY) + fsync。
/// - 其他平台：返回 null（尽力而为，无原生接口时不阻断）。
int? fsyncParentDir(Directory dir) {
  if (Platform.isWindows) {
    final kernel32 = _kernel32 ??= _Kernel32.load();
    final pathPtr = dir.path.toNativeUtf16();
    try {
      final handle = kernel32.createFile(
        pathPtr,
        _genericRead | _genericWrite,
        _fileShareRead | _fileShareWrite | _fileShareDelete,
        ffi.nullptr,
        _openExisting,
        _fileFlagBackupSemantics,
        ffi.nullptr,
      );
      if (handle == _invalidHandleValue) {
        return kernel32.getLastError();
      }
      try {
        final ok = kernel32.flushFileBuffers(handle);
        if (ok == 0) return kernel32.getLastError();
        return null;
      } finally {
        kernel32.closeHandle(handle);
      }
    } finally {
      malloc.free(pathPtr);
    }
  }
  if (Platform.isLinux) {
    final libc = _libc ??= _Libc.load();
    final pathPtr = dir.path.toNativeUtf8();
    try {
      final fd = libc.open(pathPtr, _oDirectory);
      if (fd < 0) return libc.errno;
      try {
        if (libc.fsync(fd) != 0) return libc.errno;
        return null;
      } finally {
        libc.close(fd);
      }
    } finally {
      malloc.free(pathPtr);
    }
  }
  return null;
}
