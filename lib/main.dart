import 'package:flutter/material.dart';

import 'app.dart';
import 'data/database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 首次运行建库并写入演示数据（数学 / 英语 / 政治各 3 道，共 9 道）。
  await AppDatabase.instance.db;
  runApp(const QuizMasterApp());
}
