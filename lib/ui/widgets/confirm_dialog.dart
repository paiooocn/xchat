import 'package:flutter/material.dart';

/// Shows a confirmation dialog before a destructive delete.
///
/// [label] describes what is being removed, e.g. `会话「标题」`.
Future<bool> confirmDelete(BuildContext context, String label) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('确认删除'),
      content: Text('确定要删除$label吗？此操作不可撤销。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Confirms the deletion of a project **together with all of its sessions**.
///
/// Two dialogs are shown: the first one states how many sessions go away
/// with the project, the second one is the final "are you sure".
Future<bool> confirmDeleteProject(
  BuildContext context,
  String label,
  int sessionCount,
) async {
  final sessions = sessionCount == 0
      ? '该项目下没有会话'
      : '该项目下的 $sessionCount 个会话会一并删除';
  final again = sessionCount == 0
      ? '$label 将被永久删除'
      : '$label 与它的 $sessionCount 个会话将被永久删除';
  final first = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('确认删除项目'),
      content: Text('确定要删除$label吗？$sessions，此操作不可撤销。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (!(first ?? false)) return false;
  if (!context.mounted) return false;

  final second = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('再次确认'),
      content: Text('最后确认：$again，无法恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('确认删除'),
        ),
      ],
    ),
  );
  return second ?? false;
}
