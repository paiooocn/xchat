import 'package:llm_api/llm_api.dart' as llm;

import '../models/provider_config.dart';
import 'llm_factory.dart';

/// What the AI is asked to do.
enum NoteAiMode {
  /// Rewrite the selected text.
  rewrite,

  /// Produce new text (continuation, summary, outline, …).
  generate,

  /// Answer a question about the note (read only).
  ask,
}

/// Where an AI result is supposed to go.
enum NoteAiTarget {
  /// Replace the current selection (or insert at the cursor).
  replaceSelection,

  /// Append at the end of the note.
  append,

  /// Only copy to the clipboard — the note is not modified.
  copy,
}

/// A quick action offered by the AI panel.
class NoteAiAction {
  const NoteAiAction({
    required this.id,
    required this.label,
    required this.mode,
    required this.target,
    required this.instruction,
    this.temperature = 0.3,
  });

  final String id;
  final String label;
  final NoteAiMode mode;
  final NoteAiTarget target;

  /// The instruction sent to the model.
  final String instruction;

  final double temperature;
}

/// The built-in actions (grouped by [NoteAiMode]).
const List<NoteAiAction> kNoteAiActions = <NoteAiAction>[
  // ---- 改写（作用于选区） -------------------------------------------
  NoteAiAction(
    id: 'polish',
    label: '润色',
    mode: NoteAiMode.rewrite,
    target: NoteAiTarget.replaceSelection,
    instruction: '把选区改写得通顺、准确、简洁，保持原意与原有 Markdown 结构。',
  ),
  NoteAiAction(
    id: 'expand',
    label: '扩写',
    mode: NoteAiMode.rewrite,
    target: NoteAiTarget.replaceSelection,
    instruction: '在选区基础上补充细节与解释，保持原有 Markdown 结构，不要编造笔记里没有的事实。',
  ),
  NoteAiAction(
    id: 'shorten',
    label: '缩写',
    mode: NoteAiMode.rewrite,
    target: NoteAiTarget.replaceSelection,
    instruction: '把选区压缩得更简洁，去掉冗余，保留全部关键信息。',
  ),
  NoteAiAction(
    id: 'tone',
    label: '改写语气',
    mode: NoteAiMode.rewrite,
    target: NoteAiTarget.replaceSelection,
    instruction: '把选区改成更正式/更口语（按下面用户补充的要求），其余不变。',
  ),
  NoteAiAction(
    id: 'translate',
    label: '翻译',
    mode: NoteAiMode.rewrite,
    target: NoteAiTarget.replaceSelection,
    instruction: '把选区翻译成中文（用户没指定语言时译成中文），保留 Markdown 结构。',
  ),
  NoteAiAction(
    id: 'fix',
    label: '纠错',
    mode: NoteAiMode.rewrite,
    target: NoteAiTarget.replaceSelection,
    instruction: '修正选区里的错别字、语病与明显的 Markdown 写法问题，不要改变意思。',
  ),
  NoteAiAction(
    id: 'format',
    label: '转换格式',
    mode: NoteAiMode.rewrite,
    target: NoteAiTarget.replaceSelection,
    instruction: '把选区转换成规范的 Markdown（标题层级、列表缩进、表格列结构、代码围栏与语言标注）。',
  ),

  // ---- 生成 ----------------------------------------------------------
  NoteAiAction(
    id: 'continue',
    label: '续写',
    mode: NoteAiMode.generate,
    target: NoteAiTarget.append,
    temperature: 0.7,
    instruction: '根据笔记已有内容自然地续写下去，保持同样的语气与 Markdown 结构。',
  ),
  NoteAiAction(
    id: 'summary',
    label: '摘要',
    mode: NoteAiMode.generate,
    target: NoteAiTarget.copy,
    temperature: 0.3,
    instruction: '为这篇笔记写一段简明摘要（3-5 句），只输出摘要正文。',
  ),
  NoteAiAction(
    id: 'title',
    label: '标题',
    mode: NoteAiMode.generate,
    target: NoteAiTarget.copy,
    temperature: 0.3,
    instruction: '为这篇笔记起一个简洁的标题，只输出标题本身。',
  ),
  NoteAiAction(
    id: 'tags',
    label: '标签',
    mode: NoteAiMode.generate,
    target: NoteAiTarget.copy,
    temperature: 0.3,
    instruction: '为这篇笔记推荐 3-5 个标签，用英文逗号分隔，只输出标签。',
  ),
  NoteAiAction(
    id: 'outline',
    label: '大纲',
    mode: NoteAiMode.generate,
    target: NoteAiTarget.replaceSelection,
    temperature: 0.7,
    instruction: '为这篇笔记列出一个 Markdown 大纲（只列标题层级，不要正文）。',
  ),
  NoteAiAction(
    id: 'minutes',
    label: '会议纪要模板',
    mode: NoteAiMode.generate,
    target: NoteAiTarget.copy,
    temperature: 0.7,
    instruction: '输出一份会议纪要模板（Markdown），包含议题、结论、待办三节。',
  ),
  NoteAiAction(
    id: 'cards',
    label: '复习卡片',
    mode: NoteAiMode.generate,
    target: NoteAiTarget.copy,
    temperature: 0.7,
    instruction: '把笔记里的要点做成复习卡片（Markdown 列表，每行「问：… 答：…」）。',
  ),
];

