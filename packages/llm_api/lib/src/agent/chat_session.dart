/// Multi-turn conversation with an automatic tool-calling loop.
library;

import 'dart:async';

import '../core/aggregator.dart';
import '../core/chat_events.dart';
import '../core/chat_message.dart';
import '../core/chat_request.dart';
import '../core/chat_response.dart';
import '../core/json_utils.dart';
import '../core/tool.dart';
import '../core/usage.dart';
import '../providers/provider.dart';
import '../transport/cancel_token.dart';
import 'tool_registry.dart';

/// Drives a conversation: keeps history, executes tools, trims context.
///
/// One [send] call = one *turn*, which may be several model round-trips when
/// tools are involved:
///
/// ```
/// user ─► model ─► ToolCallStarted/ArgumentsDelta ─► ToolResultEvent ─► model ─► … ─► Finished
/// ```
class ChatSession {
  ChatSession({
    required this.provider,
    required this.model,
    String? systemPrompt,
    List<ChatMessage>? history,
    Iterable<LlmTool> tools = const <LlmTool>[],
    ToolRegistry? registry,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.reasoning,
    this.toolChoice,
    this.extra = const <String, Object?>{},
    this.maxToolRounds = 8,
    this.maxHistoryCharacters,
  }) : registry = registry ?? ToolRegistry(tools) {
    if (history != null) _history.addAll(history);
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      _history.insert(0, ChatMessage.system(systemPrompt));
    }
  }

  final LlmProvider provider;

  /// Model id sent with every request.
  final String model;

  final ToolRegistry registry;
  final double? temperature;
  final double? topP;
  final int? maxTokens;

  /// Thinking configuration; `includeInHistory` is respected per provider.
  final ReasoningConfig? reasoning;

  final ToolChoice? toolChoice;

  /// Merged into every request body.
  final Map<String, Object?> extra;

  /// Hard stop for the tool loop, so a tool that always fails cannot spin
  /// forever. When exceeded the turn ends with [FinishReason.toolCalls].
  final int maxToolRounds;

  /// Approximate character budget for the conversation sent to the model.
  ///
  /// `null` (default) disables trimming — set it when you expect long sessions
  /// with small-context models. Trimmed units are dropped whole, so an
  /// assistant tool-call message never gets separated from its tool results.
  final int? maxHistoryCharacters;

  final List<ChatMessage> _history = <ChatMessage>[];
  CancelToken? _activeTurn;
  bool _busy = false;

  /// Live history (read-only view).
  List<ChatMessage> get history => List<ChatMessage>.unmodifiable(_history);

  /// Mutable history, for advanced editing (message rewriting, pinning …).
  List<ChatMessage> get messages => _history;

  /// `true` while a turn is streaming.
  bool get isBusy => _busy;

  /// Number of completed turns (one per [send] call).
  int get turnCount => _turns;
  int _turns = 0;

  /// Sends a user message and streams the whole turn.
  Stream<ChatEvent> send(String input, {CancelToken? cancel}) =>
      sendMessage(ChatMessage.user(input), cancel: cancel);

  /// Sends a prebuilt message (e.g. multimodal, or a tool result you produced
  /// yourself).
  Stream<ChatEvent> sendMessage(ChatMessage message, {CancelToken? cancel}) async* {
    if (_busy) {
      throw StateError('This ChatSession is already streaming a turn');
    }
    final token = CancelToken.link(cancel);
    _activeTurn = token;
    _busy = true;
    _history.add(message);
    var round = 0;
    var usage = const TokenUsage();
    FinishReason? reason;

    try {
      _trimHistory();
      while (true) {
        round++;
        token.throwIfCancelled();
        final aggregator = ChatStreamAggregator(model: model);
        await for (final event in provider.stream(_buildRequest(), cancel: token)) {
          // A provider emits `Finished` per request; the session owns the
          // single `Finished` for the whole turn, so drop the inner ones.
          if (event is Finished) continue;
          aggregator.feed(event);
          yield event;
        }
        final response = aggregator.build();
        _history.add(response.message);
        usage = usage.merge(response.usage);
        yield AssistantMessageCompleted(message: response.message, round: round);

        final calls = response.message.toolCalls;
        if (calls.isEmpty || registry.isEmpty) {
          reason = response.finishReason;
          break;
        }
        // Always answer every call, even on the last allowed round: an
        // assistant `tool_calls` message without its tool results makes the
        // *next* request invalid.
        for (final call in calls) {
          token.throwIfCancelled();
          final result = await registry.invoke(call, cancel: token);
          _history.add(ChatMessage.tool(
            toolCallId: call.id,
            name: call.name,
            content: result.content,
            isError: result.isError,
          ));
          yield ToolResultEvent(call: call, result: result, round: round);
        }
        if (round >= maxToolRounds) {
          // The model keeps asking for tools; stop instead of looping forever.
          reason = FinishReason.toolCalls;
          break;
        }
        _trimHistory();
      }
      _turns++;
      yield Finished(reason: reason, usage: usage, rounds: round);
    } finally {
      _busy = false;
      if (identical(_activeTurn, token)) _activeTurn = null;
    }
  }

  /// Runs a turn and returns the final response (events go to [onEvent]).
  Future<ChatResponse> ask(
    String input, {
    CancelToken? cancel,
    void Function(ChatEvent event)? onEvent,
  }) async {
    ChatMessage? last;
    var reason = FinishReason.stop;
    var usage = const TokenUsage();
    await for (final event in send(input, cancel: cancel)) {
      onEvent?.call(event);
      if (event is AssistantMessageCompleted) last = event.message;
      if (event is Finished) {
        reason = event.reason;
        usage = event.usage;
      }
    }
    final message = last;
    if (message == null) {
      throw StateError('The turn produced no assistant message');
    }
    return ChatResponse(message: message, finishReason: reason, usage: usage, model: model);
  }

  /// Cancels the in-flight turn (no-op when idle).
  void cancel() => _activeTurn?.cancel('session cancelled');

  /// Drops the conversation, optionally keeping the system prompt.
  void clear({bool keepSystemPrompt = true}) {
    if (keepSystemPrompt) {
      _history.removeWhere((message) => message.role != ChatRole.system);
    } else {
      _history.clear();
    }
    _turns = 0;
  }

  /// Appends a message without calling the model (context injection, RAG…).
  void addContext(ChatMessage message) => _history.add(message);

  /// Replaces the system prompt.
  void setSystemPrompt(String prompt) {
    _history.removeWhere((message) => message.role == ChatRole.system);
    _history.insert(0, ChatMessage.system(prompt));
  }

  ChatRequest _buildRequest() => ChatRequest(
        model: model,
        messages: List<ChatMessage>.of(_history),
        tools: registry.definitions,
        toolChoice: toolChoice,
        temperature: temperature,
        topP: topP,
        maxTokens: maxTokens,
        reasoning: reasoning,
        extra: extra,
      );

  // -------------------------------------------------------------- trimming

  int get _systemCount {
    var count = 0;
    while (count < _history.length && _history[count].role == ChatRole.system) {
      count++;
    }
    return count;
  }

  /// Characters currently in history (reasoning included: it is what the model
  /// actually had to "write", even if we do not send it back).
  int get historyCharacters => _history.fold<int>(
        0,
        (total, message) =>
            total + message.text.length + (message.reasoningContent?.length ?? 0),
      );

  void _trimHistory() {
    final budget = maxHistoryCharacters;
    if (budget == null || budget <= 0) return;
    var guard = 0;
    while (historyCharacters > budget && guard++ < 1000) {
      final drop = _leadingUnitLength();
      if (drop == 0) return;
      if (_history.length - drop < 1) return;
      _history.removeRange(_systemCount, _systemCount + drop);
    }
  }

  /// Number of messages forming the oldest droppable unit.
  ///
  /// An assistant message that requested tools is inseparable from the
  /// `tool` messages answering it — dropping only one of them makes providers
  /// reject the whole request.
  int _leadingUnitLength() {
    final start = _systemCount;
    if (start >= _history.length) return 0;
    var end = start + 1;
    if (_history[start].role == ChatRole.assistant && _history[start].hasToolCalls) {
      while (end < _history.length && _history[end].role == ChatRole.tool) {
        end++;
      }
    }
    // Never leave a dangling tool message at the head of the history.
    while (end < _history.length && _history[end].role == ChatRole.tool) {
      end++;
    }
    return end - start;
  }

  // ----------------------------------------------------------- persistence

  /// Serialises the conversation so it can be restored later.
  Map<String, Object?> toJson() => <String, Object?>{
        'model': model,
        'turn_count': _turns,
        'messages': <Map<String, Object?>>[
          for (final message in _history) message.toJson(),
        ],
      };

  /// Restores a conversation produced by [toJson].
  void restore(Map<String, Object?> json) {
    _history
      ..clear()
      ..addAll(asList(json['messages']).map(asMap).map(ChatMessage.fromJson));
    _turns = asInt(json['turn_count']) ?? 0;
  }

  /// Convenience: rebuild a session from a persisted payload.
  static ChatSession fromJson(
    Map<String, Object?> json, {
    required LlmProvider provider,
    required String model,
    Iterable<LlmTool> tools = const <LlmTool>[],
    ToolRegistry? registry,
  }) {
    final session = ChatSession(
      provider: provider,
      model: asString(json['model']) ?? model,
      tools: tools,
      registry: registry,
    );
    session.restore(json);
    return session;
  }
}
