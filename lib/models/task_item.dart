import '../core/ids.dart';
import '../core/json_utils.dart';

/// One task item of a task-style session (`<tasks>/<task>` in the session XML).
///
/// Messages of the session carry [SessionMessage.taskId]; the task item itself
/// only holds what the user typed at creation time (title + content). The task
/// content becomes the first `user` message of the task when it is started.
class TaskItem {
  TaskItem({
    required this.id,
    this.title = '',
    this.content = '',
    this.done = false,
  });

  String id;
  String title;

  /// The task body; sent verbatim as the first user message of the task.
  String content;

  /// Manually toggled by the user (never set by the agent).
  bool done;

  /// Title shown in the task list: falls back to the first non-empty content
  /// line, so an untitled imported task still has a readable label.
  String get displayTitle {
    final titled = title.trim();
    if (titled.isNotEmpty) return titled;
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      return trimmed.length <= 40 ? trimmed : '${trimmed.substring(0, 40)}…';
    }
    return '(未命名任务)';
  }

  /// The text that becomes the task's first `user` message.
  ///
  /// Deliberately **without** the title: every outgoing user message of a task
  /// gets the title prepended at the outbound layer (see `buildChatMessages`),
  /// so the title has exactly one source and the first message never carries it
  /// twice.
  String get promptText {
    final body = content.trim();
    return body.isNotEmpty ? body : displayTitle;
  }

  /// The label put in front of this task's outgoing user messages
  /// (`【任务：…】`), or `null` when it has neither a title nor content.
  ///
  /// Falls back to [displayTitle] (the first content line) so an imported but
  /// untitled task still marks its messages.
  String? get anchorTitle {
    final titled = title.trim();
    if (titled.isNotEmpty) return titled;
    return content.trim().isEmpty ? null : displayTitle;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'content': content,
        if (done) 'done': true,
      };

  factory TaskItem.fromJson(Object? value) {
    final json = asMap(value);
    return TaskItem(
      id: asString(json['id']) ?? newShortId(),
      title: asString(json['title']) ?? '',
      content: asString(json['content']) ?? '',
      done: asBool(json['done']),
    );
  }
}

/// Splits a Markdown-ish text into task items: every `## 标题` line starts a new
/// task, and the lines below it (up to the next `##`) become its content.
///
/// Deeper headings (`###…`) stay part of the content. Text before the first
/// `##` is kept as a leading untitled task when it has real content — nothing
/// the user pasted is silently dropped. A text without any `##` becomes a
/// single task holding the whole body.
List<TaskItem> parseTaskMarkdown(String text) {
  final lines = text.split('\n');
  final out = <TaskItem>[];
  String? title;
  final buffer = <String>[];

  void flush() {
    final content = buffer.join('\n').trim();
    if (title == null && content.isEmpty) return;
    out.add(TaskItem(
      id: newShortId(),
      title: title?.trim() ?? '',
      content: content,
    ));
    buffer.clear();
  }

  for (final line in lines) {
    final match = RegExp(r'^##(?!#)\s*(.*)$').firstMatch(line);
    if (match != null) {
      flush();
      title = match.group(1) ?? '';
      continue;
    }
    // A `--`/`---` separator or a stray `#` is content, not a boundary.
    if (title == null && buffer.isEmpty && line.trim().isEmpty) continue;
    buffer.add(line);
  }
  flush();
  return out;
}