/// The context handed to the model.
class NoteContext {
  const NoteContext({
    required this.text,
    required this.truncated,
    required this.selection,
  });

  /// The note text that is sent to the model.
  final String text;

  /// True when the note was too long and the context was trimmed.
  final bool truncated;

  /// The selected text (empty when nothing is selected).
  final String selection;
}

/// The system prompt for the note assistant.
String buildNoteSystemPrompt({required String title}) => '''
你是 Markdown 笔记助手。当前笔记标题是「${title.isEmpty ? '未命名笔记' : title}」。
规则：
- 输出必须是 Markdown 片段，不要用 ``` 包裹整篇，不要写解释性前言。
- 除非明确要求「重写全文」，否则只输出被修改/新增的那部分。
- 保留原有标题层级、列表缩进、代码围栏与语言标注、表格列结构。
- 不要编造笔记里没有的事实。''';

/// Builds the user prompt (note + request + selection).
String buildNoteUserPrompt({
  required NoteContext context,
  required String instruction,
  String? selection,
}) {
  final buffer = StringBuffer()
    ..writeln('【当前笔记正文】')
    ..writeln('<note>')
    ..write(context.text)
    ..writeln('</note>')
    ..writeln('【本次请求】${instruction.trim()}');
  final sel = (selection ?? context.selection).trim();
  if (sel.isNotEmpty) {
    buffer
      ..writeln('【选区】')
      ..write(sel);
  }
  if (context.truncated) {
    buffer.writeln(
      '（注：正文过长，已按相关片段裁剪上下文；如需全文请在界面上选择「包含全文」。）',
    );
  }
  return buffer.toString();
}

/// Builds the context for one request.
///
/// * the selection is surrounded by 200 characters of context, so
///   「把第二段改正式些」 is unambiguous;
/// * when the note is longer than [charLimit] the context degrades to
///   「标题 + 大纲 + 选区 + 命中关键词的段落」 and [NoteContext.truncated]
///   is set.
NoteContext buildNoteContext({
  required String body,
  required int charLimit,
  String? selection,
  String? instruction,
  bool forceFull = false,
}) {
  final sel = (selection ?? '').trim();
  final limit = charLimit <= 0 ? 12000 : charLimit;

  if (forceFull || body.length <= limit) {
    return NoteContext(
      text: _withSelectionContext(body, sel),
      truncated: false,
      selection: sel,
    );
  }

  final buffer = StringBuffer();
  final outline = _outline(body);
  if (outline.isNotEmpty) {
    buffer
      ..writeln('# 大纲')
      ..writeln(outline);
  }
  if (sel.isNotEmpty) {
    buffer
      ..writeln('# 选区')
      ..writeln(_withSelectionContext(body, sel));
  }
  final keywords = _keywords(instruction ?? '');
  final paragraphs = _paragraphs(body);
  final relevant = paragraphs
      .where((p) =>
          keywords.isEmpty || keywords.any((k) => p.toLowerCase().contains(k)))
      .take(12)
      .toList();
  if (relevant.isNotEmpty) {
    buffer
      ..writeln('# 相关段落')
      ..writeln(relevant.join('\n\n'));
  }
  return NoteContext(
    text: buffer.toString().trim(),
    truncated: true,
    selection: sel,
  );
}

