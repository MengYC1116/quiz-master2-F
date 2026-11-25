import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../models/models.dart';
import '../services/ocr_queue.dart';
import '../services/recheck_reminder.dart';
import '../state/badge_counts_provider.dart';
import '../state/settings_notifier.dart';
import '../theme/app_theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/command_palette.dart';
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
///
/// ARCH-PLAN-A 第 1 阶段：根组件是 `ConsumerStatefulWidget`，
/// 主题 / 深浅色 / 字号全部来自 `settingsProvider`（与设置页同一份），
/// 不再自己持有一份 `_settings` 快照（见 D-34）。
/// 第 4 阶段：左导航角标同样来自 Provider——`badgeCountsProvider`
///（订阅 `DataChangeBus`，见 `lib/state/badge_counts_provider.dart`），
/// 旧 `_refreshBadges` + `badgeVersion` 手动链已删除。
/// 路由、Navigator、提醒弹窗等应用级临时状态仍留根组件 State。
class QuizMasterApp extends ConsumerStatefulWidget {
  const QuizMasterApp({super.key});

  @override
  ConsumerState<QuizMasterApp> createState() => _QuizMasterAppState();
}

class _QuizMasterAppState extends ConsumerState<QuizMasterApp> {
  /// 启动路由只解析一次（设置首次读到时）：之后用户在设置页改
  /// startupPage 不应把当前路由拽走（与原来 _loadSettings 只跑
  /// 一次的行为一致）。
  bool _startupResolved = false;

  /// 用户是否已主动导航（点左导航 / 去复习 / 去设置等）。
  /// _onSettingsReady 跑在首帧后的回调里——若用户在它执行前
  /// 已经点了导航，启动路由不得再把路由拽回初始页（旧代码在
  /// initState 里解析，没有这个竞态；见 b8_1 / b9_1 回归）。
  bool _userNavigated = false;
  bool _collapsed = false;
  String _route = '/home';
  String? _subjectArg; // 带学科 ID 进错题本时直接打开对应那一本
  String? _reviewSubjectArg; // 带学科 ID 进复习时预置学科筛选
  // P3 入口 1/3：带指定题单进复习（错题本“立即专项练习”/薄弱点
  // “开始专项练习”）；只在挂载时读一次（ReviewNotifier.build 用
  // ref.read），与 _reviewSubjectArg 同款清理规则。
  List<String>? _reviewPracticeIds;
  int? _reviewPracticeCount;
  // B11-9：进设置页时直接展开的组（首页倒计时点进来时为 'exams'，
  // 其余入口为 null，各组默认全折）。
  String? _settingsGroupArg;
  String? _reportCauseArg; // 学习报告点弱点进错题本时的错因筛选
  String? _reportKpArg; // 学习报告点弱点进错题本时的知识点筛选
  String? _folderArg; // 详情页右栏「打开列表 ›」进错题本时的文件夹筛选
  // 十九批 A（D-223）：深链路跳错题本的挂载代次——_goWrongbookFiltered
  // 每调一次 +1，进 WrongbookPage 的 key，强制重挂载（已挂载的
  // notifier 不随 override 变化重建，D-50；不加代次时详情页内跳
  // 进来只会看到旧筛选的列表）。
  int _wrongbookFilterGeneration = 0;
  // 十九批 A4：命令面板里选中的查找（条件 + 显示名）：选后先切到
  // /wrongbook（已在错题本则只重建），由 WrongbookPage 在挂载 /
  // 更新时应用并回调清掉（见 WrongbookPage.pendingSearch）。
  ({Map<String, dynamic> conditions, String label})? _pendingPaletteSearch;
  final _navigatorKey = GlobalKey<NavigatorState>();

  late final QuestionRepository repo = QuestionRepository(AppDatabase.instance);

