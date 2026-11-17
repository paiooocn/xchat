import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/data/xml/session_xml.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_message.dart';
import 'package:xchat/models/session_params.dart';
import 'package:xchat/models/token_usage.dart';

void main() {
  group('SessionXml', () {
    test('round-trips a session with thinking, tools and usage', () {
      final session = Session(
        id: '550e8400-e29b-41d4-a716-446655440000',
        sandbox: '/tmp/xchat/sessions',
        createdAt: DateTime.utc(2025, 1, 15, 10, 30),
        updatedAt: DateTime.utc(2025, 1, 15, 11, 45),
        toolCalls: 1,
        toolCallsLimit: 20,
        title: '排序算法 <测试>',
        tags: ['编程', '算法'],
        provider: 'deepseek',
        model: 'deepseek-reasoner',
        tools: ['read_file', 'shell'],
        params: SessionParams(temperature: 0.7, thinking: ThinkingSwitch.auto),
        cumulativeUsage: const TokenUsage(input: 15230, output: 4120, cache: 12000),
        contextTokens: 2680,
        messages: [
          SessionMessage(role: MessageRole.system, content: '你是一个助手 <ok>'),
          SessionMessage(role: MessageRole.user, id: 'm1', content: '写个快排'),
          SessionMessage(
            role: MessageRole.assistant,
            id: 'm2',
            content: '好的',
            reasoning: '思考 <x> 中',
            reasoningMode: 'reasoning_content',
            toolCalls: [
              ToolCallData(id: 'call_1', name: 'write_file', arguments: '{"path":"a.dart"}'),
            ],
            usage: const TokenUsage(input: 1200, output: 850, cache: 300),
          ),
          SessionMessage(
            role: MessageRole.tool,
            id: 'm3',
            toolCallId: 'call_1',
            toolName: 'write_file',
            content: 'OK',
          ),
        ],
      );

      final xml = SessionXml.encode(session);
      // CDATA must be used, not entity escaping.
      expect(xml.contains('<![CDATA['), isTrue);
      expect(xml.contains('&lt;'), isFalse);

      final decoded = SessionXml.decode(xml, filePath: '/tmp/xchat/sessions/x.xml');
      expect(decoded.id, session.id);
      expect(decoded.sandbox, session.sandbox);
      expect(decoded.toolCalls, 1);
      expect(decoded.toolCallsLimit, 20);
      expect(decoded.title, '排序算法 <测试>');
      expect(decoded.tags, ['编程', '算法']);
      expect(decoded.tools, ['read_file', 'shell']);
      expect(decoded.params.temperature, 0.7);
      expect(decoded.cumulativeUsage.input, 15230);
      expect(decoded.cumulativeUsage.output, 4120);
      expect(decoded.cumulativeUsage.cache, 12000);
      expect(decoded.contextTokens, 2680);

      expect(decoded.messages.first.role, MessageRole.system);
      expect(decoded.messages[1].content, '写个快排');
      final assistant = decoded.messages[2];
      expect(assistant.reasoning, '思考 <x> 中');
      expect(assistant.reasoningMode, 'reasoning_content');
      expect(assistant.usage.input, 1200);
      expect(assistant.toolCalls.single.id, 'call_1');
      expect(assistant.toolCalls.single.name, 'write_file');
      expect(decoded.messages[3].toolCallId, 'call_1');
      expect(decoded.messages[3].role, MessageRole.tool);
    });

    test('round-trips message timestamps (sent_at / received_at)', () {
      final session = Session(
        id: 'id-ts',
        sandbox: '/tmp/s',
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
        messages: [
          SessionMessage(role: MessageRole.system, content: ''),
          SessionMessage(
            role: MessageRole.user,
            id: 'u1',
            content: 'hi',
            sentAt: DateTime.utc(2025, 1, 2, 3, 4, 5),
          ),
          SessionMessage(
            role: MessageRole.assistant,
            id: 'a1',
            content: 'yo',
            receivedAt: DateTime.utc(2025, 1, 2, 3, 5, 6),
          ),
        ],
      );

      final xml = SessionXml.encode(session);
      expect(xml, contains('sent_at="2025-01-02T03:04:05.000Z"'));
      expect(xml, contains('received_at="2025-01-02T03:05:06.000Z"'));

      final decoded = SessionXml.decode(xml, filePath: '/tmp/s/id-ts.xml');
      expect(decoded.messages[1].sentAt, DateTime.utc(2025, 1, 2, 3, 4, 5));
      expect(decoded.messages[2].receivedAt, DateTime.utc(2025, 1, 2, 3, 5, 6));
    });

    test('旧文件没有时间属性 → null（不显示时间）', () {
      const xml = '<chat sandbox="/tmp/s"><user id="u">hi</user>'
          '<assistant id="a">yo</assistant></chat>';
      final decoded = SessionXml.decode(xml, filePath: '/tmp/s/legacy.xml');
      expect(decoded.messages[1].sentAt, isNull);
      expect(decoded.messages[2].receivedAt, isNull);
    });

    test('always keeps a system element even for an empty session', () {
      final session = Session(
        id: 'id-1',
        sandbox: '/tmp/s',
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
      );
      final xml = SessionXml.encode(session);
      expect(xml.contains('<system'), isTrue);
      final decoded = SessionXml.decode(xml, filePath: '/tmp/s/id-1.xml');
      expect(decoded.messages.first.role, MessageRole.system);
    });
  });
}
