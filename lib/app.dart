import 'package:flutter/material.dart';

import '../data/badge_notifier.dart';
import '../data/database.dart';
import '../data/repository.dart';
import '../theme/app_theme.dart';
import 'modules/collect/collect_page.dart';
import 'modules/home/home_page.dart';
import 'modules/organize/organize_page.dart';
import 'modules/wrongbook/wrongbook_page.dart';

/// 应用外壳：左导航 216px，可折叠为仅图标（D-24 已确认恢复折叠）；
/// 一页一模块，只靠 ID 跳转。
/// 路由：/home /collect /organize /wrongbook（其余 4 页未实现，见 decision-log）。
class QuizMasterApp extends StatefulWidget {
  const QuizMasterApp({super.key});

  @override
  State<QuizMasterApp> createState() => _QuizMasterAppState();
}

class _QuizMasterAppState extends State<QuizMasterApp> {
  bool _dark = false;
  bool _collapsed = false; // D-24：左导航可折叠为仅图标
  String _route = '/home';
  String? _subjectArg; // 带学科 ID 进错题本时直接打开对应那一本

  late final QuestionRepository repo =
      QuestionRepository(AppDatabase.instance);

  /// 左导航角标（D-04 已确认，实时刷新）：收集 = 待修框（待框选 + 修框中）
  /// 任务数 + 待整理题数（整理工作台未确认数，边界文档口径），
  /// 整理 = 待整理题数，错题本无角标。数据写操作通过 badgeVersion 通知，
  /// 路由切换时也重查一次。
  int _collectBadge = 0;
  int _organizeBadge = 0;

  @override
  void initState() {
    super.initState();
    badgeVersion.addListener(_refreshBadges);
    _refreshBadges();
  }

  @override
  void dispose() {
    badgeVersion.removeListener(_refreshBadges);
    super.dispose();
  }