  @override
  void initState() {
    super.initState();
    // 十九批 A4：全局 Ctrl+K / Cmd+K 呼出命令面板（任意页面）。
    // 不用 Shortcuts/Focus——文本框聚焦时方向键等会被文本框的
    // 默认快捷键先吞掉；HardwareKeyboard 在焦点派发之前拦截。
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    // 十三批 M3：应用启动时启动 OCR 后台 worker（幂等；启动时回收过期租约）。
    // 启动失败不抛（worker 内部已兜底），绝不拖垮应用启动。
    // flutter test 下不启动（FLUTTER_TEST=true）：避免 widget 测试里
    // 后台轮询碰库；单测直接构造 OcrWorker，不走单例。
    if (Platform.environment['FLUTTER_TEST'] != 'true') {
      unawaited(OcrWorker.ensureStarted());
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    super.dispose();
  }

  /// 十九批 A4：全局 Ctrl+K / Cmd+K（KeyDown 才触发；面板已开时
  /// 不再叠开一层）。可打印字符一律放行（返回 false）。
  bool _handleGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyK) return false;
    final kb = HardwareKeyboard.instance;
    if (!kb.isControlPressed && !kb.isMetaPressed) return false;
    if (!mounted || CommandPalette.isOpen) return true;
    _openCommandPalette();
    return true;
  }

  /// 十九批 A4：呼出命令面板（遮罩 rgba(15,23,42,.45)，见板子 §6.1）。
  /// 选中一条后：记下待应用的查找，切到 /wrongbook（已在错题本则
  /// 只重建触发 WrongbookPage 的 pending 应用）；应用本身由
  /// WrongbookPage 在挂载 / 更新时做（条件 + 显示名一起传，
  /// 显示名进「最近搜过」）。
  void _openCommandPalette() {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    if (CommandPalette.isOpen) return;
    unawaited(
      showDialog<void>(
        context: ctx,
        barrierColor: const Color.fromRGBO(15, 23, 42, 0.45),
        barrierDismissible: true,
        builder: (dctx) => CommandPalette(
          repo: repo,
          onApply: (conditions, label) {
            _pendingPaletteSearch = (
              conditions: conditions,
              label: label,
            );
            if (_route != '/wrongbook') {
              _go('/wrongbook');
            } else {
              setState(() {});
            }
          },
        ),
      ),
    );
  }

  /// B4.1：复查提醒一轮应用只判断一次（启动时；切页不重复弹）。
  bool _reminderChecked = false;

  /// 待定3：手动备份失败标志（settings 表 `backupFailed` 键）。
  /// 设置页备份失败时置起，首页显示红色横幅；点“知道了”或下次
  /// 备份成功时清掉。
  bool _showBackupError = false;

  /// 设置首次读到（启动时）才跑一次：解析启动路由、读备份失败标志、
  /// 安排一次复查提醒、自愈 lastRoute。设置读失败时不跑——
  /// 路由 stays '/home'，设置页出错误横幅（与原来 _loadSettings
  /// 的 catch 分支一致）。之后设置再变（用户在设置页改项）不再
  /// 重解析路由（`_startupResolved` 守门）。
  Future<void> _onSettingsReady(AppSettings s) async {
    try {
      final last = await repo.lastRoute();
      // 待定3：启动时读备份失败标志（读失败按无标志处理，不影响启动）。
      var backupFailed = false;
      try {
        backupFailed = await repo.backupFailed();
      } catch (_) {}
      if (!mounted) return;
      // B3：启动页设置生效——'last' 时恢复上次退出的顶级路由，
      // 否则（'home' / 存值非法 / 无存值）回落首页。
      // 只在用户尚未导航时应用：见 _userNavigated 注释。
      final initial = resolveStartupRoute(s.startupPage, last);
      setState(() {
        if (!_userNavigated) _route = initial;
        _showBackupError = backupFailed;
      });
      // B4.1：设置读到后、首帧后判断一次复查提醒（只在启动时弹一次）。
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _maybeShowRecheckReminder(),
      );
      // 自愈：回落后的路由与存值不一致时写回去（存值非法/为空、
      // 或 startupPage 是 'home' 时上次停留页被首页覆盖），
      // 下次启动不再重复回落；合法恢复时 initial == last，不写。
      if (initial != last) {
        unawaited(repo.saveLastRoute(initial));
      }
    } catch (_) {
      // lastRoute / 备份标志读失败：不影响启动，路由 stays '/home'，
      // 提醒也不弹（_maybeShowRecheckReminder 本身也有 try/catch，
      // 但这里直接不安排，与原来 _loadSettings 的 catch 口径一致）。
    }
  }

  /// B4.1：复查提醒（应用内、进入应用时一次）。
  /// 条件见 services/recheck_reminder.dart：开关开、有错因到复查
  /// 时间、已到当日提醒时间、今天没提醒过。弹框成功展示后才把今天
  /// 的日期写进库（一天一次；SR-P2-67：旧顺序先写库再弹框，弹框
  /// 失败则当天提醒永久丢失）。点“去复习”进复习页；点“稍后再说”
  /// 只关掉，今天不再弹。
  /// 提醒是锦上添花：读库失败也不影响启动，静默跳过。
  Future<void> _maybeShowRecheckReminder() async {
    if (_reminderChecked) return;
    _reminderChecked = true;
    // 提醒条件里的开关与提醒时间来自 settingsProvider（根组件
    // 不再持有一份 _settings 快照）。
    final settings = ref.read(settingsProvider).value ?? AppSettings.defaults;
    try {
      final due = await repo.recheckDueCauseCount();
      final last = await repo.lastRecheckReminderDate();
      final now = DateTime.now();
      if (!shouldShowRecheckReminder(
        notifyEnabled: settings.notifyEnabled,
        notifyTime: settings.notifyTime,
        dueRecheckCount: due,
        now: now,
        lastRemindedDate: last,
      )) {
        return;
      }
      if (!mounted) return;
      final ctx = _navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      bool? go;
      try {
        go = await showDialog<bool>(
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
      } catch (_) {
        // SR-P2-67：弹框本身失败（上下文失效等）时不写“今天已提醒”，
        // 下次启动仍可再提醒；当天提醒不因一次弹框失败永久丢失。
        return;
      }
      // 弹框已展示（无论点哪个按钮、按 Esc 关掉），再写今天已提醒。
      try {
        await repo.saveLastRecheckReminderDate(recheckReminderDateString(now));
      } catch (_) {
        // 写库失败也不影响已展示的提醒，下次启动按库里旧值再判断。
      }
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

  ThemeMode _themeModeFor(AppSettings settings) => switch (settings.themeMode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  @override
  Widget build(BuildContext context) {
    // 主题 / 字号只从 settingsProvider 读（与设置页同一份）。
    // 首次加载且无旧值时显示启动屏；读失败时用默认设置继续跑，
    // 设置页出错误横幅（loadFailed 由 provider 的 error 态导出）。
    // 重读期间（恢复备份后 reloadSettings）旧值仍在，不闪启动屏。
    final settingsAsync = ref.watch(settingsProvider);
    final settings = settingsAsync.value ?? AppSettings.defaults;
    if (settingsAsync.isLoading && settingsAsync.value == null) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    if (settingsAsync.hasValue && !_startupResolved) {
      // 只解析一次：build 里不能直接 setState，约到下一帧再做
      // （lastRoute 读库 + 路由切换 + 提醒安排）。
      _startupResolved = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _onSettingsReady(settings),
      );
    }
    final loadFailed = settingsAsync.hasError;
    // 角标（Stage 4）：只从 badgeCountsProvider 读——首查与刷新都由
    // Provider 自己负责（订阅 DataChangeBus）；首查未完成或重读失败时
    // 用零值，导航不摆幽灵数字（B8-1：空表是合法状态，不回退预设三科）。
    // 重读期间旧值仍在（AsyncValue.copyWithPrevious），不闪回零。
    final badges = ref.watch(badgeCountsProvider).value ?? BadgeCounts.zero;
    // 字号缩放（D4）：唯一来源是 AppSettings.fontScale（标准 1.00 /
    // 大 1.15 / 特大 1.30，见 models.dart / FontScale）。
    // 字号只在这里由 MediaQuery TextScaler 全局乘一次；ThemeData 的
    // TextTheme 取基准值、不再乘，否则同一段文字会被缩放两次。
    // 布局类尺寸（圆角 / 按钮内边距）由 AppTheme 按同一因子缩放。
    final scale = settings.fontScale;
    return MaterialApp(
      title: 'quiz-master2',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: AppTheme.light(scale: scale),
      darkTheme: AppTheme.dark(scale: scale),
      themeMode: _themeModeFor(settings),
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
                      _buildNav(context, badges),
                      // 内容区：HTML `.main` 底色 `--surface` + 内边距
                      // `26px 30px`（`ScaledTokens.contentPadding`，按三档
                      // 缩放 token 缩放）。九页主体仍带各自的旧内边距
                      // （24–28px），过渡期总缩进偏大，R3–R10 逐页去掉
                      // 页内边距后落到准确的 26/30（见 R2 报告）。
                      Expanded(
                        child: Container(
                          color: palette.surface,
                          padding: scaled.contentPadding,
                          child: _buildPage(settings, loadFailed),
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

  Widget _buildNav(BuildContext context, BadgeCounts badges) {
    return AppNavBar(
      route: _route,
      collapsed: _collapsed,
      onNavigate: _go,
      onToggleCollapsed: () => setState(() => _collapsed = !_collapsed),
      collectBadge: badges.collectBadge,
      organizeBadge: badges.organizeBadge,
      reviewBadge: badges.reviewBadge,
      navRev: badges.navRev,
      navPending: badges.navPending,
      subjects: badges.subjects,
    );
  }

  void _go(String route, {String? subjectId}) {
    _userNavigated = true;
    setState(() {
      _route = route;
      _subjectArg = subjectId;
      if (route != '/review') _reviewSubjectArg = null;
      // P3：普通导航离开复习页时清掉带题单参数，避免下次进复习页
      // 时旧题单被当作新开练（见 _reviewPracticeIds 注释）。
      if (route != '/review') {
        _reviewPracticeIds = null;
        _reviewPracticeCount = null;
      }
      // D-50：深链路参数只由 `_goWrongbookFiltered` 设；普通导航（含左
      // 导航 / 首页进错题本）一律清掉。已挂载的 notifier 不随 override
      // 变化重建（initial 只在挂载时读一次），所以残留值影响的是下一次
      // 全新挂载：不清掉，下次普通进错题本会落在带筛选的列表而不是书架。
      _reportCauseArg = null;
      _reportKpArg = null;
      _folderArg = null;
      // B11-9：普通入口进设置页时不预展开任何组。
      if (route != '/settings') _settingsGroupArg = null;
    });
    // B3：记下最后停留的路由（startupPage='last' 时下次启动恢复用）。
    // 详情页是 Navigator 压栈，不经过这里，退出时最后路由仍是底层页。
    // Stage 4：切页不再手动刷角标——角标只由 badgeCountsProvider
    // 按数据变更事件刷新（写驱动）；时间驱动的复查到期（无写入）
    // 在下次写入事件或启动时刷新（B9-3 的残余滞后，见 D-43）。
    unawaited(repo.saveLastRoute(route));
  }

  /// B11-9：进设置页并直接展开指定组（首页倒计时点进来时 group='exams'）。
  void _goSettings({String? group}) {
    _userNavigated = true;
    setState(() {
      _route = '/settings';
      _settingsGroupArg = group;
    });
    unawaited(repo.saveLastRoute('/settings'));
  }

  void _goReview({
    String? subjectId,
    List<String>? practiceQuestionIds,
    int? practiceCount,
  }) {
    _userNavigated = true;
    setState(() {
      _route = '/review';
      _reviewSubjectArg = subjectId;
      // P3：不带题单的普通进复习清掉旧题单（见 _reviewPracticeIds 注释）。
      _reviewPracticeIds = practiceQuestionIds;
      _reviewPracticeCount = practiceCount;
    });
    unawaited(repo.saveLastRoute('/review'));
  }

  void _goWrongbookFiltered({
    String? subjectId,
    String? cause,
    String? knowledgePointId,
    String? folderId,
  }) {
    _userNavigated = true;
    // 十九批 A（D-223）：详情页右栏跳进来时详情还压在根 Navigator
    // 栈顶——只改底层路由不 pop，用户看到的仍是详情；pop 到栈底才
    // 看到带筛选的列表（报告页调进来时栈顶就是首页，popUntil 是空操作）。
    // 代次 +1 强制 WrongbookPage 重挂载（见 _folderArg 注释），
    // 否则已挂载的 notifier 不读新的 initial，列表仍是旧筛选。
    _wrongbookFilterGeneration++;
    setState(() {
      _route = '/wrongbook';
      _subjectArg = subjectId;
      _reportCauseArg = cause;
      _reportKpArg = knowledgePointId;
      _folderArg = folderId;
    });
    unawaited(repo.saveLastRoute('/wrongbook'));
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  Future<void> _openDetail(
    Question q,
    List<String> orderIds, {
    String sourceLabel = '错题本',
    // 十九批 A6：列表行点按时拼的查询描述（学科名 · 错因名 · 状态 ·
    // 搜索关键词，全空为「全部题目」）；详情页 B 包在返回行展示，
    // 不传时沿用现版「返回{sourceLabel}」文案。
    String? searchContext,
  }) async {
    await _navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => QuestionDetailPage(
          repo: repo,
          questionId: q.id,
          orderIds: orderIds,
          sourceLabel: sourceLabel,
          searchContext: searchContext,
          // 十九批 A（D-223）：详情页右栏「全部 ›」/「打开列表 ›」
          // 跳带筛选的错题本列表（见 _goWrongbookFiltered）。
          onOpenWrongbookFiltered: _goWrongbookFiltered,
          // B11-11：复习记录空状态的“去复习”按钮去 /review。
          onGoReview: () => _goReview(),
        ),
      ),
    );
  }

  Widget _buildPage(AppSettings settings, bool loadFailed) {
    switch (_route) {
      case '/collect':
        return CollectPage(
          repo: repo,
          onOpenOrganize: () => _go('/organize'),
          onGoSubjects: () => _go('/subjects'),
        );
      case '/organize':
        return OrganizePage(
          repo: repo,
          onOpenDetail: (q, ids) => _openDetail(q, ids, sourceLabel: '整理工作台'),
          onGoReview: () => _goReview(),
          onGoCollect: () => _go('/collect'),
        );
      case '/wrongbook':
        return WrongbookPage(
          // 十九批 A（D-223）：key 带深链路参数 + 代次——参数变化或
          // _goWrongbookFiltered 每次调用都重挂载，notifier 读到新
          // 的 initial；参数不变的普通重建不重挂（列表状态保留）。
          key: ValueKey(
            'wrongbook-$_wrongbookFilterGeneration-'
            '${_subjectArg ?? ''}-${_reportCauseArg ?? ''}-'
            '${_reportKpArg ?? ''}-${_folderArg ?? ''}',
          ),
          repo: repo,
          initialSubjectId: _subjectArg,
          filterCause: _reportCauseArg,
          filterKnowledgePointId: _reportKpArg,
          folderId: _folderArg,
          // 十九批 A4：命令面板选中的查找（挂载 / 更新时应用，见
          // WrongbookPage.pendingSearch）；应用后回调清掉。
          pendingSearch: _pendingPaletteSearch,
          onPendingSearchApplied: () {
            if (mounted) {
              setState(() => _pendingPaletteSearch = null);
            }
          },
          onOpenHome: () => _go('/home'),
          onGoSubjects: () => _go('/subjects'),
          onGoCollect: () => _go('/collect'),
          onGoOrganize: () => _go('/organize'),
          onOpenDetail: (q, ids, {String? searchContext}) => _openDetail(
            q,
            ids,
            sourceLabel: '错题本',
            searchContext: searchContext,
          ),
          onGoReview: ({String? subjectId}) => _goReview(subjectId: subjectId),
          // P3 入口 1：错题本“立即专项练习”带题单进复习页（只练不排）。
          onStartPracticeWithQuestions: (ids, {count}) =>
              _goReview(practiceQuestionIds: ids, practiceCount: count),
        );
      case '/review':
        return ReviewPage(
          repo: repo,
          onOpenDetail: (q, ids) => _openDetail(q, ids, sourceLabel: '复习'),
          initialSubjectId: _reviewSubjectArg,
          // P3 入口 1/3：带题单进复习（挂载时读一次，见 _reviewPracticeIds）。
          initialPracticeQuestionIds: _reviewPracticeIds,
          initialPracticeCount: _reviewPracticeCount,
          onGoWrongbook: () => _go('/wrongbook'),
        );
      case '/report':
        return ReportPage(
          repo: repo,
          onGoReview: () => _goReview(),
          onOpenWrongbookFiltered: _goWrongbookFiltered,
          // P3 入口 3：薄弱点列表页“开始专项练习”带题单进复习页。
          onStartPracticeWithQuestions: (ids, {count}) =>
              _goReview(practiceQuestionIds: ids, practiceCount: count),
        );
      case '/subjects':
        return SubjectsPage(repo: repo);
      case '/settings':
        return SettingsPage(
          loadFailed: loadFailed,
          onBackupFailed: () {
            if (mounted) setState(() => _showBackupError = true);
          },
          initialOpenGroup: _settingsGroupArg,
        );
      case '/home':
      default:
        return HomePage(
          repo: repo,
          settings: settings,
          onGoCollect: () => _go('/collect'),
          onGoOrganize: () => _go('/organize'),
          onGoWrongbook: (subjectId) => _go('/wrongbook', subjectId: subjectId),
          onGoReview: () => _goReview(),
          // 十二批功能 4：点“最近查看”里的一道题进详情（与错题本 /
          // 复习页相同的 _openDetail 压栈方式，来源列表即历史列表顺序）。
          onOpenDetail: (q, ids) => _openDetail(q, ids, sourceLabel: '首页'),
          showBackupError: _showBackupError,
          onBackupErrorDismissed: _clearBackupError,
          onGoSettings: () => _goSettings(group: 'exams'),
        );
    }
  }
}
