import 'dart:async';

import 'package:llm_api/llm_api.dart';
import 'package:llm_api/llm_api_testing.dart';
import 'package:test/test.dart';

/// A tool-call round: the model asks for `get_weather`.
List<Object?> toolCallRound({String id = 'call_1', String city = 'SF'}) => <Object?>[
      <String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'delta': <String, Object?>{
              'tool_calls': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'id': id,
                  'type': 'function',
                  'function': <String, Object?>{
                    'name': 'get_weather',
                    'arguments': '{"city":"$city"}',
                  },
                },
              ],
            },
          },
        ],
      },
      <String, Object?>{
        'choices': <Object?>[
          <String, Object?>{'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
        ],
      },
    ];

List<Object?> answerRound(String text) => <Object?>[
      <String, Object?>{
        'choices': <Object?>[
          <String, Object?>{'delta': <String, Object?>{'content': text}},
        ],
      },
      <String, Object?>{
        'choices': <Object?>[
          <String, Object?>{'delta': <String, Object?>{}, 'finish_reason': 'stop'},
        ],
      },
    ];

FunctionTool weatherTool({bool throwing = false}) => FunctionTool(
      name: 'get_weather',
      description: 'Current weather for a city',
      parameters: objectSchema(
        properties: <String, Object?>{'city': stringSchema(description: 'City name')},
        required: <String>['city'],
      ),
      handler: (arguments) {
        if (throwing) throw StateError('upstream weather service is down');
        return 'sunny in ${arguments['city']}';
      },
    );

ChatSession session(
  ScriptedTransport transport, {
  Iterable<LlmTool> tools = const <LlmTool>[],
  int maxToolRounds = 8,
  int? maxHistoryCharacters,
}) =>
    ChatSession(
      provider: OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: Uri.parse('https://api.test/v1'),
          name: 'test',
          apiKey: 'k',
        ),
        transport: transport,
      ),
      model: 'test-model',
      systemPrompt: 'You are a weather assistant.',
      tools: tools,
      maxToolRounds: maxToolRounds,
      maxHistoryCharacters: maxHistoryCharacters,
    );

