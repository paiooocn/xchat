import 'dart:convert';
import 'dart:io';

import 'package:llm_api/llm_api.dart' as llm;
import 'package:path/path.dart' as p;

import '../models/message_attachment.dart';
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
  // 任务式会话：user 消息的「任务标注」（`【任务：标题】`）落盘在
  // `message.premark`（`<user><premark>`），出站时**原样**插在正文前一行。
  //
  // 它是「方案 B」（整会话历史都发给模型）的分段标签，所以每条 user 消息各带
  // 各的。标注在写入时冻结：任务改名不影响历史消息的标注。
  //
  // 归属校验在这里做：任务项已被删除（或消息本来就没有 `task_id`）→ **一律不发
  // 标注**，落盘的 premark 也随之失效 —— 与「删任务项 = 连它的一切一起删」
  // 保持一致。（当前 UI 删任务项会连带删消息，见 `Session.removeTask`；
  // 这条兜的是手工改过 XML、`task_id` 悬空的存档。）
  //
  // 旧存档没有 premark（那时是出站时按 `task_id` 反查标题临时拼的），这里回退
  // 按任务项当前标题派生一次 —— 只读，不回写文件。
  String? premarkOf(String? premark, String? taskId) {
    if (taskId == null) return null;
    final task = session.taskById(taskId);
    if (task == null) return null;
    return premark ?? task.premark;
  }
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
    // 这条合成消息属于产出图片的那个任务，同样带上标注。
    final premark = premarkOf(
      pendingToolImages.first.premark,
      pendingToolImages.first.taskId,
    );
    if (premark != null) parts.add(llm.ContentPart.text('$premark\n'));
    for (final message in pendingToolImages) {
      parts.addAll(await _attachmentParts(message, sandbox: session.sandbox));
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
        final premark = premarkOf(message.premark, message.taskId);
        final parts = await _userParts(message, sandbox: session.sandbox);
        if (parts == null) {
          final text = message.content ?? '';
          // 正文为空（消息被清空）时不单独发一行标注。
          out.add(llm.ChatMessage.user(
            premark == null || text.trim().isEmpty ? text : '$premark\n$text',
          ));
        } else {
          out.add(llm.ChatMessage.userParts([
            if (premark != null) llm.ContentPart.text('$premark\n'),
            ...parts,
          ]));
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
Future<List<llm.ContentPart>?> _userParts(
  SessionMessage message, {
  required String sandbox,
}) async {
  if (!message.hasAttachments) return null;
  final parts = await _attachmentParts(message, sandbox: sandbox);
  // Text goes last: the vendor docs put the prompt *after* the media part.
  final text = message.content?.trim() ?? '';
  if (text.isNotEmpty) parts.add(llm.TextPart(text));
  return parts;
}

/// The parts for every attachment of a turn, in stored order. A file that
/// vanished degrades to a visible text marker rather than silently shrinking
/// the request.
Future<List<llm.ContentPart>> _attachmentParts(
  SessionMessage message, {
  required String sandbox,
}) async {
  final parts = <llm.ContentPart>[];
  for (final file in message.attachments) {
    parts.add(await _attachmentPart(file, sandbox: sandbox));
  }
  return parts;
}

/// One attachment → one part.
///
/// Images ride as `image_url` (base64); text files are **inlined verbatim**
/// inside a `<file name="…">` wrapper so a plain chat session — one with no
/// tools at all — can still read what the user dropped. The wrapper keeps the
/// boundary unambiguous when several files (or a file plus a prompt) share the
/// same turn.
///
/// An opaque [AttachmentKind.file] is **not** inlined: the turn only names the
/// sandbox-relative path and asks the model to open it with a tool. That is what
/// makes "any file type" safe — a 20 MB PDF or a zip never enters the prompt.
Future<llm.ContentPart> _attachmentPart(
  MessageAttachment file, {
  required String sandbox,
}) async {
  if (file.isOpaqueFile) {
    final path = file.path;
    if (path == null) return llm.TextPart('[${file.name}: 文件已丢失]');
    final where = p.isWithin(p.normalize(sandbox), p.normalize(path))
        ? p.relative(path, from: sandbox)
        : path;
    final size = await _fileSize(path);
    return llm.TextPart(
      '[附件文件] ${file.name}${size == null ? '' : '（$size）'}'
      '：已放在 `$where`。需要内容时请用 read_file 等工具读取（读取大文件请分段），'
      '无法用文本工具解析的格式可用 shell / python 处理。',
    );
  }
  if (file.isText) {
    final body = await file.readText();
    if (body == null) return llm.TextPart('[${file.name}: 文件已丢失]');
    return llm.TextPart('<file name="${file.name}">\n$body\n</file>');
  }
  final bytes = await file.readBytes();
  if (bytes == null) return llm.TextPart('[${file.name}: 文件已丢失]');
  return llm.ContentPart.imageBase64(
    base64Encode(bytes),
    mimeType: file.mimeType,
  );
}

Future<String?> _fileSize(String path) async {
  try {
    final length = await File(path).length();
    if (length >= 1024 * 1024) {
      return '${(length / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (length >= 1024) return '${(length / 1024).toStringAsFixed(0)} KB';
    return '$length 字节';
  } catch (_) {
    return null;
  }
}

/// Whether the session's thinking config requires echoing reasoning back.
bool shouldEchoReasoning(Session session) => session.params.thinkingEnabled;
