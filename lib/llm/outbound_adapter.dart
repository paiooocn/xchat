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

  // An OpenAI-compatible `tool` message can only carry a string, so an image
  // the agent produced has to ride on a user message. But that user message
  // cannot be injected *inside* a tool block: an assistant `tool_calls`
  // message must be followed by one `tool` message per call id, and anything
  // in between makes the request invalid (DeepSeek: "insufficient tool
  // messages following tool calls message"). So tool images are queued and
  // flushed as a single user message once the whole tool block is written.
  final pendingToolImages = <SessionMessage>[];
  Future<void> flushToolImages() async {
    if (pendingToolImages.isEmpty) return;
    final parts = <llm.ContentPart>[];
    for (final message in pendingToolImages) {
      parts.addAll(await _imageParts(message));
    }
    pendingToolImages.clear();
    out.add(llm.ChatMessage.userParts(parts));
  }

  for (final message in source) {
    switch (message.role) {
      case MessageRole.system:
        await flushToolImages();
        // `{sandbox}` in the system-prompt template is expanded to the session's
        // configured sandbox path.
        out.add(llm.ChatMessage.system(
          (message.content ?? '').replaceAll('{sandbox}', session.sandbox),
        ));
      case MessageRole.user:
        await flushToolImages();
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
        if (message.hasAttachments) pendingToolImages.add(message);
      case MessageRole.assistant:
        await flushToolImages();
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
  await flushToolImages();
  return _enforceToolProtocol(out);
}

/// Repairs the outbound history so it satisfies the tool-call protocol every
/// OpenAI-compatible endpoint enforces: an assistant `tool_calls` message must
/// be followed by exactly one `tool` message per `tool_call_id`. Missing
/// replies (a turn stopped mid-tool-loop, a deleted tool message …) become
/// error placeholders, and orphan `tool` messages are dropped — providers
/// reject the entire request otherwise ("insufficient tool messages following
/// tool calls message").
List<llm.ChatMessage> _enforceToolProtocol(List<llm.ChatMessage> input) {
  final out = <llm.ChatMessage>[];
  var i = 0;
  while (i < input.length) {
    final message = input[i++];
    final calls = message.toolCalls;
    if (calls.isEmpty) {
      // A `tool` reply without the assistant call it answers can never be sent
      // legally; drop it. (`toolCallId` is only set on tool messages.)
      if (message.toolCallId == null) out.add(message);
      continue;
    }
    out.add(message);
    final replies = <String, llm.ChatMessage>{};
    while (i < input.length && input[i].toolCallId != null) {
      final reply = input[i++];
      replies[reply.toolCallId!] = reply;
    }
    for (final call in calls) {
      out.add(replies.remove(call.id) ??
          llm.ChatMessage.tool(
            toolCallId: call.id,
            name: call.name,
            content: 'ERROR: 该工具调用的结果已从历史中丢失（可能因中断），'
                '如仍需要该结果，请重新调用该工具。',
            isError: true,
          ));
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
