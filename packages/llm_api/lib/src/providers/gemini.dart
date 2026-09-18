/// Provider for Google's Gemini `generateContent` API.
///
/// Gemini is the odd one out on three counts:
/// * tool calls are not "functions of a message" but `parts` inside the model
///   turn, and tool *results* go back as `functionResponse` parts of a user
///   turn keyed by **name**, not by call id;
/// * thinking is marked per-part with `"thought": true`, and it can be turned
///   off with `thinkingBudget: 0`;
/// * roles are `user` / `model`.
///
/// Streaming behaviour worth knowing: a `functionCall` part usually arrives
/// whole, but large argument payloads can still be split across chunks — see
/// [_GeminiContext] for the balancing heuristic.
library;

import 'dart:convert';

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

/// Tunables for Gemini.
class GeminiConfig {
  GeminiConfig({
    Uri? baseUrl,
    this.apiKey,
    this.name = 'gemini',
    this.apiVersion = 'v1beta',
    this.headers = const <String, String>{},
    this.sendApiKeyAsQuery = false,
    this.defaultMaxTokens,
    this.includeReasoningInHistory = true,
    this.defaultThinkingBudget = 8192,
    this.defaultBody = const <String, Object?>{},
  }) : baseUrl = baseUrl ?? _defaultBase;

  /// `https://generativelanguage.googleapis.com`
  static final Uri _defaultBase = Uri.parse('https://generativelanguage.googleapis.com');

  final Uri baseUrl;
  final String? apiKey;
  final String name;
  final String apiVersion;
  final Map<String, String> headers;

  /// Some proxies only accept `?key=`; the official API prefers the header.
  final bool sendApiKeyAsQuery;
  final int? defaultMaxTokens;

  /// Gemini wants the `thoughtSignature` of a tool-calling turn replayed.
  final bool includeReasoningInHistory;
  final int defaultThinkingBudget;
  final Map<String, Object?> defaultBody;

  GeminiConfig copyWith({
    Uri? baseUrl,
    String? apiKey,
    String? name,
    String? apiVersion,
    Map<String, String>? headers,
    bool? sendApiKeyAsQuery,
    int? defaultMaxTokens,
    bool? includeReasoningInHistory,
    int? defaultThinkingBudget,
    Map<String, Object?>? defaultBody,
  }) =>
      GeminiConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        name: name ?? this.name,
        apiVersion: apiVersion ?? this.apiVersion,
        headers: headers ?? this.headers,
        sendApiKeyAsQuery: sendApiKeyAsQuery ?? this.sendApiKeyAsQuery,
        defaultMaxTokens: defaultMaxTokens ?? this.defaultMaxTokens,
        includeReasoningInHistory: includeReasoningInHistory ?? this.includeReasoningInHistory,
        defaultThinkingBudget: defaultThinkingBudget ?? this.defaultThinkingBudget,
        defaultBody: defaultBody ?? this.defaultBody,
      );
}

/// Gemini client.
class GeminiProvider extends HttpLlmProvider {
  GeminiProvider({
    required this.config,
    super.transport,
    super.maxRetries,
    super.connectTimeout,
    super.idleTimeout,
  });

  final GeminiConfig config;

