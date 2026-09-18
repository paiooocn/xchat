/// Token accounting, normalised across providers.
library;

import 'json_utils.dart';

/// Usage counters reported by a provider.
///
/// Every field is nullable: providers report different subsets, and the same
/// field name means different things (OpenAI's `prompt_tokens` == Anthropic's
/// `input_tokens` == Gemini's `promptTokenCount`).
class TokenUsage {
  const TokenUsage({
    this.inputTokens,
    this.outputTokens,
    this.reasoningTokens,
    this.cachedInputTokens,
  });

  /// Prompt / input tokens.
  final int? inputTokens;

  /// Completion / output tokens (usually *including* reasoning tokens).
  final int? outputTokens;

  /// Tokens spent inside the thinking block, when reported separately.
  final int? reasoningTokens;

  /// Input tokens served from the provider-side prompt cache.
  final int? cachedInputTokens;

  bool get isEmpty =>
      inputTokens == null &&
      outputTokens == null &&
      reasoningTokens == null &&
      cachedInputTokens == null;

  int? get totalTokens {
    if (inputTokens == null && outputTokens == null) return null;
    return (inputTokens ?? 0) + (outputTokens ?? 0);
  }

  /// Field-wise sum; `null` only when both sides are `null`.
  TokenUsage merge(TokenUsage other) => TokenUsage(
        inputTokens: _add(inputTokens, other.inputTokens),
        outputTokens: _add(outputTokens, other.outputTokens),
        reasoningTokens: _add(reasoningTokens, other.reasoningTokens),
        cachedInputTokens: _add(cachedInputTokens, other.cachedInputTokens),
      );

  static int? _add(int? a, int? b) => (a == null && b == null) ? null : (a ?? 0) + (b ?? 0);

  /// Tolerant reader for OpenAI (`prompt_tokens`), DeepSeek, Groq, Mistral,
  /// OpenRouter (which also puts reasoning into `completion_tokens_details`).
  static TokenUsage fromOpenAi(Map<String, Object?> json) {
    final completionDetails = asMap(json['completion_tokens_details']);
    final promptDetails = asMap(json['prompt_tokens_details']);
    return TokenUsage(
      inputTokens: asInt(json['prompt_tokens']) ?? asInt(json['input_tokens']),
      outputTokens: asInt(json['completion_tokens']) ?? asInt(json['output_tokens']),
      reasoningTokens: asInt(completionDetails['reasoning_tokens']) ??
          asInt(json['reasoning_tokens']),
      cachedInputTokens: asInt(promptDetails['cached_tokens']) ??
          asInt(json['prompt_cache_hit_tokens']),
    );
  }

  /// Anthropic `usage` block (also used by Bedrock).
  static TokenUsage fromAnthropic(Map<String, Object?> json) => TokenUsage(
        inputTokens: asInt(json['input_tokens']),
        outputTokens: asInt(json['output_tokens']),
        cachedInputTokens: asInt(json['cache_read_input_tokens']),
      );

  /// Gemini `usageMetadata`.
  static TokenUsage fromGemini(Map<String, Object?> json) => TokenUsage(
        inputTokens: asInt(json['promptTokenCount']),
        outputTokens: asInt(json['candidatesTokenCount']),
        reasoningTokens: asInt(json['thoughtsTokenCount']),
        cachedInputTokens: asInt(json['cachedContentTokenCount']),
      );

  /// Best-effort heuristic reader; use the provider-specific ones when you can.
  factory TokenUsage.fromJson(Map<String, Object?> json) {
    if (json.containsKey('promptTokenCount') || json.containsKey('candidatesTokenCount')) {
      return TokenUsage.fromGemini(json);
    }
    if (json.containsKey('input_tokens') || json.containsKey('cache_read_input_tokens')) {
      return TokenUsage.fromAnthropic(json);
    }
    return TokenUsage.fromOpenAi(json);
  }

  Map<String, Object?> toJson() => pruneNulls({
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'reasoning_tokens': reasoningTokens,
        'cached_input_tokens': cachedInputTokens,
      });

  @override
  String toString() =>
      'TokenUsage(in: ${inputTokens ?? '-'}, out: ${outputTokens ?? '-'}, '
      'reasoning: ${reasoningTokens ?? '-'}, cached: ${cachedInputTokens ?? '-'})';
}
