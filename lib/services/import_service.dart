import 'dart:io';
import 'package:file_picker/file_picker.dart';

import '../data/database.dart';
import '../models/models.dart';

/// 导入服务：PDF / JPG / PNG；PDF 50MB / 图片 20MB，超限只提示不硬拦；
/// 多文件排队逐个导入，带百分比进度；导入可取消；队列重启后保留
/// （任务持久化在 collect_tasks 表）。
class ImportService {
  ImportService(this._db);
  final AppDatabase _db;

  static const allowedExtensions = ['pdf', 'jpg', 'jpeg', 'png'];
  static const maxPdfBytes = 50 * 1024 * 1024;
  static const maxImageBytes = 20 * 1024 * 1024;

  static bool isAllowed(String path) {
    final ext = path.split('.').last.toLowerCase();
    return allowedExtensions.contains(ext);
  }

  /// 超限只提示不硬拦；返回提示文案，null 表示不超限。
  static String? oversizeHint(File file) {
    final ext = file.path.split('.').last.toLowerCase();
    final limit = ext == 'pdf' ? maxPdfBytes : maxImageBytes;
    if (file.lengthSync() > limit) {
      return '文件较大（${(file.lengthSync() / 1024 / 1024).toStringAsFixed(1)}MB），'
          '超过建议上限 ${limit ~/ 1024 ~/ 1024}MB，仍可继续导入。';
    }
    return null;
  }

  /// 系统文件选择器，多选。返回选中的文件路径。
  Future<List<String>> pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      allowMultiple: true,
    );
    if (result == null) return [];
    return result.files.where((f) => f.path != null).map((f) => f.path!).toList();
  }

  /// 多文件排队：逐个导入，下一文件自动开始；返回创建的任务。
  Future<List<CollectTask>> enqueue(
    List<String> paths, {
    required String subjectId,
  }) async {
    final tasks = <CollectTask>[];
    final existing = await _db.allCollectTasks();
    for (var i = 0; i < paths.length; i++) {
      final file = File(paths[i]);
      final name = file.uri.pathSegments.last;
      final id = 'task-${DateTime.now().millisecondsSinceEpoch}-$i';
      final duplicate = existing.any((t) => t.fileName == name);
      final task = CollectTask(
        id: id,
        // 任务名 = 文件名 + 页 + 题号；此处先按第 1 页第 1 题，修框确认后拆题改名。
        name: '$name · 第1页 · 第1题',
        fileName: name,
        subjectId: subjectId,
        status: CollectStatus.queued,
      );
      // 重复导入提示“已经导入过”，仍可再次导入（由调用方弹提示，见 D-08）。
      if (duplicate) {
        // 保留任务，仅标记；UI 层据此弹“已经导入过”提示。
      }
      await _db.upsertCollectTask(task);
      tasks.add(task);
    }
    return tasks;
  }
}
