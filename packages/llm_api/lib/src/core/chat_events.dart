/// Streaming event union emitted by every provider.
library;

import 'chat_message.dart';
import 'tool.dart';
import 'usage.dart';

/// Why the model stopped generating.
enum FinishReason {
  /// Natural end of turn.
  stop,

  /// Hit `max_tokens`.
  length,

  /// The model wants to call tools.
  toolCalls,

  /// Safety filter intervened.
  contentFilter,

  /// Provider-side error / refusal.
  error,

  /// Not reported.
  unknown;

  static FinishReason parse(String? value) {
    switch (value) {
      case 'stop':
      case 'end_turn':
      case 'stop_sequence':
      case 'STOP':
        return FinishReason.stop;
      case 'length':
      case 'max_tokens':
      case 'MAX_TOKENS':
        return FinishReason.length;
      case 'tool_calls':
      case 'function_call':
      case 'tool_use':
        return FinishReason.toolCalls;
      case 'content_filter':
      case 'safety':
      case 'SAFETY':
      case 'recitation':
        return FinishReason.contentFilter;
      case 'error':
      case 'ERROR':
        return FinishReason.error;
      default:
        return FinishReason.unknown;
    }
  }
}

/// Anything a model stream can tell you, in normalised form.
///
/// The two important ones are [ReasoningDelta] and [ContentDelta]: *every*
/// provider is mapped onto this split, whatever wire format it uses.
sealed class ChatEvent {
  const ChatEvent();
}

/// A chunk of thinking text (streaming).
final class ReasoningDelta extends ChatEvent {
  const ReasoningDelta(this.text);

  final String text;

  @override
  String toString() => 'ReasoningDelta(${text.length} chars)';
}

/// A chunk of the (Anthropic) thinking signature.
final class ReasoningSignatureDelta extends ChatEvent {
  const ReasoningSignatureDelta(this.signature);

  final String signature;
}

/// A chunk of the visible answer.
final class ContentDelta extends ChatEvent {
  const ContentDelta(this.text);

  final String text;

  @override
  String toString() => 'ContentDelta(${text.length} chars)';
}

/// The model started a new tool call at [index].
///
/// Streamed tool calls are keyed by index, not by id: the id/name arrive in the
/// first fragment while the JSON arguments trickle in afterwards.
final class ToolCallStarted extends ChatEvent {
  const ToolCallStarted({required this.index, this.id, this.name});

  final int index;
  final String? id;
  final String? name;

  @override
  String toString() => 'ToolCallStarted(#$index, $name)';
}

/// A fragment of a tool call's JSON arguments.
final class ToolCallArgumentsDelta extends ChatEvent {
  const ToolCallArgumentsDelta({required this.index, required this.fragment});

  final int index;
  final String fragment;
}

/// Token accounting for the current request.
final class UsageEvent extends ChatEvent {
  const UsageEvent(this.usage);

  final TokenUsage usage;
}

/// Emitted by [ChatSession] after a tool ran and its result was recorded.
final class ToolResultEvent extends ChatEvent {
  const ToolResultEvent({required this.call, required this.result, required this.round});

  final ToolCall call;
  final ToolResult result;

  /// 1-based model round inside the current turn.
  final int round;
}

/// Emitted by [ChatSession] at the end of every model round (there may be
/// several per user turn when tools are involved).
final class AssistantMessageCompleted extends ChatEvent {
  const AssistantMessageCompleted({required this.message, required this.round});

  final ChatMessage message;
  final int round;

  @override
  String toString() => 'AssistantMessageCompleted(round $round, $message)';
}

/// Terminal event of a stream / turn.
final class Finished extends ChatEvent {
  const Finished({required this.reason, this.usage = const TokenUsage(), this.rounds = 1});

  final FinishReason reason;

  /// Usage accumulated across every round of the turn.
  final TokenUsage usage;

  /// How many model round-trips happened.
  final int rounds;

  @override
  String toString() => 'Finished(${reason.name}, usage: $usage, rounds: $rounds)';
}
