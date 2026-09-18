/// Provider for Anthropic's `/v1/messages` API.
///
/// Anthropic is the "structured" end of the spectrum: thinking arrives as its
/// own content block with a server-signed `signature`, tool arguments arrive as
/// `input_json_delta` fragments, and tool results must be sent back as
/// `tool_result` blocks *inside a user message*.
///
/// The rules that bite when you get them wrong:
/// * `max_tokens` is required, and must be **greater than** `budget_tokens`;
/// * with extended thinking on, `temperature` must stay at 1;
/// * a signed thinking block must be echoed back verbatim on the next turn,
///   otherwise the API rejects the request (see [includeReasoningInHistory]);
/// * consecutive same-role messages must be merged.
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

/// Tunables for Anthropic (and Anthropic-shaped gateways).
class AnthropicConfig {
  AnthropicConfig({
    Uri? baseUrl,
    this.apiKey,
    this.name = 'anthropic',
    this.apiVersion = '2023-06-01',
    this.betaHeaders = const <String>['prompt-caching-2024-07-31'],
    this.headers = const <String, String>{},
    this.defaultMaxTokens = 4096,
    this.defaultThinkingBudget = 4096,
    this.includeReasoningInHistory = true,
    this.reasoningSource = ReasoningSource.field,
    this.sendBetaHeaders = true,
    this.defaultBody = const <String, Object?>{},
  }) : baseUrl = baseUrl ?? _defaultBase;

  /// `https://api.anthropic.com`
  static final Uri _defaultBase = Uri.parse('https://api.anthropic.com');

  final Uri baseUrl;
  final String? apiKey;
  final String name;
  final String apiVersion;

  /// Betas the endpoint should opt into.
  final List<String> betaHeaders;
  final Map<String, String> headers;

  /// Used when the request leaves `maxTokens` unset.
  final int defaultMaxTokens;

  /// Used when `reasoning.budgetTokens` is unset.
  final int defaultThinkingBudget;

  /// Whether the signed thinking block is replayed on later turns. Must stay
  /// `true` when extended thinking is used with tools.
  final bool includeReasoningInHistory;

  /// Anthropic always uses structured blocks; `inlineTags` is only useful for
  /// third-party "Anthropic-compatible" endpoints that mangle output.
  final ReasoningSource reasoningSource;

  final bool sendBetaHeaders;
  final Map<String, Object?> defaultBody;

  AnthropicConfig copyWith({
    Uri? baseUrl,
    String? apiKey,
    String? name,
    String? apiVersion,
    List<String>? betaHeaders,
    Map<String, String>? headers,
    int? defaultMaxTokens,
    int? defaultThinkingBudget,
    bool? includeReasoningInHistory,
    ReasoningSource? reasoningSource,
    bool? sendBetaHeaders,
    Map<String, Object?>? defaultBody,
  }) =>
      AnthropicConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        name: name ?? this.name,
        apiVersion: apiVersion ?? this.apiVersion,
        betaHeaders: betaHeaders ?? this.betaHeaders,
        headers: headers ?? this.headers,
        defaultMaxTokens: defaultMaxTokens ?? this.defaultMaxTokens,
        defaultThinkingBudget: defaultThinkingBudget ?? this.defaultThinkingBudget,
        includeReasoningInHistory: includeReasoningInHistory ?? this.includeReasoningInHistory,
        reasoningSource: reasoningSource ?? this.reasoningSource,
        sendBetaHeaders: sendBetaHeaders ?? this.sendBetaHeaders,
        defaultBody: defaultBody ?? this.defaultBody,
      );
}

/// Anthropic Messages API client.
class AnthropicProvider extends HttpLlmProvider {
  AnthropicProvider({
    required this.config,
    super.transport,
    super.maxRetries,
    super.connectTimeout,
    super.idleTimeout,
  });

  final AnthropicConfig config;

