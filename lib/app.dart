import 'dart:async';

import 'package:flutter/material.dart';

import '../data/badge_notifier.dart';
import '../data/database.dart';
import '../data/repository.dart';
import '../models/models.dart';
import '../services/recheck_reminder.dart';
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

/// B3：启动路由解析（纯函数，便于单测，见 test/s8b3_startup_test.dart）。
///
/// - `startupPage == 'last'` 且存过合法顶级路由 → 恢复该路由；
/// - 其余一律回落 `/home`：startupPage 是 'home' 或非法值、
///   存值为空/损坏/不在白名单。
/// 白名单只含 9 个顶级路由；题目详情 `/question/:id` 不在其中——
/// 题目可能已被删，恢复详情页没有意义，且详情页是 Navigator 压栈
/// 的页面，不是 `_route`，退出时本来也不会被记为最后路由。
const Set<String> topLevelRoutes = {
  '/home',
  '/collect',
  '/organize',
  '/wrongbook',
  '/review',
  '/report',
  '/subjects',
  '/settings',
};

String resolveStartupRoute(String startupPage, String? lastRoute) {
  if (startupPage != 'last') return '/home';
  final r = lastRoute?.trim() ?? '';
  return topLevelRoutes.contains(r) ? r : '/home';
}

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

  /// B4.1：复查提醒一轮应用只判断一次（启动时；切页不重复弹）。
  bool _reminderChecked = false;

  /// 待定3：手动备份失败标志（settings 表 `backupFailed` 键）。
  /// 设置页备份失败时置起，首页显示红色横幅；点“知道了”或下次
  /// 备份成功时清掉。
  bool _showBackupError = false;

  /// 导航学科速览的学科列表：库里的 subjects 表（入库顺序，B2）。
  /// 读不到 / 为空时回退预设三科；`_refreshBadges` 由 badgeVersion
  /// 监听驱动，新增学科会 bump badgeVersion（`upsertSubject`），
  /// 所以加科后导航自动同步，无需单独刷新通道。
  List<Subject> _navSubjects = Subject.all;

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
      final last = await repo.lastRoute();
      // 待定3：启动时读备份失败标志（读失败按无标志处理，不影响启动）。
      var backupFailed = false;
      try {
        backupFailed = await repo.backupFailed();
      } catch (_) {}
      if (!mounted) return;
      // B3：启动页设置生效——'last' 时恢复上次退出的顶级路由，
      // 否则（'home' / 存值非法 / 无存值）回落首页。
      final initial = resolveStartupRoute(s.startupPage, last);
      setState(() {
        _settings = s;
        _route = initial;
        _settingsLoaded = true;
        _showBackupError = backupFailed;
      });
      // B4.1：设置读到后、首帧后判断一次复查提醒（只在启动时弹一次）。
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _maybeShowRecheckReminder());
      // 自愈：回落后的路由与存值不一致时写回去（存值非法/为空、
      // 或 startupPage 是 'home' 时上次停留页被首页覆盖），
      // 下次启动不再重复回落；合法恢复时 initial == last，不写。
      if (initial != last) {
        unawaited(repo.saveLastRoute(initial));
      }
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

  /// B4.1：复查提醒（应用内、进入应用时一次）。
  /// 条件见 services/recheck_reminder.dart：开关开、有错因到复查
  /// 时间、已到当日提醒时间、今天没提醒过。弹之前先把今天的日期
  /// 写进库（一天一次；弹框本身失败也不再重复弹）。点“去复习”
  /// 进复习页；点“稍后再说”只关掉，今天不再弹。
  /// 提醒是锦上添花：读库失败也不影响启动，静默跳过。
  Future<void> _maybeShowRecheckReminder() async {
    if (_reminderChecked) return;
    _reminderChecked = true;
    try {
      final due = await repo.recheckDueCauseCount();
      final last = await repo.lastRecheckReminderDate();
      final now = DateTime.now();
      if (!shouldShowRecheckReminder(
        notifyEnabled: _settings.notifyEnabled,
        notifyTime: _settings.notifyTime,
        dueRecheckCount: due,
        now: now,
        lastRemindedDate: last,
      )) {
        return;
      }
      await repo.saveLastRecheckReminderDate(recheckReminderDateString(now));
      if (!mounted) return;
      final ctx = _navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final go = await showDialog<bool>(
        context: ctx,
        builder: (dctx) => AlertDialog(
          title: const Text('该复查了'),
          content: Text('有 $due 个错因到了复查时间，去复习看一下吧。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('稍后再说'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('去复习'),
            ),
          ],
        ),
      );
      if (go == true && mounted) _goReview();
    } catch (_) {
      // 提醒失败不影响启动。
    }
  }

  /// 待定3：首页横幅点“知道了”——清库标志 + 熄掉横幅。
  /// 清标志失败也不留横幅（本次启动内不再出现；下次启动重读库）。
  Future<void> _clearBackupError() async {
    try {
      await repo.setBackupFailed(false);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _showBackupError = false);
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
    final subjects = await repo.subjects();
    if (!mounted) return;
    setState(() {
      _collectBadge = CollectPage.countPendingBox(tasks) + pendingOrganize;
      _organizeBadge = pendingOrganize;
      _navRev = rev;
      _navPending = pending;
      _navSubjects = subjects.isEmpty ? Subject.all : subjects;
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
                    // A5：内容区必须顶对齐拉满高度。Row 默认 crossAxisAlignment
                    // 是 center，内容区容器会按页面内容高度收起并垂直居中；
                    // 内容短的页（设置/学科管理全折时约 421px）会悬在窗口
                    // 中间，点段头展开/折叠改变内容高度时整个页面就跟着
                    // 上下跳（展开外观约 +238px 内容，页面上窜约 119px，
                    // 与 R11 §8.3 “点段头后页面上滚约 136–158px”同源；
                    // 不是焦点滚动——点按不请求焦点，也无 ensureVisible）。
                    // stretch 让容器恒满高、顶对齐，与 HTML `.main` 一致。
                    crossAxisAlignment: CrossAxisAlignment.stretch,
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
      subjects: _navSubjects,
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
    // B3：记下最后停留的路由（startupPage='last' 时下次启动恢复用）。
    // 详情页是 Navigator 压栈，不经过这里，退出时最后路由仍是底层页。
    unawaited(repo.saveLastRoute(route));
    _refreshBadges();
  }

  void _goReview({String? subjectId}) {
    setState(() {
      _route = '/review';
      _reviewSubjectArg = subjectId;
    });
    unawaited(repo.saveLastRoute('/review'));
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
    unawaited(repo.saveLastRoute('/wrongbook'));
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
          onBackupFailed: () {
            if (mounted) setState(() => _showBackupError = true);
          },
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
          showBackupError: _showBackupError,
          onBackupErrorDismissed: _clearBackupError,
        );
    }
  }
}
