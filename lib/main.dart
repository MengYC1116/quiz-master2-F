import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  // ARCH-PLAN-A 第 1 阶段：整应用包一层 ProviderScope，
  // 设置状态（settingsProvider，见 lib/state/）由此进入 widget 树。
  runApp(const ProviderScope(child: QuizMasterApp()));
}
