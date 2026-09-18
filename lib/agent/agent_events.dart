import '../models/session_message.dart';
import '../models/token_usage.dart';

/// Events emitted by [AgentEngine] for the UI to render.
sealed class AgentEvent {
  const AgentEvent();
}

class AgentRoundStarted extends AgentEvent {
  const AgentRoundStarted(this.round);

  final int round;
}

class AgentReasoningDelta extends AgentEvent {
  const AgentReasoningDelta(this.text);

  final String text;
}

class AgentContentDelta extends AgentEvent {
  const AgentContentDelta(this.text);

  final String text;
}

class AgentToolCallStarted extends AgentEvent {
  const AgentToolCallStarted({required this.id, required this.name});

  final String id;
  final String name;
}

class AgentToolResult extends AgentEvent {
  const AgentToolResult({
    required this.callId,
    required this.name,
    required this.content,
    required this.isError,
  });

  final String callId;
  final String name;
  final String content;
  final bool isError;
}

class AgentAssistantCompleted extends AgentEvent {
  const AgentAssistantCompleted(this.message);

  final SessionMessage message;
}

/// Emitted when the session hits its tool-call budget and enters auto-continue.
class AgentContinueDecision extends AgentEvent {
  const AgentContinueDecision({required this.cumulative, required this.limit});

  final int cumulative;
  final int limit;
}

class AgentUsageUpdated extends AgentEvent {
  const AgentUsageUpdated({required this.cumulative, required this.context});

  final TokenUsage cumulative;
  final int? context;
}

class AgentError extends AgentEvent {
  const AgentError(this.message);

  final String message;
}

class AgentFinished extends AgentEvent {
  const AgentFinished({required this.reason, required this.rounds});

  final String reason;
  final int rounds;
}

class AgentStopped extends AgentEvent {
  const AgentStopped();
}
