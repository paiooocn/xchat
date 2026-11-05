import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ids.dart';
import '../../models/session.dart';
import '../../models/task_item.dart';
import '../../models/token_usage.dart';
import '../../session/session_controller.dart';
import '../../state/app_state.dart';
import 'confirm_dialog.dart';
import 'usage_badge.dart';

/// Task list of a task-style session: one row per task item, showing its title,
/// whether it already has a reply, its manual 「完成」 checkbox, and a
/// 「自动执行」 entry that runs the remaining tasks one after another.
///
/// Tapping a row opens that task's conversation (a normal chat view filtered
/// to the task's messages). Rows are locked while another task's turn is
/// running: one session has one engine, so tasks run strictly one at a time.
///
/// The widget listens to the session controller itself: 「自动执行」progress and
/// the token spend it accumulates change far more often than `AppState` does
/// (which only re-broadcasts when the running set flips).
class TaskListView extends StatefulWidget {
  const TaskListView({
    super.key,
    required this.session,
    required this.controller,
    required this.onOpenTask,
  });

  final Session session;
  final SessionController controller;
  final void Function(String taskId) onOpenTask;

  @override
  State<TaskListView> createState() => _TaskListViewState();
}

class _TaskListViewState extends State<TaskListView> {
  /// Set while 「自动执行」is running, to report the result once it ends.
  bool _wasAutoRunning = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    // Reloads the session from disk when the index-only copy (no tasks) was
    // handed in — the task titles/messages only exist in the session XML.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.session.tasks.isEmpty) {
        unawaited(context.read<AppState>().reloadSession(widget.session.id));
      }
    });
  }

  @override
  void didUpdateWidget(covariant TaskListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final running = widget.controller.autoRunning;
    final finished = _wasAutoRunning && !running;
    _wasAutoRunning = running;
    setState(() {});
    // 汇总放到下一帧：Listener 回调里直接开 SnackBar 会撞上正在进行的 build。
    if (finished) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportAutoResult());
    }
  }

  Session get _session => widget.session;

  SessionController get _controller => widget.controller;

  /// 有任务在跑（单轮或自动执行）→ 禁止切任务 / 删除 / 改勾选。
  bool get _busy => _controller.isRunning || _controller.autoRunning;

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
    if (_busy) {
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
    if (_busy && _controller.runningTaskId != task.id) {
      _toastRunning();
      return;
    }
    widget.onOpenTask(task.id);
  }

  /// 「自动执行」：先让用户确认范围与「跑完是否勾完成」，再交给 controller。
  Future<void> _startAutoRun() async {
    final options = await showAutoRunDialog(
      context,
      session: _session,
      resumeTaskId: _controller.autoResumeTaskId,
    );
    if (options == null || !mounted) return;
    unawaited(_controller
        .runTasksAuto(
          taskIds: options.taskIds,
          markDoneWhenFinished: options.markDone,
        )
        .catchError((Object error) {
      // 正常情况下循环自己兜住错误；这里只兜意外（避免 unawaited 静默吞掉）。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('自动执行中断：$error')),
      );
    }));
  }

  /// 自动执行结束后的一次汇总（结果 / 中断原因 / 下一步动作）。
  void _reportAutoResult() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final failure = _controller.autoFailure;
    final done = _controller.autoDoneCount;
    final total = _controller.autoTotal;
    final skipped = _controller.autoSkipped;
    final skippedText = skipped > 0 ? '（跳过 $skipped 项无内容任务）' : '';
    if (failure != null) {
      messenger.showSnackBar(SnackBar(
        content: Text('$failure\n点「自动执行」可从这一项重跑'),
        duration: const Duration(seconds: 8),
      ));
      return;
    }
    if (done >= total) {
      messenger.showSnackBar(SnackBar(
        content: Text('自动执行完成：$done 项$skippedText'),
        duration: const Duration(seconds: 4),
      ));
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: Text('自动执行已停止：完成 $done/$total 项$skippedText'),
      duration: const Duration(seconds: 4),
    ));
  }

  /// 本次自动执行已消耗的 token（只显示后端给到的项）。
  String _usageText(TokenUsage usage) {
    final parts = <String>[
      if (usage.input != null) '入 ${formatTokensCompact(usage.input!)}',
      if (usage.output != null) '出 ${formatTokensCompact(usage.output!)}',
      if (usage.cache != null) '缓存 ${formatTokensCompact(usage.cache!)}',
    ];
    return parts.isEmpty ? '—' : parts.join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _session.tasks;
    final done = tasks.where((t) => t.done).length;
    final theme = Theme.of(context);
    final auto = _controller.autoRunning;
    final total = _controller.autoTotal;
    final runningIndex =
        (_controller.autoDoneCount + 1).clamp(1, total == 0 ? 1 : total);
    final subtitle = <String>[
      '共 ${tasks.length} 项 · 已完成 $done 项',
      if (auto)
        '自动执行 $runningIndex/$total'
      else if (_controller.isRunning)
        '有任务正在运行',
      if (auto) '本次已用 ${_usageText(_controller.autoUsage)}',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 窄屏：三个按钮都收成图标，标题才有地方显示。
              final compact = constraints.maxWidth < 560;
              return Row(
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
                          subtitle,
                          style: theme.textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (compact) ...[
                    IconButton(
                      tooltip: '批量导入（## 标题分段）',
                      onPressed: _busy ? null : _importTasks,
                      icon: const Icon(Icons.playlist_add, size: 20),
                    ),
                    IconButton(
                      tooltip: '新增任务',
                      onPressed: _busy ? null : _addTask,
                      icon: const Icon(Icons.add, size: 20),
                    ),
                  ] else ...[
                    TextButton.icon(
                      onPressed: _busy ? null : _importTasks,
                      icon: const Icon(Icons.playlist_add, size: 18),
                      label: const Text('批量导入'),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _addTask,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新增任务'),
                    ),
                  ],
                  const SizedBox(width: 4),
                  _autoButton(compact: compact),
                ],
              );
            },
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: tasks.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '还没有任务项。可以先加任务，之后在列表里点「自动执行」。',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _addTask,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('新增任务'),
                        ),
                        const SizedBox(height: 4),
                        TextButton.icon(
                          onPressed: _importTasks,
                          icon: const Icon(Icons.playlist_add, size: 18),
                          label: const Text('批量导入（## 标题分段）'),
                        ),
                      ],
                    ),
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
                        final running = _controller.runningTaskId == task.id;
                        final autoCurrent =
                            _controller.autoCurrentTaskId == task.id;
                        final replied = _session.taskHasReply(task.id);
                        return ListTile(
                          onTap: () => _open(task),
                          leading: Checkbox(
                            // 自动执行期间不允许改勾选：队列是按点「开始」时的
                            // 「未完成」快照跑的，中途改动会让人看不懂进度。
                            value: task.done,
                            onChanged: _controller.autoRunning
                                ? null
                                : (value) =>
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
                                : (autoCurrent
                                    ? '自动执行中…'
                                    : (messages.isEmpty
                                        ? '未开始'
                                        : '${messages.length} 条消息'
                                            '${replied ? '' : ' · 尚无回复'}')),
                            style: theme.textTheme.bodySmall,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (running || autoCurrent)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
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

  /// 「自动执行 / 停止自动执行」按钮。
  Widget _autoButton({required bool compact}) {
    final controller = _controller;
    if (controller.autoRunning) {
      return compact
          ? IconButton.filledTonal(
              tooltip: '停止自动执行',
              onPressed: controller.cancelAutoRun,
              icon: const Icon(Icons.stop_circle_outlined, size: 20),
            )
          : FilledButton.icon(
              onPressed: controller.cancelAutoRun,
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('停止自动执行'),
            );
    }
    final candidates = _session.autoRunCandidates();
    final enabled = candidates.isNotEmpty && !controller.isRunning;
    final tooltip = candidates.isEmpty
        ? '没有可执行的任务（已完成的任务需先取消勾选「完成」）'
        : (controller.isRunning ? '本会话有任务正在运行' : '自动执行未完成的任务');
    final onPressed = enabled ? _startAutoRun : null;
    if (compact) {
      return IconButton.filledTonal(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: const Icon(Icons.play_arrow_rounded, size: 20),
      );
    }
    return Tooltip(
      message: tooltip,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.play_arrow_rounded, size: 18),
        label: const Text('自动执行'),
      ),
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
                  running
                      ? '正在运行…'
                      : (task?.done == true
                          ? '已完成：取消勾选「完成」后才能继续对话'
                          : '本任务下的对话（模型仍可见整个会话历史）'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (task?.done == true)
            Icon(
              Icons.lock_outline,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
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

/// 「自动执行」的确认结果：要跑哪些任务项 + 跑完是否自动勾选「完成」。
class AutoRunOptions {
  const AutoRunOptions({required this.taskIds, required this.markDone});

  final List<String> taskIds;
  final bool markDone;
}

/// 「自动执行」确认框：范围（仅未开始 / 全部未完成）+ 是否自动勾选完成。
///
/// [resumeTaskId] 是上次中断/报错的任务项：它在候选里时默认「从这一项开始」，
/// 这样重跑不必从头再跑一遍已经完成的任务。
Future<AutoRunOptions?> showAutoRunDialog(
  BuildContext context, {
  required Session session,
  String? resumeTaskId,
}) {
  return showDialog<AutoRunOptions>(
    context: context,
    builder: (context) => _AutoRunDialog(
      session: session,
      resumeTaskId: resumeTaskId,
    ),
  );
}

class _AutoRunDialog extends StatefulWidget {
  const _AutoRunDialog({required this.session, this.resumeTaskId});

  final Session session;
  final String? resumeTaskId;

  @override
  State<_AutoRunDialog> createState() => _AutoRunDialogState();
}

class _AutoRunDialogState extends State<_AutoRunDialog> {
  bool _includeReplied = false;
  bool _markDone = true;

  /// 是否从上次中断的任务项开始（候选里找不到时为假，并自动清掉）。
  late bool _resume;

  @override
  void initState() {
    super.initState();
    _resume = _resumeCandidates().isNotEmpty;
  }

  List<TaskItem> get _candidates =>
      widget.session.autoRunCandidates(includeReplied: _includeReplied);

  /// 从上次中断项到队列末尾；找不到就返回空。
  List<TaskItem> _resumeCandidates() {
    final id = widget.resumeTaskId;
    if (id == null) return const <TaskItem>[];
    final all = _candidates;
    final index = all.indexWhere((t) => t.id == id);
    if (index < 0) return const <TaskItem>[];
    return all.sublist(index);
  }

  List<TaskItem> get _queue {
    final all = _candidates;
    if (!_resume) return all;
    final sliced = _resumeCandidates();
    return sliced.isEmpty ? all : sliced;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final queue = _queue;
    final all = _candidates;
    final resumeTask = widget.session.taskById(widget.resumeTaskId);
    return AlertDialog(
      title: const Text('自动执行任务'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '按列表顺序逐个执行：每个任务先把任务内容作为该任务的第一条 user '
              '消息发出，再把这一轮完整跑完才进入下一个（中途可随时停止）。'
              '发给模型的历史仍是整个会话。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('仅未开始的任务'),
                  selected: !_includeReplied,
                  onSelected: (_) => setState(() {
                    _includeReplied = false;
                    _resume = _resumeCandidates().isNotEmpty;
                  }),
                ),
                ChoiceChip(
                  label: const Text('全部未完成任务（已有回复的再跑一轮）'),
                  selected: _includeReplied,
                  onSelected: (_) => setState(() {
                    _includeReplied = true;
                    _resume = _resumeCandidates().isNotEmpty;
                  }),
                ),
              ],
            ),
            if (resumeTask != null && _resumeCandidates().isNotEmpty) ...[
              const SizedBox(height: 4),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _resume,
                onChanged: (value) => setState(() => _resume = value ?? false),
                title: Text(
                  '从上次中断的「${resumeTask.displayTitle}」开始',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: const Text('取消勾选则从队列第一项开始'),
              ),
            ],
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _markDone,
              onChanged: (value) => setState(() => _markDone = value ?? false),
              title: const Text('每项跑完自动勾选「完成」'),
              subtitle: const Text('勾选后该项对话会被锁定（取消勾选「完成」可再继续）'),
            ),
            const SizedBox(height: 8),
            Text(
              queue.isEmpty
                  ? '没有可执行的任务项。'
                  : '将执行 ${queue.length} 项'
                      '${all.length != queue.length ? '（候选 ${all.length} 项）' : ''}：'
                      '${queue.take(3).map((t) => t.displayTitle).join('、')}'
                      '${queue.length > 3 ? '…' : ''}',
              style: theme.textTheme.bodySmall,
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
          onPressed: queue.isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    AutoRunOptions(
                      taskIds: [for (final task in queue) task.id],
                      markDone: _markDone,
                    ),
                  ),
          child: const Text('开始执行'),
        ),
      ],
    );
  }
}