  @override
  String get name => config.name;

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        supportsReasoning: true,
        supportsReasoningBudget: true,
        supportsToolChoice: true,
        supportsStreamUsage: true,
        supportsStructuredOutput: true,
        supportsSystemRole: true,
      );

  static String _bareModel(String model) =>
      model.startsWith('models/') ? model.substring('models/'.length) : model;

  @override
  Uri buildUri(ChatRequest request, {required bool stream}) {
    final method = stream ? 'streamGenerateContent' : 'generateContent';
    final query = <String, String>{
      if (stream) 'alt': 'sse',
      if (config.sendApiKeyAsQuery && config.apiKey != null) 'key': config.apiKey!,
    };
    return joinUri(
      config.baseUrl,
      '/${config.apiVersion}/models/${_bareModel(request.model)}:$method',
      query: query,
    );
  }

  @override
  Map<String, String> buildHeaders(ChatRequest? request) => <String, String>{
        'content-type': 'application/json',
        if (config.apiKey != null && config.apiKey!.isNotEmpty && !config.sendApiKeyAsQuery)
          'x-goog-api-key': config.apiKey!,
        ...config.headers,
      };

  @override
  ReasoningContext createContext(ChatRequest request) => _GeminiContext(
        source: ReasoningSource.auto,
        request: request,
        includeReasoningInHistory:
            request.reasoning?.includeInHistory ?? config.includeReasoningInHistory,
      );

  // ------------------------------------------------------------------- body

  @override
  Map<String, Object?> buildRequestBody(ChatRequest request, {required bool stream}) {
    final system = request.messages
        .where((message) => message.role == ChatRole.system)
        .map((message) => message.text)
        .where((text) => text.isNotEmpty)
        .join('\n\n');

    final generationConfig = pruneNulls(<String, Object?>{
      'temperature': request.temperature,
      'topP': request.topP,
      'maxOutputTokens': request.maxTokens ?? config.defaultMaxTokens,
      if (request.stop != null && request.stop!.isNotEmpty) 'stopSequences': request.stop,
      if (request.responseJsonSchema != null) ...<String, Object?>{
        'responseMimeType': 'application/json',
        'responseSchema': request.responseJsonSchema,
      },
      ..._thinkingConfig(request),
    });

    final body = <String, Object?>{
      'contents': _encodeContents(request.messages),
      if (system.isNotEmpty)
        'systemInstruction': <String, Object?>{
          'parts': <Map<String, Object?>>[
            <String, Object?>{'text': system},
          ],
        },
      if (request.tools.isNotEmpty)
        'tools': <Map<String, Object?>>[
          <String, Object?>{
            'functionDeclarations': <Map<String, Object?>>[
              for (final tool in request.tools) tool.toGeminiJson(),
            ],
          },
        ],
      if (request.tools.isNotEmpty && request.toolChoice != null)
        'toolConfig': request.toolChoice!.toGeminiJson(),
      if (generationConfig.isNotEmpty) 'generationConfig': generationConfig,
      ...config.defaultBody,
      ...request.extra,
    };
    return body;
  }

  Map<String, Object?> _thinkingConfig(ChatRequest request) {
    final reasoning = request.reasoning;
    if (reasoning == null) return const <String, Object?>{};
    final budget = reasoning.budgetTokens ??
        (reasoning.enabled == false
            ? 0
            : reasoning.effort != null
                ? _effortToBudget(reasoning.effort!)
                : config.defaultThinkingBudget);
    return <String, Object?>{
      'thinkingConfig': <String, Object?>{
        if (budget > 0) 'includeThoughts': true,
        'thinkingBudget': budget,
      },
    };
  }

  static int _effortToBudget(ReasoningEffort effort) {
    switch (effort) {
      case ReasoningEffort.minimal:
        return 0;
      case ReasoningEffort.low:
        return 1024;
      case ReasoningEffort.medium:
        return 8192;
      case ReasoningEffort.high:
        return 16384;
      case ReasoningEffort.xhigh:
        return 32768;
    }
  }

  List<Map<String, Object?>> _encodeContents(List<ChatMessage> messages) {
    final contents = <Map<String, Object?>>[];
    for (final message in messages) {
      if (message.role == ChatRole.system) continue;
      final parts = _encodeParts(message);
      if (parts.isEmpty) continue;
      contents.add(<String, Object?>{
        'role': message.role == ChatRole.assistant ? 'model' : 'user',
        'parts': parts,
      });
    }
    return contents;
  }

  List<Map<String, Object?>> _encodeParts(ChatMessage message) {
    if (message.role == ChatRole.tool) {
      return <Map<String, Object?>>[
        <String, Object?>{
          'functionResponse': <String, Object?>{
            // Gemini keys results by function *name*, not by call id.
            'name': message.toolName ?? message.toolCallId ?? '',
            'response': <String, Object?>{
              'result': _maybeJson(message.content),
              if (message.isError) 'error': true,
            },
          },
        },
      ];
    }

    if (message.role == ChatRole.assistant) {
      final parts = <Map<String, Object?>>[];
      final signature = message.reasoningSignature;
      if (config.includeReasoningInHistory && message.hasReasoning) {
        parts.add(<String, Object?>{
          'text': message.reasoningContent,
          'thought': true,
        });
      }
      if (message.content != null && message.content!.isNotEmpty) {
        parts.add(<String, Object?>{'text': message.content});
      }
      var first = true;
      for (final call in message.toolCalls) {
        final part = <String, Object?>{
          'functionCall': <String, Object?>{
            'name': call.name,
            'args': call.tryArguments() ?? const <String, Object?>{},
          },
        };
        // Gemini 3 requires the thought signature back on the tool-call turn.
        if (first && signature != null && signature.isNotEmpty) {
          part['thoughtSignature'] = signature;
        }
        first = false;
        parts.add(part);
      }
      return parts;
    }

    return <Map<String, Object?>>[
      for (final part in message.effectiveParts)
        switch (part) {
          TextPart(:final text) => <String, Object?>{'text': text},
          ImagePart() => part.base64Data != null
              ? <String, Object?>{
                  'inlineData': <String, Object?>{
                    'mimeType': part.mimeType,
                    'data': part.base64Data,
                  },
                }
              : <String, Object?>{
                  'fileData': <String, Object?>{
                    'mimeType': part.mimeType,
                    'fileUri': part.url,
                  },
                },
        },
    ];
  }

  static Object? _maybeJson(String? text) {
    if (text == null || text.isEmpty) return '';
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  // ---------------------------------------------------------------- decoding

  @override
  Iterable<ChatEvent> decodeChunk(Map<String, Object?> payload, ReasoningContext context) sync* {
    final ctx = context as _GeminiContext;

    final error = payload['error'];
    if (error != null) {
      final map = asMap(error);
      throw ProtocolException(
        asString(map['message']) ?? 'Gemini reported an error',
        body: jsonEncode(payload),
      );
    }

    for (final rawCandidate in asList(payload['candidates'])) {
      final candidate = asMap(rawCandidate);
      final content = asMap(candidate['content']);
      for (final rawPart in asList(content['parts'])) {
        final part = asMap(rawPart);

        final signature = asString(part['thoughtSignature']);
        if (signature != null && signature.isNotEmpty) {
          yield ReasoningSignatureDelta(signature);
        }

        final text = asString(part['text']);
        if (text != null && text.isNotEmpty) {
          if (asBool(part['thought'])) {
            // Per-part flag: this piece belongs to the thinking channel.
            yield* ctx.router.reasoning(text);
          } else {
            yield* ctx.router.content(text);
          }
        }

        final functionCall = part['functionCall'];
        if (functionCall is Map) {
          yield* ctx.functionCall(asMap(functionCall));
        }
      }

      final finish = asString(candidate['finishReason']);
      if (finish != null && finish.isNotEmpty) {
        context.finishReason = FinishReason.parse(finish);
      }
    }

    final usage = payload['usageMetadata'];
    if (usage is Map) {
      yield UsageEvent(TokenUsage.fromGemini(asMap(usage)));
    }
  }

  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancel}) async {
    final payload = await postJson(
      uri: joinUri(
        config.baseUrl,
        '/${config.apiVersion}/models',
        query: <String, String>{
          if (config.sendApiKeyAsQuery && config.apiKey != null) 'key': config.apiKey!,
        },
      ),
      headers: buildHeaders(null),
      body: const <String, Object?>{},
      cancel: cancel,
      method: 'GET',
    );
    return <ModelInfo>[
      for (final entry in asList(payload['models']))
        ModelInfo(
          id: asString(asMap(entry)['name'])?.replaceFirst('models/', '') ?? '',
          displayName: asString(asMap(entry)['displayName']),
          contextWindow: asInt(asMap(entry)['inputTokenLimit']),
        ),
    ]..removeWhere((model) => model.id.isEmpty);
  }
}

