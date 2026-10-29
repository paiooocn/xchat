import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:llm_api/llm_api.dart' as llm;
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_paths.dart';
import '../../core/app_version.dart';
import '../../core/ids.dart';
import '../../models/project.dart';
import '../../models/session.dart';
import '../../models/agent_mode.dart';
import '../../models/message_attachment.dart';
import '../../models/provider_config.dart';
import '../../models/session_message.dart';
import '../../models/session_params.dart';
import '../../models/session_template.dart';
import '../../models/task_item.dart';
import '../../session/session_controller.dart';
import '../../session/session_ops.dart';
import '../../state/app_state.dart';
import '../../state/approval_center.dart';
import '../../util/editor_launcher.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/brand_mark.dart';
import '../widgets/input_area.dart';
import '../widgets/message_bubble.dart';
import '../widgets/project_dialog.dart';
import '../widgets/session_info_dialog.dart';
import '../widgets/task_session_view.dart';
import '../widgets/thinking_block.dart';
import '../widgets/tool_call_block.dart';
import 'pip_packages_page.dart';
import '../widgets/usage_badge.dart';
import '../theme/app_fonts.dart';
import '../theme/app_theme.dart';
import 'archive_page.dart';
import 'compress_prompts_page.dart';
import 'providers_page.dart';
import 'session_wizard_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'templates_page.dart';
import 'tools_page.dart';
import 'xml_editor_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _selectedId;

  /// 任务式会话中当前打开的任务项（空 = 显示任务列表）。
  String? _activeTaskId;

  /// Selected session tag filters (empty = show all).
  final Set<String> _tagFilter = <String>{};

  /// Whether the global sessions section is expanded (persisted).
  bool _globalSessionsExpanded = true;

  /// Whether a manual session-list refresh is in flight (spinner in header).
  bool _refreshingSessions = false;

  /// Whether the global approval window is on screen. While closed, pending
  /// requests stay queued and surface via the app-bar badge instead.
  bool _approvalDialogOpen = false;

  /// Set when the user dismisses the window via 稍后处理: the still-pending
  /// requests must NOT trigger an immediate auto-reopen (that made the button
  /// look broken). Cleared by the next *new* request or when the queue drains.
  bool _approvalSnoozed = false;

  /// Ids of requests already seen, to tell a brand-new request from a change
  /// on an existing one.
  final Set<String> _knownApprovalIds = <String>{};

  /// Captured in initState: the center outlives this State, and `context`
  /// must not be touched in dispose.
  late final ApprovalCenter _approvalCenter;

  static const _globalExpandedKey = 'xchat_global_sessions_expanded';

  @override
  void initState() {
    super.initState();
    _loadGlobalExpanded();
    _approvalCenter = context.read<AppState>().approvalCenter;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Approvals can arrive from any session at any time (including one whose
      // panel is not visible), so the queue is observed from the page root.
      _approvalCenter.addListener(_onApprovalsChanged);
      _maybeOpenApprovalDialog();
    });
  }

  @override
  void dispose() {
    _approvalCenter.removeListener(_onApprovalsChanged);
    super.dispose();
  }

  void _onApprovalsChanged() {
    if (!mounted) return;
    final pending = _approvalCenter.pending;
    // A brand-new request always reopens the window, even after 稍后处理.
    final hasNew = pending.any((r) => !_knownApprovalIds.contains(r.id));
    _knownApprovalIds
      ..clear()
      ..addAll(pending.map((r) => r.id));
    if (pending.isEmpty || hasNew) _approvalSnoozed = false;
    setState(() {}); // refresh the app-bar badge
    _maybeOpenApprovalDialog();
  }

  /// Auto-open driven by the approval queue: suppressed while the user has
  /// dismissed the window via 稍后处理 (until the next new request arrives).
  /// New requests arriving while it is open are appended to its list by the
  /// dialog itself.
  void _maybeOpenApprovalDialog() {
    if (_approvalDialogOpen || _approvalSnoozed) return;
    _showApprovalDialog();
  }

  /// Manual open from the app-bar badge: explicit user intent, so it always
  /// opens — the 稍后处理 snooze only gates *automatic* reopening.
  void _openApprovalDialog() {
    _approvalSnoozed = false;
    _showApprovalDialog();
  }

  void _showApprovalDialog() {
    if (_approvalDialogOpen) return;
    if (_approvalCenter.pending.isEmpty) return;
    _approvalDialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ApprovalDialog(
        onDismissed: () => _approvalSnoozed = true,
      ),
    ).whenComplete(() {
      _approvalDialogOpen = false;
      // A request may have arrived while the dialog was closing.
      if (mounted) _maybeOpenApprovalDialog();
    });
  }

  /// 侧栏工具条里的审批入口；角标显示待处理数量。
  Widget _approvalBadge() {
    final count = context.watch<AppState>().approvalCenter.pending.length;
    return IconButton(
      tooltip: count > 0 ? '工具审批（$count 项待处理）' : '工具审批',
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.fact_check_outlined),
      ),
      onPressed: _openApprovalDialog,
    );
  }

  Future<void> _loadGlobalExpanded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getBool(_globalExpandedKey);
      if (value != null && mounted) {
        setState(() => _globalSessionsExpanded = value);
      }
    } catch (_) {
      // Ignore — use default (expanded).
    }
  }

  Future<void> _saveGlobalExpanded(bool expanded) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_globalExpandedKey, expanded);
    } catch (_) {
      // Ignore — state is still kept in memory.
    }
  }

  void _toggleTag(String tag) {
    setState(() {
      if (!_tagFilter.remove(tag)) _tagFilter.add(tag);
    });
  }

  /// Re-reads the session index from disk (picks up sessions created,
  /// deleted or archived by another app instance) and rebuilds the lists.
  Future<void> _refreshSessions() async {
    if (_refreshingSessions) return;
    setState(() => _refreshingSessions = true);
    try {
      final state = context.read<AppState>();
      await state.refreshSessions();
      await state.refreshArchived();
    } finally {
      if (mounted) setState(() => _refreshingSessions = false);
    }
  }

  Future<void> _newSession(BuildContext context, {String? projectId}) async {
    final state = context.read<AppState>();
    final created = await Navigator.of(context).push<Session>(
      MaterialPageRoute(
        builder: (_) => SessionWizardPage(initialProjectId: projectId),
      ),
    );
    if (created != null && mounted) {
      setState(() => _selectedId = created.id);
      await state.refreshSessions();
    }
  }

  Future<void> _newProject(BuildContext context) async {
    final state = context.read<AppState>();
    final result = await _showProjectDialog(context);
    if (result == null) return;
    await state.createProject(
      name: result.name,
      description: result.description,
      sandbox: result.sandbox,
      systemPrompt: result.systemPrompt,
      memoryEnabled: result.memoryEnabled,
    );
  }

  Future<void> _editProject(BuildContext context, Project project) async {
    final state = context.read<AppState>();
    final result = await _showProjectDialog(context, existing: project);
    if (result == null) return;
    project
      ..name = result.name
      ..description = result.description
      ..sandbox = result.sandbox
      ..systemPrompt = result.systemPrompt
      ..memoryEnabled = result.memoryEnabled;
    await state.saveProject(project);
    // 打开记忆开关时补齐骨架；已存在的文件不会被覆盖。
    if (result.memoryEnabled) {
      await state.ensureProjectMemory(project);
    }
  }

  /// Selects a session and reloads its content from disk so the latest
  /// conversation is always shown when (re)opening it.
  Future<void> _openSession(BuildContext context, String id) async {
    final state = context.read<AppState>();
    // Load the authoritative copy (full conversation) before showing it, so the
    // panel always has messages instead of the index's metadata-only entry.
    await state.reloadSession(id);
    if (mounted) {
      setState(() {
        _selectedId = id;
        _activeTaskId = null;
      });
    }
  }

  /// Opens the project create/edit dialog.
  ///
  /// The dialog owns its text controllers (they are disposed with the
  /// dialog widget, i.e. after the closing animation) — disposing them
  /// right after `showDialog` returns would break the still-mounted dialog.
  Future<ProjectDialogResult?> _showProjectDialog(
    BuildContext context, {
    Project? existing,
  }) {
    return showDialog<ProjectDialogResult>(
      context: context,
      builder: (context) => ProjectDialog(existing: existing),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final sessions = state.sessions;
    final projects = state.projects;
    final selected = _firstWhereOrNull(sessions, (s) => s.id == _selectedId);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 820;
        final scheme = Theme.of(context).colorScheme;

        return Scaffold(
          body: wide
              ? Row(
                  children: [
                    SizedBox(
                      width: AppTheme.sidebarWidth,
                      child: _Sidebar(
                        toolbarActions: _sidebarToolbar(context),
                        sessions: sessions,
                        projects: projects,
                        selectedId: _selectedId,
                        runningIds: state.runningSessionIds,
                        tagFilter: _tagFilter,
                        onTagToggle: _toggleTag,
                        globalSessionsExpanded: _globalSessionsExpanded,
                        onGlobalExpandedChanged: (expanded) {
                          setState(() => _globalSessionsExpanded = expanded);
                          _saveGlobalExpanded(expanded);
                        },
                        onRefreshSessions: _refreshSessions,
                        refreshingSessions: _refreshingSessions,
                        onSelect: (id) => _openSession(context, id),
                        onNewSession: (projectId) =>
                            _newSession(context, projectId: projectId),
                        onNewProject: () => _newProject(context),
                        onEditProject: (p) => _editProject(context, p),
                        onNavigate: (id) => _navigate(context, id),
                        onGoHome: _goHome,
                      ),
                    ),
                    VerticalDivider(width: 1, color: scheme.outlineVariant),
                    Expanded(
                      child: selected == null
                          ? _WelcomeView(
                              onSend: (text, attachments,
                                      {SessionTemplate? template,
                                      required AgentMode mode,
                                      String? projectPath}) =>
                                  _startSession(
                                text,
                                attachments,
                                template: template,
                                mode: mode,
                                projectPath: projectPath,
                              ),
                            )
                          : _sessionArea(context, state, selected),
                    ),
                  ],
                )
              : _Sidebar(
                  toolbarActions: _sidebarToolbar(context),
                  sessions: sessions,
                  projects: projects,
                  selectedId: _selectedId,
                  runningIds: state.runningSessionIds,
                  tagFilter: _tagFilter,
                  onTagToggle: _toggleTag,
                  globalSessionsExpanded: _globalSessionsExpanded,
                  onGlobalExpandedChanged: (expanded) {
                    setState(() => _globalSessionsExpanded = expanded);
                    _saveGlobalExpanded(expanded);
                  },
                  onRefreshSessions: _refreshSessions,
                  refreshingSessions: _refreshingSessions,
                  // 底部工具条已固定在侧栏底部，列表不再需要为悬浮按钮留白。
                  bottomInset: 8,
                  onSelect: (id) async {
                    await _openSession(context, id);
                    if (!context.mounted) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _MobileChatPage(sessionId: id),
                      ),
                    );
                  },
                  onNewSession: (projectId) =>
                      _newSession(context, projectId: projectId),
                  onNewProject: () => _newProject(context),
                  onEditProject: (p) => _editProject(context, p),
                  onNavigate: (id) => _navigate(context, id),
                  onGoHome: _goHome,
                ),
        );
      },
    );
  }

  /// 右栏内容：普通会话直接进对话；任务式会话先进任务列表，再进某个任务的对话。
  Widget _sessionArea(BuildContext context, AppState state, Session session) {
    if (!session.isTaskSession) {
      return SessionChatPanel(
        key: ValueKey(session.id),
        sessionId: session.id,
        onCompressCompleted: (id) async => _openSession(context, id),
      );
    }
    final taskId = _activeTaskId;
    if (taskId == null) {
      final controller = state.controllerFor(session.id);
      return TaskListView(
        key: ValueKey('tasks-${session.id}'),
        session: session,
        running: controller.isRunning,
        runningTaskId: controller.runningTaskId,
        onOpenTask: (id) => setState(() => _activeTaskId = id),
      );
    }
    return SessionChatPanel(
      key: ValueKey('${session.id}-$taskId'),
      sessionId: session.id,
      taskId: taskId,
      onBackToTasks: () => setState(() => _activeTaskId = null),
      onCompressCompleted: (id) async => _openSession(context, id),
    );
  }

  /// 侧栏底部右侧的工具图标栏：审批 / 模板 / 更多。
  List<Widget> _sidebarToolbar(BuildContext context) => [
        _approvalBadge(),
        _templatesButton(context),
        _moreMenu(context),
      ];

  /// 侧栏工具条里的「模板」入口。
  Widget _templatesButton(BuildContext context) => IconButton(
        tooltip: '模板',
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.dashboard_customize_outlined),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TemplatesPage()),
        ),
      );

  /// 侧栏工具条里的「更多」菜单。
  Widget _moreMenu(BuildContext context) => PopupMenuButton<String>(
        tooltip: '更多',
        iconSize: 20,
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.more_vert),
        onSelected: (value) {
          if (value == 'theme') {
            _toggleTheme();
            return;
          }
          _navigate(context, value);
        },
        itemBuilder: (context) {
          final mode = context.read<AppState>().config.themeMode;
          final themeIcon = switch (mode) {
            'light' => Icons.light_mode_outlined,
            'dark' => Icons.dark_mode_outlined,
            _ => Icons.brightness_auto_outlined,
          };
          final themeLabel = switch (mode) {
            'light' => '主题：亮',
            'dark' => '主题：暗',
            _ => '主题：跟随系统',
          };
          return [
            PopupMenuItem(
              value: 'search',
              child: _MoreMenuItem(
                icon: Icons.travel_explore,
                label: '手动搜索',
              ),
            ),
            PopupMenuItem(
              value: 'tools',
              child: _MoreMenuItem(
                icon: Icons.handyman_outlined,
                label: '工具管理',
              ),
            ),
            PopupMenuItem(
              value: 'pip',
              child: _MoreMenuItem(
                icon: Icons.inventory_2_outlined,
                label: 'pip 库管理',
              ),
            ),
            PopupMenuItem(
              value: 'providers',
              child: _MoreMenuItem(
                icon: Icons.cloud_outlined,
                label: '模型服务',
              ),
            ),
            PopupMenuItem(
              value: 'archive',
              child: _MoreMenuItem(
                icon: Icons.archive_outlined,
                label: '归档管理',
              ),
            ),
            PopupMenuItem(
              value: 'theme',
              child: _MoreMenuItem(
                icon: themeIcon,
                label: '$themeLabel（点击切换）',
              ),
            ),
            PopupMenuItem(
              value: 'settings',
              child: _MoreMenuItem(
                icon: Icons.settings_outlined,
                label: '设置',
              ),
            ),
            PopupMenuDivider(),
            // 最后一项显示应用版本号（只读，不可点击）。
            PopupMenuItem(
              enabled: false,
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '版本 $kAppVersionFull',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ];
        },
      );

  /// 侧边栏入口 / 溢出菜单的统一路由。
  void _navigate(BuildContext context, String destination) {
    switch (destination) {
      case 'new':
        _newSession(context);
      case 'search':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SearchPage()),
        );
      case 'templates':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TemplatesPage()),
        );
      case 'tools':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ToolsPage()),
        );
      case 'pip':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PipPackagesPage()),
        );
      case 'providers':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ProvidersPage()),
        );
      case 'archive':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ArchivePage()),
        );
      case 'settings':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsPage()),
        );
    }
  }

  /// 主题在「跟随系统 → 亮 → 暗」之间轮换。
  Future<void> _toggleTheme() async {
    final state = context.read<AppState>();
    final next = switch (state.config.themeMode) {
      'system' => 'light',
      'light' => 'dark',
      _ => 'system',
    };
    state.config.themeMode = next;
    await state.saveConfig();
    if (mounted) setState(() {});
  }

  /// 回到欢迎页（取消选中当前会话）。
  void _goHome() {
    if (_selectedId == null) return;
    setState(() {
      _selectedId = null;
      _activeTaskId = null;
    });
  }

  /// 欢迎页发起的第一轮：建会话并直接发送。
  ///
  /// [template] 非空时按模板建会话（沿用模板的系统提示词 / 模型 / 工具），
  /// [mode] 是欢迎页选择的执行模式。
  /// [projectPath] 非空时在指定文件夹下建项目，并在该项目内建会话。
  ///
  /// 会话先在内存中建好并立即切换到聊天面板，落盘在后台完成——
  /// 磁盘写入不应延迟界面切换。
  Future<void> _startSession(
    String text,
    List<MessageAttachment> attachments, {
    SessionTemplate? template,
    AgentMode mode = AgentMode.auto,
    String? projectPath,
  }) async {
    final state = context.read<AppState>();
    final path = projectPath?.trim() ?? '';
    String? projectId;
    String? sandbox;
    if (path.isNotEmpty) {
      final project = await state.ensureProjectForPath(path);
      projectId = project.id;
      sandbox = project.sandbox;
    }
    final session = template != null
        ? state.createFromTemplateDraft(
            template,
            projectId: projectId,
            sandbox: sandbox,
            mode: mode,
          )
        : state.createSessionDraft(
            mode: mode,
            projectId: projectId,
            sandbox: sandbox,
          );
    if (!mounted) {
      unawaited(state.persistSession(session));
      return;
    }
    // 立即切到新会话，落盘与首轮发送在后台继续。
    setState(() => _selectedId = session.id);
    await state.persistSession(session);
    if (text.trim().isEmpty && attachments.isEmpty) return;
    final controller = state.controllerFor(session.id);
    // 面板尚未挂载时也要能审批工具：先把全局审批队列接上（面板挂载后会
    // 覆盖成等价的处理器）。
    final center = state.approvalCenter;
    controller.approvalHandler = (tool, arguments, note) => center.request(
          sessionId: session.id,
          sessionTitle: session.title,
          tool: tool,
          arguments: arguments,
          note: note,
        );
    controller.onStop = () => center.dropForSession(session.id);
    await controller.send(text, attachments: attachments);
  }
}

