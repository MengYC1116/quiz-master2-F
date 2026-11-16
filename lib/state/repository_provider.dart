// ARCH-PLAN-A 第 1 阶段：数据层入口的 Provider。
//
// 唯一作用是把 [QuestionRepository] 交给 Riverpod 的依赖图，
// 让 Notifier 经 `ref.read(repositoryProvider)` 拿库，
// 而不是自己 new 一个——测试用
// `ProviderScope(overrides: [repositoryProvider.overrideWithValue(fake)])`
// 或 `ProviderContainer.test(overrides: [...])` 注入 FakeRepo / 内存库，
// 不碰真实数据库。
//
// 默认值与 `lib/app.dart` 的根组件一致：
// `QuestionRepository(AppDatabase.instance)`（单例库，同一份数据）。
// 注意：[repositoryProvider] 只提供 Repository，不直接提供
// [AppDatabase]；数据层本身不 import flutter_riverpod（见方案 §六-7
// 白名单：riverpod import 只出现在 lib/state/、lib/modules/、
// lib/app.dart 与 lib/main.dart）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';

/// 数据层入口：默认接单例库；测试用 override 替换。
final repositoryProvider = Provider<QuestionRepository>(
  (ref) => QuestionRepository(AppDatabase.instance),
);
