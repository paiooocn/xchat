import '../core/json_utils.dart';
import 'token_usage.dart';

/// How historical thinking text is echoed back to the model.
enum ThinkingReplyMode {
  /// Derive from the provider preset.
  auto,

  /// Send as the `reasoning_content` field (deepseek/kimi/glm/mimo/qwen…).
  reasoningContent,

  /// Wrap as `<think>…</think>` inside `content` (minimax…).
  thinkTag;

  static ThinkingReplyMode parse(String? value) => switch (value) {
        'reasoning_content' => ThinkingReplyMode.reasoningContent,
        'think_tag' => ThinkingReplyMode.thinkTag,
        _ => ThinkingReplyMode.auto,
      };

  String get wire => switch (this) {
        ThinkingReplyMode.auto => 'auto',
        ThinkingReplyMode.reasoningContent => 'reasoning_content',
        ThinkingReplyMode.thinkTag => 'think_tag',
      };
}

enum MessageRole {
  system,
  user,
  assistant,
  tool;

  static MessageRole parse(String? value) => switch (value) {
        'system' => MessageRole.system,
        'assistant' => MessageRole.assistant,
        'tool' => MessageRole.tool,
        _ => MessageRole.user,
      };

  String get wire => name;
}

/// A tool invocation requested by the assistant.
class ToolCallData {
  ToolCallData({required this.id, required this.name, required this.arguments});

  final String id;
  final String name;

  /// The raw JSON argument string as produced by the model.
  final String arguments;

  Map<String, Object?> toJson() =>
      <String, Object?>{'id': id, 'name': name, 'arguments': arguments};

  factory ToolCallData.fromJson(Object? value) {
    final json = asMap(value);
    return ToolCallData(
      id: asString(json['id']) ?? '',
      name: asString(json['name']) ?? '',
      arguments: asString(json['arguments']) ?? '',
    );
  }
}

/// One entry of a session's `messages` array (mapped to an XML element).
class SessionMessage {
  SessionMessage({
    required this.role,
    this.id,
    this.content,
    this.reasoning,
    this.reasoningMode,
    List<ToolCallData>? toolCalls,
    this.toolCallId,
    this.toolName,
    this.isError = false,
    this.usage = TokenUsage.empty,
  }) : toolCalls = toolCalls ?? <ToolCallData>[];

  MessageRole role;
  String? id;
  String? content;

  /// Thinking text (assistant only).
  String? reasoning;

  /// Which channel the thinking came from (`reasoning_content` / `think_tag`).
  String? reasoningMode;

  List<ToolCallData> toolCalls;
  String? toolCallId;
  String? toolName;
  bool isError;

  /// Per-turn usage (assistant only).
  TokenUsage usage;

  bool get hasToolCalls => toolCalls.isNotEmpty;

  bool get hasReasoning => reasoning != null && reasoning!.isNotEmpty;

  SessionMessage copyWith({
    MessageRole? role,
    String? id,
    String? content,
    String? reasoning,
    String? reasoningMode,
    List<ToolCallData>? toolCalls,
    String? toolCallId,
    String? toolName,
    bool? isError,
    TokenUsage? usage,
  }) =>
      SessionMessage(
        role: role ?? this.role,
        id: id ?? this.id,
        content: content ?? this.content,
        reasoning: reasoning ?? this.reasoning,
        reasoningMode: reasoningMode ?? this.reasoningMode,
        toolCalls: toolCalls ?? this.toolCalls,
        toolCallId: toolCallId ?? this.toolCallId,
        toolName: toolName ?? this.toolName,
        isError: isError ?? this.isError,
        usage: usage ?? this.usage,
      );

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'role': role.wire,
        if (id != null) 'id': id,
        'content': content,
        'reasoning': reasoning,
        if (reasoningMode != null) 'reasoning_mode': reasoningMode,
        if (toolCalls.isNotEmpty)
          'tool_calls': toolCalls.map((call) => call.toJson()).toList(),
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (toolName != null) 'tool_name': toolName,
        if (isError) 'is_error': true,
        if (usage.isNotEmpty) 'usage': usage.toJson(),
      });

  factory SessionMessage.fromJson(Object? value) {
    final json = asMap(value);
    return SessionMessage(
      role: MessageRole.parse(asString(json['role'])),
      id: asString(json['id']),
      content: asString(json['content']),
      reasoning: asString(json['reasoning']),
      reasoningMode: asString(json['reasoning_mode']),
      toolCalls: asList(json['tool_calls']).map(ToolCallData.fromJson).toList(),
      toolCallId: asString(json['tool_call_id']),
      toolName: asString(json['tool_name']),
      isError: asBool(json['is_error']),
      usage: TokenUsage.fromJson(json['usage']),
    );
  }
}