/// One row of the app-bar「更多」menu: icon + label.
class _MoreMenuItem extends StatelessWidget {
  const _MoreMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}

/// 欢迎页（尚未选中会话）：品牌水印 + 问候语 + 居中输入卡 + 快捷入口。
class _WelcomeView extends StatefulWidget {
  const _WelcomeView({required this.onSend});

  /// Called with the first user message; the page creates the session.
  /// [template] 非空时按模板建会话，[mode] 是用户在欢迎页选择的执行模式，
  /// [projectPath] 非空时在指定文件夹（项目）内建会话。
  final Future<void> Function(
    String text,
    List<MessageAttachment> attachments, {
    SessionTemplate? template,
    required AgentMode mode,
    String? projectPath,
  }) onSend;

  @override
  State<_WelcomeView> createState() => _WelcomeViewState();
}

class _WelcomeViewState extends State<_WelcomeView> {
  /// True while the first session is being created — blocks a double send.
  bool _busy = false;

  /// 执行模式：建会话时生效。
  AgentMode _mode = AgentMode.auto;

  /// 指定的项目文件夹；空串 = 未指定（建全局会话）。
  String _projectPath = '';

  /// 用户在首页手动选择的会话模板；为空时用设置里的默认模板。
  SessionTemplate? _selectedTemplate;

