import 'dart:async';

import 'package:llm_api/llm_api.dart';
import 'package:llm_api/llm_api_testing.dart';
import 'package:test/test.dart';

OpenAiCompatibleProvider build(
  MockHttpTransport transport, {
  ReasoningSource source = ReasoningSource.auto,
  int maxRetries = 0,
  OpenAiReasoningRequestStyle reasoningStyle = OpenAiReasoningRequestStyle.none,
  OpenAiCompatibleConfig Function(OpenAiCompatibleConfig config)? tweak,
}) {
  var config = OpenAiCompatibleConfig(
    baseUrl: Uri.parse('https://api.test/v1'),
    name: 'test',
    apiKey: 'sk-test',
    reasoningSource: source,
    reasoningRequestStyle: reasoningStyle,
  );
  if (tweak != null) config = tweak(config);
  return OpenAiCompatibleProvider(
    config: config,
    transport: transport,
    maxRetries: maxRetries,
    retryBaseDelay: Duration.zero,
  );
}

ChatRequest simpleRequest({String text = 'hi'}) => ChatRequest(
      model: 'test-model',
      messages: <ChatMessage>[ChatMessage.user(text)],
    );

void main() {
  group('OpenAI-compatible wire format', () {
    test('encodes every role', () async {
      final transport = MockHttpTransport.sse(<Object?>[
        <String, Object?>{
          'choices': <Object?>[
            <String, Object?>{'delta': <String, Object?>{'content': 'ok'}, 'finish_reason': 'stop'},
          ],
        },
      ]);
      final provider = build(transport);
      await provider.complete(
        ChatRequest(
          model: 'm',
          temperature: 0.3,
          maxTokens: 128,
          messages: <ChatMessage>[
            ChatMessage.system('be nice'),
            ChatMessage.user('hi'),
            ChatMessage.assistant(
              content: 'let me look',
              toolCalls: const <ToolCall>[
                ToolCall(id: 'call_1', name: 'lookup', arguments: '{"q":"x"}'),
              ],
            ),
            ChatMessage.tool(toolCallId: 'call_1', name: 'lookup', content: '{"found":true}'),
            ChatMessage.assistant(content: 'done', reasoningContent: 'secret thinking'),
          ],
          tools: const <ToolDefinition>[
            ToolDefinition(name: 'lookup', description: 'Look something up'),
          ],
          toolChoice: const ToolChoice.auto(),
        ),
      );

      final body = transport.lastBody;
      expect(transport.lastRequest!.uri.toString(), 'https://api.test/v1/chat/completions');
      expect(transport.lastRequest!.headers['authorization'], 'Bearer sk-test');
      expect(body['model'], 'm');
      expect(body['stream'], isTrue);
      expect(body['stream_options'], <String, Object?>{'include_usage': true});
      expect(body['temperature'], 0.3);
      expect(body['max_tokens'], 128);
      expect(body['tool_choice'], <String, Object?>{'type': 'auto'});
      expect((body['tools'] as List).single, <String, Object?>{
        'type': 'function',
        'function': <String, Object?>{
          'name': 'lookup',
          'description': 'Look something up',
          'parameters': <String, Object?>{'type': 'object', 'properties': <String, Object?>{}},
        },
      });

      final messages = transport.lastMessages;
      expect(messages[0], <String, Object?>{'role': 'system', 'content': 'be nice'});
      expect(messages[1], <String, Object?>{'role': 'user', 'content': 'hi'});
      expect(messages[2]['role'], 'assistant');
      expect((messages[2]['tool_calls'] as List).single, <String, Object?>{
        'id': 'call_1',
        'type': 'function',
        'function': <String, Object?>{'name': 'lookup', 'arguments': '{"q":"x"}'},
      });
      // A pure tool-call turn must not smuggle an empty `content` string.
      expect(messages[2].containsKey('content'), isFalse);
      expect(messages[3], <String, Object?>{
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': '{"found":true}',
        'name': 'lookup',
      });
      // Reasoning is not replayed by default (DeepSeek drops it, gateways reject it).
      expect(messages[4].containsKey('reasoning_content'), isFalse);
      expect(messages[4]['content'], 'done');
    });

    test('replays reasoning when explicitly requested', () async {
      final transport = MockHttpTransport.sse(<Object?>[
        <String, Object?>{'choices': <Object?>[<String, Object?>{'delta': <String, Object?>{'content': 'x'}}]},
      ]);
      await build(transport).complete(
        ChatRequest(
          model: 'm',
          reasoning: const ReasoningConfig(includeInHistory: true),
          messages: <ChatMessage>[
            ChatMessage.assistant(content: 'done', reasoningContent: 'secret'),
            ChatMessage.user('next'),
          ],
        ),
      );
      expect(transport.lastMessages.first['reasoning_content'], 'secret');
    });

    test('maps reasoning effort to variants the vendor understands', () async {
      final transport = MockHttpTransport.sse(<Object?>[<String, Object?>{'choices': <Object?>[]}]);
      await build(transport, reasoningStyle: OpenAiReasoningRequestStyle.reasoningEffort).complete(
        ChatRequest(
          model: 'o4-mini',
          reasoning: const ReasoningConfig(effort: ReasoningEffort.high),
          messages: <ChatMessage>[ChatMessage.user('hi')],
        ),
      );
      expect(transport.lastBody['reasoning_effort'], 'high');

      final qwen = MockHttpTransport.sse(<Object?>[<String, Object?>{'choices': <Object?>[]}]);
      await build(qwen, reasoningStyle: OpenAiReasoningRequestStyle.enableThinking).complete(
        ChatRequest(
          model: 'qwen3',
          reasoning: const ReasoningConfig(enabled: true, budgetTokens: 2048),
          messages: <ChatMessage>[ChatMessage.user('hi')],
        ),
      );
      expect(qwen.lastBody['enable_thinking'], isTrue);
      expect(qwen.lastBody['thinking_budget'], 2048);

      final glm = MockHttpTransport.sse(<Object?>[<String, Object?>{'choices': <Object?>[]}]);
      await build(glm, reasoningStyle: OpenAiReasoningRequestStyle.thinkingBudget).complete(
        ChatRequest(
          model: 'glm-4.6',
          reasoning: const ReasoningConfig(budgetTokens: 4096),
          messages: <ChatMessage>[ChatMessage.user('hi')],
        ),
      );
      expect(glm.lastBody['thinking'], <String, Object?>{'type': 'enabled', 'budget_tokens': 4096});
    });

    test('merges extra body overrides last', () async {
      final transport = MockHttpTransport.sse(<Object?>[<String, Object?>{'choices': <Object?>[]}]);
      await build(transport).complete(
        ChatRequest(
          model: 'm',
          messages: <ChatMessage>[ChatMessage.user('hi')],
          extra: const <String, Object?>{'top_k': 5, 'stream': false},
        ),
      );
      expect(transport.lastBody['top_k'], 5);
      // `extra` is the documented escape hatch: it wins over generated fields.
      expect(transport.lastBody['stream'], isFalse);
    });
  });

  group('OpenAI-compatible streaming decode', () {
    test('splits reasoning_content from content', () async {
      final transport = MockHttpTransport.sse(
        <Object?>[
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{'reasoning_content': 'Let me '}},
            ],
          },
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{'reasoning_content': 'think.'}},
            ],
          },
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{'content': '4'}},
            ],
          },
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{'content': '2'}, 'finish_reason': 'stop'},
            ],
          },
          <String, Object?>{
            'choices': <Object?>[],
            'usage': <String, Object?>{
              'prompt_tokens': 10,
              'completion_tokens': 5,
              'completion_tokens_details': <String, Object?>{'reasoning_tokens': 3},
            },
          },
        ],
        // One byte per HTTP chunk: SSE framing, JSON and tag parsing all get
        // exercised at every possible split point.
        fragmentSize: 1,
      );

      final events = await build(transport).stream(simpleRequest()).toList();
      final reasoning = events.whereType<ReasoningDelta>().map((e) => e.text).join();
      final content = events.whereType<ContentDelta>().map((e) => e.text).join();

      expect(reasoning, 'Let me think.');
      expect(content, '42');
      expect(events.whereType<Finished>(), hasLength(1));
      final finished = events.whereType<Finished>().single;
      expect(finished.reason, FinishReason.stop);
      expect(finished.usage.reasoningTokens, 3);
      expect(finished.usage.inputTokens, 10);
      expect(finished.usage.totalTokens, 15);
    });

    test('extracts inline think tags when the gateway inlines them', () async {
      final transport = MockHttpTransport.sse(
        <Object?>[
          for (final chunk in <String>['Bal', 'ance the eq', 'uation:  thinking2+2', '=4<｜end▁of▁thinking｜>4'])
            <String, Object?>{
              'choices': <Object?>[
                <String, Object?>{'delta': <String, Object?>{'content': chunk}},
              ],
            },
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{}, 'finish_reason': 'stop'},
            ],
          },
        ],
        fragmentSize: 3,
      );

      final response = await build(transport).complete(simpleRequest());
      expect(response.text, 'Balance the equation: 4');
      expect(response.reasoningContent, '2+2=4');
    });

    test('assembles streamed tool call fragments by index', () async {
      final transport = MockHttpTransport.sse(
        <Object?>[
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'delta': <String, Object?>{
                  'tool_calls': <Object?>[
                    <String, Object?>{
                      'index': 0,
                      'id': 'call_abc',
                      'type': 'function',
                      'function': <String, Object?>{'name': 'get_weather', 'arguments': ''},
                    },
                  ],
                },
              },
            ],
          },
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'delta': <String, Object?>{
                  'tool_calls': <Object?>[
                    <String, Object?>{'index': 0, 'function': <String, Object?>{'arguments': '{"ci'}},
                  ],
                },
              },
            ],
          },
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'delta': <String, Object?>{
                  'tool_calls': <Object?>[
                    <String, Object?>{'index': 0, 'function': <String, Object?>{'arguments': 'ty":"SF"}'}},
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
        ],
        fragmentSize: 2,
      );

      final response = await build(transport).complete(simpleRequest());
      expect(response.toolCalls, hasLength(1));
      final call = response.toolCalls.single;
      expect(call.id, 'call_abc');
      expect(call.name, 'get_weather');
      expect(call.arguments, '{"city":"SF"}');
      expect(call.argumentsAsMap(), <String, Object?>{'city': 'SF'});
      expect(response.finishReason, FinishReason.toolCalls);
    });

    test('assembles parallel tool calls in order', () async {
      final transport = MockHttpTransport.sse(<Object?>[
        <String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{
                'tool_calls': <Object?>[
                  <String, Object?>{
                    'index': 0,
                    'id': 'a',
                    'function': <String, Object?>{'name': 'one', 'arguments': '{"n":1}'},
                  },
                  <String, Object?>{
                    'index': 1,
                    'id': 'b',
                    'function': <String, Object?>{'name': 'two', 'arguments': '{"n":2}'},
                  },
                ],
              },
            },
          ],
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
            ],
          },
        ],
      ]);

      final response = await build(transport).complete(simpleRequest());
      expect(response.toolCalls.map((c) => c.name), <String>['one', 'two']);
      expect(response.toolCalls.map((c) => c.arguments), <String>['{"n":1}', '{"n":2}']);
    });

    test('reads OpenRouter reasoning_details', () async {
      final transport = MockHttpTransport.sse(<Object?>[
        <String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{
                'reasoning_details': <Object?>[
                  <String, Object?>{'type': 'reasoning.text', 'text': 'part one '},
                ],
              },
            },
          ],
        },
        <String, Object?>{
          'choices': <Object?>[
            <String, Object?>{'delta': <String, Object?>{'content': 'done'}, 'finish_reason': 'stop'},
          ],
        },
      ]);
      final response = await build(transport).complete(simpleRequest());
      expect(response.reasoningContent, 'part one ');
      expect(response.text, 'done');
    });
  });

  group('error handling', () {
    test('maps 401 to AuthenticationException', () async {
      final transport = MockHttpTransport.error(401, '{"error":{"message":"invalid api key"}}');
      expect(
        () => build(transport).complete(simpleRequest()),
        throwsA(isA<AuthenticationException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', 'invalid api key')),
      );
    });

    test('maps context overflow to ContextLengthException', () async {
      final transport = MockHttpTransport.error(
        400,
        '{"error":{"message":"This model\'s maximum context length is 8192 tokens"}}',
      );
      expect(
        () => build(transport).complete(simpleRequest()),
        throwsA(isA<ContextLengthException>()),
      );
    });

    test('retries 500 before the stream starts', () async {
      final transport = ScriptedTransport(<FutureOr<TransportResponse> Function(TransportRequest)>[
        ScriptedTransport.sse(<Object?>[], statusCode: 500),
        ScriptedTransport.sse(<Object?>[
          <String, Object?>{
            'choices': <Object?>[
              <String, Object?>{'delta': <String, Object?>{'content': 'recovered'}, 'finish_reason': 'stop'},
            ],
          },
        ]),
      ]);
      final retrying = OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: Uri.parse('https://api.test/v1'),
          name: 'test',
          apiKey: 'sk-test',
        ),
        transport: transport,
        maxRetries: 2,
        retryBaseDelay: Duration.zero,
      );
      final response = await retrying.complete(simpleRequest());
      expect(response.text, 'recovered');
      expect(transport.requests, hasLength(2));
    });

    test('surfaces a 200-with-error-frame as a failure', () async {
      final transport = MockHttpTransport.sse(<Object?>[
        <String, Object?>{'error': <String, Object?>{'message': 'model overloaded'}},
      ]);
      expect(
        () => build(transport).complete(simpleRequest()),
        throwsA(isA<LlmApiException>().having((e) => e.message, 'message', contains('overloaded'))),
      );
    });
  });

  group('listModels', () {
    test('parses the standard payload', () async {
      final transport = MockHttpTransport.json(<String, Object?>{
        'data': <Object?>[
          <String, Object?>{'id': 'deepseek-chat'},
          <String, Object?>{'id': 'deepseek-reasoner'},
        ],
      });
      final models = await build(transport).listModels();
      expect(models.map((m) => m.id), <String>['deepseek-chat', 'deepseek-reasoner']);
      expect(transport.lastRequest!.method, 'GET');
      expect(transport.lastRequest!.uri.toString(), 'https://api.test/v1/models');
    });
  });
}
