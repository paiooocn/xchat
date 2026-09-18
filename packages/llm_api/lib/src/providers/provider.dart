/// The provider contract plus the shared HTTP/retry plumbing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';

import '../core/aggregator.dart';
import '../core/chat_events.dart';
import '../core/chat_request.dart';
import '../core/chat_response.dart';
import '../core/errors.dart';
import '../core/json_utils.dart';
import '../core/usage.dart';
import '../stream/sse.dart';
import '../transport/cancel_token.dart';
import '../transport/io_transport.dart';
import '../transport/transport.dart';

/// What a provider/model can do. Used to fail fast and to shape requests.
class ProviderCapabilities {
  const ProviderCapabilities({
    this.supportsStreaming = true,
    this.supportsTools = true,
    this.supportsParallelToolCalls = true,
    this.supportsReasoning = true,
    this.supportsReasoningEffort = false,
    this.supportsReasoningBudget = false,
    this.requiresReasoningEcho = false,
    this.supportsImageInput = true,
    this.supportsSystemRole = true,
    this.supportsToolChoice = true,
    this.supportsStreamUsage = true,
    this.supportsStructuredOutput = false,
  });

  final bool supportsStreaming;
  final bool supportsTools;
  final bool supportsParallelToolCalls;
  final bool supportsReasoning;
  final bool supportsReasoningEffort;
  final bool supportsReasoningBudget;

  /// True when the thinking block must be sent back verbatim (Anthropic
  /// extended thinking: the signature is validated server-side).
  final bool requiresReasoningEcho;
  final bool supportsImageInput;
  final bool supportsSystemRole;
  final bool supportsToolChoice;
  final bool supportsStreamUsage;
  final bool supportsStructuredOutput;

  ProviderCapabilities copyWith({
    bool? supportsStreaming,
    bool? supportsTools,
    bool? supportsParallelToolCalls,
    bool? supportsReasoning,
    bool? supportsReasoningEffort,
    bool? supportsReasoningBudget,
    bool? requiresReasoningEcho,
    bool? supportsImageInput,
    bool? supportsSystemRole,
    bool? supportsToolChoice,
    bool? supportsStreamUsage,
    bool? supportsStructuredOutput,
  }) =>
      ProviderCapabilities(
        supportsStreaming: supportsStreaming ?? this.supportsStreaming,
        supportsTools: supportsTools ?? this.supportsTools,
        supportsParallelToolCalls: supportsParallelToolCalls ?? this.supportsParallelToolCalls,
        supportsReasoning: supportsReasoning ?? this.supportsReasoning,
        supportsReasoningEffort: supportsReasoningEffort ?? this.supportsReasoningEffort,
        supportsReasoningBudget: supportsReasoningBudget ?? this.supportsReasoningBudget,
        requiresReasoningEcho: requiresReasoningEcho ?? this.requiresReasoningEcho,
        supportsImageInput: supportsImageInput ?? this.supportsImageInput,
        supportsSystemRole: supportsSystemRole ?? this.supportsSystemRole,
        supportsToolChoice: supportsToolChoice ?? this.supportsToolChoice,
        supportsStreamUsage: supportsStreamUsage ?? this.supportsStreamUsage,
        supportsStructuredOutput: supportsStructuredOutput ?? this.supportsStructuredOutput,
      );
}

/// Metadata for one model returned by `listModels`.
class ModelInfo {
  const ModelInfo({required this.id, this.displayName, this.contextWindow});

  final String id;
  final String? displayName;
  final int? contextWindow;

  @override
  String toString() => 'ModelInfo($id)';
}

/// A chat backend (OpenAI-compatible, Anthropic, Gemini, …).
abstract class LlmProvider {
  /// Short identifier used in logs/errors, e.g. `deepseek`.
  String get name;

  /// Feature matrix of the backend.
  ProviderCapabilities get capabilities;

  /// Streams a completion as normalised events.
  ///
  /// The stream always ends with [Finished] on success. Failures before the
  /// first token are thrown; failures after that surface as stream errors.
  Stream<ChatEvent> stream(ChatRequest request, {CancelToken? cancel});

  /// Non-streaming request, implemented on top of [stream] so there is only one
  /// decoding path to trust.
  Future<ChatResponse> complete(ChatRequest request, {CancelToken? cancel}) =>
      collectChatResponse(stream(request, cancel: cancel), model: request.model);

