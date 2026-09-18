/// Provider for the OpenAI `/chat/completions` wire format.
///
/// This one adapter covers a large chunk of the ecosystem, because most vendors
/// copied the format: OpenAI, DeepSeek, Qwen (DashScope compatible mode),
/// Moonshot/Kimi, Zhipu GLM, SiliconFlow, OpenRouter, Groq, Mistral, xAI,
/// Together, Fireworks, Ollama, vLLM, SGLang, LM Studio, llama.cpp server.
///
/// The differences that actually matter are all captured here:
/// * where thinking text lives (`reasoning_content` vs `reasoning` vs inline
///   ` thinking` tags) — see [ReasoningSource];
/// * how thinking is *requested* (`reasoning_effort` vs `enable_thinking` vs
///   `thinking.budget_tokens`) — see [OpenAiReasoningRequestStyle];
/// * whether `max_tokens` or `max_completion_tokens` is accepted.
library;

import '../core/chat_events.dart';
import '../core/chat_message.dart';
import '../core/chat_request.dart';
import '../core/content_part.dart';
import '../core/errors.dart';
import '../core/json_utils.dart';
import '../core/uri_utils.dart';
import '../core/usage.dart';
import '../thinking/reasoning_router.dart';
import '../transport/cancel_token.dart';
import 'provider.dart';

/// How to ask for thinking in an OpenAI-shaped body.
enum OpenAiReasoningRequestStyle {
  /// Send nothing; the model thinks (or not) based on its own defaults.
  none,

  /// `reasoning_effort: "low" | "medium" | "high"` — OpenAI o-series / gpt-5,
  /// Groq, OpenRouter, xAI.
  reasoningEffort,

  /// `enable_thinking: true` + `thinking_budget` — Qwen3 on DashScope.
  enableThinking,

  /// `thinking: {"type": "enabled", "budget_tokens": N}` — GLM-4.5/4.6,
  /// Anthropic-shaped gateways, some OpenRouter routes.
  thinkingBudget,

  /// `reasoning: {"max_tokens": N}` — OpenRouter.
  reasoningMaxTokens,
}

/// Everything tunable about an OpenAI-compatible endpoint.
class OpenAiCompatibleConfig {
  const OpenAiCompatibleConfig({
    required this.baseUrl,
    this.name = 'openai-compatible',
    this.apiKey,
    this.headers = const <String, String>{},
    this.chatPath = '/chat/completions',
    this.modelsPath = '/models',
    this.authHeader = 'Authorization',
    this.authScheme = 'Bearer',
    this.query = const <String, String>{},
    this.reasoningSource = ReasoningSource.auto,
    this.inlineThinkTags = const <String>['think', 'thinking', 'reasoning', 'analysis'],
    this.reasoningFields = const <String>[
      'reasoning_content',
      'reasoning',
      'reasoning_details',
      'thinking_content',
      'thinking',
    ],
    this.startInReasoning = false,
    this.reasoningRequestStyle = OpenAiReasoningRequestStyle.none,
    this.useMaxCompletionTokens = false,
    this.sendStreamOptions = true,
    this.capabilities = const ProviderCapabilities(),
    this.defaultBody = const <String, Object?>{},
    this.modelsField = 'data',
  });

  /// API root, e.g. `https://api.deepseek.com/v1`.
  final Uri baseUrl;

  /// Identifier used in errors/logs.
  final String name;

  /// Sent as `<authScheme> <apiKey>` in [authHeader] when non-null.
  final String? apiKey;
  final Map<String, String> headers;
  final String chatPath;
  final String modelsPath;
  final String authHeader;
  final String authScheme;

  /// Extra query parameters (Gemini needs `alt=sse`; some gateways need
  /// `?api-version=`).
  final Map<String, String> query;

  /// Where thinking text comes from.
  final ReasoningSource reasoningSource;

  /// Tag names accepted when [reasoningSource] parses inline tags.
  final List<String> inlineThinkTags;

  /// Response fields checked for thinking text, in order.
  final List<String> reasoningFields;

  /// Set when the endpoint serves a pre-filled assistant prefix that starts
  /// *inside* a thinking block.
  final bool startInReasoning;

  /// How to request thinking.
  final OpenAiReasoningRequestStyle reasoningRequestStyle;

  /// o-series / gpt-5 reject `max_tokens` and require `max_completion_tokens`.
  final bool useMaxCompletionTokens;

  /// Send `stream_options: {"include_usage": true}` to get token counts while
  /// streaming.
  final bool sendStreamOptions;

  final ProviderCapabilities capabilities;

  /// Merged into every request body (vendor defaults, e.g. `{"top_k": 40}`).
  final Map<String, Object?> defaultBody;

