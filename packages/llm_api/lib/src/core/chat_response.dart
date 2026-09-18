/// The aggregated result of a streamed (or non-streamed) completion.
library;

import 'chat_message.dart';
import 'chat_events.dart';
import 'tool.dart';
import 'usage.dart';

/// Everything a single model round-trip produced.
class ChatResponse {
  const ChatResponse({
    required this.message,
    required this.finishReason,
    this.usage = const TokenUsage(),
    this.model,
    this.id,
    this.raw = const <String, Object?>{},
  });

  /// The assistant message, including `reasoningContent` and `toolCalls`.
  final ChatMessage message;

  final FinishReason finishReason;
  final TokenUsage usage;

  /// Model that actually served the request.
  final String? model;

  /// Provider response id.
  final String? id;

  /// Last raw provider payload (diagnostics).
  final Map<String, Object?> raw;

  /// Visible answer text.
  String get text => message.text;

  /// The thinking text, or `null`.
  String? get reasoningContent => message.reasoningContent;

  List<ToolCall> get toolCalls => message.toolCalls;

  bool get hasToolCalls => message.toolCalls.isNotEmpty;

  ChatResponse copyWith({
    ChatMessage? message,
    FinishReason? finishReason,
    TokenUsage? usage,
    String? model,
    String? id,
    Map<String, Object?>? raw,
  }) =>
      ChatResponse(
        message: message ?? this.message,
        finishReason: finishReason ?? this.finishReason,
        usage: usage ?? this.usage,
        model: model ?? this.model,
        id: id ?? this.id,
        raw: raw ?? this.raw,
      );

  @override
  String toString() => 'ChatResponse(${finishReason.name}, '
      'text: ${text.length} chars, '
      'reasoning: ${reasoningContent?.length ?? 0} chars, '
      'toolCalls: ${toolCalls.length}, $usage)';
}
