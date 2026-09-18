import '../models/session.dart';
import '../models/session_message.dart';

/// Pure session transformations (no IO).
class SessionOps {
  const SessionOps._();

  /// Index of the last user message, or `-1`.
  static int lastUserIndex(Session session) {
    for (var i = session.messages.length - 1; i >= 0; i--) {
      if (session.messages[i].role == MessageRole.user) return i;
    }
    return -1;
  }

  /// Truncates everything after the last user message and replaces its content.
  ///
  /// Returns `false` when there is no user message to edit.
  static bool editLastUser(Session session, String newText) {
    final index = lastUserIndex(session);
    if (index < 0) return false;
    session.messages.removeRange(index + 1, session.messages.length);
    session.messages[index].content = newText;
    session.recomputeToolCalls();
    session.recomputeUsage();
    session.updatedAt = DateTime.now();
    return true;
  }

  /// Drops the trailing assistant turn (and its tool results) so it can be
  /// regenerated. Returns `false` when there is nothing to drop.
  static bool dropLastAssistant(Session session) {
    var index = -1;
    for (var i = session.messages.length - 1; i >= 0; i--) {
      if (session.messages[i].role == MessageRole.assistant) {
        index = i;
        break;
      }
    }
    if (index < 0) return false;
    session.messages.removeRange(index, session.messages.length);
    session.recomputeToolCalls();
    session.recomputeUsage();
    session.updatedAt = DateTime.now();
    return true;
  }

  /// Removes a message (and any tool results that follow an assistant turn).
  static void deleteMessage(Session session, int index) {
    if (index < 0 || index >= session.messages.length) return;
    if (session.messages[index].role == MessageRole.system) return;
    var end = index + 1;
    if (session.messages[index].role == MessageRole.assistant &&
        session.messages[index].hasToolCalls) {
      while (end < session.messages.length &&
          session.messages[end].role == MessageRole.tool) {
        end++;
      }
    }
    session.messages.removeRange(index, end);
    session.recomputeToolCalls();
    session.recomputeUsage();
    session.updatedAt = DateTime.now();
  }
}
