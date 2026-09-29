import 'dart:convert';

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
///
/// Async because user messages carrying attachments have to read their
/// payloads off disk before they can be turned into [llm.ContentPart]s.
Future<List<llm.ChatMessage>> buildChatMessages(
  Session session, {
  required ProviderConfig provider,
  List<SessionMessage>? messages,
}) async {
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
        final parts = await _userParts(message);
        if (parts == null) {
          out.add(llm.ChatMessage.user(message.content ?? ''));
        } else {
          out.add(llm.ChatMessage.userParts(parts));
        }
      case MessageRole.tool:
        out.add(llm.ChatMessage.tool(
          toolCallId: message.toolCallId ?? '',
          content: message.content ?? '',
          name: message.toolName,
          isError: message.isError,
        ));
        // An OpenAI-compatible `tool` message can only carry a string, so an
        // image the agent produced cannot ride on it. Follow it with a user
        // message holding just the image parts — the one encoding all
        // OpenAI-compatible endpoints agree on.
        if (message.hasAttachments) {
          out.add(llm.ChatMessage.userParts(await _imageParts(message)));
        }
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

/// Builds the parts of a multimodal user turn, or `null` when the message has
/// no usable attachment and can go out as plain text.
Future<List<llm.ContentPart>?> _userParts(SessionMessage message) async {
  if (!message.hasAttachments) return null;
  final parts = await _imageParts(message);
  // Text goes last: the vendor docs put the prompt *after* the media part.
  final text = message.content?.trim() ?? '';
  if (text.isNotEmpty) parts.add(llm.TextPart(text));
  return parts;
}

/// The image parts of a turn; a file that vanished degrades to a visible text
/// marker rather than silently shrinking the request.
Future<List<llm.ContentPart>> _imageParts(SessionMessage message) async {
  final parts = <llm.ContentPart>[];
  for (final file in message.attachments) {
    final bytes = await file.readBytes();
    if (bytes == null) {
      parts.add(llm.TextPart('[${file.name}: 文件已丢失]'));
      continue;
    }
    parts.add(llm.ContentPart.imageBase64(
      base64Encode(bytes),
      mimeType: file.mimeType,
    ));
  }
  return parts;
}

/// Whether the session's thinking config requires echoing reasoning back.
bool shouldEchoReasoning(Session session) => session.params.thinkingEnabled;
