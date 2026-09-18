import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../widgets/confirm_dialog.dart';

/// Manages archived sessions and projects: view, restore or delete them.
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
              Tab(icon: Icon(Icons.chat_bubble_outline), text: '归档会话'),
              Tab(icon: Icon(Icons.folder_outlined), text: '归档项目'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ArchivedSessions(state: state),
            _ArchivedProjects(state: state),
          ],
        ),
      ),
    );
  }
}

class _ArchivedSessions extends StatelessWidget {
  const _ArchivedSessions({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = state.archivedSessions;
    if (sessions.isEmpty) {
      return const Center(child: Text('暂无归档会话'));
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

class _ArchivedProjects extends StatelessWidget {
  const _ArchivedProjects({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final projects = state.archivedProjects;
    if (projects.isEmpty) {
      return const Center(child: Text('暂无归档项目'));
    }
    return ListView(
      children: [
        for (final project in projects)
          ListTile(
            leading: const Icon(Icons.folder_delete_outlined),
            title: Text(
              project.name.isEmpty ? '(未命名项目)' : project.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${project.description.isEmpty ? project.sandbox : project.description} · '
              '归档于 ${_fmt(project.archivedAt ?? project.updatedAt)}',
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
                  onPressed: () => state.setProjectArchived(project.id, false),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final ok = await confirmDelete(
                      context,
                      '项目「${project.name.isEmpty ? project.id : project.name}」',
                    );
                    if (ok) await state.deleteProject(project.id);
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _fmt(DateTime time) {
  final local = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
