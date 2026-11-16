// B11-8：题目详情页导出图片（复制 / 保存 / 带答案分享卡片）。
//
// 三个动作共用同一份切片字节（question.slicePath 指向的 PNG 文件）：
// - 复制：super_clipboard 写 PNG（Flutter 自带 Clipboard 只支持文本）；
// - 保存：file_picker 另存为对话框（桌面端只返回路径，须自己写文件，
//   与设置页备份同款做法，见 settings_page.dart 的 B4.2 注释）；
// - 带答案版：详情页弹窗里预览 QuestionShareCard（见
//   widgets/question_share_card.dart），点保存时把 RepaintBoundary
//   转 PNG 再走同一套另存为。
//
// 可注入性：pickSavePath / writeClipboardImage 两个外部边界可注入，
// widget 测试用假实现（不弹系统对话框、不碰真实剪贴板）；默认实现
// 就是生产行为。captureBoundary 是纯 dart:ui 调用，测试里须包在
// tester.runAsync 里调（testWidgets 体内直接 toImage 会挂起）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../data/database.dart';
import '../models/models.dart';

/// 另存为对话框：返回用户选好的路径，取消返回 null。
typedef SaveFilePicker =
    Future<String?> Function({
      required String dialogTitle,
      required String fileName,
    });

/// 把 PNG 字节写进系统剪贴板（图片格式）。
typedef ClipboardImageWriter = Future<void> Function(Uint8List pngBytes);

class QuestionExportService {
  QuestionExportService({
    SaveFilePicker? pickSavePath,
    ClipboardImageWriter? writeClipboardImage,
  }) : _pickSavePath = pickSavePath ?? _defaultPickSavePath,
       _writeClipboardImage =
           writeClipboardImage ?? _defaultWriteClipboardImage;

  final SaveFilePicker _pickSavePath;
  final ClipboardImageWriter _writeClipboardImage;

  /// 读本题的切片 PNG 字节；无切片、路径解析失败、文件缺失或读盘
  /// 失败都返回 null（调用方给“这道题没有图片可导出”提示，不抛错）。
  /// v1 演示库的题没有 slicePath（只有 sliceText 占位），同样走 null。
  Future<Uint8List?> sliceBytes(Question q) async {
    if (q.slicePath == null) return null;
    final abs = AppDatabase.resolveDataPath(q.slicePath!);
    if (abs == null) return null;
    final file = File(abs);
    if (!file.existsSync()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 复制 PNG 到剪贴板；成功 true，失败 false（剪贴板不可用、写失败
  /// 都不抛到界面）。Windows 上 super_clipboard 会把 PNG 按需转成
  /// DIB/DIBv5，原生应用可直接粘贴（见 super_clipboard README）。
  Future<bool> copyImageToClipboard(Uint8List pngBytes) async {
    try {
      await _writeClipboardImage(pngBytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _defaultWriteClipboardImage(
    Uint8List pngBytes,
  ) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      throw StateError('clipboard unavailable on this platform');
    }
    final item = DataWriterItem();
    item.add(Formats.png(pngBytes));
    await clipboard.write([item]);
  }

  /// 另存为对话框（file_picker）；取消返回 null。
  Future<String?> pickSavePath({
    required String dialogTitle,
    required String fileName,
  }) => _pickSavePath(dialogTitle: dialogTitle, fileName: fileName);

  static Future<String?> _defaultPickSavePath({
    required String dialogTitle,
    required String fileName,
  }) => FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
  );

  /// 把 PNG 字节写到 [path]；成功 true，写失败 false。
  Future<bool> saveBytesTo(String path, Uint8List bytes) async {
    try {
      await File(path).writeAsBytes(bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 把 [key] 对应的 RepaintBoundary 按 [pixelRatio] 转 PNG 字节。
  /// boundary 不在树上、或编码失败时抛 StateError（调用方给提示）。
  Future<Uint8List> captureBoundary(
    GlobalKey key, {
    double pixelRatio = 2.0,
  }) async {
    final boundary =
        key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      throw StateError('share card boundary not found');
    }
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('share card encode failed');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// 题名做文件名：Windows 文件名禁用的字符换成下划线，空题名回退
  /// 'question'；调用方再拼扩展名/后缀。
  static String safeFileName(String title) {
    final cleaned = title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    return cleaned.isEmpty ? 'question' : cleaned;
  }
}
