/// Rebuilds a complete [ChatResponse] from a [ChatEvent] stream.
library;

import 'dart:async';

import 'chat_events.dart';
import 'chat_message.dart';
import 'chat_response.dart';
import 'tool.dart';
import 'usage.dart';

/// Consumes streamed deltas and produces the equivalent non-streamed message.
///
/// Two things are non-obvious and handled here:
/// * tool call arguments arrive as *string fragments* and must be concatenated
///   per `index` (not per id — the id itself may only show up in fragment #1);
/// * reasoning text and content text are accumulated independently so a UI can
///   render them in separate panes while the final message still keeps both.
class ChatStreamAggregator {
  ChatStreamAggregator({this.model, this.id});

  final String? model;
  final String? id;

  final StringBuffer _content = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();
  final StringBuffer _signature = StringBuffer();
  final Map<int, _ToolCallBuilder> _toolCalls = <int, _ToolCallBuilder>{};
  TokenUsage _usage = const TokenUsage();
  FinishReason? _finishReason;
  Map<String, Object?> _raw = const <String, Object?>{};

  /// Records the last raw provider payload for diagnostics.
  void setRaw(Map<String, Object?> payload) => _raw = payload;

  /// Partial content so far (handy for progressive UI rendering).
  String get content => _content.toString();

  /// Partial reasoning so far.
  String get reasoning => _reasoning.toString();

  void feed(ChatEvent event) {
    switch (event) {
      case ReasoningDelta(:final text):
        _reasoning.write(text);
      case ReasoningSignatureDelta(:final signature):
        _signature.write(signature);
      case ContentDelta(:final text):
        _content.write(text);
      case ToolCallStarted(:final index, :final id, :final name):
        _builder(index).start(id: id, name: name);
      case ToolCallArgumentsDelta(:final index, :final fragment):
        _builder(index).appendArguments(fragment);
      case UsageEvent(:final usage):
        _usage = _usage.merge(usage);
      case Finished(:final reason):
        _finishReason = reason;
      case ToolResultEvent():
      case AssistantMessageCompleted():
        break;
    }
  }

  /// Feeds a whole stream.
  Future<void> feedAll(Stream<ChatEvent> events) async {
    await for (final event in events) {
      feed(event);
    }
  }

  List<ToolCall> get toolCalls {
    final indexes = _toolCalls.keys.toList()..sort();
    return <ToolCall>[
      for (final index in indexes)
        if (!_toolCalls[index]!.isEmpty) _toolCalls[index]!.build(),
    ];
  }

  /// Builds the final message + metadata.
  ChatResponse build() {
    final calls = toolCalls;
    final message = ChatMessage(
      role: ChatRole.assistant,
      content: _content.isEmpty ? null : _content.toString(),
      reasoningContent: _reasoning.isEmpty ? null : _reasoning.toString(),
      reasoningSignature: _signature.isEmpty ? null : _signature.toString(),
      toolCalls: calls,
    );
    return ChatResponse(
      message: message,
      finishReason: _finishReason ?? (calls.isEmpty ? FinishReason.stop : FinishReason.toolCalls),
      usage: _usage,
      model: model,
      id: id,
      raw: _raw,
    );
  }

  _ToolCallBuilder _builder(int index) =>
      _toolCalls.putIfAbsent(index, () => _ToolCallBuilder(index));
}

/// Convenience: drains [events] into a single response.
Future<ChatResponse> collectChatResponse(
  Stream<ChatEvent> events, {
  String? model,
  void Function(ChatEvent event)? onEvent,
}) async {
  final aggregator = ChatStreamAggregator(model: model);
  await for (final event in events) {
    aggregator.feed(event);
    onEvent?.call(event);
  }
  return aggregator.build();
}

/// Splits a stream so both the live events *and* the aggregated response are
/// available, without buffering twice.
///
/// ```dart
/// final (events, response) = ChatResponse.split(provider.stream(request));
/// ```
class ChatResponseSplitter {
  ChatResponseSplitter(this.events, this.response);

  final Stream<ChatEvent> events;
  final Future<ChatResponse> response;

  static ChatResponseSplitter of(Stream<ChatEvent> source, {String? model}) {
    final controller = StreamController<ChatEvent>();
    final aggregator = ChatStreamAggregator(model: model);
    final done = Completer<ChatResponse>();
    controller
        .stream
        .forEach(aggregator.feed)
        .then((_) => done.complete(aggregator.build()))
        .catchError((Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    });
    source.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
      cancelOnError: false,
    );
    return ChatResponseSplitter(controller.stream, done.future);
  }
}

class _ToolCallBuilder {
  _ToolCallBuilder(this.index);

  final int index;
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();

  bool _touched = false;

  bool get isEmpty => !_touched;

  void start({String? id, String? name}) {
    _touched = true;
    if (id != null && id.isNotEmpty) this.id = id;
    if (name != null && name.isNotEmpty) this.name = name;
  }

  void appendArguments(String fragment) {
    _touched = true;
    arguments.write(fragment);
  }

  ToolCall build() => ToolCall(
        id: (id == null || id!.isEmpty) ? 'call_$index' : id!,
        name: name ?? '',
        arguments: arguments.toString(),
      );
}
