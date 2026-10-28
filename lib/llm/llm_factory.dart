import 'package:llm_api/llm_api.dart';

import '../models/provider_config.dart';

/// Builds an `llm_api` provider from an [ProviderConfig].
///
/// [reasoningEffort] is the thinking level of the current session
/// (`reasoning_effort`); it selects the output cap when the service defines
/// per-effort caps (see [ProviderConfig.maxOutputTokensByEffort]).
///
/// Uses the plain transport: request/response JSON is never dumped to the
/// console, in either debug or release builds.
LlmProvider createProvider(ProviderConfig config, {String? reasoningEffort}) {
  return OpenAiCompatibleProvider(
      config: buildOpenAiConfig(config, reasoningEffort: reasoningEffort));
}

/// Translates an [ProviderConfig] into the wire-level configuration.
///
/// Exposed separately so the request body can be inspected in tests.
OpenAiCompatibleConfig buildOpenAiConfig(ProviderConfig config,
    {String? reasoningEffort}) {
  return OpenAiCompatibleConfig(
    baseUrl: Uri.parse(config.baseUrl),
    name: config.id,
    apiKey: config.apiKey.isEmpty ? null : config.apiKey,
    headers: config.headers,
    reasoningSource: _reasoningSource(config.reasoningSource),
    reasoningRequestStyle: _reasoningStyle(config.reasoningStyle),
    useMaxCompletionTokens: config.useMaxCompletionTokens,
    // Output cap of the service; a request-level `max_tokens` overrides it.
    // With per-effort caps the value depends on the session's thinking level.
    defaultMaxTokens: config.maxOutputTokensFor(reasoningEffort),
    sendStreamOptions: true,
  );
}
ReasoningSource _reasoningSource(String value) => switch (value) {
      'field' => ReasoningSource.field,
      'inline' => ReasoningSource.inlineTags,
      'none' => ReasoningSource.none,
      _ => ReasoningSource.auto,
    };

OpenAiReasoningRequestStyle _reasoningStyle(String value) => switch (value) {
      'reasoning_effort' => OpenAiReasoningRequestStyle.reasoningEffort,
      'enable_thinking' => OpenAiReasoningRequestStyle.enableThinking,
      'thinking_budget' => OpenAiReasoningRequestStyle.thinkingBudget,
      'reasoning_max_tokens' => OpenAiReasoningRequestStyle.reasoningMaxTokens,
      _ => OpenAiReasoningRequestStyle.none,
    };

/// Fetches the model list from the endpoint (`/models`).
Future<List<String>> fetchModels(ProviderConfig config) async {
  final provider = createProvider(config);
  try {
    final models = await provider.listModels();
    return models.map((m) => m.id).toList();
  } finally {
    provider.close();
  }
}

/// A quick connectivity check against the endpoint.
Future<String> testProvider(ProviderConfig config) async {
  final provider = createProvider(config);
  try {
    final models = await provider.listModels();
    return 'OK (${models.length} models)';
  } finally {
    provider.close();
  }
}