  /// Lists models, when the backend exposes it.
  Future<List<ModelInfo>> listModels({CancelToken? cancel}) async =>
      throw UnsupportedError('$name does not expose a model list');

  /// Releases the transport. After this the provider is unusable.
  void close() {}
}

/// Shared implementation: retries, SSE plumbing, error mapping, timeouts.
abstract class HttpLlmProvider extends LlmProvider {
  HttpLlmProvider({
    HttpTransport? transport,
    this.maxRetries = 2,
    this.retryBaseDelay = const Duration(milliseconds: 400),
    this.retryMaxDelay = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 20),
    this.idleTimeout = const Duration(seconds: 120),
    bool ownsTransport = false,
  })  : _transport = transport ?? IoHttpTransport(),
        _ownsTransport = ownsTransport || transport == null;

  final HttpTransport _transport;
  final bool _ownsTransport;

  /// Number of *additional* attempts for retryable failures.
  final int maxRetries;
  final Duration retryBaseDelay;
  final Duration retryMaxDelay;
  final Duration connectTimeout;

  /// Max silence between two SSE chunks.
  final Duration idleTimeout;

  /// The transport in use.
  HttpTransport get transport => _transport;

  @override
  void close() {
    if (_ownsTransport) _transport.close();
  }

  // --------------------------------------------------------------- wire build

  /// Provider-specific request body.
  Map<String, Object?> buildRequestBody(ChatRequest request, {required bool stream});

  /// Provider-specific endpoint.
  Uri buildUri(ChatRequest request, {required bool stream});

  /// Provider-specific headers (auth lives here).
  ///
  /// [request] is `null` for requests that are not tied to a chat call
  /// (`listModels`).
  Map<String, String> buildHeaders(ChatRequest? request);

  /// Maps one decoded SSE payload onto zero or more events.
  Iterable<ChatEvent> decodeChunk(Map<String, Object?> payload, ReasoningContext context);

  /// Called once per stream; lets providers own per-request decoding state.
  ReasoningContext createContext(ChatRequest request) => ReasoningContext.none();

  // ------------------------------------------------------------ stream driver

  @override
  Stream<ChatEvent> stream(ChatRequest request, {CancelToken? cancel}) async* {
    if (request.messages.isEmpty) {
      throw ArgumentError.value(request.messages, 'request.messages', 'must not be empty');
    }
    final context = createContext(request);
    try {
      final payloads = sseJsonPayloads(
        uri: buildUri(request, stream: true),
        headers: buildHeaders(request),
        body: buildRequestBody(request, stream: true),
        cancel: cancel,
      );
      var finished = false;
      FinishReason? declaredReason;
      await for (final payload in payloads) {
        context.raw = payload;
        for (final event in decodeChunk(payload, context)) {
          if (event is UsageEvent) {
            context.usage = context.usage.merge(event.usage);
          } else if (event is Finished) {
            finished = true;
            declaredReason = event.reason;
          }
          yield event;
        }
      }
      for (final event in context.finalize()) {
        if (event is UsageEvent) {
          context.usage = context.usage.merge(event.usage);
        } else if (event is Finished) {
          finished = true;
          declaredReason = event.reason;
        }
        yield event;
      }
      if (!finished) {
        yield Finished(
          reason: declaredReason ?? context.finishReason ?? FinishReason.unknown,
          usage: context.usage,
        );
      }
    } on LlmApiException {
      rethrow;
    } on FormatException catch (error) {
      throw ProtocolException('Malformed response from $name: ${error.message}', cause: error);
    }
  }

  /// POSTs [body] and yields every decoded SSE `data:` payload.
  ///
  /// Retries 429/5xx/connection failures while nothing has been received yet;
  /// once the first chunk is out, a retry would duplicate output, so the error
  /// is propagated instead.
  Stream<Map<String, Object?>> sseJsonPayloads({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    CancelToken? cancel,
  }) async* {
    final token = CancelToken.link(cancel);
    try {
      final response = await _sendWithRetry(
        TransportRequest(
          uri: uri,
          headers: <String, String>{...headers, 'accept': 'text/event-stream'},
          jsonBody: body,
          connectTimeout: connectTimeout,
          idleTimeout: idleTimeout,
        ),
        token,
      );
      await for (final event in decodeSse(response.byteStream)) {
        token.throwIfCancelled();
        final data = event.data.trim();
        if (data.isEmpty) continue;
        if (event.isDone) return;
        final decoded = _tryDecode(data);
        if (decoded == null) continue; // keep-alive junk / non-JSON frame
        yield decoded;
      }
    } finally {
      token.cancel();
    }
  }

  /// Non-streaming JSON POST (used by `listModels` and opt-out streaming).
  Future<Map<String, Object?>> postJson({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    CancelToken? cancel,
    String method = 'POST',
  }) async {
    final token = CancelToken.link(cancel);
    try {
      final response = await _sendWithRetry(
        TransportRequest(
          uri: uri,
          method: method,
          headers: headers,
          jsonBody: method == 'GET' ? null : body,
          connectTimeout: connectTimeout,
          idleTimeout: idleTimeout,
        ),
        token,
      );
      final text = await response.readAsString();
      final decoded = _tryDecode(text);
      if (decoded == null) {
        throw ProtocolException('Expected a JSON object from $uri', body: text, uri: uri);
      }
      return decoded;
    } finally {
      token.cancel();
    }
  }

  Future<TransportResponse> _sendWithRetry(TransportRequest request, CancelToken cancel) async {
    var attempt = 0;
    while (true) {
      cancel.throwIfCancelled();
      try {
        final response = await _transport.send(request, cancel: cancel);
        if (response.isSuccess) return response;

        // Drain first: releasing the body lets the pooled connection be reused.
        final body = await response.readAsString();
        final error = mapHttpError(
          statusCode: response.statusCode,
          body: body,
          uri: request.uri,
          headers: response.flatHeaders,
        );
        if (!error.retryable || attempt >= maxRetries) throw error;
        await _delayBeforeRetry(attempt, error is RateLimitException ? error.retryAfter : null);
      } on LlmApiException catch (error) {
        if (cancel.isCancelled) {
          throw RequestCancelledException(cancel.reason?.toString());
        }
        if (!error.retryable || attempt >= maxRetries) rethrow;
        await _delayBeforeRetry(attempt, error is RateLimitException ? error.retryAfter : null);
      } on SocketException catch (error) {
        if (attempt >= maxRetries) {
          throw TransportException(
            'Network failure talking to ${request.uri.host}: ${error.message}',
            uri: request.uri,
            cause: error,
          );
        }
        await _delayBeforeRetry(attempt, null);
      }
      attempt++;
    }
  }

  Future<void> _delayBeforeRetry(int attempt, Duration? serverHint) async {
    final exponential = retryBaseDelay * pow(2, attempt).toDouble();
    final jitter = Duration(
      milliseconds: Random().nextInt(1 + (retryBaseDelay.inMilliseconds ~/ 2) + 1),
    );
    var delay = exponential + jitter;
    if (serverHint != null && serverHint > delay) delay = serverHint;
    if (delay > retryMaxDelay) delay = retryMaxDelay;
    await Future<void>.delayed(delay);
  }

  Map<String, Object?>? _tryDecode(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return asMap(decoded);
      return null;
    } on FormatException {
      // Some gateways prefix SSE data with `data: ` twice, or emit `ping`.
      if (trimmed == 'ping' || trimmed == 'keep-alive') return null;
      throw ProtocolException('Could not parse JSON chunk from $name', body: trimmed);
    }
  }
}

/// Per-request decoding state (a mutable scratchpad for providers).
class ReasoningContext {
  ReasoningContext();

  /// A context with no special behaviour.
  factory ReasoningContext.none() = ReasoningContext;

  /// Last raw payload, kept for diagnostics.
  Map<String, Object?> raw = const <String, Object?>{};

  /// Accumulated usage across chunks.
  var usage = const TokenUsage();

  /// Reported finish reason.
  FinishReason? finishReason;

  /// Arbitrary provider scratch space.
  final Map<String, Object?> scratch = <String, Object?>{};

  /// Extra events to emit when the stream ends (e.g. flush a think parser).
  Iterable<ChatEvent> finalize() => const <ChatEvent>[];
}
