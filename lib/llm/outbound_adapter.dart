import 'package:llm_api/llm_api.dart' as llm;

import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_message.dart';

/// Resolves how historical thinking should be echoed for a session.
///
/// Order: explicit session mode → provider default → derive from preset.
ThinkingReplyMode resolveEchoMode(Session session, ProviderConfig provider) {
  if (session.thinkingReplyMode != ThinkingReplyMode.auto) {
    return session.thinkingReplyMode;
  }
  if (provider.defaultThinkingReplyMode != ThinkingReplyMode.auto) {
    return provider.defaultThinkingReplyMode;
  }
  return switch (provider.preset) {
    'minimax' => ThinkingReplyMode.thinkTag,
    _ => ThinkingReplyMode.reasoningContent,
  };
}

/// Converts the persisted session messages into `llm_api` chat messages,
/// applying the thinking echo policy and the tool-call protocol.
List<llm.ChatMessage> buildChatMessages(
  Session session, {
  required ProviderConfig provider,
  List<SessionMessage>? messages,
}) {
  final source = messages ?? session.messages;
  final echo = resolveEchoMode(session, provider);
  final thinkingOn = session.params.thinkingEnabled;
  final out = <llm.ChatMessage>[];

  for (final message in source) {
    switch (message.role) {
      case MessageRole.system:
        // `{sandbox}` in the system-prompt template is expanded to the session's
        // configured sandbox path.
        out.add(llm.ChatMessage.system(
          (message.content ?? '').replaceAll('{sandbox}', session.sandbox),
        ));
      case MessageRole.user:
        out.add(llm.ChatMessage.user(message.content ?? ''));
      case MessageRole.tool:
        out.add(llm.ChatMessage.tool(
          toolCallId: message.toolCallId ?? '',
          content: message.content ?? '',
          name: message.toolName,
          isError: message.isError,
        ));
      case MessageRole.assistant:
        final calls = message.toolCalls
            .map((call) => llm.ToolCall(
                  id: call.id,
                  name: call.name,
                  arguments: call.arguments,
                ))
            .toList();
        if (!thinkingOn || !message.hasReasoning || echo == ThinkingReplyMode.thinkTag) {
          final content = (!thinkingOn || !message.hasReasoning)
              ? message.content
              : '<think>${message.reasoning}</think>\n\n${message.content ?? ''}';
          out.add(llm.ChatMessage.assistant(content: content, toolCalls: calls));
        } else {
          out.add(llm.ChatMessage.assistant(
            content: message.content,
            reasoningContent: message.reasoning,
            toolCalls: calls,
          ));
        }
    }
  }
  return out;
}

/// Whether the session's thinking config requires echoing reasoning back.
bool shouldEchoReasoning(Session session) => session.params.thinkingEnabled;
