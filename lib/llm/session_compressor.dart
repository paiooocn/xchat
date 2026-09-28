import 'package:llm_api/llm_api.dart' as llm;

import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_message.dart';
import 'llm_factory.dart';

/// Framing that surrounds the user's chosen compress prompt, so the model
/// always knows *what* it is compressing and *what* the output is used for —
/// even when the picked prompt is a terse custom one.
const kCompressInstruction = '''你是一个「会话上下文压缩器」。

任务：把下面这段对话记录压缩成一份可以直接接续对话的上下文摘要。
- 摘要将成为后续对话的**唯一上下文**，原始对话不再被发送，因此关键信息不能丢。
- 必须保留：用户的任务目标与明确要求、已确认的结论与决定、涉及的文件路径/代码标识/命令与参数、尚未完成的事项。
- 只输出摘要正文，使用 Markdown；不要复述本指令，不要寒暄，不要提问，不要编造原文没有的信息。''';

/// Sends a "compress session" prompt plus the conversation transcript to the
/// LLM and returns the compressed context text.
Future<String> compressSessionContent({
  required ProviderConfig provider,
  required String model,
  required Session session,
  required String compressPrompt,
  String? systemPrompt,
  void Function(String partialText)? onProgress,
  llm.CancelToken? cancel,
}) async {
  final transcript = buildTranscript(session);
  if (transcript.isEmpty) {
    throw StateError('会话内容为空，无法压缩');
  }
  final llmProvider = createProvider(provider);
  try {
    final buffer = StringBuffer();
    final events = llmProvider.stream(
      llm.ChatRequest(
        model: model,
        messages: [
          if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
            llm.ChatMessage.system(systemPrompt),
          llm.ChatMessage.user(buildCompressRequest(compressPrompt, transcript)),
        ],
      ),
      cancel: cancel,
    );
    await for (final event in events) {
      if (event is llm.ContentDelta) {
        buffer.write(event.text);
        onProgress?.call(buffer.toString());
      }
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) throw StateError('模型未返回有效压缩内容');
    return text;
  } finally {
    llmProvider.close();
  }
}

/// Composes the single user message of a compression request: the framing
/// instruction, the chosen prompt, then the transcript in explicit delimiters.
String buildCompressRequest(String compressPrompt, String transcript) =>
    '$kCompressInstruction\n'
    '\n'
    '本次压缩要求：\n$compressPrompt\n'
    '\n'
    '===== 对话记录开始 =====\n'
    '$transcript\n'
    '===== 对话记录结束 =====\n'
    '\n'
    '现在只输出压缩后的 Markdown 摘要正文。';

/// Builds a user/assistant transcript of the session (excluding system/tool).
String buildTranscript(Session session) {
  final buffer = StringBuffer();
  for (final message in session.messages) {
    if (message.role != MessageRole.user && message.role != MessageRole.assistant) {
      continue;
    }
    final text = (message.content ?? '').trim();
    if (text.isEmpty) continue;
    buffer.writeln('${message.role == MessageRole.user ? '用户' : '助手'}：$text');
  }
  return buffer.toString().trim();
}

/// The first user message of the compressed session: a hand-off that tells the
/// model the summary is the carried-over context of the original conversation.
String buildCompressHandoff(String sourceTitle, String compressed) =>
    '以下是会话「${sourceTitle.isEmpty ? '未命名会话' : sourceTitle}」的压缩摘要，'
    '它将作为本次对话此前的全部上下文，请在理解它的基础上继续与我协作。\n\n'
    '$compressed';