  /// 模板选择弹窗是否打开——防止重复弹窗 / 重复发送。
  bool _asking = false;

  /// 当前生效的模板：手动选择的优先，其次是设置里的默认模板。
  SessionTemplate? _effectiveTemplate(AppState state) {
    final selected = _selectedTemplate;
    // 手动选择的模板可能已被删除——此时回落到默认模板。
    if (selected != null &&
        state.templates.any((t) => t.id == selected.id)) {
      return selected;
    }
    return state.defaultTemplate;
  }

  /// 发送第一轮对话：先确定模板，再建会话并发送。
  ///
  /// 返回 false 表示消息未被接受（缺少模板），输入框会保留草稿。
  bool _send(
    String text,
    List<MessageAttachment> attachments, {
    SessionTemplate? template,
  }) {
    if (_busy) return false;
    final state = context.read<AppState>();
    final effective = template ?? _effectiveTemplate(state);
    if (effective == null) {
      // 既没选模板，也没配置默认模板：让用户先选一个。
      if (!_asking) unawaited(_askTemplate(text, attachments));
      return false;
    }
    setState(() => _busy = true);
    unawaited(
      widget
          .onSend(
            text,
            attachments,
            template: effective,
            mode: _mode,
            projectPath: _projectPath,
          )
          .whenComplete(() {
        if (mounted) setState(() => _busy = false);
      }),
    );
    return true;
  }

  /// 未选模板时的提示：列出可选模板，或跳到设置里配置默认模板。
  ///
  /// 直接在弹窗里选模板后立即用该模板重发本次消息。
  Future<void> _askTemplate(
    String text,
    List<MessageAttachment> attachments,
  ) async {
    final state = context.read<AppState>();
    if (!mounted) return;
    final pageContext = context;
    setState(() => _asking = true);
    final picked = await showDialog<Object>(
      context: pageContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('请先选择会话模板'),
        // 模板数量不定，内容必须可滚动，否则会溢出弹窗。
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('发送对话需要一个会话模板：请选择一个模板，或在「设置」里配置默认会话模板。'),
              const SizedBox(height: 12),
              if (state.templates.isEmpty)
                const Text('当前还没有任何会话模板，请先到「模板」页创建。')
              else
                for (final template in state.templates)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      template.name.isEmpty ? '(未命名模板)' : template.name,
                    ),
                    onTap: () => Navigator.of(dialogContext).pop(template),
                  ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(_goToSettings),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    setState(() => _asking = false);
    if (picked == _goToSettings) {
      // 去设置里配置默认会话模板。
      if (!pageContext.mounted) return;
      await Navigator.of(pageContext).push(
        MaterialPageRoute(builder: (_) => const SettingsPage()),
      );
      return;
    }
    if (picked is! SessionTemplate) return;
    setState(() => _selectedTemplate = picked);
    _send(text, attachments, template: picked);
  }

  /// Dialog result that asks the caller to open the settings page.
  static const _goToSettings = '__go_to_settings__';

  /// 快捷会话：模板页开启了「快捷会话」的模板。
  List<SessionTemplate> _quickTemplates(AppState state) =>
      state.templates.where((t) => t.quickEnabled).toList();

  /// 选中模板（手动选择优先于设置里的默认模板），并刷新界面。
  void _selectTemplate(SessionTemplate? template) {
    setState(() => _selectedTemplate = template);
  }

