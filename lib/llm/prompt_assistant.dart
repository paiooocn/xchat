import 'package:llm_api/llm_api.dart' as llm;

import '../models/provider_config.dart';
import 'llm_factory.dart';

/// 预置场景类别（模板向导一键生成系统提示词）。
const List<String> kPromptCategories = <String>[
  '商业',
  '办公',
  '生活',
  '编程',
  '旅游',
];

/// Streams a freshly-generated system prompt for [category]/[requirement].
/// Partial text is reported via [onProgress]; the final value is unwrapped.
Future<String> generateSystemPrompt({
  required ProviderConfig provider,
  required String model,
  String category = '',
  String requirement = '',
  void Function(String partialText)? onProgress,
  llm.CancelToken? cancel,
}) {
  return _stream(
    provider: provider,
    model: model,
    messages: [
      llm.ChatMessage.system(
        '你是资深的 AI 系统提示词（System Prompt）设计师。'
        '你撰写的提示词用于设定 AI 助手的角色与行为规范，要求专业、具体、可直接使用。',
      ),
      llm.ChatMessage.user(
        '请为以下用途撰写一段中文系统提示词：\n'
        '场景类别：${category.isEmpty ? '（未指定）' : category}\n'
        '用途描述：${requirement.trim().isEmpty ? '（无，按该场景的通用最佳实践设计）' : requirement.trim()}\n\n'
        '要求：\n'
        '1. 包含角色定位、核心职责、工作流程、输出规范与约束边界；\n'
        '2. 结构清晰（可用分节或列表），长度 200-500 字；\n'
        '3. 内容可直接作为 system prompt 使用；\n'
        '4. 只输出提示词正文本身，不要任何解释，不要用代码块包裹，不要「系统提示词：」等前缀。',
      ),
    ],
    onProgress: onProgress,
    cancel: cancel,
  );
}

/// Streams a revised system prompt: [prompt] adjusted per [instruction].
Future<String> refineSystemPrompt({
  required ProviderConfig provider,
  required String model,
  required String prompt,
  required String instruction,
  void Function(String partialText)? onProgress,
  llm.CancelToken? cancel,
}) {
  return _stream(
    provider: provider,
    model: model,
    temperature: 0.4,
    messages: [
      llm.ChatMessage.system(
        '你是系统提示词（System Prompt）润色专家，擅长在保持原意的前提下改进提示词的清晰度、具体性与有效性。',
      ),
      llm.ChatMessage.user(
        '请按调整要求修改下面的系统提示词。\n'
        '调整要求：${instruction.trim()}\n\n'
        '===== 原始提示词 =====\n'
        '${prompt.trim()}\n'
        '====================\n\n'
        '要求：输出修改后的完整提示词正文，保持原有结构与语言；'
        '只输出正文本身，不要任何解释，不要用代码块包裹。',
      ),
    ],
    onProgress: onProgress,
    cancel: cancel,
  );
}

Future<String> _stream({
  required ProviderConfig provider,
  required String model,
  required List<llm.ChatMessage> messages,
  double? temperature,
  void Function(String partialText)? onProgress,
  llm.CancelToken? cancel,
}) async {
  final llmProvider = createProvider(provider);
  try {
    final buffer = StringBuffer();
    final events = llmProvider.stream(
      llm.ChatRequest(
        model: model,
        messages: messages,
        temperature: temperature,
      ),
      cancel: cancel,
    );
    await for (final event in events) {
      if (event is llm.ContentDelta) {
        buffer.write(event.text);
        onProgress?.call(buffer.toString());
      }
    }
    final text = _unwrap(buffer.toString().trim());
    if (text.isEmpty) throw StateError('模型未返回有效内容');
    return text;
  } finally {
    llmProvider.close();
  }
}

/// Strips a wrapping markdown code fence (and a leading label), if present.
String _unwrap(String raw) {
  var text = raw.trim();
  final fenced = RegExp(r'^```[a-zA-Z]*\n([\s\S]*?)\n?```$', multiLine: false);
  final match = fenced.firstMatch(text);
  if (match != null) text = match.group(1)!.trim();
  text = text.replaceFirst(RegExp(r'^系统提示词[:：]\s*'), '');
  return text.trim();
}
