import 'package:flutter/material.dart';

import '../data/badge_notifier.dart';
import '../data/database.dart';
import '../data/repository.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
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
  bool _settingsLoadFailed = false;
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
    try {
      final s = await repo.settings();
      if (!mounted) return;
      setState(() {
        _settings = s;
        _settingsLoaded = true;
      });
    } catch (_) {
      // 设置读失败：用默认设置继续跑，设置页出错误横幅（HTML 错误态）。
      if (!mounted) return;
      setState(() {
        _settingsLoadFailed = true;
        _settingsLoaded = true;
      });
    }
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
    // 字号缩放（D4）：唯一来源是 AppSettings.fontScale（标准 1.00 /
    // 大 1.15 / 特大 1.30，见 models.dart / FontScale）。
    // 字号只在这里由 MediaQuery TextScaler 全局乘一次；ThemeData 的
    // TextTheme 取基准值、不再乘，否则同一段文字会被缩放两次。
    // 布局类尺寸（圆角 / 按钮内边距）由 AppTheme 按同一因子缩放。
    final scale = _settings.fontScale;
    return MaterialApp(
      title: 'quiz-master2',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: AppTheme.light(scale: scale),
      darkTheme: AppTheme.dark(scale: scale),
      themeMode: _themeMode,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        );
      },
      home: Builder(
        builder: (context) {
          final palette = DesignTokens.of(Theme.of(context).brightness);
          final scaled = DesignTokens.scaled(scale);
          return Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(child: PaperDots()),
                Positioned.fill(
                  child: Row(
                    children: [
                      _buildNav(context),
                      // 内容区：HTML `.main` 底色 `--surface` + 内边距
                      // `26px 30px`（`ScaledTokens.contentPadding`，按三档
                      // 缩放 token 缩放）。九页主体仍带各自的旧内边距
                      // （24–28px），过渡期总缩进偏大，R3–R10 逐页去掉
                      // 页内边距后落到准确的 26/30（见 R2 报告）。
                      Expanded(
                        child: Container(
                          color: palette.surface,
                          padding: scaled.contentPadding,
                          child: _buildPage(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildNav(BuildContext context) {
    return AppNavBar(
      route: _route,
      collapsed: _collapsed,
      onNavigate: _go,
      onToggleCollapsed: () => setState(() => _collapsed = !_collapsed),
      collectBadge: _collectBadge,
      organizeBadge: _organizeBadge,
      navRev: _navRev,
      navPending: _navPending,
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

  void _goWrongbookFiltered({
    String? subjectId,
    String? cause,
    String? knowledgePointId,
  }) {
    setState(() {
      _route = '/wrongbook';
      _subjectArg = subjectId;
      _reportCauseArg = cause;
      _reportKpArg = knowledgePointId;
    });
    _refreshBadges();
  }

  Future<void> _openDetail(Question q, List<String> orderIds,
      {String sourceLabel = '错题本'}) async {
    await _navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => QuestionDetailPage(
          repo: repo,
          questionId: q.id,
          orderIds: orderIds,
          sourceLabel: sourceLabel,
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
          onOpenDetail: (q, ids) =>
              _openDetail(q, ids, sourceLabel: '整理工作台'),
          onGoReview: () => _goReview(),
          onGoCollect: () => _go('/collect'),
        );
      case '/wrongbook':
        return WrongbookPage(
          repo: repo,
          initialSubjectId: _subjectArg,
          filterCause: _reportCauseArg,
          filterKnowledgePointId: _reportKpArg,
          onOpenHome: () => _go('/home'),
          onOpenDetail: (q, ids) => _openDetail(q, ids, sourceLabel: '错题本'),
          onGoReview: ({String? subjectId}) =>
              _goReview(subjectId: subjectId),
        );
      case '/review':
        return ReviewPage(
          repo: repo,
          onOpenDetail: (q, ids) => _openDetail(q, ids, sourceLabel: '复习'),
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
          loadFailed: _settingsLoadFailed,
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