  /// 按时段问候，跟参考界面一致。
  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 6) return '夜深了';
    if (hour < 11) return '早上好呀';
    if (hour < 14) return '中午好呀';
    if (hour < 18) return '下午好呀';
    return '晚上好呀';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = context.watch<AppState>();
    final quickTemplates = _quickTemplates(state);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(
                child: BrandMark.outline(
                  size: 168,
                  color: scheme.outlineVariant.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '$_greeting，接下来交给我吧',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '描述你的需求，XChat 会调用工具完成剩下的事',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 26),
              InputArea(
                onSend: (text, attachments) => _send(text, attachments),
                onStop: () {},
                running: _busy,
                mode: _mode,
                onModeChanged: (value) => setState(() => _mode = value),
                hint: '描述你的任务，例如「帮我修复这个报错」',
                afterMode: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TemplatePicker(
                      selected: _selectedTemplate,
                      defaultTemplate: state.defaultTemplate,
                      onChanged: _selectTemplate,
                    ),
                    const SizedBox(width: 6),
                    _ProjectFolderPicker(
                      path: _projectPath,
                      onChanged: (path) => setState(() => _projectPath = path),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (quickTemplates.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final template in quickTemplates)
                      ActionChip(
                        avatar: Icon(
                          Icons.bolt,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        label: Text(
                          template.name.isEmpty ? '(未命名模板)' : template.name,
                        ),
                        // 快捷会话只是「选中模板」：真正的会话在发送消息时创建。
                        onPressed: () => _selectTemplate(template),
                        backgroundColor:
                            _selectedTemplate?.id == template.id
                                ? scheme.primary.withValues(alpha: 0.12)
                                : scheme.surfaceContainerLowest,
                        side: BorderSide(
                          color: _selectedTemplate?.id == template.id
                              ? scheme.primary
                              : scheme.outlineVariant,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMedium),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mobile chat page that resolves the session from the store by id.
class _MobileChatPage extends StatefulWidget {
  const _MobileChatPage({required this.sessionId});

  final String sessionId;

  @override
  State<_MobileChatPage> createState() => _MobileChatPageState();
}

class _MobileChatPageState extends State<_MobileChatPage> {
  /// Session info / model selector header is hidden by default on mobile to
  /// reclaim vertical space; toggled from the top bar.
  bool _showInfo = false;

  /// 任务式会话：当前打开的任务项（空 = 任务列表）。
  String? _activeTaskId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final session = state.sessionById(widget.sessionId);
    final taskId = session?.isTaskSession == true ? _activeTaskId : null;
    if (session != null && session.isTaskSession && taskId == null) {
      final controller = state.controllerFor(session.id);
      return Scaffold(
        appBar: AppBar(
          title: Text(session.title.isNotEmpty ? session.title : '任务式会话'),
        ),
        body: TaskListView(
          session: session,
          running: controller.isRunning,
          runningTaskId: controller.runningTaskId,
          onOpenTask: (id) => setState(() => _activeTaskId = id),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(session?.title.isNotEmpty == true ? session!.title : '会话'),
        actions: [
          IconButton(
            tooltip: '会话信息 / 模型 / 思考设置',
            icon: Icon(_showInfo ? Icons.info : Icons.info_outline),
            onPressed: () => setState(() => _showInfo = !_showInfo),
          ),
        ],
      ),
      body: session == null
          ? const Center(child: Text('会话不存在'))
          : SessionChatPanel(
              key: ValueKey(session.id),
              sessionId: session.id,
              taskId: taskId,
              onBackToTasks: () => setState(() => _activeTaskId = null),
              showHeader: _showInfo,
              mobileLayout: true,
              onCompressCompleted: (id) {
                final state = context.read<AppState>();
                final created = state.sessionById(id);
                if (created != null) {
                  Navigator.of(context).pushReplacement(MaterialPageRoute(
                    builder: (_) => _MobileChatPage(sessionId: id),
                  ));
                }
              },
            ),
    );
  }
}

/// Left sidebar: global (standalone) sessions on top, then each project with
/// its own sessions nested underneath — so project sessions never mix into the
/// global list and are visually tied to their project.
/// Left sidebar: brand + navigation on top, then global (standalone) sessions
/// and each project with its own sessions nested underneath — so project
/// sessions never mix into the global list and are visually tied to their
/// project.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.sessions,
    required this.projects,
    required this.selectedId,
    required this.runningIds,
    required this.onSelect,
    required this.onNewSession,
    required this.onNewProject,
    required this.tagFilter,
    required this.onTagToggle,
    required this.globalSessionsExpanded,
    required this.onGlobalExpandedChanged,
    required this.onRefreshSessions,
    required this.refreshingSessions,
    this.bottomInset = 0,
    this.onEditProject,
    this.onNavigate,
    this.onGoHome,
    this.toolbarActions = const [],
  });

  final List<Session> sessions;
  final List<Project> projects;
  final String? selectedId;

  /// Ids of sessions whose agent turn is running (shown with a spinner).
  final Set<String> runningIds;
  final void Function(String id) onSelect;
  final void Function(String? projectId) onNewSession;
  final VoidCallback onNewProject;
  final Set<String> tagFilter;
  final void Function(String tag) onTagToggle;
  final bool globalSessionsExpanded;
  final void Function(bool expanded) onGlobalExpandedChanged;

  /// Re-lists sessions from disk (manual refresh button in the header).
  final VoidCallback onRefreshSessions;

  /// Whether the refresh is running — swaps the icon for a spinner.
  final bool refreshingSessions;

  /// Extra space reserved at the end of the list so the floating
  /// 「新建会话」button never covers the last rows.
  final double bottomInset;
  final void Function(Project project)? onEditProject;

  /// Sidebar quick entries (new / search / templates / tools / …).
  final void Function(String destination)? onNavigate;

  /// Back to the welcome page (clears the selected session).
  final VoidCallback? onGoHome;

  /// 侧栏底部右侧的工具图标栏（审批 / 模板 / 更多）。
  final List<Widget> toolbarActions;

  /// 侧栏快捷入口（其余页面入口在顶部工具条与「更多」菜单里）。
  static const _navEntries =
      <({IconData icon, String label, String? shortcut, String id})>[
    (
      icon: Icons.add_comment_outlined,
      label: '新建会话',
      shortcut: 'Ctrl+N',
      id: 'new'
    ),
  ];

  bool _matchesFilter(Session session) =>
      tagFilter.isEmpty || session.tags.any(tagFilter.contains);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visible = sessions.where(_matchesFilter).toList();
    final global = visible.where((s) => s.projectId.isEmpty).toList();
    final allTags = <String>{
      for (final s in sessions) ...s.tags.where((t) => t.trim().isNotEmpty),
    }.toList()
      ..sort();

    // 用 Material 而不是 ColoredBox：ListTile / ExpansionTile 的选中底色与
    // 水波纹会画在最近的 Material 祖先上，中间夹一层 ColoredBox 会让它们
    // 被遮住（Flutter 会断言告警）。
    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          _brandRow(context, theme),
          _navList(context, theme),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: ListView(
              // Keep the trailing rows clear of the floating「新建会话」button.
              padding: EdgeInsets.only(bottom: bottomInset),
              children: [
                // ---- 标签筛选 ------------------------------------------
                if (allTags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('#', style: theme.textTheme.labelSmall),
                        for (final tag in allTags)
                          FilterChip(
                            label: Text(tag, style: theme.textTheme.labelSmall),
                            selected: tagFilter.contains(tag),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onSelected: (_) => onTagToggle(tag),
                          ),
                      ],
                    ),
                  ),
                // ---- 全局会话 ------------------------------------------
                ExpansionTile(
                  initiallyExpanded: globalSessionsExpanded,
                  onExpansionChanged: onGlobalExpandedChanged,
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  childrenPadding: const EdgeInsets.only(left: 4),
                  leading: const Icon(Icons.public_outlined, size: 20),
                  title: const Text('全局会话'),
                  children: [
                    for (final session in global)
                      _SessionTile(
                        session: session,
                        selected: session.id == selectedId,
                        running: runningIds.contains(session.id),
                        indent: 12,
                        leading: const Icon(Icons.chat_bubble_outline, size: 20),
                        onTap: () => onSelect(session.id),
                      ),
                    if (global.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(44, 4, 16, 8),
                        child: Text(
                          '暂无全局会话',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                  ],
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                // ---- 项目 ----------------------------------------------
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
                  child: Row(
                    children: [
                      Text(
                        '项目',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '新建项目',
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.create_new_folder_outlined),
                        onPressed: onNewProject,
                      ),
                    ],
                  ),
                ),
                for (final project in projects)
                  _ProjectGroup(
                    project: project,
                    sessions:
                        visible.where((s) => s.projectId == project.id).toList(),
                    selectedId: selectedId,
                    runningIds: runningIds,
                    onSelect: onSelect,
                    onNewSession: () => onNewSession(project.id),
                    onEdit: () => onEditProject?.call(project),
                    onArchive: () =>
                        context.read<AppState>().setProjectArchived(project.id, true),
                    onDelete: () async {
                      final ok = await confirmDelete(
                        context,
                        '项目「${project.name.isEmpty ? project.id : project.name}」',
                      );
                      if (ok && context.mounted) {
                        await context
                            .read<AppState>()
                            .deleteProject(project.id);
                      }
                    },
                  ),
                if (projects.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Text('暂无项目', style: TextStyle(color: Colors.grey)),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          _bottomRow(context, theme),
        ],
      ),
    );
  }

  /// 品牌行：徽标 + 应用名 + 新建会话。
  Widget _brandRow(BuildContext context, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Row(
        children: [
          const BrandMark.solid(size: 26),
          const SizedBox(width: 10),
          Text(
            'XChat',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '刷新会话列表',
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            icon: refreshingSessions
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: refreshingSessions ? null : onRefreshSessions,
          ),
          IconButton(
            tooltip: '回到首页',
            icon: const Icon(Icons.home_outlined),
            onPressed: onGoHome,
          ),
        ],
      ),
    );
  }

  /// 快捷入口列表（新建会话；其余入口在顶部工具条与「更多」菜单里）。
  Widget _navList(BuildContext context, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        children: [
          for (final entry in _navEntries)
            _NavRow(
              icon: entry.icon,
              label: entry.label,
              shortcut: entry.shortcut,
              onTap: () => onNavigate?.call(entry.id),
            ),
        ],
      ),
    );
  }

  /// 底部条：品牌 + 工具图标栏（审批 / 模板 / 更多）。
  Widget _bottomRow(BuildContext context, ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
      child: Row(
        children: [
          const BrandMark.solid(size: 20),
          const SizedBox(width: 8),
          Text(
            'XChat',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          ...toolbarActions,
        ],
      ),
    );
  }
}

/// 侧边栏里的一行快捷入口：图标 + 名称（+ 快捷键提示）。
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.shortcut,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          hoverColor: scheme.onSurface.withValues(alpha: 0.05),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Text(label, style: theme.textTheme.bodyMedium),
                const Spacer(),
                if (shortcut != null)
                  Text(
                    shortcut!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A project row that expands to reveal its own sessions.
class _ProjectGroup extends StatelessWidget {
  const _ProjectGroup({
    required this.project,
    required this.sessions,
    required this.selectedId,
    required this.runningIds,
    required this.onSelect,
    required this.onNewSession,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
  });

  final Project project;
  final List<Session> sessions;
  final String? selectedId;
  final Set<String> runningIds;
  final void Function(String id) onSelect;
  final VoidCallback onNewSession;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: false,
      dense: true,
      visualDensity: VisualDensity.compact,
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: const Icon(Icons.folder_outlined, size: 20),
      title: Text(
        project.name.isEmpty ? '(未命名项目)' : project.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '在项目中新建会话',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add),
            onPressed: onNewSession,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  onEdit();
                case 'archive':
                  onArchive();
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'archive', child: Text('归档')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
      children: [
        for (final session in sessions)
          _SessionTile(
            session: session,
            selected: session.id == selectedId,
            running: runningIds.contains(session.id),
            indent: 28,
            leading: const Icon(Icons.forum_outlined, size: 18),
            onTap: () => onSelect(session.id),
          ),
        if (sessions.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(44, 4, 16, 4),
            child: Text('暂无会话', style: TextStyle(color: Colors.grey)),
          ),
      ],
    );
  }
}