void main() {
  group('ChatSession', () {
    test('runs a full tool round and feeds the result back', () async {
      final transport = ScriptedTransport(<FutureOr<TransportResponse> Function(TransportRequest)>[
        ScriptedTransport.sse(toolCallRound()),
        ScriptedTransport.sse(answerRound('It is sunny in SF.')),
      ]);
      final chat = session(transport, tools: <LlmTool>[weatherTool()]);

      final events = await chat.send('weather in SF?').toList();

      expect(events.whereType<Finished>(), hasLength(1), reason: 'one Finished per turn');
      final finished = events.whereType<Finished>().single;
      expect(finished.reason, FinishReason.stop);
      expect(finished.rounds, 2);
      expect(events.whereType<AssistantMessageCompleted>(), hasLength(2));
      expect(events.whereType<ToolCallStarted>().single.name, 'get_weather');

      final result = events.whereType<ToolResultEvent>().single;
      expect(result.result.content, 'sunny in SF');
      expect(result.result.isError, isFalse);
      expect(result.round, 1);

      expect(events.whereType<ContentDelta>().map((e) => e.text).join(), 'It is sunny in SF.');

      // History: system, user, assistant(tool_calls), tool, assistant.
      expect(chat.history, hasLength(5));
      expect(chat.history[2].toolCalls.single.name, 'get_weather');
      expect(chat.history[3].role, ChatRole.tool);
      expect(chat.history[3].toolCallId, 'call_1');
      expect(chat.history[4].content, 'It is sunny in SF.');
      expect(chat.turnCount, 1);

      // The second request must carry the tool result back to the model.
      final second = transport.requests[1].jsonBody!;
      final messages = (second['messages'] as List).cast<Map<String, Object?>>();
      expect(messages.map((m) => m['role']),
          <String>['system', 'user', 'assistant', 'tool']);
      expect(messages[3]['tool_call_id'], 'call_1');
      expect(messages[3]['content'], 'sunny in SF');
      expect((messages[2]['tool_calls'] as List), hasLength(1));
    });

    test('turns tool failures into error results instead of crashing', () async {
      final transport = ScriptedTransport(<FutureOr<TransportResponse> Function(TransportRequest)>[
        ScriptedTransport.sse(toolCallRound()),
        ScriptedTransport.sse(answerRound('The weather service is unavailable.')),
      ]);
      final chat = session(transport, tools: <LlmTool>[weatherTool(throwing: true)]);

      final events = await chat.send('weather?').toList();
      final result = events.whereType<ToolResultEvent>().single;
      expect(result.result.isError, isTrue);
      expect(result.result.content, contains('upstream weather service is down'));
      expect(chat.history[3].isError, isTrue);
      expect(events.whereType<Finished>().single.reason, FinishReason.stop);
    });

    test('reports an unknown tool back to the model', () async {
      final transport = ScriptedTransport(<FutureOr<TransportResponse> Function(TransportRequest)>[
        ScriptedTransport.sse(toolCallRound()),
        ScriptedTransport.sse(answerRound('I cannot do that.')),
      ]);
      final chat = session(transport, tools: <LlmTool>[]);
      // No tools registered at all: the model should not have asked, but if it
      // does we must not hang.
      final events = await chat.send('weather?').toList();
      expect(events.whereType<Finished>().single.reason, FinishReason.toolCalls);
      expect(chat.history, hasLength(3));
    });

    test('stops after maxToolRounds but leaves history consistent', () async {
      final transport = ScriptedTransport(<FutureOr<TransportResponse> Function(TransportRequest)>[
        ScriptedTransport.sse(toolCallRound(id: 'call_a')),
        ScriptedTransport.sse(toolCallRound(id: 'call_b')),
        ScriptedTransport.sse(answerRound('never reached')),
      ]);
      final chat = session(transport, tools: <LlmTool>[weatherTool()], maxToolRounds: 2);

      final events = await chat.send('loop please').toList();
      final finished = events.whereType<Finished>().single;
      expect(finished.reason, FinishReason.toolCalls);
      expect(finished.rounds, 2);
      expect(transport.requests, hasLength(2));

      // Every assistant tool_calls message is answered.
      final calls = chat.history
          .where((m) => m.hasToolCalls)
          .expand((m) => m.toolCalls)
          .map((c) => c.id)
          .toList();
      final results = chat.history
          .where((m) => m.role == ChatRole.tool)
          .map((m) => m.toolCallId)
          .toList();
      expect(results, calls);
    });

    test('streams reasoning and content separately mid-turn', () async {
      final transport = ScriptedTransport(<FutureOr<TransportResponse> Function(TransportRequest)>[
        ScriptedTransport.sse(<Object?>[
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{'reasoning_content': 'thinking…'}},
            ],
          },
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{'content': 'hi'}, 'finish_reason': 'stop'},
            ],
          },
        ]),
      ]);
      final chat = session(transport);
      final events = await chat.send('hello').toList();
      expect(events.first, isA<ReasoningDelta>());
      expect(chat.history.last.reasoningContent, 'thinking…');
      expect(chat.history.last.content, 'hi');
    });

    test('trimming never orphans a tool result', () async {
      final transport = ScriptedTransport(<FutureOr<TransportResponse> Function(TransportRequest)>[
        ScriptedTransport.sse(toolCallRound()),
        ScriptedTransport.sse(answerRound('done')),
        ScriptedTransport.sse(answerRound('second turn')),
      ]);
      final chat = session(
        transport,
        tools: <LlmTool>[weatherTool()],
        // Small enough to force dropping the first unit on the second turn.
        maxHistoryCharacters: 60,
      );

      await chat.send('first question');
      await chat.send('second question');

      expect(chat.history.first.role, ChatRole.system);
      expect(chat.history.where((m) => m.role == ChatRole.tool ||
          (m.role == ChatRole.assistant && m.hasToolCalls)), isEmpty);
      expect(chat.history.last.content, 'second turn');

      // Whatever survived is still a legal request.
      final messages = (transport.requests.last.jsonBody!['messages'] as List)
          .cast<Map<String, Object?>>();
      expect(messages.first['role'], 'system');
      expect(messages.where((m) => m['role'] == 'tool'), isEmpty);
    });

    test('rejects a second concurrent turn', () async {
      final transport = ScriptedTransport(<FutureOr<TransportResponse> Function(TransportRequest)>[
        ScriptedTransport.sse(answerRound('one')),
      ]);
      final chat = session(transport);
      final first = chat.send('a');
      final subscription = first.listen((_) {});
      // The generator only starts on the first listen.
      await Future<void>.delayed(Duration.zero);
      expect(chat.isBusy, isTrue);
      expect(() => chat.send('b'), throwsA(isA<StateError>()));
      await subscription.cancel();
      expect(chat.isBusy, isFalse);
    });

    test('round-trips through JSON', () async {
      final transport = ScriptedTransport(<FutureOr<TransportResponse> Function(TransportRequest)>[
        ScriptedTransport.sse(toolCallRound()),
        ScriptedTransport.sse(answerRound('sunny')),
      ]);
      final chat = session(transport, tools: <LlmTool>[weatherTool()]);
      await chat.send('weather?');

      final json = chat.toJson();
      final restored = ChatSession(
        provider: chat.provider,
        model: chat.model,
        registry: chat.registry,
      )..restore(json);

      expect(restored.history, hasLength(chat.history.length));
      expect(restored.history[2].toolCalls.single.name, 'get_weather');
      expect(restored.messages[4].reasoningContent, chat.messages[4].reasoningContent);
      expect(restored.history[3].toolCallId, 'call_1');
    });

    test('clear keeps the system prompt', () async {
      final transport = ScriptedTransport(<FutureOr<TransportResponse> Function(TransportRequest)>[
        ScriptedTransport.sse(answerRound('ok')),
      ]);
      final chat = session(transport);
      await chat.send('hello');
      chat.clear();
      expect(chat.history, hasLength(1));
      expect(chat.history.single.role, ChatRole.system);
      chat.clear(keepSystemPrompt: false);
      expect(chat.history, isEmpty);
    });
  });

  group('ToolRegistry', () {
    test('reports unknown tools and bad arguments as error results', () async {
      final registry = ToolRegistry(<LlmTool>[weatherTool()]);

      final unknown = await registry.invoke(const ToolCall(id: 'x', name: 'nope', arguments: '{}'));
      expect(unknown.isError, isTrue);
      expect(unknown.content, contains('Unknown tool "nope"'));
      expect(unknown.content, contains('get_weather'));

      final badJson =
          await registry.invoke(const ToolCall(id: 'y', name: 'get_weather', arguments: '{"city":'));
      expect(badJson.isError, isTrue);
      expect(badJson.content, contains('not valid JSON'));

      final ok = await registry.invoke(
        const ToolCall(id: 'z', name: 'get_weather', arguments: '{"city":"Paris"}'),
      );
      expect(ok.content, 'sunny in Paris');
    });

    test('truncates oversized results', () async {
      final registry = ToolRegistry(<LlmTool>[
        FunctionTool(
          name: 'big',
          description: 'returns a lot',
          handler: (_) => 'x' * 100,
        ),
      ])..maxResultCharacters = 10;
      final result = await registry.invoke(const ToolCall(id: 'a', name: 'big'));
      expect(result.content, startsWith('xxxxxxxxxx'));
      expect(result.content, contains('truncated 90 characters'));
    });

    test('times out slow tools', () async {
      final registry = ToolRegistry(<LlmTool>[
        FunctionTool(
          name: 'slow',
          description: 'never returns',
          handler: (_) async {
            await Future<void>.delayed(const Duration(seconds: 5));
            return 'done';
          },
        ),
      ])..timeout = const Duration(milliseconds: 20);
      final result = await registry.invoke(const ToolCall(id: 'a', name: 'slow'));
      expect(result.isError, isTrue);
      expect(result.content, contains('timed out'));
    });

    test('exposes definitions for the wire', () {
      final registry = ToolRegistry(<LlmTool>[weatherTool()]);
      expect(registry.definitions.single.name, 'get_weather');
      expect(registry.definitions.single.parameters['required'], <String>['city']);
      expect(registry.contains('get_weather'), isTrue);
      expect(registry.remove('get_weather'), isTrue);
      expect(registry.isEmpty, isTrue);
    });
  });
}
