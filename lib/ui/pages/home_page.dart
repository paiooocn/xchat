import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:async';
import 'package:llm_api/llm_api.dart' as llm;
import 'package:provider/provider.dart';

import '../../core/app_paths.dart';
import '../../models/project.dart';
import '../../models/session.dart';
import '../../models/session_message.dart';
import '../../session/session_controller.dart';
import '../../session/session_ops.dart';
import '../../state/app_state.dart';
import '../../util/editor_launcher.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/input_area.dart';
import '../widgets/message_bubble.dart';
import '../widgets/thinking_block.dart';
import '../widgets/tool_call_block.dart';
import '../widgets/usage_badge.dart';
import '../theme/app_fonts.dart';
import 'archive_page.dart';
import 'compress_prompts_page.dart';
import 'providers_page.dart';
import 'session_wizard_page.dart';
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

  /// Selected session tag filters (empty = show all).
  final Set<String> _tagFilter = <String>{};

  void _toggleTag(String tag) {
    setState(() {
      if (!_tagFilter.remove(tag)) _tagFilter.add(tag);
    });
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
    );
  }

  Future<void> _editProject(BuildContext context, Project project) async {
    final state = context.read<AppState>();
    final result = await _showProjectDialog(context, existing: project);
    if (result == null) return;
    project
      ..name = result.name
      ..description = result.description
      ..sandbox = result.sandbox;
    await state.saveProject(project);
  }

  /// Selects a session and reloads its content from disk so the latest
  /// conversation is always shown when (re)opening it.
  Future<void> _openSession(BuildContext context, String id) async {
    final state = context.read<AppState>();
    // Load the authoritative copy (full conversation) before showing it, so the
    // panel always has messages instead of the index's metadata-only entry.
    await state.reloadSession(id);
    if (mounted) setState(() => _selectedId = id);
  }

  Future<({String name, String description, String sandbox})?> _showProjectDialog(
    BuildContext context, {
    Project? existing,
  }) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final desc = TextEditingController(text: existing?.description ?? '');
    final sandbox = TextEditingController(text: existing?.sandbox ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? '新建项目' : '编辑项目'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '项目名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: desc,
              decoration: const InputDecoration(labelText: '说明'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: sandbox,
              decoration: const InputDecoration(
                labelText: '工作目录（留空=默认 projects/<项目id>）',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true) return null;
    return (
      name: name.text.trim(),
      description: desc.text.trim(),
      sandbox: sandbox.text.trim(),
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

        return Scaffold(
          appBar: AppBar(
            title: const Text('XChat'),
            actions: [
              IconButton(
                tooltip: '模板',
                icon: const Icon(Icons.dashboard_customize_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TemplatesPage()),
                ),
              ),
              IconButton(
                tooltip: '模型服务',
                icon: const Icon(Icons.cloud_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProvidersPage()),
                ),
              ),
              IconButton(
                tooltip: '工具管理',
                icon: const Icon(Icons.handyman_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ToolsPage()),
                ),
              ),
              IconButton(
                tooltip: '归档管理',
                icon: const Icon(Icons.archive_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ArchivePage()),
                ),
              ),
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                ),
              ),
            ],
          ),
          floatingActionButton: wide
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _newSession(context),
                  icon: const Icon(Icons.add),
                  label: const Text('新建会话'),
                ),
          body: wide
              ? Row(
                  children: [
                    SizedBox(
                      width: 340,
                      child: _Sidebar(
                        sessions: sessions,
                        projects: projects,
                        selectedId: _selectedId,
                        tagFilter: _tagFilter,
                        onTagToggle: _toggleTag,
                        showHeader: true,
                        onSelect: (id) => _openSession(context, id),
                        onNewSession: (projectId) => _newSession(context, projectId: projectId),
                        onNewProject: () => _newProject(context),
                        onEditProject: (p) => _editProject(context, p),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: selected == null
                          ? const _EmptyState()
                          : SessionChatPanel(
                              key: ValueKey(selected.id),
                              sessionId: selected.id,
                              onCompressCompleted: (id) async {
                                await _openSession(context, id);
                              },
                            ),
                    ),
                  ],
                )
              : _Sidebar(
                  sessions: sessions,
                  projects: projects,
                  selectedId: _selectedId,
                  tagFilter: _tagFilter,
                  onTagToggle: _toggleTag,
                  showHeader: false,
                  onSelect: (id) async {
                    await _openSession(context, id);
                    if (!context.mounted) return;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _MobileChatPage(sessionId: id),
                      ),
                    );
                  },
                  onNewSession: (projectId) => _newSession(context, projectId: projectId),
                  onNewProject: () => _newProject(context),
                  onEditProject: (p) => _editProject(context, p),
                ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text('选择或新建一个会话开始对话', style: theme.textTheme.titleMedium),
        ],
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

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppState>().sessionById(widget.sessionId);
    return Scaffold(
      appBar: AppBar(
        title: Text(session?.title.isNotEmpty == true ? session!.title : '会话'),
        actions: [
          IconButton(
            tooltip: '显示/隐藏会话信息',
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
              showHeader: _showInfo,
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
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.sessions,
    required this.projects,
    required this.selectedId,
    required this.onSelect,
    required this.onNewSession,
    required this.onNewProject,
    required this.tagFilter,
    required this.onTagToggle,
    this.onEditProject,
    this.showHeader = false,
  });

  final List<Session> sessions;
  final List<Project> projects;
  final String? selectedId;
  final void Function(String id) onSelect;
  final void Function(String? projectId) onNewSession;
  final VoidCallback onNewProject;
  final Set<String> tagFilter;
  final void Function(String tag) onTagToggle;
  final void Function(Project project)? onEditProject;
  final bool showHeader;

  bool _matchesFilter(Session session) =>
      tagFilter.isEmpty || session.tags.any(tagFilter.contains);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = sessions.where(_matchesFilter).toList();
    final global = visible.where((s) => s.projectId.isEmpty).toList();
    final allTags = <String>{
      for (final s in sessions) ...s.tags.where((t) => t.trim().isNotEmpty),
    }.toList()
      ..sort();

    return Column(
      children: [
        if (showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Text('会话', style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: '新建项目',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: onNewProject,
                ),
                IconButton(
                  tooltip: '新建会话',
                  icon: const Icon(Icons.add),
                  onPressed: () => onNewSession(null),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            children: [
              // ---- 标签筛选 ------------------------------------------
              if (allTags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
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
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onSelected: (_) => onTagToggle(tag),
                        ),
                    ],
                  ),
                ),
              // ---- 全局会话 ------------------------------------------
              _sectionHeader(context, '全局会话'),
              for (final session in global)
                _SessionTile(
                  session: session,
                  selected: session.id == selectedId,
                  leading: const Icon(Icons.chat_bubble_outline, size: 20),
                  onTap: () => onSelect(session.id),
                ),
              if (global.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text('暂无全局会话', style: TextStyle(color: Colors.grey)),
                ),
              const Divider(height: 1),
              // ---- 项目 ----------------------------------------------
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Text('项目', style: theme.textTheme.labelLarge),
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
                  sessions: visible.where((s) => s.projectId == project.id).toList(),
                  selectedId: selectedId,
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
                      await context.read<AppState>().deleteProject(project.id);
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
      ],
    );
  }

  static Widget _sectionHeader(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}

/// A project row that expands to reveal its own sessions.
class _ProjectGroup extends StatelessWidget {
  const _ProjectGroup({
    required this.project,
    required this.sessions,
    required this.selectedId,
    required this.onSelect,
    required this.onNewSession,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
  });

  final Project project;
  final List<Session> sessions;
  final String? selectedId;
  final void Function(String id) onSelect;
  final VoidCallback onNewSession;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      initiallyExpanded: false,
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: const Icon(Icons.folder_outlined, size: 20),
      title: Text(
        project.name.isEmpty ? '(未命名项目)' : project.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        project.sandbox,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: PopupMenuButton<String>(
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
      children: [
        for (final session in sessions)
          _SessionTile(
            session: session,
            selected: session.id == selectedId,
            indent: 28,
            leading: const Icon(Icons.forum_outlined, size: 18),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('项目', style: theme.textTheme.labelSmall),
            ),
            onTap: () => onSelect(session.id),
          ),
        if (sessions.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(44, 4, 16, 4),
            child: Text('暂无会话', style: TextStyle(color: Colors.grey)),
          ),
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 44, right: 16),
          leading: const Icon(Icons.add, size: 18),
          title: const Text('在项目中新建会话'),
          onTap: onNewSession,
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
    this.trailing,
    this.indent = 0,
  });

  final Session session;
  final bool selected;
  final Widget leading;
  final Widget? trailing;
  final VoidCallback onTap;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      selected: selected,
      contentPadding: EdgeInsets.only(left: 16 + indent, right: 8),
      leading: leading,
      title: Text(
        session.title.isNotEmpty ? session.title : '(未命名会话)',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${session.model.isNotEmpty ? session.model : session.provider} · ${_fmt(session.updatedAt)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?trailing,
          _SessionMenu(session: session, state: context.read<AppState>()),
        ],
      ),
      onTap: onTap,
    );
  }

  static String _fmt(DateTime time) {
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
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
        PopupMenuItem(value: 'system', child: Text('查看系统提示词')),
        PopupMenuItem(value: 'rename', child: Text('重命名')),
        PopupMenuItem(value: 'tags', child: Text('编辑标签')),
        PopupMenuItem(value: 'autoname', child: Text('AI 自动命名')),
        PopupMenuItem(value: 'clone_empty', child: Text('克隆（到首轮之前）')),
        PopupMenuItem(value: 'clone_first', child: Text('克隆（含首次对话）')),
        PopupMenuItem(value: 'clone_full', child: Text('克隆（完整会话）')),
        PopupMenuItem(value: 'edit_xml', child: Text('用编辑工具打开')),
        PopupMenuItem(value: 'archive', child: Text('归档')),
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
  }

  Future<void> _handle(BuildContext context, String action) async {
    switch (action) {
      case 'system':
        await _showSystemPrompt(context);
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

  /// Shows the session's system prompt (with `{sandbox}` expanded) in a
  /// read-only dialog panel.
  Future<void> _showSystemPrompt(BuildContext context) async {
    final full = await state.loadFullSession(session.id);
    if (!context.mounted) return;
    final prompt = full.systemPrompt.replaceAll('{sandbox}', full.sandbox);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '系统提示词',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        content: SizedBox(
          width: 620,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 480),
            child: SingleChildScrollView(
              child: SelectableText(
                prompt.trim().isEmpty ? '（空）' : prompt,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontFamily: AppFonts.mono,
                      fontFamilyFallback: AppFonts.monoFallback,
                      height: 1.5,
                    ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
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
  });

  final String sessionId;

  /// Called after "compress session" created a new session (to select it).
  final ValueChanged<String>? onCompressCompleted;

  /// Whether to show the session info / model selector header. Mobile hides it
  /// by default to reclaim vertical space and toggles it from the app bar.
  final bool showHeader;

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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final live = context.watch<AppState>().sessionById(widget.sessionId);
    final current = _controller?.session;
    // Adopt a refreshed instance (e.g. after reload) unless we are mid-stream.
    if (live != null &&
        !identical(live, current) &&
        !(_controller?.isRunning ?? false)) {
      _controller?.removeListener(_onChange);
      _controller?.dispose();
      _controller = _build();
      setState(() {});
    }
  }

  SessionController _build() {
    final state = context.read<AppState>();
    final session = state.sessionById(widget.sessionId);
    final controller = SessionController(
      repository: state.sessionRepository,
      config: state.config,
      providerResolver: state.providerById,
    );
    if (session != null) controller.open(session);
    controller.approvalHandler = _requestApproval;
    controller.addListener(_onChange);
    return controller;
  }

  /// Asks the user whether to run a tool that requires approval.
  Future<bool> _requestApproval(String tool, String arguments, String? note) async {
    if (!mounted) return false;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('允许执行工具「$tool」？'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (note != null && note.isNotEmpty) ...[
                  Text(note, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary)),
                  const SizedBox(height: 8),
                ],
                Text(
                  arguments.isEmpty ? '(无参数)' : arguments,
                  style: const TextStyle(
                    fontFamily: AppFonts.mono,
                    fontFamilyFallback: AppFonts.monoFallback,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('允许'),
          ),
        ],
      ),
    );
    return approved ?? false;
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
    _controller?.removeListener(_onChange);
    _controller?.dispose();
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
    final messages = session.messages
        .where((m) => m.role != MessageRole.system)
        .toList(growable: false);
    final lastUserIndex = SessionOps.lastUserIndex(session);

    return Column(
      children: [
        if (widget.showHeader) ...[
          _Header(controller: controller),
          const Divider(height: 1),
        ],
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            itemCount: messages.length + (controller.isRunning ? 1 : 0),
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
        if (controller.error != null || controller.notice != null)
          _StatusBar(
            text: controller.error ?? controller.notice!,
            isError: controller.error != null,
          ),
        InputArea(
          running: controller.isRunning,
          onSend: (text) => controller.send(text),
          onStop: controller.stop,
          mode: session.mode,
          onModeChanged: (value) => controller.setMode(value),
          webSearchAvailable: session.tools.contains('web_search'),
          webSearchEnabled: session.webSearchEnabled,
          onWebSearchChanged: (value) => controller.setWebSearch(value),
          onCompress: _compressSession,
          onScrollToRecent: () => _guardedScroll(_scrollToLastUser),
          onScrollToBottom: () => _guardedScroll(() async => _scrollToBottom()),
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
    var dialogOpen = true;
    // Show a progress dialog streaming the compressed text so the user can
    // follow (and cancel) the compression work.
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
      ).then((_) => dialogOpen = false),
    );
    // Live partial text from the compressor stream, shown in the dialog.
    try {
      final created = await state.compressSession(
        session.id,
        prompt,
        onProgress: (text) => progress.value = text,
        cancel: cancel,
      );
      await state.refreshSessions();
      if (dialogOpen && mounted) Navigator.of(context).pop();
      progress.dispose();
      if (!mounted) return;
      widget.onCompressCompleted?.call(created.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已创建压缩会话「${created.title}」')),
      );
    } catch (error) {
      if (dialogOpen && mounted) Navigator.of(context).pop();
      progress.dispose();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('压缩失败：$error')),
      );
    }
  }

  Future<void> _editLastUser(BuildContext context, Session session) async {
    final index = SessionOps.lastUserIndex(session);
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
    if (SessionOps.editLastUser(session, text)) {
      await _controller?.resend();
      setState(() {});
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final session = controller.session!;
    final usage = controller.cumulativeUsage;
    final contextWindow = controller.activeProvider.contextWindowFor(session.model);
    final contextTokens = controller.contextTokens;
    final ratio = (contextWindow != null && contextWindow > 0 && contextTokens != null)
        ? (contextTokens / contextWindow).clamp(0.0, 1.0)
        : null;
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
              const SizedBox(width: 8),
              _ModelSelector(controller: controller),
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
    if (models.isEmpty) {
      return Text('${provider.name} · $label', style: Theme.of(context).textTheme.bodySmall);
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.memory, size: 16),
          const SizedBox(width: 4),
          Text('${provider.name} · $label', style: Theme.of(context).textTheme.bodySmall),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
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