  Future<void> _refreshBadges() async {
    final tasks = await AppDatabase.instance.allCollectTasks();
    final pendingOrganize = await repo.pendingOrganizeCount();
    if (!mounted) return;
    setState(() {
      // 收集 = 待修框任务数 + 待整理题数（D-25：待整理数来自整理工作台，
      // 不再数 pendingOrganize 任务——修框确认现在直接产出题目）；
      // 整理 = 待整理题数。
      _collectBadge = CollectPage.countPendingBox(tasks) + pendingOrganize;
      _organizeBadge = pendingOrganize;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'quiz-master2',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
      // Builder：外壳的 Theme.of(context) 必须在 MaterialApp 之下取，
      // 否则深色模式下导航会取到默认浅色主题（白底 + 浅色字，看不清）。
      home: Builder(
        builder: (context) => Scaffold(
          body: Stack(
            children: [
              // 纸纹微点铺在应用底色上（预览 body 背景）。
              const Positioned.fill(child: PaperDots()),
              Positioned.fill(
                child: Row(
                  children: [
                    _buildNav(context),
                    Expanded(child: _buildPage()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNav(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final navBackground =
        dark ? AppTheme.darkNavBackground : AppTheme.lightNavBackground;
    final selectedBackground =
        dark ? AppTheme.darkNavSelected : AppTheme.lightNavSelected;
    final items = [
      ('/home', '首页', Icons.home_outlined, 0),
      ('/collect', '收集中心', Icons.upload_file_outlined, _collectBadge),
      ('/organize', '整理工作台', Icons.edit_note_outlined, _organizeBadge),
      ('/wrongbook', '错题本', Icons.book_outlined, 0),
    ];
    return Container(
      width: _collapsed ? 64 : 216,
      decoration: BoxDecoration(
        color: navBackground,
        border: Border(
          right: BorderSide(
              color: dark
                  ? const Color(0xFF333B47)
                  : AppTheme.lightLine),
        ),
      ),
      child: Column(
        crossAxisAlignment:
            _collapsed ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          // 导航标题两行（预览 .brand）：quiz-master2 / 个人智能错题本。
          // D-24：顶部加折叠小箭头，点一下折叠为仅图标，再点展开。
          if (_collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 16, 0, 10),
              child: IconButton(
                tooltip: '展开导航',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _collapsed = false),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('quiz-master2',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w800)),
                        SizedBox(height: 2),
                        Text('个人智能错题本',
                            style: TextStyle(fontSize: 11.5)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '折叠导航',
                    icon: const Icon(Icons.chevron_left, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => setState(() => _collapsed = true),
                  ),
                ],
              ),
            ),
          // 当前页：实心蓝块 + 白字（预览口径）；未选中：深色字。
          // 折叠时只显示图标，角标以右上角小圆标叠在图标上。
          for (final (route, label, icon, badge) in items)
            _collapsed
                ? Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Tooltip(
                      message: label,
                      child: Material(
                        color: _route == route
                            ? selectedBackground
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _go(route),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Center(
                                  child: Icon(icon,
                                      color: _route == route
                                          ? Colors.white
                                          : Theme.of(context)
                                              .colorScheme
                                              .onSurface),
                                ),
                                if (badge > 0)
                                  Positioned(
                                    top: 6,
                                    right: 4,
                                    child: Container(
                                      constraints: const BoxConstraints(
                                          minWidth: 16, minHeight: 16),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4),
                                      decoration: BoxDecoration(
                                        color: _route == route
                                            ? Colors.white
                                            : _badgeBackground(route, dark),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        '$badge',
                                        style: TextStyle(
                                          color: _route == route
                                              ? selectedBackground
                                              : _badgeForeground(route, dark),
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Material(
                      color: _route == route
                          ? selectedBackground
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        leading: Icon(icon,
                            color: _route == route
                                ? Colors.white
                                : Theme.of(context).colorScheme.onSurface),
                        title: Text(label,
                            style: TextStyle(
                                fontSize: 14,
                                color: _route == route
                                    ? Colors.white
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurface,
                                fontWeight: _route == route
                                    ? FontWeight.w700
                                    : FontWeight.normal)),
                        trailing: (badge > 0)
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _route == route
                                      ? Colors.white
                                      : _badgeBackground(route, dark),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '$badge',
                                  style: TextStyle(
                                    color: _route == route
                                        ? selectedBackground
                                        : _badgeForeground(route, dark),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              )
                            : null,
                        onTap: () => _go(route),
                      ),
                    ),
                  ),
          const Spacer(),
          _collapsed
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Tooltip(
                    message: '深色模式',
                    child: IconButton(
                      icon: Icon(_dark ? Icons.light_mode : Icons.dark_mode),
                      onPressed: () => setState(() => _dark = !_dark),
                    ),
                  ),
                )
              : ListTile(
                  leading:
                      Icon(_dark ? Icons.light_mode : Icons.dark_mode),
                  title: const Text('深色模式'),
                  onTap: () => setState(() => _dark = !_dark),
                ),
          if (!_collapsed)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('设计演示数据', style: TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }

  /// 导航角标底色（预览 .bdg）：收集是灰色信息角标，
  /// 整理是实心强调色角标；选中项上的角标统一白底。
  Color _badgeBackground(String route, bool dark) {
    if (route == '/collect') {
      return dark ? AppTheme.darkElevated : const Color(0xFFF3E9C8);
    }
    return dark ? AppTheme.darkNavSelected : AppTheme.accent;
  }

  /// 导航角标数字色（预览 .bdg）：收集灰色角标配次要文字色，
  /// 整理强调色角标配白字（深色配深字）。
  Color _badgeForeground(String route, bool dark) {
    if (route == '/collect') {
      return dark ? const Color(0xFFC6CEDA) : const Color(0xFF3D4E6B);
    }
    return dark ? const Color(0xFF131A24) : Colors.white;
  }

  void _go(String route, {String? subjectId}) {
    setState(() {
      _route = route;
      _subjectArg = subjectId;
    });
    _refreshBadges();
  }

  Widget _buildPage() {
    switch (_route) {
      case '/collect':
        return CollectPage(repo: repo, onOpenOrganize: () => _go('/organize'));
      case '/organize':
        return OrganizePage(repo: repo);
      case '/wrongbook':
        return WrongbookPage(
          repo: repo,
          initialSubjectId: _subjectArg,
          onOpenHome: () => _go('/home'),
        );
      case '/home':
      default:
        return HomePage(
          repo: repo,
          onGoCollect: () => _go('/collect'),
          onGoOrganize: () => _go('/organize'),
          onGoWrongbook: (subjectId) =>
              _go('/wrongbook', subjectId: subjectId),
        );
    }
  }
}
