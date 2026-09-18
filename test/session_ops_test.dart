import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_message.dart';
import 'package:xchat/models/token_usage.dart';
import 'package:xchat/session/session_ops.dart';

Session _session() => Session(
      id: 's1',
      sandbox: '/tmp/s',
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
      messages: [
        SessionMessage(role: MessageRole.system, content: 'sys'),
        SessionMessage(role: MessageRole.user, id: 'u1', content: 'first'),
        SessionMessage(
          role: MessageRole.assistant,
          id: 'a1',
          content: 'reply1',
          toolCalls: [ToolCallData(id: 'c1', name: 'shell', arguments: '{}')],
          usage: const TokenUsage(input: 10, output: 5),
        ),
        SessionMessage(role: MessageRole.tool, id: 't1', toolCallId: 'c1', content: 'ok'),
        SessionMessage(role: MessageRole.user, id: 'u2', content: 'second'),
      ],
    );

void main() {
  group('SessionOps', () {
    test('editLastUser truncates and replaces', () {
      final session = _session()..toolCalls = 1;
      final ok = SessionOps.editLastUser(session, 'second-edited');
      expect(ok, isTrue);
      expect(session.messages.last.role, MessageRole.user);
      expect(session.messages.last.content, 'second-edited');
      expect(session.messages.length, 5);
    });

    test('editLastUser in the middle drops later assistant/tool', () {
      final session = _session();
      // Move to the first user by dropping the last user first.
      session.messages.removeLast();
      final ok = SessionOps.editLastUser(session, 'first-edited');
      expect(ok, isTrue);
      // system + user only (assistant/tool after it removed).
      expect(session.messages.length, 2);
      expect(session.messages.last.content, 'first-edited');
      expect(session.toolCalls, 0);
    });

    test('cloneToFirstUser copies system + first user only', () {
      final session = _session();
      final clone = session.cloneToFirstUser();
      expect(clone.id, isNot(session.id));
      expect(clone.messages.length, 2);
      expect(clone.messages[0].role, MessageRole.system);
      expect(clone.messages[1].role, MessageRole.user);
      expect(clone.messages[1].content, 'first');
      expect(clone.toolCalls, 0);
    });
  });
}
