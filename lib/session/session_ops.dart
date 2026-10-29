import '../models/session.dart';
import '../models/session_message.dart';

/// Pure session transformations (no IO).
class SessionOps {
  const SessionOps._();

  /// Whether [message] belongs to the scope selected by [onlyTaskId].
  ///
  /// `null` means "the whole session" (a normal session, or the global view of
  /// a task-style session).
  static bool _inScope(SessionMessage message, String? onlyTaskId) =>
      onlyTaskId == null || message.taskId == onlyTaskId;

  /// Index of the last user message in scope, or `-1`.
  static int lastUserIndex(Session session, {String? onlyTaskId}) {
    for (var i = session.messages.length - 1; i >= 0; i--) {
      final message = session.messages[i];
      if (message.role == MessageRole.user && _inScope(message, onlyTaskId)) {
        return i;
      }
    }
    return -1;
  }

  /// Truncates everything after the last user message (in scope) and replaces
  /// its content.
  ///
  /// In a task-style session only the messages **of that task** after the user
  /// message are dropped: the other tasks' turns are separate conversations
  /// and must survive an edit/regenerate of this one.
  ///
  /// Returns `false` when there is no user message to edit.
  static bool editLastUser(Session session, String newText, {String? onlyTaskId}) {
    final index = lastUserIndex(session, onlyTaskId: onlyTaskId);
    if (index < 0) return false;
    if (onlyTaskId == null) {
      session.messages.removeRange(index + 1, session.messages.length);
    } else {
      for (var i = session.messages.length - 1; i > index; i--) {
        final message = session.messages[i];
        if (message.role != MessageRole.system &&
            _inScope(message, onlyTaskId)) {
          session.messages.removeAt(i);
        }
      }
    }
    session.messages[index].content = newText;
    session.recomputeToolCalls();
    session.recomputeUsage();
    session.updatedAt = DateTime.now();
    return true;
  }

  /// Drops the trailing assistant turn (and its tool results) so it can be
  /// regenerated. Returns `false` when there is nothing to drop.
  static bool dropLastAssistant(Session session, {String? onlyTaskId}) {
    var index = -1;
    for (var i = session.messages.length - 1; i >= 0; i--) {
      final message = session.messages[i];
      if (message.role == MessageRole.assistant && _inScope(message, onlyTaskId)) {
        index = i;
        break;
      }
    }
    if (index < 0) return false;
    if (onlyTaskId == null) {
      session.messages.removeRange(index, session.messages.length);
    } else {
      for (var i = session.messages.length - 1; i >= index; i--) {
        final message = session.messages[i];
        if (message.role != MessageRole.system &&
            _inScope(message, onlyTaskId)) {
          session.messages.removeAt(i);
        }
      }
    }
    session.recomputeToolCalls();
    session.recomputeUsage();
    session.updatedAt = DateTime.now();
    return true;
  }

  /// Removes a message (and any tool results that follow an assistant turn).
  ///
  /// Only the tool results of the **same** turn are removed, so deleting a
  /// message never eats another task's tool output.
  static void deleteMessage(Session session, int index) {
    if (index < 0 || index >= session.messages.length) return;
    final target = session.messages[index];
    if (target.role == MessageRole.system) return;
    var end = index + 1;
    if (target.role == MessageRole.assistant && target.hasToolCalls) {
      while (end < session.messages.length &&
          session.messages[end].role == MessageRole.tool &&
          session.messages[end].taskId == target.taskId) {
        end++;
      }
    }
    session.messages.removeRange(index, end);
    session.recomputeToolCalls();
    session.recomputeUsage();
    session.updatedAt = DateTime.now();
  }
}
