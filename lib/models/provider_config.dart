import '../core/json_utils.dart';
import 'session_message.dart';
import 'session_params.dart';

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
    this.maxOutputTokens,
    this.defaultThinkingReplyMode = ThinkingReplyMode.auto,
    this.syncReasoningEffort = false,
    Map<String, ModelSpec>? modelSpecs,
    Map<String, List<String>>? reasoningEfforts,
    List<String>? models,
  })  : name = name ?? id,
        headers = headers ?? <String, String>{},
        models = models ?? <String>[],
        modelSpecs = modelSpecs ?? <String, ModelSpec>{},
        reasoningEfforts = reasoningEfforts ?? <String, List<String>>{};

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

  /// 最大输出 tokens（可选）：该服务单次回复的输出上限。
  ///
  /// `null` = 不限制（请求体不带输出上限参数）。请求时按
  /// [useMaxCompletionTokens] 决定参数名是 `max_completion_tokens` 还是
  /// `max_tokens`；会话参数 `max_tokens` 有值时以会话为准。
  int? maxOutputTokens;
  /// How history thinking should be echoed for this provider.
  ThinkingReplyMode defaultThinkingReplyMode;

  /// Known model ids (for the model picker).
  List<String> models;

  /// Per-model parameters keyed by model id (see [ModelSpec]).
  Map<String, ModelSpec> modelSpecs;

  /// 「同步思考强度」：开启后每模型的 `reasoning_effort` 候选值取自
  /// models.dev（见 [reasoningEfforts]）；关闭时用会话模板里
  /// `reasoning_effort` 的全部候选值。
  bool syncReasoningEffort;

  /// 已同步的每模型思考强度候选值（模型 id → 值列表）。
  ///
  /// 只在 [syncReasoningEffort] 开启时写入 / 生效；关闭或重新同步时会被清空，
  /// 避免留下过期的选项。
  Map<String, List<String>> reasoningEfforts;

  /// 已同步的 [model] 思考强度候选值（空 = 未同步）。
  ///
  /// 先按模型 ID 精确匹配，再忽略大小写；目录里没有这个 ID 时用该服务已同步
  /// 值的并集——同一服务的档位通常一致，比回落到含无效档位的通用列表好。
  List<String> effortOptionsFor(String model) {
    if (!syncReasoningEffort || reasoningEfforts.isEmpty) {
      return const <String>[];
    }
    final key = model.trim();
    final direct = reasoningEfforts[key] ?? _ciLookup(key);
    if (direct != null && direct.isNotEmpty) return direct;
    return <String>{
      for (final values in reasoningEfforts.values) ...values,
    }.toList(growable: false);
  }

  List<String>? _ciLookup(String model) {
    if (model.isEmpty) return null;
    final lower = model.toLowerCase();
    for (final entry in reasoningEfforts.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

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
        maxOutputTokens: maxOutputTokens,
        defaultThinkingReplyMode: defaultThinkingReplyMode,
        syncReasoningEffort: syncReasoningEffort,
        models: List<String>.of(models),
        modelSpecs: Map<String, ModelSpec>.of(modelSpecs),
        reasoningEfforts: <String, List<String>>{
          for (final entry in reasoningEfforts.entries)
            entry.key: List<String>.of(entry.value),
        },
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
        'max_output_tokens': maxOutputTokens,
        'thinking_reply_mode': defaultThinkingReplyMode.wire,
        if (syncReasoningEffort) 'sync_reasoning_effort': true,
        if (models.isNotEmpty) 'models': models,
        if (modelSpecs.isNotEmpty)
          'model_specs': [for (final spec in modelSpecs.values) spec.toJson()],
        if (reasoningEfforts.isNotEmpty && syncReasoningEffort)
          'reasoning_efforts': reasoningEfforts,
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
      maxOutputTokens: asInt(json['max_output_tokens']),
      defaultThinkingReplyMode:
          ThinkingReplyMode.parse(asString(json['thinking_reply_mode'])),
      models: asStringList(json['models']),
      syncReasoningEffort: asBool(json['sync_reasoning_effort']),
      modelSpecs: <String, ModelSpec>{
        for (final spec in asList(json['model_specs']).map(ModelSpec.fromJson))
          if (spec.id.isNotEmpty) spec.id: spec,
      },
      reasoningEfforts: <String, List<String>>{
        for (final entry in asMap(json['reasoning_efforts']).entries)
          if (asStringList(entry.value).isNotEmpty)
            entry.key: asStringList(entry.value),
      },
    );
  }
}

/// `reasoning_effort` 的候选档位（空串 = 不传入，由调用方决定是否显示）：
///
/// - 服务开启了「同步思考强度」且有该模型的同步值时，用 models.dev 同步好的
///   档位（deepseek 这类服务只接受 low/high/max，才不会给出无效档位）；
/// - 否则回落到会话模板 `reasoning_effort` 的完整候选列表。
List<String> reasoningEffortOptionsFor(ProviderConfig? provider, String model) {
  final synced = provider?.effortOptionsFor(model) ?? const <String>[];
  if (synced.isNotEmpty) return synced;
  return kReasoningEffortOptions
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
}
