// FR-45：测试兜底防护——全量测试期间演示库 md5 曾变化（W7，94,208 →
// 126,976 字节），二分 88 个测试文件未能复现（见
// ~/workspace/final-review/fix-batch2-log.md 与 FIX-BATCH-2.md）。
// 最可能的肇事是 W7 窗口内并行工作员的 GUI/应用真机运行（应用 _openDb
// 删 v1 演示库重建 v2 的行为与字节变化一致），而非某个测试。
// 无论肇事是谁，加一道防线：每个测试文件跑在独立 isolate，
// testExecutable 在文件 main() 之前把 AppDatabase.testDataDirectory
// 指到全新临时目录——此后任何忘了重定向的测试都只会动临时目录，
// 不再可能碰到真实演示库。加之前已逐项核对：
// - 两处 setCustomDataDirectory 测试（b2_leftover_data_test、
//   b5_p2_data_test）都先设 testMarkerDirectory，不受影响；
// - 无测试断言 testDataDirectory 为 null 或 dataDirectoryPath()
//   等于真实路径；
// - 各文件 setUp 里自己设 testDataDirectory 的仍以文件内设置为准
//   （后设覆盖先设）；tearDownAll 里恢复 null 的是套件收尾，不影响
//   本文件内的测试。
// 注意：这道防线只拦测试进程，拦不住 GUI/应用真机运行——跑应用验证
// 仍须用隔离数据目录（见批一/批二验收流程）。
import 'dart:async';
import 'dart:io';

import 'package:quiz_master2/data/database.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final tmp = await Directory.systemTemp.createTemp('qm2-test-data-dir-');
  AppDatabase.testDataDirectory = tmp.path;
  await testMain();
}