  /// JSON path holding the model list for `/models`.
  final String modelsField;

  OpenAiCompatibleConfig copyWith({
    Uri? baseUrl,
    String? name,
    String? apiKey,
    Map<String, String>? headers,
    String? chatPath,
    String? modelsPath,
    String? authHeader,
    String? authScheme,
    Map<String, String>? query,
    ReasoningSource? reasoningSource,
    List<String>? inlineThinkTags,
    List<String>? reasoningFields,
    bool? startInReasoning,
    OpenAiReasoningRequestStyle? reasoningRequestStyle,
    bool? useMaxCompletionTokens,
    bool? sendStreamOptions,
    ProviderCapabilities? capabilities,
    Map<String, Object?>? defaultBody,
    String? modelsField,
  }) =>
      OpenAiCompatibleConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        name: name ?? this.name,
        apiKey: apiKey ?? this.apiKey,
        headers: headers ?? this.headers,
        chatPath: chatPath ?? this.chatPath,
        modelsPath: modelsPath ?? this.modelsPath,
        authHeader: authHeader ?? this.authHeader,
        authScheme: authScheme ?? this.authScheme,
        query: query ?? this.query,
        reasoningSource: reasoningSource ?? this.reasoningSource,
        inlineThinkTags: inlineThinkTags ?? this.inlineThinkTags,
        reasoningFields: reasoningFields ?? this.reasoningFields,
        startInReasoning: startInReasoning ?? this.startInReasoning,
        reasoningRequestStyle: reasoningRequestStyle ?? this.reasoningRequestStyle,
        useMaxCompletionTokens: useMaxCompletionTokens ?? this.useMaxCompletionTokens,
        sendStreamOptions: sendStreamOptions ?? this.sendStreamOptions,
        capabilities: capabilities ?? this.capabilities,
        defaultBody: defaultBody ?? this.defaultBody,
        modelsField: modelsField ?? this.modelsField,
      );
}

/// Streams chat completions from any OpenAI-compatible endpoint.
class OpenAiCompatibleProvider extends HttpLlmProvider {
  OpenAiCompatibleProvider({
    required this.config,
    super.transport,
    super.maxRetries,
    super.connectTimeout,
    super.idleTimeout,
    super.ownsTransport,
  });

  final OpenAiCompatibleConfig config;

  @override
  String get name => config.name;

  @override
  ProviderCapabilities get capabilities => config.capabilities;

  @override
  Uri buildUri(ChatRequest request, {required bool stream}) =>
      joinUri(config.baseUrl, config.chatPath, query: config.query);

  @override
  Map<String, String> buildHeaders(ChatRequest? request) {
    final key = config.apiKey;
    return <String, String>{
      'content-type': 'application/json',
      if (key != null && key.isNotEmpty)
        config.authHeader: config.authScheme.isEmpty ? key : '${config.authScheme} $key',
      ...config.headers,
    };
  }

  @override
  ReasoningContext createContext(ChatRequest request) => OpenAiReasoningContext(
        request: request,
        source: config.reasoningSource,
        tags: config.inlineThinkTags,
        startInReasoning: config.startInReasoning,
        includeReasoningInHistory:
            request.reasoning?.includeInHistory ?? config.capabilities.requiresReasoningEcho,
      );

  @override
  Map<String, Object?> buildRequestBody(ChatRequest request, {required bool stream}) {
    final includeReasoningInHistory =
        (request.reasoning?.includeInHistory ?? false) || config.capabilities.requiresReasoningEcho;
    final maxTokensKey =
        config.useMaxCompletionTokens ? 'max_completion_tokens' : 'max_tokens';

    final body = <String, Object?>{
      'model': request.model,
      'messages': <Map<String, Object?>>[
        for (final message in request.messages) encodeMessage(message, includeReasoningInHistory),
      ],
      if (stream) 'stream': true,
      if (stream && config.sendStreamOptions && config.capabilities.supportsStreamUsage)
        'stream_options': const <String, Object?>{'include_usage': true},
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.topP != null) 'top_p': request.topP,
      if (request.maxTokens != null) maxTokensKey: request.maxTokens,
      if (request.stop != null && request.stop!.isNotEmpty) 'stop': request.stop,
      if (request.seed != null) 'seed': request.seed,
      if (request.responseJsonSchema != null)
        'response_format': <String, Object?>{
          'type': 'json_schema',
          'json_schema': <String, Object?>{
            'name': 'response',
            'strict': true,
            'schema': request.responseJsonSchema,
          },
        },
      if (request.tools.isNotEmpty) 'tools': <Map<String, Object?>>[
        for (final tool in request.tools) tool.toJson(),
      ],
      if (request.tools.isNotEmpty && request.toolChoice != null && config.capabilities.supportsToolChoice)
        'tool_choice': request.toolChoice!.toOpenAiJson(),
      ..._reasoningBody(request),
      ...config.defaultBody,
      ...request.extra,
    };