  @override
  String get name => config.name;

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        supportsReasoning: true,
        supportsReasoningEffort: false,
        supportsReasoningBudget: true,
        requiresReasoningEcho: true,
        supportsToolChoice: true,
        supportsStreamUsage: true,
      );

  @override
  Uri buildUri(ChatRequest request, {required bool stream}) =>
      joinUri(config.baseUrl, '/v1/messages');

  @override
  Map<String, String> buildHeaders(ChatRequest? request) => <String, String>{
        'content-type': 'application/json',
        'anthropic-version': config.apiVersion,
        if (config.sendBetaHeaders && config.betaHeaders.isNotEmpty)
          'anthropic-beta': config.betaHeaders.join(','),
        if (config.apiKey != null && config.apiKey!.isNotEmpty) 'x-api-key': config.apiKey!,
        ...config.headers,
      };

  @override
  ReasoningContext createContext(ChatRequest request) => AnthropicContext(
        source: config.reasoningSource,
        includeReasoningInHistory:
            request.reasoning?.includeInHistory ?? config.includeReasoningInHistory,
      );

  // ------------------------------------------------------------------- body

  @override
  Map<String, Object?> buildRequestBody(ChatRequest request, {required bool stream}) {
    final budget = _thinkingBudget(request);
    final maxTokens = _maxTokens(request, budget);
    final includeReasoning =
        (request.reasoning?.includeInHistory ?? false) ||
            (config.includeReasoningInHistory && budget != null);

    final system = _collectSystem(request.messages);

    final body = <String, Object?>{
      'model': request.model,
      'max_tokens': maxTokens,
      if (system.isNotEmpty) 'system': system,
      'messages': _encodeMessages(request.messages, includeReasoning),
      if (stream) 'stream': true,
      // Extended thinking requires temperature == 1; anything else is a 400.
      if (request.temperature != null && budget == null) 'temperature': request.temperature,
      if (request.topP != null && budget == null) 'top_p': request.topP,
      if (request.stop != null && request.stop!.isNotEmpty) 'stop_sequences': request.stop,
      if (budget != null)
        'thinking': <String, Object?>{
          'type': 'enabled',
          'budget_tokens': budget,
        },
      if (request.tools.isNotEmpty)
        'tools': <Map<String, Object?>>[
          for (final tool in request.tools) tool.toAnthropicJson(),
        ],
      if (request.tools.isNotEmpty && request.toolChoice != null)
        'tool_choice': request.toolChoice!.toAnthropicJson(),
      ...config.defaultBody,
      ...request.extra,
    };
    body.removeWhere((key, value) => value == null);
    return body;
  }

  /// `null` when thinking is off.
  int? _thinkingBudget(ChatRequest request) {
    final reasoning = request.reasoning;
    if (reasoning == null) return null;
    if (reasoning.enabled == false) return null;
    if (reasoning.budgetTokens != null) return reasoning.budgetTokens;
    if (reasoning.enabled == true || reasoning.effort != null) {
      return _effortToBudget(reasoning.effort) ?? config.defaultThinkingBudget;
    }
    return null;
  }

  static int? _effortToBudget(ReasoningEffort? effort) {
    switch (effort) {
      case null:
        return null;
      case ReasoningEffort.minimal:
        return 1024;
      case ReasoningEffort.low:
        return 2048;
      case ReasoningEffort.medium:
        return 8192;
      case ReasoningEffort.high:
        return 16384;
      case ReasoningEffort.xhigh:
        return 32768;
    }
  }

  int _maxTokens(ChatRequest request, int? budget) {
    final requested = request.maxTokens ?? config.defaultMaxTokens;
    if (budget == null) return requested;
    // max_tokens must exceed the thinking budget, so grow it if needed.
    final minimum = budget + 1024;
    return requested > minimum ? requested : minimum;
  }

  static String _collectSystem(List<ChatMessage> messages) => messages
      .where((message) => message.role == ChatRole.system)
      .map((message) => message.text)
      .where((text) => text.isNotEmpty)
      .join('\n\n');

  List<Map<String, Object?>> _encodeMessages(
    List<ChatMessage> messages,
    bool includeReasoning,
  ) {
    final encoded = <Map<String, Object?>>[];
    for (final message in messages) {
      if (message.role == ChatRole.system) continue; // hoisted to `system`
      final blocks = _encodeBlocks(message, includeReasoning);
      if (blocks.isEmpty) continue;
      // Merge consecutive same-role turns: Anthropic wants strict alternation.
      if (encoded.isNotEmpty && encoded.last['role'] == _wireRole(message)) {
        final previous = encoded.last['content'];
        if (previous is List) {
          previous.addAll(blocks);
          continue;
        }
      }
      encoded.add(<String, Object?>{'role': _wireRole(message), 'content': blocks});
    }
    return encoded;
  }

  static String _wireRole(ChatMessage message) =>
      message.role == ChatRole.assistant ? 'assistant' : 'user';

  List<Map<String, Object?>> _encodeBlocks(ChatMessage message, bool includeReasoning) {
    if (message.role == ChatRole.tool) {
      return <Map<String, Object?>>[
        <String, Object?>{
          'type': 'tool_result',
          'tool_use_id': message.toolCallId ?? '',
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': message.content ?? ''},
          ],
          if (message.isError) 'is_error': true,
        },
      ];
    }

    if (message.role == ChatRole.assistant) {
      final blocks = <Map<String, Object?>>[];
      // Thinking blocks must come first, and must be signed to be accepted.
      if (includeReasoning && message.hasReasoning && message.reasoningSignature != null) {
        blocks.add(<String, Object?>{
          'type': 'thinking',
          'thinking': message.reasoningContent,
          'signature': message.reasoningSignature,
        });
      }
      if (message.content != null && message.content!.isNotEmpty) {
        blocks.add(<String, Object?>{'type': 'text', 'text': message.content});
      }
      for (final call in message.toolCalls) {
        blocks.add(<String, Object?>{
          'type': 'tool_use',
          'id': call.id,
          'name': call.name,
          'input': call.tryArguments() ?? const <String, Object?>{},
        });
      }
      return blocks;
    }

    return <Map<String, Object?>>[
      for (final part in message.effectiveParts)
        switch (part) {
          TextPart(:final text) => <String, Object?>{'type': 'text', 'text': text},
          ImagePart() => <String, Object?>{
              'type': 'image',
              'source': part.base64Data != null
                  ? <String, Object?>{
                      'type': 'base64',
                      'media_type': part.mimeType,
                      'data': part.base64Data,
                    }
                  : <String, Object?>{'type': 'url', 'url': part.url},
            },
        },
    ];
  }

  // ---------------------------------------------------------------- decoding

  @override
  Iterable<ChatEvent> decodeChunk(Map<String, Object?> payload, ReasoningContext context) sync* {
    final ctx = context as AnthropicContext;
    final type = asString(payload['type']);

    switch (type) {
      case 'message_start':
        final message = asMap(payload['message']);
        final usage = asMap(message['usage']);
        ctx.scratch['id'] = asString(message['id']);
        ctx.scratch['model'] = asString(message['model']);
        if (usage.isNotEmpty) yield UsageEvent(TokenUsage.fromAnthropic(usage));
        return;

      case 'content_block_start':
        final index = asInt(payload['index']) ?? 0;
        final block = asMap(payload['content_block']);
        ctx.scratch['block_$index'] = asString(block['type']);
        switch (asString(block['type'])) {
          case 'thinking':
          case 'redacted_thinking':
            final text = asString(block['thinking']);
            if (text != null && text.isNotEmpty) yield ReasoningDelta(text);
            final signature = asString(block['signature']);
            if (signature != null && signature.isNotEmpty) {
              yield ReasoningSignatureDelta(signature);
            }
          case 'tool_use':
            yield ToolCallStarted(
              index: index,
              id: asString(block['id']),
              name: asString(block['name']),
            );
            // A non-streaming client would already see the whole `input` here.
            final input = block['input'];
            if (input is Map && input.isNotEmpty) {
              yield ToolCallArgumentsDelta(index: index, fragment: jsonEncode(input));
            }
          case 'text':
            final text = asString(block['text']);
            if (text != null && text.isNotEmpty) yield* ctx.router.content(text);
        }
        return;

      case 'content_block_delta':
        final index = asInt(payload['index']) ?? 0;
        final delta = asMap(payload['delta']);
        switch (asString(delta['type'])) {
          case 'text_delta':
            yield* ctx.router.content(asString(delta['text']));
          case 'thinking_delta':
            yield* ctx.router.reasoning(asString(delta['thinking']));
          case 'signature_delta':
            yield* ctx.router.signature(asString(delta['signature']));
          case 'input_json_delta':
            final fragment = asString(delta['partial_json']);
            if (fragment != null && fragment.isNotEmpty) {
              yield ToolCallArgumentsDelta(index: index, fragment: fragment);
            }
        }
        return;

      case 'message_delta':
        final delta = asMap(payload['delta']);
        final stop = asString(delta['stop_reason']);
        if (stop != null && stop.isNotEmpty) {
          context.finishReason = FinishReason.parse(stop);
        }
        final usage = asMap(payload['usage']);
        if (usage.isNotEmpty) yield UsageEvent(TokenUsage.fromAnthropic(usage));
        return;

      case 'error':
        final error = asMap(payload['error']);
        throw ProtocolException(
          asString(error['message']) ?? 'Anthropic reported an error',
          body: jsonEncode(payload),
        );

      case 'message_stop':
        yield Finished(reason: context.finishReason ?? FinishReason.stop, usage: context.usage);
        return;

      default:
        // `ping`, `content_block_stop`, unknown future events: ignore.
        return;
    }
  }

  @override
  Future<List<ModelInfo>> listModels({CancelToken? cancel}) async {
    final payload = await postJson(
      uri: joinUri(config.baseUrl, '/v1/models'),
      headers: buildHeaders(null),
      body: const <String, Object?>{},
      cancel: cancel,
      method: 'GET',
    );
    return <ModelInfo>[
      for (final entry in asList(payload['data']))
        ModelInfo(
          id: asString(asMap(entry)['id']) ?? '',
          displayName: asString(asMap(entry)['display_name']),
        ),
    ]..removeWhere((model) => model.id.isEmpty);
  }
}

/// Anthropic streams thinking as structured blocks.
class AnthropicContext extends ReasoningContext {
  AnthropicContext({required ReasoningSource source, bool includeReasoningInHistory = true})
      : includeReasoningInHistory = includeReasoningInHistory,
        router = ReasoningRouter(source: source);

  final ReasoningRouter router;
  final bool includeReasoningInHistory;

  @override
  Iterable<ChatEvent> finalize() => router.finish();
}