/// Tracks Gemini's function-call parts across chunks.
class _GeminiContext extends ReasoningContext {
  _GeminiContext({
    required ReasoningSource source,
    required this.request,
    required this.includeReasoningInHistory,
  }) : router = ReasoningRouter(source: source);

  final ChatRequest request;
  final ReasoningRouter router;
  final bool includeReasoningInHistory;

  /// Index of the call currently being filled in, if its JSON looks unfinished.
  int? _openIndex;
  String _openName = '';
  String _openArguments = '';

  Iterable<ChatEvent> functionCall(Map<String, Object?> call) sync* {
    final name = asString(call['name']) ?? '';
    final args = call['args'];
    final encoded = args == null ? '' : jsonEncode(args);

    // Same name and the previous payload was not balanced JSON → continuation.
    if (_openIndex != null && name == _openName && !_isBalanced(_openArguments)) {
      _openArguments += encoded;
      if (encoded.isNotEmpty) {
        yield ToolCallArgumentsDelta(index: _openIndex!, fragment: encoded);
      }
      return;
    }

    final index = asInt(scratch['next_index']) ?? 0;
    scratch['next_index'] = index + 1;
    _openIndex = index;
    _openName = name;
    _openArguments = encoded;
    yield ToolCallStarted(index: index, id: 'call_$index', name: name);
    if (encoded.isNotEmpty) {
      yield ToolCallArgumentsDelta(index: index, fragment: encoded);
    }
  }

  @override
  Iterable<ChatEvent> finalize() => router.finish();

  /// Cheap brace/bracket balance check (ignores braces inside strings).
  static bool _isBalanced(String text) {
    if (text.isEmpty) return false;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (char == '"') {
        inString = true;
      } else if (char == '{' || char == '[') {
        depth++;
      } else if (char == '}' || char == ']') {
        depth--;
        if (depth < 0) return false;
      }
    }
    return depth == 0 && !inString;
  }
}
