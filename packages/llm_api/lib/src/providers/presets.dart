/// Ready-made providers for popular endpoints.
///
/// Each preset only encodes the differences that actually matter: base URL,
/// where thinking lives ([ReasoningSource]) and how to ask for it
/// ([OpenAiReasoningRequestStyle]). Everything else is ordinary
/// OpenAI-compatible traffic.
///
/// ```dart
/// final provider = LlmPresets.deepseek(apiKey: Platform.environment['DEEPSEEK_API_KEY']!);
/// final session  = ChatSession(provider: provider, model: 'deepseek-reasoner');
/// ```
library;

import '../thinking/reasoning_router.dart';
import '../transport/transport.dart';
import 'anthropic.dart';
import 'gemini.dart';
import 'openai_compatible.dart';
import 'provider.dart';

/// Factory methods for common backends.
abstract final class LlmPresets {
  // ------------------------------------------------------------ OpenAI-compat

  /// Fully manual OpenAI-compatible endpoint.
  static OpenAiCompatibleProvider openAiCompatible({
    required Uri baseUrl,
    String? apiKey,
    String name = 'openai-compatible',
    Map<String, String>? headers,
    ReasoningSource reasoningSource = ReasoningSource.auto,
    OpenAiReasoningRequestStyle reasoningStyle = OpenAiReasoningRequestStyle.none,
    bool useMaxCompletionTokens = false,
    bool sendStreamOptions = true,
    ProviderCapabilities capabilities = const ProviderCapabilities(),
    HttpTransport? transport,
  }) =>
      OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: baseUrl,
          name: name,
          apiKey: apiKey,
          headers: headers ?? const <String, String>{},
          reasoningSource: reasoningSource,
          reasoningRequestStyle: reasoningStyle,
          useMaxCompletionTokens: useMaxCompletionTokens,
          sendStreamOptions: sendStreamOptions,
          capabilities: capabilities,
        ),
        transport: transport,
      );

  /// OpenAI (`gpt-5*`, `o*` reason natively; `reasoning_effort` is sent only
  /// when you set [ReasoningConfig.effort]).
  static OpenAiCompatibleProvider openai({
    required String apiKey,
    String? organization,
    Uri? baseUrl,
    HttpTransport? transport,
  }) =>
      OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: baseUrl ?? Uri.parse('https://api.openai.com/v1'),
          name: 'openai',
          apiKey: apiKey,
          headers: organization == null ? const {} : <String, String>{'OpenAI-Organization': organization},
          reasoningSource: ReasoningSource.auto,
          reasoningRequestStyle: OpenAiReasoningRequestStyle.reasoningEffort,
          useMaxCompletionTokens: true,
          capabilities: const ProviderCapabilities(
            supportsReasoningEffort: true,
            supportsStructuredOutput: true,
          ),
        ),
        transport: transport,
      );

  /// DeepSeek. `deepseek-reasoner` (R1/V3.1-thinking) returns
  /// `reasoning_content`; there is no knob to turn thinking on/off.
  static OpenAiCompatibleProvider deepseek({
    required String apiKey,
    Uri? baseUrl,
    HttpTransport? transport,
  }) =>
      OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: baseUrl ?? Uri.parse('https://api.deepseek.com/v1'),
          name: 'deepseek',
          apiKey: apiKey,
          reasoningSource: ReasoningSource.auto,
          reasoningRequestStyle: OpenAiReasoningRequestStyle.none,
          capabilities: const ProviderCapabilities(supportsParallelToolCalls: false),
        ),
        transport: transport,
      );

  /// Qwen via DashScope's OpenAI-compatible mode. Thinking is opt-in through
  /// `enable_thinking` (Qwen3 / QwQ).
  static OpenAiCompatibleProvider qwen({
    required String apiKey,
    Uri? baseUrl,
    HttpTransport? transport,
  }) =>
      OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: baseUrl ?? Uri.parse('https://dashscope.aliyuncs.com/compatible-mode/v1'),
          name: 'qwen',
          apiKey: apiKey,
          reasoningSource: ReasoningSource.auto,
          reasoningRequestStyle: OpenAiReasoningRequestStyle.enableThinking,
          capabilities: const ProviderCapabilities(
            supportsReasoningBudget: true,
            supportsParallelToolCalls: false,
          ),
        ),
        transport: transport,
      );

  /// Zhipu GLM (`glm-4.5`, `glm-4.6`) — `thinking: {type: enabled}`.
  static OpenAiCompatibleProvider zhipu({
    required String apiKey,
    Uri? baseUrl,
    HttpTransport? transport,
  }) =>
      OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: baseUrl ?? Uri.parse('https://open.bigmodel.cn/api/paas/v4'),
          name: 'zhipu',
          apiKey: apiKey,
          reasoningSource: ReasoningSource.auto,
          reasoningRequestStyle: OpenAiReasoningRequestStyle.thinkingBudget,
          capabilities: const ProviderCapabilities(supportsReasoningBudget: true),
        ),
        transport: transport,
      );

  /// Moonshot / Kimi (`kimi-k2-thinking`).
  static OpenAiCompatibleProvider moonshot({
    required String apiKey,
    Uri? baseUrl,
    HttpTransport? transport,
  }) =>
      OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: baseUrl ?? Uri.parse('https://api.moonshot.cn/v1'),
          name: 'moonshot',
          apiKey: apiKey,
          reasoningSource: ReasoningSource.auto,
          reasoningRequestStyle: OpenAiReasoningRequestStyle.none,
        ),
        transport: transport,
      );

  /// OpenRouter — aggregates many models and normalises reasoning into either
  /// `reasoning` or `reasoning_details`.
  static OpenAiCompatibleProvider openRouter({
    required String apiKey,
    String? appName,
    String? appUrl,
    Uri? baseUrl,
    HttpTransport? transport,
  }) =>
      OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: baseUrl ?? Uri.parse('https://openrouter.ai/api/v1'),
          name: 'openrouter',
          apiKey: apiKey,
          headers: <String, String>{
            if (appUrl != null) 'HTTP-Referer': appUrl,
            if (appName != null) 'X-Title': appName,
          },
          reasoningSource: ReasoningSource.auto,
          reasoningRequestStyle: OpenAiReasoningRequestStyle.reasoningMaxTokens,
          capabilities: const ProviderCapabilities(
            supportsReasoningEffort: true,
            supportsReasoningBudget: true,
          ),
        ),
        transport: transport,
      );

  static OpenAiCompatibleProvider groq({required String apiKey, HttpTransport? transport}) =>
      _chatty('groq', Uri.parse('https://api.groq.com/openai/v1'), apiKey, transport: transport);

  static OpenAiCompatibleProvider mistral({required String apiKey, HttpTransport? transport}) =>
      _chatty('mistral', Uri.parse('https://api.mistral.ai/v1'), apiKey, transport: transport);

  static OpenAiCompatibleProvider xai({required String apiKey, HttpTransport? transport}) =>
      _chatty('xai', Uri.parse('https://api.x.ai/v1'), apiKey, transport: transport);

  static OpenAiCompatibleProvider siliconflow({required String apiKey, HttpTransport? transport}) =>
      _chatty('siliconflow', Uri.parse('https://api.siliconflow.cn/v1'), apiKey, transport: transport);

  static OpenAiCompatibleProvider together({required String apiKey, HttpTransport? transport}) =>
      _chatty('together', Uri.parse('https://api.together.xyz/v1'), apiKey, transport: transport);

  static OpenAiCompatibleProvider _chatty(
    String name,
    Uri baseUrl,
    String apiKey, {
    HttpTransport? transport,
  }) =>
      OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: baseUrl,
          name: name,
          apiKey: apiKey,
          reasoningSource: ReasoningSource.auto,
        ),
        transport: transport,
      );

  // ------------------------------------------------------------------ local

  /// Ollama's OpenAI shim (default port 11434).
  static OpenAiCompatibleProvider ollama({
    String host = 'http://localhost:11434',
    HttpTransport? transport,
  }) =>
      OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: Uri.parse('$host/v1'),
          name: 'ollama',
          apiKey: 'ollama',
          // Ollama has no `stream_options` and no `reasoning` field; thinking
          // (if any) shows up inline in the text as ` thinking`.
          reasoningSource: ReasoningSource.auto,
          sendStreamOptions: false,
          capabilities: const ProviderCapabilities(supportsStreamUsage: false),
        ),
        transport: transport,
      );

  /// A vLLM / SGLang / LM Studio style local server.
  ///
  /// Set [startInReasoning] when the server prefills the assistant turn inside
  /// a thinking block, which makes the stream start with a bare ``.
  static OpenAiCompatibleProvider local({
    String baseUrl = 'http://localhost:8000/v1',
    String name = 'local',
    String apiKey = 'EMPTY',
    bool startInReasoning = false,
    ReasoningSource reasoningSource = ReasoningSource.auto,
    Map<String, Object?>? defaultBody,
    HttpTransport? transport,
  }) =>
      OpenAiCompatibleProvider(
        config: OpenAiCompatibleConfig(
          baseUrl: Uri.parse(baseUrl),
          name: name,
          apiKey: apiKey,
          startInReasoning: startInReasoning,
          reasoningSource: reasoningSource,
          // vLLM/SGLang accept `chat_template_kwargs.enable_thinking`.
          reasoningRequestStyle: OpenAiReasoningRequestStyle.none,
          defaultBody: defaultBody ?? const <String, Object?>{},
          capabilities: const ProviderCapabilities(supportsStreamUsage: false),
        ),
        transport: transport,
      );

  // ------------------------------------------------------- other protocols

  /// Anthropic Messages API (Claude).
  static AnthropicProvider anthropic({
    required String apiKey,
    Uri? baseUrl,
    String name = 'anthropic',
    bool enablePromptCaching = true,
    HttpTransport? transport,
  }) =>
      AnthropicProvider(
        config: AnthropicConfig(
          baseUrl: baseUrl,
          apiKey: apiKey,
          name: name,
          sendBetaHeaders: enablePromptCaching,
          betaHeaders: enablePromptCaching
              ? const <String>['prompt-caching-2024-07-31']
              : const <String>[],
        ),
        transport: transport,
      );

  /// Google Gemini (`generateContent`).
  static GeminiProvider gemini({
    required String apiKey,
    Uri? baseUrl,
    String name = 'gemini',
    HttpTransport? transport,
  }) =>
      GeminiProvider(
        config: GeminiConfig(baseUrl: baseUrl, apiKey: apiKey, name: name),
        transport: transport,
      );
}
