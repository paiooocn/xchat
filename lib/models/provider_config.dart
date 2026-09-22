import '../core/json_utils.dart';
import 'session_message.dart';

/// Per-model parameters (context window, output cap, capabilities). Filled
/// from models.dev and used to size the context bar per selected model.
class ModelSpec {
  ModelSpec({
    required this.id,
    this.name = '',
    this.description = '',
    this.contextWindow,
    this.maxOutputTokens,
    this.reasoning = false,
    this.toolCall = false,
    this.status = '',
  });

  final String id;
  final String name;
  final String description;

  /// Context window (tokens); `null` = unknown.
  final int? contextWindow;

  /// Max output tokens; `null` = unknown.
  final int? maxOutputTokens;
  final bool reasoning;
  final bool toolCall;

  /// `''` | `beta` | `deprecated`.
  final String status;

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'id': id,
        if (name.isNotEmpty) 'name': name,
        if (description.isNotEmpty) 'description': description,
        'context_window': contextWindow,
        'max_output_tokens': maxOutputTokens,
        'reasoning': reasoning,
        'tool_call': toolCall,
        if (status.isNotEmpty) 'status': status,
      });

  factory ModelSpec.fromJson(Object? value) {
    final json = asMap(value);
    return ModelSpec(
      id: asString(json['id']) ?? '',
      name: asString(json['name']) ?? '',
      description: asString(json['description']) ?? '',
      contextWindow: asInt(json['context_window']),
      maxOutputTokens: asInt(json['max_output_tokens']),
      reasoning: asBool(json['reasoning']),
      toolCall: asBool(json['tool_call']),
      status: asString(json['status']) ?? '',
    );
  }
}

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
    Map<String, ModelSpec>? modelSpecs,
  })  : name = name ?? id,
        headers = headers ?? <String, String>{},
        models = models ?? <String>[],
        modelSpecs = modelSpecs ?? <String, ModelSpec>{};

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

  /// Per-model parameters keyed by model id (see [ModelSpec]).
  Map<String, ModelSpec> modelSpecs;

  /// Parameters of [model], or `null` when unknown.
  ModelSpec? specFor(String model) => modelSpecs[model];

  /// Context window for [model], falling back to the provider-wide value.
  int? contextWindowFor(String model) => specFor(model)?.contextWindow ?? contextWindow;

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
        modelSpecs: Map<String, ModelSpec>.of(modelSpecs),
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
        if (modelSpecs.isNotEmpty)
          'model_specs': [for (final spec in modelSpecs.values) spec.toJson()],
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
      modelSpecs: <String, ModelSpec>{
        for (final spec in asList(json['model_specs']).map(ModelSpec.fromJson))
          if (spec.id.isNotEmpty) spec.id: spec,
      },
    );
  }
}
