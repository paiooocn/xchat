/// The request object handed to providers.
library;

import 'chat_message.dart';
import 'json_utils.dart';
import 'tool.dart';

/// How much thinking the model should spend on the answer.
enum ReasoningEffort {
  /// Gemini "no thinking", OpenAI `minimal`.
  minimal,
  low,
  medium,
  high,

  /// Anthropic `budget_tokens` or OpenRouter `xhigh`.
  xhigh;

  static ReasoningEffort? parse(String? value) {
    switch (value?.toLowerCase()) {
      case 'minimal':
      case 'none':
      case 'off':
        return ReasoningEffort.minimal;
      case 'low':
        return ReasoningEffort.low;
      case 'medium':
      case 'mid':
        return ReasoningEffort.medium;
      case 'high':
        return ReasoningEffort.high;
      case 'xhigh':
      case 'max':
        return ReasoningEffort.xhigh;
      default:
        return null;
    }
  }
}

/// Vendor-neutral description of the desired thinking behaviour.
///
/// Providers translate this into their own dialect (`reasoning_effort`,
/// `enable_thinking`, `thinking: {"type":"enabled","budget_tokens":…}`) and
/// silently drop what they do not support.
class ReasoningConfig {
  const ReasoningConfig({
    this.enabled,
    this.effort,
    this.effortName,
    this.budgetTokens,
    this.includeInHistory = false,
  });

  /// Explicit on/off switch (Qwen3 `enable_thinking`, Gemini thinkingBudget 0).
  final bool? enabled;

  /// Coarse effort knob.
  final ReasoningEffort? effort;

  /// Verbatim `reasoning_effort` label (`max` | `xhigh` | `high` | `medium` |
  /// `low` | `minimal` | `none`). When set, providers that speak
  /// `reasoning_effort` send it as-is instead of mapping [effort].
  final String? effortName;

  /// Token budget for the thinking block (Anthropic / Qwen / Gemini).
  final int? budgetTokens;

  /// Whether `reasoningContent` from previous turns is sent back to the model.
  ///
  /// Defaults to `false`: DeepSeek explicitly discards it server-side and
  /// several gateways reject unknown fields. Turn it on for Anthropic extended
  /// thinking, where the signed thinking block *must* be echoed.
  final bool includeInHistory;

  static const ReasoningConfig off = ReasoningConfig(enabled: false);

  ReasoningConfig copyWith({
    bool? enabled,
    ReasoningEffort? effort,
    String? effortName,
    int? budgetTokens,
    bool? includeInHistory,
  }) =>
      ReasoningConfig(
        enabled: enabled ?? this.enabled,
        effort: effort ?? this.effort,
        effortName: effortName ?? this.effortName,
        budgetTokens: budgetTokens ?? this.budgetTokens,
        includeInHistory: includeInHistory ?? this.includeInHistory,
      );

  Map<String, Object?> toJson() => pruneNulls({
        'enabled': enabled,
        'effort': effort?.name,
        'effort_name': effortName,
        'budget_tokens': budgetTokens,
        'include_in_history': includeInHistory,
      });

  factory ReasoningConfig.fromJson(Map<String, Object?> json) => ReasoningConfig(
        enabled: json.containsKey('enabled') ? asBool(json['enabled']) : null,
        effort: ReasoningEffort.parse(asString(json['effort'])),
        effortName: asString(json['effort_name']),
        budgetTokens: asInt(json['budget_tokens']),
        includeInHistory: asBool(json['include_in_history']),
      );
}

/// A complete, provider-agnostic chat request.
class ChatRequest {
  const ChatRequest({
    required this.model,
    required this.messages,
    this.tools = const <ToolDefinition>[],
    this.toolChoice,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.stop,
    this.seed,
    this.reasoning,
    this.responseJsonSchema,
    this.extra = const <String, Object?>{},
  });

  final String model;
  final List<ChatMessage> messages;
  final List<ToolDefinition> tools;
  final ToolChoice? toolChoice;
  final double? temperature;
  final double? topP;
  final int? maxTokens;

  /// One or more stop sequences.
  final List<String>? stop;
  final int? seed;
  final ReasoningConfig? reasoning;

  /// When set, providers that support structured output enable JSON mode.
  final Map<String, Object?>? responseJsonSchema;

  /// Escape hatch merged verbatim into the request body. Use it for vendor
  /// extensions this package does not model (e.g. `top_k`, `logprobs`).
  final Map<String, Object?> extra;

  ChatRequest copyWith({
    String? model,
    List<ChatMessage>? messages,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    double? temperature,
    double? topP,
    int? maxTokens,
    List<String>? stop,
    int? seed,
    ReasoningConfig? reasoning,
    Map<String, Object?>? responseJsonSchema,
    Map<String, Object?>? extra,
  }) =>
      ChatRequest(
        model: model ?? this.model,
        messages: messages ?? this.messages,
        tools: tools ?? this.tools,
        toolChoice: toolChoice ?? this.toolChoice,
        temperature: temperature ?? this.temperature,
        topP: topP ?? this.topP,
        maxTokens: maxTokens ?? this.maxTokens,
        stop: stop ?? this.stop,
        seed: seed ?? this.seed,
        reasoning: reasoning ?? this.reasoning,
        responseJsonSchema: responseJsonSchema ?? this.responseJsonSchema,
        extra: extra ?? this.extra,
      );
}
