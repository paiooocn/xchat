import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/agent/openai_validator.dart';

void main() {
  group('OpenAiValidator.validate', () {
    test('基本 user/assistant 对话通过', () {
      final msgs = [
        {'role': 'system', 'content': '你是助手'},
        {'role': 'user', 'content': '你好'},
        {'role': 'assistant', 'content': '你好,有什么可以帮你?'},
      ];
      expect(OpenAiValidator.validate(msgs), null);
    });

    test('messages 为空拒绝', () {
      expect(OpenAiValidator.validate([]), isNotNull);
    });

    test('首条非 system/user 拒绝', () {
      final msgs = [
        {'role': 'assistant', 'content': 'hi'},
      ];
      final err = OpenAiValidator.validate(msgs);
      expect(err, contains('first message'));
    });

    test('末尾为 assistant 在 OpenAI 协议中是允许的', () {
      final msgs = [
        {'role': 'user', 'content': 'q'},
        {'role': 'assistant', 'content': 'a'},
      ];
      // 协议上允许(虽然实践中常以 user 收尾触发新一轮)
      expect(OpenAiValidator.validate(msgs), null);
    });

    test('完整工具往返 (assistant{tool_calls} → tool → assistant)', () {
      final msgs = [
        {'role': 'user', 'content': '读 README'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'read_file',
                'arguments': '{"path":"README.md"}',
              },
            }
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'hello'},
        {'role': 'assistant', 'content': 'README 内容是 hello'},
      ];
      expect(OpenAiValidator.validate(msgs), null);
    });

    test('多个并行 tool_calls 必须都有对应 tool 结果', () {
      final msgs = [
        {'role': 'user', 'content': 'list'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {'id': 'c1', 'type': 'function', 'function': {'name': 'list_dir', 'arguments': '{"path":"."}'}},
            {'id': 'c2', 'type': 'function', 'function': {'name': 'get_time', 'arguments': '{}'}},
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c1', 'content': 'a.txt'},
        {'role': 'tool', 'tool_call_id': 'c2', 'content': '2024-01-01'},
        {'role': 'assistant', 'content': 'done'},
      ];
      expect(OpenAiValidator.validate(msgs), null);
    });

    test('tool_call_id 不匹配拒绝', () {
      final msgs = [
        {'role': 'user', 'content': 'q'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {'id': 'c1', 'type': 'function', 'function': {'name': 'shell', 'arguments': '{}'}},
          ],
        },
        {'role': 'tool', 'tool_call_id': 'WRONG', 'content': 'x'},
        {'role': 'user', 'content': 'next'},
      ];
      final err = OpenAiValidator.validate(msgs);
      expect(err, isNotNull);
      expect(err, contains('WRONG'));
    });

    test('assistant{tool_calls} 后未接 tool 结果拒绝', () {
      final msgs = [
        {'role': 'user', 'content': 'q'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {'id': 'c1', 'type': 'function', 'function': {'name': 'shell', 'arguments': '{}'}},
          ],
        },
        {'role': 'user', 'content': 'next'},
      ];
      final err = OpenAiValidator.validate(msgs);
      expect(err, isNotNull);
      expect(err, contains('unconsumed'));
    });

    test('孤立 tool 消息拒绝', () {
      final msgs = [
        {'role': 'user', 'content': 'q'},
        {'role': 'tool', 'tool_call_id': 'orphan', 'content': 'x'},
      ];
      final err = OpenAiValidator.validate(msgs);
      expect(err, contains('orphan'));
    });

    test('arguments 不是字符串拒绝', () {
      final msgs = [
        {'role': 'user', 'content': 'q'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {'name': 'shell', 'arguments': {'cmd': 'ls'}},
            }
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c1', 'content': 'x'},
        {'role': 'user', 'content': 'next'},
      ];
      final err = OpenAiValidator.validate(msgs);
      expect(err, isNotNull);
      expect(err, contains('arguments must be JSON string'));
    });

    test('arguments 不是合法 JSON 拒绝', () {
      final msgs = [
        {'role': 'user', 'content': 'q'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {'name': 'shell', 'arguments': '{not json'},
            }
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c1', 'content': 'x'},
        {'role': 'user', 'content': 'next'},
      ];
      final err = OpenAiValidator.validate(msgs);
      expect(err, contains('not valid JSON'));
    });

    test('tool 消息缺 tool_call_id 拒绝', () {
      final msgs = [
        {'role': 'user', 'content': 'q'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {'id': 'c1', 'type': 'function', 'function': {'name': 'shell', 'arguments': '{}'}},
          ],
        },
        {'role': 'tool', 'content': 'x'},
      ];
      final err = OpenAiValidator.validate(msgs);
      expect(err, contains('tool_call_id'));
    });

    test('normalize 把 assistant{tool_calls}+null content 转为空字符串', () {
      final msgs = [
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {'id': 'c1', 'type': 'function', 'function': {'name': 'shell', 'arguments': '{}'}},
          ],
        },
      ];
      final n = OpenAiValidator.normalize(msgs);
      expect(n[0]['content'], '');
      // 不影响非 tool_calls 的 assistant
      final n2 = OpenAiValidator.normalize([
        {'role': 'assistant', 'content': null},
      ]);
      expect(n2[0]['content'], null);
    });

    test('多轮连续:tool_calls+tool+assistant+tool+user 全部对齐', () {
      final msgs = [
        {'role': 'user', 'content': 'round1'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {'id': 'r1', 'type': 'function', 'function': {'name': 'read_file', 'arguments': '{"path":"a"}'}},
          ],
        },
        {'role': 'tool', 'tool_call_id': 'r1', 'content': 'A'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {'id': 'r2', 'type': 'function', 'function': {'name': 'read_file', 'arguments': '{"path":"b"}'}},
          ],
        },
        {'role': 'tool', 'tool_call_id': 'r2', 'content': 'B'},
        {'role': 'assistant', 'content': 'all done'},
        {'role': 'user', 'content': 'next question'},
      ];
      expect(OpenAiValidator.validate(msgs), null);
    });
  });
}
