import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/archive_group.dart';
import '../../models/project.dart';
import '../../state/app_state.dart';
import '../widgets/confirm_dialog.dart';

/// Manages archived sessions and projects.
///
/// The page has two tabs:
/// * 「归档·全局」 — the archived sessions that belong to no project;
/// * 「归档·项目」 — every project that has something archived, with its
///   archived sessions nested underneath.
class ArchivePage extends StatelessWidget {
  const ArchivePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('归档管理'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.chat_bubble_outline), text: '归档·全局'),
              Tab(icon: Icon(Icons.folder_outlined), text: '归档·项目'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ArchivedGlobalSessions(state: state),
            _ArchivedProjects(state: state),
          ],
        ),
      ),
    );
  }
}

/// The archived sessions that are not bound to any existing project
/// (`projectId` 为空，或指向一个已不存在的项目文件).
class _ArchivedGlobalSessions extends StatelessWidget {
  const _ArchivedGlobalSessions({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = state.archivedGlobalSessions;
    if (sessions.isEmpty) {
      return const Center(child: Text('暂无归档的全局会话'));
    }
    return ListView(
      children: [
        for (final session in sessions)
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(
              session.title.isNotEmpty ? session.title : '(未命名会话)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${session.model.isNotEmpty ? session.model : session.provider} · '
              '归档于 ${_fmt(session.archivedAt ?? session.updatedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '恢复',
                  icon: const Icon(Icons.unarchive_outlined),
                  onPressed: () => state.setSessionArchived(session.id, false),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final ok = await confirmDelete(
                      context,
                      '会话「${session.title.isNotEmpty ? session.title : session.id}」',
                    );
                    if (ok) await state.deleteSession(session.id);
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The archived projects, each with its archived sessions as children.
class _ArchivedProjects extends StatelessWidget {
  const _ArchivedProjects({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final groups = state.archiveProjectGroups;
    if (groups.isEmpty) {
      return const Center(child: Text('暂无归档的项目'));
    }
    return ListView(
      children: [
        for (final group in groups) _ProjectArchiveTile(group: group, state: state),
      ],
    );
  }
}

/// One project entry: the project itself (restore / delete) plus its
/// archived sessions underneath.
class _ProjectArchiveTile extends StatelessWidget {
  const _ProjectArchiveTile({required this.group, required this.state});

  final ArchiveProjectGroup group;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = group.project;
    return ExpansionTile(
      // Collapsed by default — the archived sessions are a detail of the
      // project, not the first thing to look at.
      initiallyExpanded: false,
      maintainState: false,
      leading: const Icon(Icons.folder_outlined),
      title: Row(
        children: [
          Flexible(
            child: Text(
              project.name.isEmpty ? '(未命名项目)' : project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (group.badge != ArchiveBadge.none) ...[
            const SizedBox(width: 8),
            _BadgeChip(badge: group.badge),
          ],
        ],
      ),
      subtitle: Text(
        '归档会话 ${group.archivedCount}/${group.totalSessions} · '
        '归档于 ${_fmt(project.archivedAt ?? project.updatedAt)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '恢复项目',
            icon: const Icon(Icons.unarchive_outlined),
            onPressed: () => state.setProjectArchived(project.id, false),
          ),
          IconButton(
            tooltip: '删除项目',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteProject(context, project),
          ),
        ],
      ),
      children: [
        for (final session in group.archivedSessions)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 56, right: 8),
            leading: const Icon(Icons.chat_bubble_outline, size: 20),
            title: Text(
              session.title.isNotEmpty ? session.title : '(未命名会话)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '归档于 ${_fmt(session.archivedAt ?? session.updatedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '恢复',
                  icon: const Icon(Icons.unarchive_outlined),
                  onPressed: () => state.setSessionArchived(session.id, false),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final ok = await confirmDelete(
                      context,
                      '会话「${session.title.isNotEmpty ? session.title : session.id}」',
                    );
                    if (ok) await state.deleteSession(session.id);
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _deleteProject(BuildContext context, Project project) async {
    final ok = await confirmDeleteProject(
      context,
      '项目「${project.name.isEmpty ? project.id : project.name}」',
      state.totalSessionsOfProject(project.id),
    );
    if (ok) await state.deleteProject(project.id);
  }
}

/// The 「全部」/「部分」 badge of a project entry.
class _BadgeChip extends StatelessWidget {
  const _BadgeChip({required this.badge});

  final ArchiveBadge badge;

  @override
  Widget build(BuildContext context) {
    final color = badge == ArchiveBadge.all ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        badge.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

String _fmt(DateTime time) {
  final local = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
