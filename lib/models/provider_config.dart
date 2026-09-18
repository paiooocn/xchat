import '../core/json_utils.dart';
import 'session_message.dart';

/// A configured LLM endpoint (OpenAI-compatible) or vendor preset.
class ProviderConfig {
  ProviderConfig({
    required this.id,
    String? name,
    this.baseUrl = '',
    this.apiKey = '',
    Map<String, String>? headers,
    this.preset = 'custom',
    this.reasoningSource = 'auto',
    this.reasoningStyle = 'none',
    this.useMaxCompletionTokens = false,
    this.contextWindow,
    this.defaultThinkingReplyMode = ThinkingReplyMode.auto,
    List<String>? models,
  })  : name = name ?? id,
        headers = headers ?? <String, String>{},
        models = models ?? <String>[];

  /// Stable identifier referenced by sessions (`provider` field).
  String id;
  String name;
  String baseUrl;
  String apiKey;
  Map<String, String> headers;

  /// `custom` | `openai` | `deepseek` | `moonshot` | `zhipu` | `mimo` |
  /// `minimax` | `qwen` | `openrouter` | …
  String preset;

  /// auto | field | inline | none (maps to llm_api ReasoningSource).
  String reasoningSource;

  /// none | reasoning_effort | enable_thinking | thinking_budget |
  /// reasoning_max_tokens (maps to llm_api OpenAiReasoningRequestStyle).
  String reasoningStyle;

  bool useMaxCompletionTokens;

  /// Context window (tokens) for the context bar; `null` = unknown.
  int? contextWindow;

  /// How history thinking should be echoed for this provider.
  ThinkingReplyMode defaultThinkingReplyMode;

  /// Known model ids (for the model picker).
  List<String> models;

  ProviderConfig copyWith({String? id, String? name}) => ProviderConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        baseUrl: baseUrl,
        apiKey: apiKey,
        headers: Map<String, String>.of(headers),
        preset: preset,
        reasoningSource: reasoningSource,
        reasoningStyle: reasoningStyle,
        useMaxCompletionTokens: useMaxCompletionTokens,
        contextWindow: contextWindow,
        defaultThinkingReplyMode: defaultThinkingReplyMode,
        models: List<String>.of(models),
      );

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'id': id,
        'name': name,
        'base_url': baseUrl,
        if (apiKey.isNotEmpty) 'api_key': apiKey,
        if (headers.isNotEmpty) 'headers': headers,
        'preset': preset,
        'reasoning_source': reasoningSource,
        'reasoning_style': reasoningStyle,
        'use_max_completion_tokens': useMaxCompletionTokens,
        'context_window': contextWindow,
        'thinking_reply_mode': defaultThinkingReplyMode.wire,
        if (models.isNotEmpty) 'models': models,
      });

  factory ProviderConfig.fromJson(Object? value) {
    final json = asMap(value);
    final id = asString(json['id']) ?? 'provider';
    return ProviderConfig(
      id: id,
      name: asString(json['name']) ?? id,
      baseUrl: asString(json['base_url']) ?? '',
      apiKey: asString(json['api_key']) ?? '',
      headers: asMap(json['headers']).map((k, v) => MapEntry(k, '${v ?? ''}')),
      preset: asString(json['preset']) ?? 'custom',
      reasoningSource: asString(json['reasoning_source']) ?? 'auto',
      reasoningStyle: asString(json['reasoning_style']) ?? 'none',
      useMaxCompletionTokens: asBool(json['use_max_completion_tokens']),
      contextWindow: asInt(json['context_window']),
      defaultThinkingReplyMode:
          ThinkingReplyMode.parse(asString(json['thinking_reply_mode'])),
      models: asStringList(json['models']),
    );
  }
}