/// A single session row with its context menu.
class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.selected,
    required this.leading,
    required this.onTap,
    this.indent = 0,
    this.running = false,
  });

  final Session session;
  final bool selected;
  final Widget leading;
  final VoidCallback onTap;
  final double indent;

  /// Whether the session's agent turn is running — replaces [leading] with a
  /// spinning progress ring so an in-progress session is visible at a glance.
  final bool running;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      selected: selected,
      contentPadding: EdgeInsets.only(left: 16 + indent, right: 8),
      minVerticalPadding: 0,
      leading: running
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            )
          : leading,
      title: Row(
        children: [
          if (session.isTaskSession) ...[
            Icon(Icons.checklist, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              session.title.isNotEmpty ? session.title : '(未命名会话)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (session.isTaskSession && session.tasks.isNotEmpty)
            Text(
              '${session.tasks.where((t) => t.done).length}/${session.tasks.length}',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      trailing: _SessionMenu(session: session, state: context.read<AppState>()),
      onTap: onTap,
    );
  }
}

class _SessionMenu extends StatelessWidget {
  const _SessionMenu({required this.session, required this.state});

  final Session session;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      onSelected: (value) => _handle(context, value),
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'info', child: Text('查看会话信息')),
        PopupMenuItem(value: 'rename', child: Text('重命名')),
        PopupMenuItem(value: 'tags', child: Text('编辑标签')),
        PopupMenuItem(value: 'autoname', child: Text('AI 自动命名')),
        PopupMenuItem(value: 'clone_empty', child: Text('克隆（到首轮之前）')),
        PopupMenuItem(value: 'clone_first', child: Text('克隆（含首次对话）')),
        PopupMenuItem(value: 'clone_full', child: Text('克隆（完整会话）')),
        PopupMenuItem(value: 'edit_xml', child: Text('用编辑工具打开')),
        PopupMenuItem(value: 'open_dir', child: Text('打开工作目录')),
        PopupMenuItem(value: 'archive', child: Text('归档')),
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
  }

  Future<void> _handle(BuildContext context, String action) async {
    switch (action) {
      case 'info':
        await _showSessionInfo(context);
      case 'rename':
        final text = await _prompt(context, '重命名', session.title);
        if (text != null && text.trim().isNotEmpty) {
          await state.renameSession(session.id, text.trim());
        }
      case 'tags':
        await _editTags(context);
      case 'autoname':
        await _autoName(context);
      case 'clone_empty':
        final clone = await state.cloneSession(session);
        if (context.mounted) _toast(context, '已克隆为 ${clone.id.substring(0, 8)}');
      case 'clone_first':
        final clone = await state.cloneSessionWithFirstTurn(session);
        if (context.mounted) _toast(context, '已克隆为 ${clone.id.substring(0, 8)}');
      case 'clone_full':
        final clone = await state.cloneSessionFull(session);
        if (context.mounted) _toast(context, '已克隆为 ${clone.id.substring(0, 8)}');
      case 'edit_xml':
        final path = AppPaths.instance.sessionFile(session.id);
        final result = await openInEditor(path, state.config.editorCommand);
        if (!context.mounted) return;
        if (!result.ok) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => XmlEditorPage(sessionId: session.id)),
          );
        } else {
          _toast(context, result.message);
        }
      case 'open_dir':
        final result = await openDirectory(session.sandbox);
        if (context.mounted) _toast(context, result.message);
      case 'archive':
        await state.setSessionArchived(session.id, true);
        if (context.mounted) _toast(context, '已归档会话');
      case 'delete':
        if (!context.mounted) return;
        final ok = await confirmDelete(
          context,
          '会话「${session.title.isNotEmpty ? session.title : session.id}」',
        );
        if (ok) await state.deleteSession(session.id);
    }
  }

  /// Edits the session's tags (comma-separated).
  Future<void> _editTags(BuildContext context) async {
    final full = await state.loadFullSession(session.id);
    if (!context.mounted) return;
    final text = await _prompt(context, '编辑标签（逗号分隔）', full.tags.join(','));
    if (text == null) return;
    final tags = text
        .split(RegExp(r'[,，]'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    await state.setSessionTags(session.id, tags);
  }

  /// Asks the app default model to name the session from its first turn's
  /// user/assistant messages.
  Future<void> _autoName(BuildContext context) async {
    _toast(context, '正在生成标题…');
    try {
      final title = await state.autoNameSession(session.id);
      if (context.mounted) _toast(context, '已重命名为「$title」');
    } catch (e) {
      if (context.mounted) _toast(context, '自动命名失败：$e');
    }
  }

  /// Shows the full session information (file path, token usage, model /
  /// thinking settings, enabled tools, system prompt, timestamps).
  Future<void> _showSessionInfo(BuildContext context) async {
    final full = await state.loadFullSession(session.id);
    if (!context.mounted) return;
    final path = AppPaths.instance.sessionFile(full.id);
    showDialog<void>(
      context: context,
      builder: (context) => SessionInfoDialog(
        session: full,
        filePath: path,
      ),
    );
  }

  static void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  static Future<String?> _prompt(BuildContext context, String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

/// 常用模板下拉：列出用户的会话模板，选中即按模板建会话。
class _TemplatePicker extends StatelessWidget {
  const _TemplatePicker({
    required this.selected,
    required this.defaultTemplate,
    required this.onChanged,
  });

  /// 用户手动选择的模板；为空时用 [defaultTemplate]。
  final SessionTemplate? selected;

  /// 设置里配置的默认模板（未配置时为空）。
  final SessionTemplate? defaultTemplate;

  /// Called with the newly selected template, or null to fall back to the
  /// default template.
  final void Function(SessionTemplate? template) onChanged;

  /// The template that will actually be used for the next session.
  SessionTemplate? _effective(List<SessionTemplate> templates) {
    final selected = this.selected;
    // 手动选择的模板可能已被删除——此时回落到默认模板。
    if (selected != null && templates.any((t) => t.id == selected.id)) {
      return selected;
    }
    return defaultTemplate;
  }

  @override
  Widget build(BuildContext context) {
    final templates = context.watch<AppState>().templates;
    final effective = _effective(templates);
    if (templates.isEmpty) {
      return const ToolbarPill(
        icon: Icons.dashboard_customize_outlined,
        label: '暂无模板',
      );
    }
    return PopupMenuButton<String>(
      tooltip: '会话模板',
      onSelected: (id) {
        if (id == _clearValue) {
          onChanged(null);
          return;
        }
        final template = templates.firstWhere(
          (t) => t.id == id,
          orElse: () => templates.first,
        );
        onChanged(template);
      },
      itemBuilder: (context) => [
        // 回到「使用默认模板」。
        if (selected != null)
          const PopupMenuItem(
            value: _clearValue,
            child: Row(
              children: [
                Icon(Icons.settings_suggest_outlined, size: 18),
                SizedBox(width: 10),
                Flexible(
                  child: Text(
                    '使用默认模板',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        for (final template in templates)
          PopupMenuItem(
            value: template.id,
            child: Row(
              children: [
                const Icon(Icons.dashboard_customize_outlined, size: 18),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    template.name.isEmpty ? '(未命名模板)' : template.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (template.id == defaultTemplate?.id)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text(
                      '默认',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
      ],
      child: ToolbarPill(
        icon: Icons.dashboard_customize_outlined,
        label: effective == null
            ? '会话模板'
            : (effective.name.isEmpty ? '(未命名模板)' : effective.name),
        trailing: true,
        active: effective != null,
      ),
    );
  }

  /// Menu value that clears the manual selection.
  static const _clearValue = '__clear__';
}

/// 项目文件夹选择器：未指定（建全局会话）或具体路径（用最后一级目录名建项目）。
///
/// 选中的路径只在建会话时落库：项目不存在时按目录名新建项目，会话建在项目内。
class _ProjectFolderPicker extends StatelessWidget {
  const _ProjectFolderPicker({required this.path, required this.onChanged});

  /// Current folder path; empty = 未指定.
  final String path;

  /// Called with the new path (empty = 未指定).
  final ValueChanged<String> onChanged;

  static const _none = '__none__';
  static const _current = '__current__';
  static const _pick = '__pick__';
  static const _input = '__input__';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final label = path.isEmpty ? '项目文件夹' : p.basename(path);
    return PopupMenuButton<String>(
      tooltip: '指定项目文件夹',
      onSelected: (value) => _handle(context, value, state),
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _none,
          child: Row(
            children: [
              Icon(Icons.public_outlined, size: 18),
              SizedBox(width: 10),
              Text('未指定（全局会话）'),
            ],
          ),
        ),
        if (path.isNotEmpty)
          PopupMenuItem(
            value: _current,
            child: Row(
              children: [
                const Icon(Icons.folder, size: 18),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(p.basename(path), overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        for (final project in state.projects)
          PopupMenuItem(
            value: 'p:${project.id}',
            child: Row(
              children: [
                const Icon(Icons.folder_outlined, size: 18),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    '${project.name.isEmpty ? '(未命名项目)' : project.name}'
                    ' · ${project.sandbox}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (state.projects.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(
          value: _pick,
          child: Row(
            children: [
              Icon(Icons.drive_folder_upload_outlined, size: 18),
              SizedBox(width: 10),
              Text('选择文件夹…'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: _input,
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 18),
              SizedBox(width: 10),
              Text('输入路径…'),
            ],
          ),
        ),
      ],
      child: ToolbarPill(
        icon: Icons.folder_outlined,
        label: label,
        trailing: true,
        active: path.isNotEmpty,
      ),
    );
  }

  /// Applies the menu choice: an existing project's folder, a freshly picked
  /// folder, a typed path, or 未指定.
  Future<void> _handle(
    BuildContext context,
    String value,
    AppState state,
  ) async {
    if (value == _none) {
      onChanged('');
      return;
    }
    if (value == _current) return;
    if (value.startsWith('p:')) {
      final id = value.substring(2);
      final project = state.projectById(id);
      if (project != null) onChanged(project.sandbox);
      return;
    }
    if (value == _pick) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      try {
        final picked = await FilePicker.getDirectoryPath(
          dialogTitle: '选择项目文件夹',
        );
        if (picked != null && picked.trim().isNotEmpty) onChanged(picked.trim());
      } catch (error) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text('选择文件夹失败：$error'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    if (value == _input) {
      final input = await _askPath(context);
      if (input != null && input.trim().isNotEmpty) onChanged(input.trim());
    }
  }

  /// 手动输入文件夹路径（跨平台可用，作为系统选择器的补充）。
  Future<String?> _askPath(BuildContext context) async {
    final controller = TextEditingController(text: path);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入项目文件夹路径'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '例如 /storage/emulated/0/Documents/demo',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }
}

/// Chat panel for one session: header, message list, live stream, input.
///
/// The panel is addressed by [sessionId] and always mirrors the live instance
/// held by [AppState] — so re-opening a session (including a project session)
/// shows the persisted conversation instead of a stale/empty copy.
class SessionChatPanel extends StatefulWidget {
  const SessionChatPanel({
    super.key,
    required this.sessionId,
    this.onCompressCompleted,
    this.showHeader = true,
    this.mobileLayout = false,
    this.taskId,
    this.onBackToTasks,
  });

  final String sessionId;

  /// Called after "compress session" created a new session (to select it).
  final ValueChanged<String>? onCompressCompleted;

  /// Whether to show the session info / model selector header. Mobile hides it
  /// by default to reclaim vertical space and toggles it from the app bar.
  final bool showHeader;

  /// 移动端布局：模型选择 / 思考开关 / 思考强度从输入栏移到顶部「i」面板里，
  /// 输入栏右侧只保留发送键——窄屏下原本这两组控件会把发送键挤出可视区。
  final bool mobileLayout;

  /// 任务式会话中当前打开的任务项；为空表示普通会话视图（显示整会话消息）。
  ///
  /// 它只影响**显示**：发给模型的历史始终是整个会话（任务项只是分组维度）。
  final String? taskId;

  /// 从任务对话返回任务列表。
  final VoidCallback? onBackToTasks;

  @override
  State<SessionChatPanel> createState() => _SessionChatPanelState();
}

class _SessionChatPanelState extends State<SessionChatPanel> {
  SessionController? _controller;
  final _scroll = ScrollController();
  final _lastUserKey = GlobalKey();
  bool _wasRunning = false;
  bool _autoNaming = false;

  @override
  void initState() {
    super.initState();
    _controller = _build();
    if (widget.taskId != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _maybeStartTask());
    }
  }

  /// 打开一个「新任务」（该任务项下还没有 assistant 回复）时，询问用户是否
  /// 立即发送：发送会把任务内容写成该任务的第一条 user 消息并跑一轮。
  Future<void> _maybeStartTask() async {
    final controller = _controller;
    final session = controller?.session;
    final taskId = widget.taskId;
    if (!mounted || controller == null || session == null || taskId == null) {
      return;
    }
    if (controller.isRunning) return;
    final task = session.taskById(taskId);
    if (task == null || session.taskHasReply(taskId)) return;
    final start = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('开始这个任务？'),
        content: Text(
          '该任务还没有回复。立即发送会把任务内容作为第一条 user 消息发出，并开始一轮对话。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后（先看任务）'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('立即发送'),
          ),
        ],
      ),
    );
    if (start != true || !mounted) return;
    await _startTask(controller, session, task);
  }

  /// Ensures the task content is the task's first `user` message, then runs a
  /// turn with the existing history (the whole session history is sent).
  Future<void> _startTask(
    SessionController controller,
    Session session,
    TaskItem task,
  ) async {
    final hasUser = session
        .taskMessages(task.id)
        .any((m) => m.role == MessageRole.user);
    if (!hasUser) {
      session.messages.add(SessionMessage(
        role: MessageRole.user,
        id: newShortId(),
        content: task.promptText,
        taskId: task.id,
      ));
      session.updatedAt = DateTime.now();
      await controller.save();
    }
    if (!mounted) return;
    await controller.resend(taskId: task.id);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final live = context.watch<AppState>().sessionById(widget.sessionId);
    final current = _controller?.session;
    // Adopt a refreshed instance (e.g. after reload) unless we are mid-stream:
    // a running turn keeps mutating (and persisting) the instance it started
    // with, so swapping it out mid-run would detach the engine's state.
    if (live != null &&
        !identical(live, current) &&
        !(_controller?.isRunning ?? false)) {
      _controller?.open(live);
      setState(() {});
    }
  }

  SessionController _build() {
    // The controller is owned by AppState (keyed by session id), so it — and
    // the agent turn it drives — survives the panel being swapped out when
    // switching sessions: multiple sessions can run at the same time.
    final controller = context.read<AppState>().controllerFor(widget.sessionId);
    // Captured here (not via `context` in the handler): the engine keeps
    // running — and asking for approval — after this panel is disposed, and a
    // disposed State's `context` can no longer be touched.
    final center = context.read<AppState>().approvalCenter;
    controller.approvalHandler = (tool, arguments, note) =>
        _requestApproval(center, tool, arguments, note);
    controller.onStop = () => center.dropForSession(widget.sessionId);
    controller.addListener(_onChange);
    return controller;
  }

  /// Forwards the engine's approval ask to the global [ApprovalCenter].
  ///
  /// The prompt is deliberately not tied to this panel: switching to another
  /// session disposes the panel, so a per-session dialog would strand — and
  /// silently deny — the background session's approval. The center keeps the
  /// request pending until the user resolves it from the global approval
  /// window, whichever session is visible.
  Future<bool> _requestApproval(
    ApprovalCenter center,
    String tool,
    String arguments,
    String? note,
  ) {
    return center.request(
      sessionId: widget.sessionId,
      sessionTitle: _controller?.session?.title ?? '',
      tool: tool,
      arguments: arguments,
      note: note,
    );
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    final running = _controller?.isRunning ?? false;
    // When the stream ends, the assistant message switches from plain streaming
    // text to full markdown — whose layout (code highlighting, wrapping) settles
    // over the next frames. Re-pin to the bottom across those frames so the view
    // stays on the freshly finished reply.
    _scheduleScrollToBottom(settle: _wasRunning && !running);
    // 第一轮对话结束时，若标题仍为空则由会话模型自动命名。
    if (_wasRunning && !running) _maybeAutoName();
    _wasRunning = running;
  }

  /// Titles a still-untitled session from its first turn on the session's own
  /// model (one attempt per turn end; a failed attempt is retried later).
  Future<void> _maybeAutoName() async {
    if (_autoNaming || !mounted) return;
    final session = _controller?.session;
    if (session == null || session.title.trim().isNotEmpty) return;
    _autoNaming = true;
    final state = context.read<AppState>();
    try {
      await state.autoNameFirstTurn(session.id);
    } catch (_) {
      _autoNaming = false;
    }
  }

  void _scheduleScrollToBottom({bool settle = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    if (!settle) return;
    // Once the stream ends, re-pin to the bottom across the following frames so
    // the markdown layout (code highlighting, wrapping) settling doesn't leave
    // the view stranded above the reply.
    for (final ms in const [80, 200, 400, 700]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (mounted) _scrollToBottom();
      });
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  /// Guards a scroll action: message text (markdown) must be fully laid out
  /// first. If it is still loading (or a turn is streaming), tells the user to
  /// wait and retry instead of scrolling to a stale position.
  Future<void> _guardedScroll(Future<void> Function() action) async {
    if (!_scroll.hasClients) return;
    if ((_controller?.isRunning ?? false) || !await _contentSettled()) {
      _notifyNotReady();
      return;
    }
    await action();
  }

  /// Waits until the list's extent stops changing across a couple of frames —
  /// i.e. asynchronous rendering (markdown, code highlighting, images) is done.
  Future<bool> _contentSettled() async {
    double? previous;
    var stableFrames = 0;
    for (var i = 0; i < 10; i++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scroll.hasClients) return false;
      final current = _scroll.position.maxScrollExtent;
      if (previous != null && (current - previous).abs() < 0.5) {
        if (++stableFrames >= 2) return true;
      } else {
        stableFrames = 0;
      }
      previous = current;
    }
    return false;
  }

  void _notifyNotReady() {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('消息内容仍在加载渲染中，请稍候完成后再操作一次'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Returns the viewport to the top of the most recent user message, so the
  /// reply is read from its start.
  ///
  /// The message list is lazy, so on a re-opened session the target may not be
  /// built yet: snap to the bottom first (laying out the tail items), then walk
  /// upward until it appears, and finally align its top to the viewport top.
  Future<void> _scrollToLastUser() async {
    if (!_scroll.hasClients) return;
    // A freshly-opened list may not have resolved its metrics yet; without this
    // `maxScrollExtent` reads 0 and the snap below becomes a no-op.
    for (var i = 0;
        i < 4 && _scroll.hasClients && _scroll.position.viewportDimension == 0;
        i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!_scroll.hasClients) return;

    var box = _lastUserBox();
    if (box == null) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      await WidgetsBinding.instance.endOfFrame;
      box = _lastUserBox();
    }
    if (box == null) {
      final step = _scroll.position.viewportDimension * 0.8;
      var offset = _scroll.position.pixels;
      while (box == null && offset > 0 && mounted) {
        offset = (offset - step).clamp(0.0, _scroll.position.maxScrollExtent);
        _scroll.jumpTo(offset);
        await WidgetsBinding.instance.endOfFrame;
        box = _lastUserBox();
      }
    }
    if (box == null) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final target = viewport
        .getOffsetToReveal(box, 0.0)
        .offset
        .clamp(0.0, _scroll.position.maxScrollExtent);
    await _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  RenderBox? _lastUserBox() {
    final box = _lastUserKey.currentContext?.findRenderObject();
    return (box is RenderBox && box.hasSize) ? box : null;
  }

  @override
  void dispose() {
    // The controller belongs to AppState and outlives this panel — only the
    // listener is removed here so a background turn keeps running after the
    // user switches to another session.
    _controller?.removeListener(_onChange);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final session = controller?.session;
    if (controller == null || session == null) {
      return const Center(child: Text('会话不存在'));
    }
    // 任务式会话只看当前任务项的消息；普通会话（taskId 为空）看全部。
    final messages = session.messages
        .where((m) =>
            m.role != MessageRole.system &&
            (widget.taskId == null || m.taskId == widget.taskId))
        .toList(growable: false);
    final lastUserIndex =
        SessionOps.lastUserIndex(session, onlyTaskId: widget.taskId);
    // 同一会话串行执行：只有本视图所属任务在运行时才显示流式区。
    final live = controller.isRunning && controller.runningTaskId == widget.taskId;

    return Column(
      children: [
        if (widget.taskId != null) ...[
          TaskChatHeader(
            session: session,
            taskId: widget.taskId!,
            running: controller.isRunning,
            onBack: widget.onBackToTasks,
          ),
          const Divider(height: 1),
        ],
        if (widget.showHeader) ...[
          _Header(controller: controller, showControls: widget.mobileLayout),
          const Divider(height: 1),
        ],
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            itemCount: messages.length + (live ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= messages.length) {
                return _LiveStream(controller: controller);
              }
              final message = messages[index];
              final globalIndex = session.messages.indexOf(message);
              final isLastUser = globalIndex == lastUserIndex;
              return Padding(
                key: isLastUser ? _lastUserKey : null,
                padding: const EdgeInsets.only(bottom: 16),
                child: MessageBubble(
                  message: message,
                  isLastUser: isLastUser,
                  onEdit: () => _editLastUser(context, session),
                  onDelete: () async {
                    final ok = await confirmDelete(context, '这条消息');
                    if (!ok) return;
                    SessionOps.deleteMessage(session, globalIndex);
                    await controller.save();
                    if (mounted) setState(() {});
                  },
                ),
              );
                },
              ),
            ),
          ),
        ),
        if (controller.error != null || controller.notice != null)
          _StatusBar(
            text: controller.error ?? controller.notice!,
            isError: controller.error != null,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: InputArea(
            running: controller.isRunning,
            onSend: (text, attachments) {
              controller.send(
                text,
                attachments: attachments,
                taskId: widget.taskId,
              );
              return true;
            },
            onStop: controller.stop,
            mode: session.mode,
            onModeChanged: (value) => controller.setMode(value),
            maxAttachmentBytes:
                context.watch<AppState>().config.maxAttachmentBytes,
            webSearchAvailable: session.tools.contains('web_search'),
            webSearchEnabled: session.webSearchEnabled,
            onWebSearchChanged: (value) => controller.setWebSearch(value),
            onCompress: _compressSession,
            onScrollToRecent: () => _guardedScroll(_scrollToLastUser),
            onScrollToBottom: () => _guardedScroll(() async => _scrollToBottom()),
            trailing: widget.mobileLayout
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ModelSelector(controller: controller),
                      const SizedBox(width: 6),
                      _ReasoningControls(controller: controller),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  /// Compress flow: pick/enter a prompt, call the LLM, create a new session
  /// with the compressed context as the first user/assistant pair.
  Future<void> _compressSession() async {
    final controller = _controller;
    final session = controller?.session;
    if (controller == null || session == null || controller.isRunning) return;
    final prompt = await showCompressDialog(context, session);
    if (prompt == null || !mounted) return;
    final state = context.read<AppState>();
    final cancel = llm.CancelToken();
    final progress = ValueNotifier<String>('');
    var dialogVisible = true;
    var progressDead = false;
    // Show a progress dialog streaming the compressed text so the user can
    // follow (and cancel) the compression work. The notifier is disposed only
    // once the route is gone — disposing while the dialog is still on screen
    // would break its listener and abort the rest of the flow.
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _CompressProgressDialog(
          progress: progress,
          onCancel: () {
            cancel.cancel();
            Navigator.of(dialogContext).pop();
          },
        ),
      ).whenComplete(() {
        dialogVisible = false;
        progressDead = true;
        progress.dispose();
      }),
    );
    // Live partial text from the compressor stream, shown in the dialog.
    try {
      final created = await state.compressSession(
        session.id,
        prompt,
        onProgress: (text) {
          if (!progressDead) progress.value = text;
        },
        cancel: cancel,
      );
      await state.refreshSessions();
      if (dialogVisible && mounted) Navigator.of(context).pop();
      if (!mounted) return;
      widget.onCompressCompleted?.call(created.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已创建并保存压缩会话「${created.title}」')),
      );
    } catch (error) {
      if (dialogVisible && mounted) Navigator.of(context).pop();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(cancel.isCancelled ? '已取消压缩' : '压缩失败：$error')),
      );
    }
  }

  Future<void> _editLastUser(BuildContext context, Session session) async {
    final index = SessionOps.lastUserIndex(session, onlyTaskId: widget.taskId);
    if (index < 0) return;
    final controller = TextEditingController(text: session.messages[index].content ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑最近一次用户消息（将重发）'),
        content: SizedBox(
          width: 520,
          child: TextField(controller: controller, maxLines: 8, minLines: 3),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存并重发'),
          ),
        ],
      ),
    );
    if (text == null) return;
    if (SessionOps.editLastUser(session, text, onlyTaskId: widget.taskId)) {
      await _controller?.resend(taskId: widget.taskId);
      setState(() {});
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller, this.showControls = false});

  final SessionController controller;

  /// 移动端布局：模型选择与思考开关并入本面板（输入栏没有横向空间）。
  final bool showControls;

  @override
  Widget build(BuildContext context) {
    final session = controller.session!;
    final usage = controller.cumulativeUsage;
    final contextWindow = controller.activeProvider.contextWindowFor(session.model);
    final contextTokens = controller.contextTokens;
    final ratio = (contextWindow != null && contextWindow > 0 && contextTokens != null)
        ? (contextTokens / contextWindow).clamp(0.0, 1.0)
        : null;
    final showControls = this.showControls;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  session.title.isNotEmpty ? session.title : '(未命名会话)',
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              UsageBadge(usage: usage, contextTokens: contextTokens),
              const Spacer(),
              Text(
                '工具 ${session.toolCalls}/${session.toolCallsLimit == 0 ? '禁用' : session.toolCallsLimit}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
          if (ratio != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: ratio, minHeight: 4),
            ),
          ],
          // 移动端：模型选择 / 思考开关 / 思考强度放在这里，输入栏只留发送。
          if (showControls) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _ModelSelector(controller: controller),
                _ReasoningControls(controller: controller),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelSelector extends StatelessWidget {
  const _ModelSelector({required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final session = controller.session!;
    final provider = controller.activeProvider;
    final models = <String>{
      ...provider.models,
      if (session.model.isNotEmpty) session.model,
    }.toList();
    final label = session.model.isNotEmpty ? session.model : provider.name;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final full = '${provider.name} · $label';
    if (models.isEmpty) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Text(
          full,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return PopupMenuButton<String>(
      tooltip: '切换模型（限同一提供商）',
      onSelected: (value) => controller.setModel(value),
      itemBuilder: (context) => [
        for (final model in models)
          CheckedPopupMenuItem(
            value: model,
            checked: model == session.model,
            child: Text(model),
          ),
      ],
      child: Tooltip(
        message: full,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.memory, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  full,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 16, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 思考开关 + 思考强度：与模型选择并排，改动后写回会话文件
/// （`meta/params/thinking` 与 `meta/params/reasoning_effort`）。
///
/// 两个控件都做成紧凑的图标按钮：桌面端它们位于输入区工具栏右侧，移动端则
/// 移到顶部「i」信息面板里（窄屏工具栏放不下，会把发送键挤出可视区）。
class _ReasoningControls extends StatelessWidget {
  const _ReasoningControls({required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    // 服务配置（「同步思考强度」的档位）存在 AppState 里：订阅一下，同步完就
    // 立刻换菜单，而不是等父级因为别的原因重建。
    context.watch<AppState>();
    final session = controller.session;
    if (session == null) return const SizedBox.shrink();
    final params = session.params;
    final efforts = _effortOptions(session);
    final effort = params.reasoningEffort ?? '';
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<ThinkingSwitch>(
          tooltip: '思考开关：${_thinkingLabel(params.thinking)}',
          onSelected: (value) => controller.setThinking(value),
          itemBuilder: (context) => [
            for (final value in ThinkingSwitch.values)
              CheckedPopupMenuItem(
                value: value,
                checked: value == params.thinking,
                child: Text(_thinkingLabel(value)),
              ),
          ],
          child: _ReasoningIcon(
            icon: _thinkingIcon(params.thinking),
            active: params.thinking == ThinkingSwitch.on,
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (efforts.isNotEmpty)
          PopupMenuButton<String>(
            tooltip: '思考强度：${effort.isEmpty ? '默认（不传入）' : effort}'
                ' · 最大输出tokens：${_maxTokensLabel(session)}',
            onSelected: (value) => controller.setReasoningEffort(value),
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: '',
                checked: effort.isEmpty,
                child: const Text('默认（不传入）'),
              ),
              for (final value in efforts)
                CheckedPopupMenuItem(
                  value: value,
                  checked: value == effort,
                  child: Text(value),
                ),
            ],
            child: _ReasoningIcon(
              icon: Icons.tune,
              active: effort.isNotEmpty,
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  static String _thinkingLabel(ThinkingSwitch value) => switch (value) {
        ThinkingSwitch.auto => 'auto（由模型决定）',
        ThinkingSwitch.on => 'on（开启思考）',
        ThinkingSwitch.off => 'off（关闭思考）',
      };

  static IconData _thinkingIcon(ThinkingSwitch value) => switch (value) {
        ThinkingSwitch.on => Icons.psychology,
        ThinkingSwitch.off => Icons.psychology_outlined,
        ThinkingSwitch.auto => Icons.auto_awesome,
      };

  /// 思考强度选项：服务开启「同步思考强度」且有同步值时用同步档位，否则用
  /// 会话模板 `reasoning_effort` 的全部候选值（见 [reasoningEffortOptionsFor]）。
  List<String> _effortOptions(Session session) =>
      reasoningEffortOptionsFor(controller.activeProvider, session.model);

  /// 当前会话生效的输出上限：会话（模板）里显式指定的值优先，否则用模型服务
  /// 的配置（可按思考档位取值）。`null` = 不限制。
  String _maxTokensLabel(Session session) {
    final value = session.params.maxTokens ??
        controller.activeProvider.maxOutputTokensFor(session.params.reasoningEffort);
    return value == null ? '不限制' : '$value';
  }
}

/// 思考控件用的紧凑图标按钮（32×32）。
class _ReasoningIcon extends StatelessWidget {
  const _ReasoningIcon({
    required this.icon,
    required this.active,
    required this.color,
  });

  final IconData icon;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active
            ? scheme.primary.withValues(alpha: 0.12)
            : scheme.surfaceContainerHigh.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Icon(icon, size: 17, color: active ? scheme.primary : color),
    );
  }
}

class _LiveStream extends StatelessWidget {
  const _LiveStream({required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final reasoning = controller.streamReasoning;
    final content = controller.streamContent;
    final calls = controller.liveToolCalls;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (reasoning.isNotEmpty)
            ThinkingBlock(text: reasoning, streaming: true, initiallyExpanded: true),
          if (calls.isNotEmpty) ToolCallBlock(calls: calls),
          if (content.isNotEmpty)
            DefaultTextStyle(
              style: Theme.of(context).textTheme.bodyMedium!,
              child: Text(content),
            ),
          if (reasoning.isEmpty && content.isEmpty && calls.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.text, required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: isError
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.secondaryContainer.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: isError ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T item) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}

/// Non-dismissible progress dialog shown while a session is being compressed.
/// Streams the partial compressed text so the user can follow the work, with a
/// cancel button that aborts the underlying LLM request.
class _CompressProgressDialog extends StatelessWidget {
  const _CompressProgressDialog({required this.progress, required this.onCancel});

  final ValueNotifier<String> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          const Text('正在压缩会话…'),
        ],
      ),
      content: SizedBox(
        width: 480,
        height: 260,
        child: ValueListenableBuilder<String>(
          valueListenable: progress,
          builder: (context, text, _) {
            if (text.isEmpty) {
              return const Center(child: Text('正在生成压缩摘要…'));
            }
            return SingleChildScrollView(
              child: SelectableText(text),
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: onCancel, child: const Text('取消')),
      ],
    );
  }
}

/// Global tool-approval window: a list column of every pending request (from
/// all sessions) beside a detail pane for the selected one.
///
/// The dialog watches [ApprovalCenter], so requests that arrive while it is
/// open are appended to the list, and it auto-closes once the queue drains.
class _ApprovalDialog extends StatefulWidget {
  const _ApprovalDialog({this.onDismissed});

  /// Called when the user picks 稍后处理, before the window closes, so the
  /// page can suppress auto-reopen until the next new request arrives.
  final VoidCallback? onDismissed;

  @override
  State<_ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<_ApprovalDialog> {
  late final ApprovalCenter _center;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _center = context.read<AppState>().approvalCenter;
    _center.addListener(_onCenterChanged);
    _selectedId = _center.pending.isNotEmpty ? _center.pending.first.id : null;
  }

  void _onCenterChanged() {
    if (!mounted) return;
    setState(() {
      final pending = _center.pending;
      if (pending.isEmpty) {
        // Everything resolved — nothing left to review.
        _selectedId = null;
        Navigator.of(context).pop();
        return;
      }
      // Keep a valid selection: follow the selected request out, else fall
      // back to the oldest pending one.
      if (_selectedId == null || !pending.any((r) => r.id == _selectedId)) {
        _selectedId = pending.first.id;
      }
    });
  }

  @override
  void dispose() {
    _center.removeListener(_onCenterChanged);
    super.dispose();
  }

  ApprovalRequest? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final r in _center.pending) {
      if (r.id == id) return r;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = _center.pending;
    final selected = _selected;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.fact_check_outlined, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text('工具审批（${pending.length} 项待处理）'),
        ],
      ),
      content: SizedBox(
        // Upper bounds only: parents tighten these on small screens, and the
        // LayoutBuilder below adapts the list/detail layout to the width.
        width: 640,
        height: 380,
        child: pending.isEmpty
            ? const Center(child: Text('暂无待处理的审批'))
            : LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 560;
                  final list = _ApprovalList(
                    requests: pending,
                    selectedId: _selectedId,
                    onSelect: (id) => setState(() => _selectedId = id),
                  );
                  final detail = selected == null
                      ? const Center(child: Text('从列表中选择一项审批'))
                      : _ApprovalDetail(
                          request: selected,
                          onResolve: (approved) => _center.resolve(selected.id, approved),
                        );
                  if (narrow) {
                    return Column(
                      children: [
                        SizedBox(height: 150, child: list),
                        const Divider(height: 1),
                        Expanded(child: detail),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      SizedBox(width: 240, child: list),
                      const VerticalDivider(width: 1),
                      Expanded(child: detail),
                    ],
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.onDismissed?.call();
            Navigator.of(context).pop();
          },
          child: const Text('稍后处理'),
        ),
      ],
    );
  }
}

/// The list column: one row per pending approval, showing which session it
/// came from, the tool, and when it was asked.
class _ApprovalList extends StatelessWidget {
  const _ApprovalList({
    required this.requests,
    required this.selectedId,
    required this.onSelect,
  });

  final List<ApprovalRequest> requests;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: requests.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final req = requests[index];
        final selected = req.id == selectedId;
        return ListTile(
          dense: true,
          selected: selected,
          leading: Icon(
            Icons.handyman_outlined,
            size: 18,
            color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
          ),
          title: Text(
            req.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium,
          ),
          subtitle: Text(
            '${req.tool} · ${_formatTime(req.createdAt)}',
            style: theme.textTheme.bodySmall,
          ),
          onTap: () => onSelect(req.id),
        );
      },
    );
  }

  static String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

/// Detail pane for the selected approval: why it was asked, the arguments,
/// and the allow/deny actions.
class _ApprovalDetail extends StatelessWidget {
  const _ApprovalDetail({required this.request, required this.onResolve});

  final ApprovalRequest request;
  final ValueChanged<bool> onResolve;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('允许执行工具「${request.tool}」？', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text('来自会话：${request.displayTitle}', style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        if (request.note != null && request.note!.isNotEmpty) ...[
          Text(
            request.note!,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                request.arguments.isEmpty ? '(无参数)' : request.arguments,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: AppFonts.mono,
                  fontFamilyFallback: AppFonts.monoFallback,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => onResolve(false),
              child: const Text('拒绝'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => onResolve(true),
              child: const Text('允许'),
            ),
          ],
        ),
      ],
    );
  }
}
