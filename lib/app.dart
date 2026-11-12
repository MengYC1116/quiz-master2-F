import 'package:flutter/material.dart';

import '../data/badge_notifier.dart';
import '../data/database.dart';
import '../data/repository.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';
import 'modules/collect/collect_page.dart';
import 'modules/detail/question_detail_page.dart';
import 'modules/home/home_page.dart';
import 'modules/organize/organize_page.dart';
import 'modules/report/report_page.dart';
import 'modules/review/review_page.dart';
import 'modules/settings/settings_page.dart';
import 'modules/subjects/subjects_page.dart';
import 'modules/wrongbook/wrongbook_page.dart';

/// 应用外壳：左导航 216px，可折叠为仅图标；一页一模块，只靠 ID 跳转。
/// 路由：/home /collect /organize /wrongbook /question/:id /review
/// /report /subjects /settings（9 页）。
class QuizMasterApp extends StatefulWidget {
  const QuizMasterApp({super.key});

  @override
  State<QuizMasterApp> createState() => _QuizMasterAppState();
}

class _QuizMasterAppState extends State<QuizMasterApp> {
  AppSettings _settings = AppSettings.defaults;
  bool _settingsLoaded = false;
  bool _collapsed = false;
  String _route = '/home';
  String? _subjectArg; // 带学科 ID 进错题本时直接打开对应那一本
  String? _reviewSubjectArg; // 带学科 ID 进复习时预置学科筛选
  String? _reportCauseArg; // 学习报告点弱点进错题本时的错因筛选
  String? _reportKpArg; // 学习报告点弱点进错题本时的知识点筛选
  final _navigatorKey = GlobalKey<NavigatorState>();

  late final QuestionRepository repo =
      QuestionRepository(AppDatabase.instance);

  int _collectBadge = 0;
  int _organizeBadge = 0;
  Map<String, int> _navRev = {};
  Map<String, int> _navPending = {};

  @override
  void initState() {
    super.initState();
    badgeVersion.addListener(_refreshBadges);
    _loadSettings();
    _refreshBadges();
  }

  @override
  void dispose() {
    badgeVersion.removeListener(_refreshBadges);
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final s = await repo.settings();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _settingsLoaded = true;
    });
  }

  Future<void> _updateSettings(AppSettings s) async {
    await repo.saveSettings(s);
    if (!mounted) return;
    setState(() => _settings = s);
  }

  ThemeMode get _themeMode => switch (_settings.themeMode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  Future<void> _refreshBadges() async {
    final tasks = await repo.collectTasks();
    final pendingOrganize = await repo.pendingOrganizeCount();
    final rev = await repo.homeRevCounts();
    final pending = await repo.pendingOrganizeBySubject();
    if (!mounted) return;
    setState(() {
      _collectBadge = CollectPage.countPendingBox(tasks) + pendingOrganize;
      _organizeBadge = pendingOrganize;
      _navRev = rev;
      _navPending = pending;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_settingsLoaded) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    final scale = _settings.fontSize == 'large'
        ? 1.12
        : _settings.fontSize == 'extraLarge'
            ? 1.25
            : 1.0;
    return MaterialApp(
      title: 'quiz-master2',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        );
      },
      home: Builder(
        builder: (context) => Scaffold(
          body: Stack(
            children: [
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
      ('/review', '复习', Icons.school_outlined, 0),
      ('/report', '学习报告', Icons.bar_chart_outlined, 0),
      ('/subjects', '学科管理', Icons.folder_outlined, 0),
      ('/settings', '设置', Icons.settings_outlined, 0),
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
                                            : AppTheme.accent,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        '$badge',
                                        style: TextStyle(
                                          color: _route == route
                                              ? selectedBackground
                                              : Colors.white,
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
                                      : AppTheme.accent,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '$badge',
                                  style: TextStyle(
                                    color: _route == route
                                        ? selectedBackground
                                        : Colors.white,
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
          // 学科速览：待整理 + 待复习（待复习与首页焦点卡同一口径
          // homeRevCounts，数题不数错因，每次渲染刷新）。
          if (!_collapsed) ...[
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 10, 8, 4),
              child: Text('学科速览',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            for (final s in Subject.all)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: s.color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text(s.name, style: const TextStyle(fontSize: 13)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '待整理 ${_navPending[s.id] ?? 0} · 待复习 ${_navRev[s.id] ?? 0}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
          if (!_collapsed)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('设计演示数据', style: TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }

  void _go(String route, {String? subjectId}) {
    setState(() {
      _route = route;
      _subjectArg = subjectId;
      if (route != '/review') _reviewSubjectArg = null;
      if (route != '/wrongbook') {
        _reportCauseArg = null;
        _reportKpArg = null;
      }
    });
    _refreshBadges();
  }

  void _goReview({String? subjectId}) {
    setState(() {
      _route = '/review';
      _reviewSubjectArg = subjectId;
    });
    _refreshBadges();
  }

  void _goWrongbookFiltered({String? cause, String? knowledgePointId}) {
    setState(() {
      _route = '/wrongbook';
      _reportCauseArg = cause;
      _reportKpArg = knowledgePointId;
    });
    _refreshBadges();
  }

  Future<void> _openDetail(Question q, List<String> orderIds) async {
    await _navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => QuestionDetailPage(
          repo: repo,
          questionId: q.id,
          orderIds: orderIds,
          onChanged: _refreshBadges,
        ),
      ),
    );
    _refreshBadges();
  }

  Widget _buildPage() {
    switch (_route) {
      case '/collect':
        return CollectPage(repo: repo, onOpenOrganize: () => _go('/organize'));
      case '/organize':
        return OrganizePage(
          repo: repo,
          onOpenDetail: _openDetail,
          onGoReview: () => _goReview(),
        );
      case '/wrongbook':
        return WrongbookPage(
          repo: repo,
          initialSubjectId: _subjectArg,
          filterCause: _reportCauseArg,
          filterKnowledgePointId: _reportKpArg,
          onOpenHome: () => _go('/home'),
          onOpenDetail: _openDetail,
          onGoReview: ({String? subjectId}) =>
              _goReview(subjectId: subjectId),
        );
      case '/review':
        return ReviewPage(
          repo: repo,
          onOpenDetail: _openDetail,
          initialSubjectId: _reviewSubjectArg,
          onGoWrongbook: () => _go('/wrongbook'),
        );
      case '/report':
        return ReportPage(
          repo: repo,
          onGoReview: () => _goReview(),
          onOpenWrongbookFiltered: _goWrongbookFiltered,
        );
      case '/subjects':
        return SubjectsPage(repo: repo);
      case '/settings':
        return SettingsPage(
          repo: repo,
          settings: _settings,
          onSettingsChanged: _updateSettings,
        );
      case '/home':
      default:
        return HomePage(
          repo: repo,
          settings: _settings,
          onGoCollect: () => _go('/collect'),
          onGoOrganize: () => _go('/organize'),
          onGoWrongbook: (subjectId) =>
              _go('/wrongbook', subjectId: subjectId),
          onGoReview: () => _goReview(),
        );
    }
  }
}