    body.removeWhere((key, value) => value == null);
    return body;
  }

  /// Vendor-specific "please think" knobs.
  Map<String, Object?> _reasoningBody(ChatRequest request) {
    final reasoning = request.reasoning;
    if (reasoning == null) return const <String, Object?>{};
    final effort = reasoning.effort;
    final budget = reasoning.budgetTokens;
    // Explicit label (e.g. `max`, `none`) wins over the coarse enum mapping.
    final effortLabel = reasoning.effortName ?? (effort == null ? null : _effortName(effort));

    switch (config.reasoningRequestStyle) {
      case OpenAiReasoningRequestStyle.none:
        return const <String, Object?>{};
      case OpenAiReasoningRequestStyle.reasoningEffort:
        if (effortLabel == null) return const <String, Object?>{};
        return <String, Object?>{'reasoning_effort': effortLabel};
      case OpenAiReasoningRequestStyle.enableThinking:
        return pruneNulls({
          'enable_thinking': reasoning.enabled ?? true,
          if (budget != null) 'thinking_budget': budget,
        });
      case OpenAiReasoningRequestStyle.thinkingBudget:
        if (reasoning.enabled == false) {
          return const <String, Object?>{
            'thinking': <String, Object?>{'type': 'disabled'},
          };
        }
        return <String, Object?>{
          'thinking': pruneNulls({
            'type': 'enabled',
            if (budget != null) 'budget_tokens': budget,
          }),
        };
      case OpenAiReasoningRequestStyle.reasoningMaxTokens:
        if (reasoning.enabled == false) {
          return const <String, Object?>{
            'reasoning': <String, Object?>{'enabled': false},
          };
        }
        return <String, Object?>{
          'reasoning': pruneNulls({
            if (budget != null) 'max_tokens': budget,
            if (effortLabel != null) 'effort': effortLabel,
          }),
        };
    }
  }

  static String _effortName(ReasoningEffort effort) {
    switch (effort) {
      case ReasoningEffort.minimal:
        return 'minimal';
      case ReasoningEffort.low:
        return 'low';
      case ReasoningEffort.medium:
        return 'medium';
      case ReasoningEffort.high:
        return 'high';
      case ReasoningEffort.xhigh:
        return 'high';
    }
  }

  /// Encodes one message in the OpenAI wire format.
  Map<String, Object?> encodeMessage(ChatMessage message, bool includeReasoningInHistory) {
    switch (message.role) {
      case ChatRole.system:
        return <String, Object?>{'role': 'system', 'content': message.text};
      case ChatRole.user:
        return <String, Object?>{
          'role': 'user',
          'content': _encodeUserContent(message),
        };
      case ChatRole.tool:
        return pruneNulls(<String, Object?>{
          'role': 'tool',
          'tool_call_id': message.toolCallId ?? '',
          'content': message.content ?? '',
          if (message.toolName != null) 'name': message.toolName,
        });
      case ChatRole.assistant:
        final hasVisibleText = message.content != null && message.content!.isNotEmpty;
        return pruneNulls(<String, Object?>{
          'role': 'assistant',
          // A pure tool-call turn must not carry an empty `content` string:
          // several gateways then reject the follow-up tool message.
          'content': hasVisibleText ? message.content : (message.hasToolCalls ? null : ''),
          if (includeReasoningInHistory && message.hasReasoning)
            config.reasoningFields.first: message.reasoningContent,
          if (message.hasToolCalls)
            'tool_calls': <Map<String, Object?>>[
              for (final call in message.toolCalls) call.toJson(),
            ],
        });
    }
  }

  Object? _encodeUserContent(ChatMessage message) {
    final parts = message.parts;
    if (parts == null || parts.isEmpty) {
      return message.content ?? '';
    }
    if (parts.length == 1 && parts.first is TextPart) {
      return (parts.first as TextPart).text;
    }
    return <Map<String, Object?>>[
      for (final part in parts)
        switch (part) {
          TextPart(:final text) => <String, Object?>{'type': 'text', 'text': text},
          ImagePart() => <String, Object?>{
              'type': 'image_url',
              'image_url': <String, Object?>{'url': part.toDataUri()},
            },
        },
    ];
  }

  @override
  Iterable<ChatEvent> decodeChunk(Map<String, Object?> payload, ReasoningContext context) sync* {
    final ctx = context as OpenAiReasoningContext;

    // Some gateways stream `{"error": {...}}` with HTTP 200.
    final error = payload['error'];
    if (error != null) {
      final map = asMap(error);
      throw _StreamError(asString(map['message']) ?? 'Provider reported an error: $error');
    }

    final choices = asList(payload['choices']);
    for (final raw in choices) {
      final choice = asMap(raw);
      final delta = asMap(choice['delta']).isNotEmpty
          ? asMap(choice['delta'])
          : asMap(choice['message']);

      yield* ctx.router.reasoning(_extractReasoningText(delta));

      final content = delta['content'];
      if (content is String) {
        yield* ctx.router.content(content);
      } else if (content is List) {
        for (final piece in content) {
          final map = asMap(piece);
          if (map['type'] == 'text' || map['text'] != null) {
            yield* ctx.router.content(asString(map['text']));
          }
        }
      }

      final toolCalls = asList(delta['tool_calls']);
      for (var i = 0; i < toolCalls.length; i++) {
        final call = asMap(toolCalls[i]);
        final index = asInt(call['index']) ?? i;
        final function = asMap(call['function']);
        final id = asString(call['id']);
        final callName = asString(function['name']) ?? asString(call['name']);
        if (id != null || callName != null) {
          yield ToolCallStarted(index: index, id: id, name: callName);
        }
        final arguments = asString(function['arguments']);
        if (arguments != null && arguments.isNotEmpty) {
          yield ToolCallArgumentsDelta(index: index, fragment: arguments);
        }
      }
      // Legacy `function_call` (pre-tools API), still emitted by old proxies.
      final legacy = asMap(delta['function_call']);
      if (legacy.isNotEmpty) {
        final legacyName = asString(legacy['name']);
        if (legacyName != null) yield ToolCallStarted(index: 0, id: 'call_0', name: legacyName);
        final legacyArgs = asString(legacy['arguments']);
        if (legacyArgs != null && legacyArgs.isNotEmpty) {
          yield ToolCallArgumentsDelta(index: 0, fragment: legacyArgs);
        }
      }

      final finish = asString(choice['finish_reason']);
      if (finish != null && finish.isNotEmpty) {
        context.finishReason = FinishReason.parse(finish);
      }
    }

    final usage = payload['usage'];
    if (usage is Map) {
      yield UsageEvent(TokenUsage.fromOpenAi(asMap(usage)));
    }
  }

  /// Reads thinking text out of any of the known fields.
  String? _extractReasoningText(Map<String, Object?> delta) {
    for (final field in config.reasoningFields) {
      final value = delta[field];
      if (value == null) continue;
      final text = _reasoningToText(value);
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  /// `reasoning_details` is a list of `{type: 'reasoning.text', text: …}`.
  static String? _reasoningToText(Object? value) {
    if (value is String) return value;
    if (value is List) {
      final buffer = StringBuffer();
      for (final item in value) {
        final map = asMap(item);
        buffer.write(asString(map['text']) ?? asString(map['summary']) ?? '');
      }
      final text = buffer.toString();
      return text.isEmpty ? null : text;
    }
    if (value is Map) {
      return asString(value['text']) ?? asString(value['content']) ?? asString(value['summary']);
    }
    return null;
  }

  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancel}) async {
    final payload = await postJson(
      uri: joinUri(config.baseUrl, config.modelsPath, query: config.query),
      headers: buildHeaders(null),
      body: const <String, Object?>{},
      cancel: cancel,
      method: 'GET',
    );
    return <ModelInfo>[
      for (final entry in asList(payload[config.modelsField]))
        ModelInfo(
          id: asString(asMap(entry)['id']) ?? asString(asMap(entry)['name']) ?? '',
          displayName: asString(asMap(entry)['name']),
        ),
    ]..removeWhere((model) => model.id.isEmpty);
  }
}

/// Per-stream decoding state; owns the thinking-tag parser.
class OpenAiReasoningContext extends ReasoningContext {
  OpenAiReasoningContext({
    required this.request,
    required ReasoningSource source,
    required List<String> tags,
    required bool startInReasoning,
    bool includeReasoningInHistory = false,
  })  : includeReasoningInHistory = includeReasoningInHistory,
        router = ReasoningRouter(source: source, tags: tags, startInReasoning: startInReasoning);

  final ChatRequest request;
  final ReasoningRouter router;
  final bool includeReasoningInHistory;

  @override
  Iterable<ChatEvent> finalize() => router.finish();
}

/// Thrown for error frames inside an otherwise healthy SSE stream.
class _StreamError extends LlmApiException {
  _StreamError(String message) : super(message);
}
