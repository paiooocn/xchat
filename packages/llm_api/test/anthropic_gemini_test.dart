import 'dart:async';

import 'package:llm_api/llm_api.dart';
import 'package:llm_api/llm_api_testing.dart';
import 'package:test/test.dart';

ChatRequest request({
  List<ChatMessage>? messages,
  ReasoningConfig? reasoning,
  List<ToolDefinition> tools = const <ToolDefinition>[],
  ToolChoice? toolChoice,
  int? maxTokens,
}) =>
    ChatRequest(
      model: 'claude-sonnet-4',
      messages: messages ?? <ChatMessage>[ChatMessage.user('hi')],
      reasoning: reasoning,
      tools: tools,
      toolChoice: toolChoice,
      maxTokens: maxTokens,
    );

AnthropicProvider anthropic(MockHttpTransport transport) => AnthropicProvider(
      config: AnthropicConfig(apiKey: 'sk-ant', baseUrl: Uri.parse('https://api.anthropic.test')),
      transport: transport,
    );

GeminiProvider gemini(MockHttpTransport transport) => GeminiProvider(
      config: GeminiConfig(apiKey: 'gm-key', baseUrl: Uri.parse('https://gemini.test')),
      transport: transport,
    );

const emptyStream = <Object?>[];

void main() {
  group('Anthropic', () {
    test('hoists system, encodes tools and thinking, merges tool results', () async {
      final transport = MockHttpTransport.sse(
        <Object?>[
          <String, Object?>{
            'choices': <Object?>[], // never read: Anthropic uses typed events
          },
        ],
      );
      final provider = anthropic(transport);
      await provider.complete(
        request(
          maxTokens: 2048,
          reasoning: const ReasoningConfig(budgetTokens: 1024),
          tools: const <ToolDefinition>[
            ToolDefinition(name: 'lookup', description: 'look things up'),
          ],
          toolChoice: const ToolChoice.required(),
          messages: <ChatMessage>[
            ChatMessage.system('be terse'),
            ChatMessage.user('who?'),
            ChatMessage.assistant(
              content: 'checking',
              reasoningContent: 'maybe it is X',
              reasoningSignature: 'sig-1',
              toolCalls: const <ToolCall>[
                ToolCall(id: 'toolu_1', name: 'lookup', arguments: '{"q":"who"}'),
              ],
            ),
            ChatMessage.tool(toolCallId: 'toolu_1', name: 'lookup', content: 'Alice'),
            ChatMessage.tool(toolCallId: 'toolu_2', name: 'lookup', content: 'nope', isError: true),
          ],
        ),
      );

      final body = transport.lastBody;
      expect(transport.lastRequest!.uri.toString(), 'https://api.anthropic.test/v1/messages');
      expect(transport.lastRequest!.headers['x-api-key'], 'sk-ant');
      expect(transport.lastRequest!.headers['anthropic-version'], '2023-06-01');
      expect(body['max_tokens'], 2048);
      expect(body['system'], 'be terse');
      expect(body['thinking'], <String, Object?>{'type': 'enabled', 'budget_tokens': 1024});
      expect(body['tools'], <Object?>[
        <String, Object?>{
          'name': 'lookup',
          'description': 'look things up',
          'input_schema': <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{},
          },
        },
      ]);
      expect(body['tool_choice'], <String, Object?>{'type': 'any'});
      // Extended thinking requires temperature == 1, so we simply omit it.
      expect(body.containsKey('temperature'), isFalse);

      final messages = transport.lastMessages;
      expect(messages, hasLength(3));
      expect(messages[0]['role'], 'user');
      expect((messages[1]['content'] as List).first, <String, Object?>{
        'type': 'thinking',
        'thinking': 'maybe it is X',
        'signature': 'sig-1',
      });
      // The two tool results are merged into a single user turn.
      expect(messages[2]['role'], 'user');
      final results = messages[2]['content'] as List;
      expect(results, hasLength(2));
      expect((results[0] as Map)['type'], 'tool_result');
      expect((results[0] as Map)['tool_use_id'], 'toolu_1');
      expect((results[1] as Map)['is_error'], isTrue);
    });

    test('decodes thinking blocks, signatures and streamed tool input', () async {
      final transport = MockHttpTransport.sse(
        <Object?>[
          const RawSse(
            'event: message_start\ndata: {"type":"message_start","message":{"id":"msg_1",'
            '"model":"claude-sonnet-4","usage":{"input_tokens":12,"output_tokens":1}}}',
          ),
          <String, Object?>{
            'type': 'content_block_start',
            'index': 0,
            'content_block': <String, Object?>{'type': 'thinking', 'thinking': ''},
          },
          <String, Object?>{
            'type': 'content_block_delta',
            'index': 0,
            'delta': <String, Object?>{'type': 'thinking_delta', 'thinking': 'weighing '},
          },
          <String, Object?>{
            'type': 'content_block_delta',
            'index': 0,
            'delta': <String, Object?>{'type': 'thinking_delta', 'thinking': 'options'},
          },
          <String, Object?>{
            'type': 'content_block_delta',
            'index': 0,
            'delta': <String, Object?>{'type': 'signature_delta', 'signature': 'sig-abc'},
          },
          const RawSse('event: content_block_stop\ndata: {"type":"content_block_stop","index":0}'),
          <String, Object?>{
            'type': 'content_block_start',
            'index': 1,
            'content_block': <String, Object?>{
              'type': 'tool_use',
              'id': 'toolu_9',
              'name': 'lookup',
            },
          },
          <String, Object?>{
            'type': 'content_block_delta',
            'index': 1,
            'delta': <String, Object?>{'type': 'input_json_delta', 'partial_json': '{"q":'},
          },
          <String, Object?>{
            'type': 'content_block_delta',
            'index': 1,
            'delta': <String, Object?>{'type': 'input_json_delta', 'partial_json': '"who"}'},
          },
          <String, Object?>{
            'type': 'message_delta',
            'delta': <String, Object?>{'stop_reason': 'tool_use'},
            'usage': <String, Object?>{'output_tokens': 7},
          },
          <String, Object?>{'type': 'message_stop'},
        ],
        fragmentSize: 1,
      );

      final events = await anthropic(transport).stream(request()).toList();
      expect(
        events.whereType<ReasoningDelta>().map((e) => e.text).join(),
        'weighing options',
      );
      expect(
        events.whereType<ReasoningSignatureDelta>().map((e) => e.signature).join(),
        'sig-abc',
      );
      final finished = events.whereType<Finished>().single;
      expect(finished.reason, FinishReason.toolCalls);
      expect(finished.usage.inputTokens, 12);
      expect(finished.usage.outputTokens, 7);
    });

    test('grows max_tokens past the thinking budget and reports usage', () async {
      final transport = MockHttpTransport.sse(<Object?>[
        <String, Object?>{
          'type': 'message_delta',
          'delta': <String, Object?>{'stop_reason': 'end_turn'},
          'usage': <String, Object?>{'output_tokens': 2},
        },
        <String, Object?>{'type': 'message_stop'},
      ]);
      final response = await anthropic(transport).complete(
        request(reasoning: const ReasoningConfig(budgetTokens: 4096), maxTokens: 512),
      );
      expect(transport.lastBody['max_tokens'], 5120);
      expect(response.finishReason, FinishReason.stop);
    });

    test('drops a completed response with only thinking into reasoningContent', () async {
      final transport = MockHttpTransport.sse(<Object?>[
        <String, Object?>{
          'type': 'content_block_delta',
          'index': 0,
          'delta': <String, Object?>{'type': 'thinking_delta', 'thinking': 'silent'},
        },
        <String, Object?>{'type': 'message_stop'},
      ]);
      final response = await anthropic(transport).complete(request());
      expect(response.reasoningContent, 'silent');
      expect(response.text, isEmpty);
    });
  });

  group('Gemini', () {
    test('encodes contents, system instruction, tools and thinking budget', () async {
      final transport = MockHttpTransport.sse(emptyStream);
      await gemini(transport).complete(
        request(
          reasoning: const ReasoningConfig(effort: ReasoningEffort.high),
          tools: const <ToolDefinition>[ToolDefinition(name: 'lookup', description: 'd')],
          toolChoice: const ToolChoice.function('lookup'),
          messages: <ChatMessage>[
            ChatMessage.system('be terse'),
            ChatMessage.user('hi'),
            ChatMessage.assistant(
              toolCalls: const <ToolCall>[
                ToolCall(id: 'call_0', name: 'lookup', arguments: '{"q":"x"}'),
              ],
            ),
            ChatMessage.tool(toolCallId: 'call_0', name: 'lookup', content: '{"found":1}'),
          ],
        ),
      );

      expect(
        transport.lastRequest!.uri.toString(),
        'https://gemini.test/v1beta/models/claude-sonnet-4:streamGenerateContent?alt=sse',
      );
      expect(transport.lastRequest!.headers['x-goog-api-key'], 'gm-key');
      final body = transport.lastBody;
      expect(body['systemInstruction'], <String, Object?>{
        'parts': <Object?>[
          <String, Object?>{'text': 'be terse'},
        ],
      });
      expect(body['generationConfig'], <String, Object?>{
        'thinkingConfig': <String, Object?>{'includeThoughts': true, 'thinkingBudget': 16384},
      });
      final contents = body['contents'] as List;
      expect((contents[0] as Map)['role'], 'user');
      expect((contents[1] as Map)['role'], 'model');
      expect(((contents[1] as Map)['parts'] as List).single, <String, Object?>{
        'functionCall': <String, Object?>{
          'name': 'lookup',
          'args': <String, Object?>{'q': 'x'},
        },
      });
      // Tool results come back keyed by function NAME, not by call id.
      expect(((contents[2] as Map)['parts'] as List).single, <String, Object?>{
        'functionResponse': <String, Object?>{
          'name': 'lookup',
          'response': <String, Object?>{'result': <String, Object?>{'found': 1}},
        },
      });
      expect(body['toolConfig'], <String, Object?>{
        'functionCallingConfig': <String, Object?>{
          'mode': 'ANY',
          'allowedFunctionNames': <Object?>['lookup'],
        },
      });
    });

    test('separates thought parts from the answer', () async {
      final transport = MockHttpTransport.sse(
        <Object?>[
          <String, Object?>{
            'candidates': <Object?>[
              <String, Object?>{
                'content': <String, Object?>{
                  'role': 'model',
                  'parts': <Object?>[
                    <String, Object?>{'text': 'silent reasoning', 'thought': true},
                  ],
                },
              },
            ],
          },
          <String, Object?>{
            'candidates': <Object?>[
              <String, Object?>{
                'content': <String, Object?>{
                  'role': 'model',
                  'parts': <Object?>[
                    <String, Object?>{'text': 'The answer'},
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
            'usageMetadata': <String, Object?>{
              'promptTokenCount': 5,
              'candidatesTokenCount': 2,
              'thoughtsTokenCount': 3,
            },
          },
        ],
        fragmentSize: 2,
      );

      final response = await gemini(transport).complete(request());
      expect(response.reasoningContent, 'silent reasoning');
      expect(response.text, 'The answer');
      expect(response.finishReason, FinishReason.stop);
      expect(response.usage.reasoningTokens, 3);
    });

    test('turns functionCall parts into tool calls', () async {
      final transport = MockHttpTransport.sse(<Object?>[
        <String, Object?>{
          'candidates': <Object?>[
            <String, Object?>{
              'content': <String, Object?>{
                'parts': <Object?>[
                  <String, Object?>{
                    'functionCall': <String, Object?>{'name': 'lookup', 'args': <String, Object?>{'q': 'x'}},
                  },
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        },
      ]);
      final response = await gemini(transport).complete(request());
      expect(response.toolCalls.single.name, 'lookup');
      expect(response.toolCalls.single.argumentsAsMap(), <String, Object?>{'q': 'x'});
    });

    test('merges a functionCall whose arguments were split across chunks', () async {
      final transport = MockHttpTransport.sse(<Object?>[
        <String, Object?>{
          'candidates': <Object?>[
            <String, Object?>{
              'content': <String, Object?>{
                'parts': <Object?>[
                  <String, Object?>{
                    'functionCall': <String, Object?>{'name': 'write', 'args': <String, Object?>{'a': 1}},
                  },
                ],
              },
            },
          ],
        },
        <String, Object?>{
          'candidates': <Object?>[
            <String, Object?>{
              'content': <String, Object?>{
                'parts': <Object?>[
                  <String, Object?>{
                    // Continuation: no closing brace above, so this appends.
                    'functionCall': <String, Object?>{'name': 'write', 'args': <String, Object?>{'b': 2}},
                  },
                ],
              },
            },
          ],
        },
      ]);
      final response = await gemini(transport).complete(request());
      expect(response.toolCalls, hasLength(1));
      expect(response.toolCalls.single.argumentsAsMap(), <String, Object?>{'a': 1, 'b': 2});
    });

    test('keeps separate calls to the same function apart', () async {
      final transport = MockHttpTransport.sse(<Object?>[
        <String, Object?>{
          'candidates': <Object?>[
            <String, Object?>{
              'content': <String, Object?>{
                'parts': <Object?>[
                  <String, Object?>{
                    'functionCall': <String, Object?>{'name': 'write', 'args': <String, Object?>{'a': 1}},
                  },
                  <String, Object?>{
                    'functionCall': <String, Object?>{'name': 'write', 'args': <String, Object?>{'b': 2}},
                  },
                ],
              },
            },
          ],
        },
      ]);
      final response = await gemini(transport).complete(request());
      expect(response.toolCalls, hasLength(2));
      expect(response.toolCalls.map((c) => c.argumentsAsMap()),
          <Map<String, Object?>>[<String, Object?>{'a': 1}, <String, Object?>{'b': 2}]);
    });
  });
}
