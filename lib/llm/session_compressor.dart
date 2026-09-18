import 'package:llm_api/llm_api.dart' as llm;

import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_message.dart';
import 'llm_factory.dart';

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
          llm.ChatMessage.user(
            '$compressPrompt\n\n===== 对话内容 =====\n$transcript',
          ),
        ],
      ),
      cancel: cancel,
    );
    await for (final event in events) {
      if (event is llm.ContentDelta) {
        buffer.write(event.text);
        onProgress?.call(buffer.toString());
      } else if (event is llm.ReasoningDelta) {
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