/// The note text with 200 characters of context around the selection.
String _withSelectionContext(String body, String selection) {
  if (selection.isEmpty) return body;
  final index = body.indexOf(selection);
  if (index < 0) return body;
  const radius = 200;
  final start = (index - radius).clamp(0, body.length);
  final end = (index + selection.length + radius).clamp(0, body.length);
  final buffer = StringBuffer();
  if (start > 0) buffer.write('…\n');
  buffer.write(body.substring(start, end));
  if (end < body.length) buffer.write('\n…');
  return buffer.toString();
}

/// The headings of the note (as a Markdown list).
String _outline(String body) {
  final lines = <String>[];
  for (final line in body.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('#')) lines.add(trimmed);
  }
  return lines.join('\n');
}

/// The note's paragraphs (blank-line separated blocks).
List<String> _paragraphs(String body) {
  return body
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
}

/// Rough keywords of an instruction (CJK words + latin words).
List<String> _keywords(String instruction) {
  final words = RegExp(r'[A-Za-z一-龥]{2,}').allMatches(instruction);
  final seen = <String>{};
  final out = <String>[];
  for (final match in words) {
    final word = match.group(0)!.toLowerCase();
    if (seen.add(word)) out.add(word);
  }
  return out.take(12).toList();
}

/// Whether a provider looks usable (an API key, or a local endpoint).
bool isProviderConfigured(ProviderConfig provider) {
  final baseUrl = provider.baseUrl.trim().toLowerCase();
  final local = baseUrl.contains('localhost') || baseUrl.contains('127.0.0.1');
  if (provider.apiKey.trim().isNotEmpty) return true;
  return local && baseUrl.isNotEmpty;
}

/// Streams one AI request and returns the cleaned-up result.
///
/// Partial output is reported through [onProgress]; [cancel] stops the
/// request (nothing is written back).
///
/// [providerFactory] exists for tests (inject a fake provider).
Future<String> runNoteAssistant({
  required ProviderConfig provider,
  required String model,
  required String systemPrompt,
  required String userPrompt,
  double temperature = 0.3,
  void Function(String partialText)? onProgress,
  llm.CancelToken? cancel,
  llm.LlmProvider Function(ProviderConfig config)? providerFactory,
}) async {
  final llmProvider = (providerFactory ?? createProvider)(provider);
  try {
    final buffer = StringBuffer();
    final events = llmProvider.stream(
      llm.ChatRequest(
        model: model,
        messages: [
          llm.ChatMessage.system(systemPrompt),
          llm.ChatMessage.user(userPrompt),
        ],
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
    final text = cleanNoteAiResult(buffer.toString());
    if (text.isEmpty) throw StateError('模型未返回有效内容');
    return text;
  } finally {
    llmProvider.close();
  }
}

/// Strips code fences and common prefixes from a model answer.
String cleanNoteAiResult(String raw) {
  var text = raw.trim();
  final fenced =
      RegExp(r'^```[a-zA-Z]*\n([\s\S]*?)\n?```$').firstMatch(text);
  if (fenced != null) text = fenced.group(1)!.trim();
  text = text.replaceFirst(RegExp(r'^(改写|润色|结果|输出|摘要)[:：]\s*'), '');
  return text.trim();
}
