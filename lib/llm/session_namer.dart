import 'package:llm_api/llm_api.dart' as llm;

import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_message.dart';
import 'llm_factory.dart';

/// Uses the LLM to generate a short, human-friendly title from the session's
/// first turn (the first user message and the assistant replies before the
/// next user message).
Future<String> generateSessionTitle({
  required ProviderConfig provider,
  required String model,
  required Session session,
}) async {
  final transcript = _firstTurn(session);
  if (transcript.isEmpty) {
    throw StateError('没有首轮对话内容，无法自动命名');
  }
  final llmProvider = createProvider(provider);
  try {
    final response = await llmProvider.complete(
      llm.ChatRequest(
        model: model,
        messages: [
          llm.ChatMessage.system(
            '你是会话标题生成器。请根据对话内容生成一个简洁、具体的中文标题。'
            '要求：不超过 20 个字；只输出标题本身；不要引号、不要序号、不要句末标点。',
          ),
          llm.ChatMessage.user('首轮对话内容：\n$transcript\n\n请输出标题：'),
        ],
        temperature: 0.3,
        maxTokens: 64,
      ),
    );
    final title = _clean(response.message.content ?? '');
    if (title.isEmpty) throw StateError('模型未返回有效标题');
    return title;
  } finally {
    llmProvider.close();
  }
}

/// The first turn only: the first user message and the assistant messages up
/// to (excluding) the next user message.
String _firstTurn(Session session) {
  final buffer = StringBuffer();
  var seenUser = false;
  for (final message in session.messages) {
    final isUser = message.role == MessageRole.user;
    if (!isUser && message.role != MessageRole.assistant) continue;
    if (isUser) {
      if (seenUser) break;
      seenUser = true;
    }
    final text = (message.content ?? '').trim();
    if (text.isEmpty) continue;
    buffer.writeln('${isUser ? '用户' : '助手'}：${_clip(text, 500)}');
    if (buffer.length > 2000) break;
  }
  return buffer.toString().trim();
}

String _clip(String value, int max) =>
    value.length <= max ? value : '${value.substring(0, max)}…';

String _clean(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  // Keep only the first non-empty line, then strip common decorations.
  text = text.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => text).trim();
  text = text.replaceAll(RegExp(r'^[#\-\*\s"\u201c\u201d\u300c\u300d]+'), '');
  text = text.replaceAll(RegExp(r'["\u201c\u201d\u300c\u300d\s]+$'), '');
  text = text.replaceFirst(RegExp(r'[。.!！,，；;：:]+$'), '');
  if (text.length > 30) text = text.substring(0, 30);
  return text.trim();
}
