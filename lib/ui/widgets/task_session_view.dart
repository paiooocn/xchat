import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ids.dart';
import '../../models/session.dart';
import '../../models/task_item.dart';
import '../../state/app_state.dart';
import 'confirm_dialog.dart';

/// Task list of a task-style session: one row per task item, showing its title,
/// whether it already has a reply, and a manual 「完成」 checkbox.
///
/// Tapping a row opens that task's conversation (a normal chat view filtered
/// to the task's messages). Rows are locked while another task's turn is
/// running: one session has one engine, so tasks run strictly one at a time.
class TaskListView extends StatefulWidget {
  const TaskListView({
    super.key,
    required this.session,
    required this.onOpenTask,
    this.running = false,
    this.runningTaskId,
  });

  final Session session;
  final void Function(String taskId) onOpenTask;

  /// Whether a turn of this session is currently streaming.
  final bool running;

  /// The task item that turn belongs to.
  final String? runningTaskId;

  @override
  State<TaskListView> createState() => _TaskListViewState();
}

class _TaskListViewState extends State<TaskListView> {
  /// Reloads the session from disk when the index-only copy (no tasks) was
  /// handed in — the task titles/messages only exist in the session XML.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.session.tasks.isEmpty) {
        unawaited(context.read<AppState>().reloadSession(widget.session.id));
      }
    });
  }

  Session get _session => widget.session;

  /// Writes the task list change to disk (session XML + catalog index).
  Future<void> _save() async {
    await context.read<AppState>().persistSession(_session);
    if (mounted) setState(() {});
  }

  Future<void> _toggleDone(TaskItem task, bool done) async {
    task.done = done;
    await _save();
  }

  Future<void> _addTask() async {
    final created = await showTaskEditorDialog(context);
    if (created == null || !mounted) return;
    _session.tasks.add(created);
    _session.updatedAt = DateTime.now();
    await _save();
  }

  Future<void> _importTasks() async {
    final imported = await showTaskImportDialog(context);
    if (imported == null || imported.isEmpty || !mounted) return;
    _session.tasks.addAll(imported);
    _session.updatedAt = DateTime.now();
    await _save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导入 ${imported.length} 个任务项')),
    );
  }

  Future<void> _deleteTask(TaskItem task) async {
    if (widget.running) {
      _toastRunning();
      return;
    }
    final count = _session.taskMessages(task.id).length;
    final ok = await confirmDelete(
      context,
      count > 0
          ? '任务「${task.displayTitle}」及其 $count 条对话消息'
          : '任务「${task.displayTitle}」',
    );
    if (!ok || !mounted) return;
    _session.removeTask(task.id);
    await _save();
  }

  void _toastRunning() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('本会话有任务正在运行，请先停止后再切换或删除任务'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _open(TaskItem task) {
    if (widget.running && widget.runningTaskId != task.id) {
      _toastRunning();
      return;
    }
    widget.onOpenTask(task.id);
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _session.tasks;
    final done = tasks.where((t) => t.done).length;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          child: Row(
            children: [
              const Icon(Icons.checklist, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _session.title.isEmpty ? '任务式会话' : _session.title,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '共 ${tasks.length} 项 · 已完成 $done 项'
                      '${widget.running ? ' · 有任务正在运行' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: widget.running ? null : _importTasks,
                icon: const Icon(Icons.playlist_add, size: 18),
                label: const Text('批量导入'),
              ),
              TextButton.icon(
                onPressed: widget.running ? null : _addTask,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新增任务'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有任务项。点右上角「新增任务」或「批量导入」。'),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: tasks.length,
                      itemBuilder: (context, index) {
                        final task = tasks[index];
                        final messages = _session.taskMessages(task.id);
                        final running = widget.runningTaskId == task.id;
                        final replied = _session.taskHasReply(task.id);
                        return ListTile(
                          onTap: () => _open(task),
                          leading: Checkbox(
                            value: task.done,
                            onChanged: (value) =>
                                _toggleDone(task, value ?? false),
                          ),
                          title: Text(
                            task.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: task.done
                                ? TextStyle(
                                    decoration: TextDecoration.lineThrough,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  )
                                : null,
                          ),
                          subtitle: Text(
                            running
                                ? '正在运行…'
                                : (messages.isEmpty
                                    ? '未开始'
                                    : '${messages.length} 条消息'
                                        '${replied ? '' : ' · 尚无回复'}'),
                            style: theme.textTheme.bodySmall,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (running)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              if (task.done)
                                Icon(
                                  Icons.check_circle,
                                  size: 18,
                                  color: theme.colorScheme.primary,
                                ),
                              IconButton(
                                tooltip: '删除任务项（连同其对话消息）',
                                iconSize: 18,
                                onPressed: () => _deleteTask(task),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Compact bar above a task's conversation: back to the task list, the task
/// title, and its manual 「完成」 switch.
class TaskChatHeader extends StatelessWidget {
  const TaskChatHeader({
    super.key,
    required this.session,
    required this.taskId,
    this.running = false,
    this.onBack,
  });

  final Session session;
  final String taskId;

  /// Whether this session currently has a streaming turn.
  final bool running;

  /// Leaves the conversation and returns to the task list.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final task = session.taskById(taskId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回任务列表',
            iconSize: 20,
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task?.displayTitle ?? '(任务项已删除)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  running ? '正在运行…' : '本任务下的对话（模型仍可见整个会话历史）',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (task != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('完成', style: theme.textTheme.bodySmall),
                Checkbox(
                  value: task.done,
                  onChanged: (value) async {
                    task.done = value ?? false;
                    session.updatedAt = DateTime.now();
                    await context.read<AppState>().persistSession(session);
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Prompts for one task item (title + content).
Future<TaskItem?> showTaskEditorDialog(BuildContext context) {
  final title = TextEditingController();
  final content = TextEditingController();
  return showDialog<TaskItem>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('新增任务'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(
                labelText: '任务标题',
                helperText: '留空则用内容首行作为标题',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: content,
              minLines: 5,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: '任务内容',
                helperText: '开始该任务时，这段内容作为第一条 user 消息发出',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final t = title.text.trim();
            final c = content.text.trim();
            if (t.isEmpty && c.isEmpty) {
              Navigator.pop(context);
              return;
            }
            Navigator.pop(
              context,
              TaskItem(id: newShortId(), title: t, content: c),
            );
          },
          child: const Text('添加'),
        ),
      ],
    ),
  );
}

/// Batch import: paste Markdown and every `## 标题` section becomes a task.
Future<List<TaskItem>?> showTaskImportDialog(BuildContext context) {
  final input = TextEditingController();
  return showDialog<List<TaskItem>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final parsed = parseTaskMarkdown(input.text);
        return AlertDialog(
          title: const Text('批量导入任务'),
          content: SizedBox(
            width: 640,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '用「## 标题」分段，每段标题下正文作为该任务内容；'
                    '识别到 0 项时正文作为一个任务。',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: input,
                  minLines: 8,
                  maxLines: 16,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: '## 任务一\n内容一\n\n## 任务二\n内容二',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    parsed.isEmpty
                        ? '尚未识别到任务项'
                        : '将导入 ${parsed.length} 项：'
                            '${parsed.take(3).map((t) => t.displayTitle).join('、')}'
                            '${parsed.length > 3 ? '…' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: parsed.isEmpty
                  ? null
                  : () => Navigator.pop(context, parsed),
              child: const Text('导入'),
            ),
          ],
        );
      },
    ),
  );
}
