/// Provider-agnostic Dart client for LLM chat APIs.
///
/// Streaming, multi-turn conversations, deep-thinking / reasoning extraction
/// (`reasoning_content` fields, inline ` thinking` tags, Anthropic thinking
/// blocks, Gemini thought parts) and tool calling.
///
/// ```dart
/// import 'package:llm_api/llm_api.dart';
///
/// final provider = LlmPresets.deepseek(apiKey: apiKey);
/// final session = ChatSession(
///   provider: provider,
///   model: 'deepseek-reasoner',
///   systemPrompt: 'You are concise.',
/// );
///
/// await for (final event in session.send('Why is the sky blue?')) {
///   switch (event) {
///     case ReasoningDelta(:final text):
///       stdout.write('\x1b[2m$text\x1b[0m'); // thinking pane
///     case ContentDelta(:final text):
///       stdout.write(text);                  // answer pane
///     case ToolCallStarted(:final name):
///       stdout.write('\n[tool: $name]\n');
///     case Finished():
///       break;
///     default:
///       break;
///   }
/// }
/// ```
library;

// Core model
export 'src/core/aggregator.dart'
    show ChatStreamAggregator, ChatResponseSplitter, collectChatResponse;
export 'src/core/chat_events.dart';
export 'src/core/chat_message.dart';
export 'src/core/chat_request.dart';
export 'src/core/chat_response.dart';
export 'src/core/content_part.dart';
export 'src/core/errors.dart';
export 'src/core/json_utils.dart';
export 'src/core/schema.dart';
export 'src/core/tool.dart';
export 'src/core/uri_utils.dart';
export 'src/core/usage.dart';

// Thinking / reasoning
export 'src/thinking/reasoning_router.dart';
export 'src/thinking/think_tag_parser.dart';

// Streaming + transport
export 'src/stream/sse.dart';
export 'src/transport/cancel_token.dart';
export 'src/transport/io_transport.dart';
export 'src/transport/transport.dart';

// Providers
export 'src/providers/anthropic.dart';
export 'src/providers/gemini.dart';
export 'src/providers/openai_compatible.dart';
export 'src/providers/presets.dart';
export 'src/providers/provider.dart';

// Agent layer
export 'src/agent/chat_session.dart';
export 'src/agent/tool_registry.dart';
