import 'package:flutter/foundation.dart';

/// 跨模块共享状态：数据写操作后通知外壳重查左导航角标（D-04 已确认：
/// 角标实时刷新）。各数据写入口在写完后调用 [bump]；外壳监听它。
final ValueNotifier<int> badgeVersion = ValueNotifier<int>(0);

void bumpBadgeVersion() => badgeVersion.value++;
