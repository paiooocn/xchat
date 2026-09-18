/// The single message type used everywhere in this package.
library;

import 'content_part.dart';
import 'json_utils.dart';
import 'tool.dart';

/// Who authored a message.
enum ChatRole {
  system,
  user,
  assistant,
  tool;

  static ChatRole parse(String? value) {
    switch (value) {
      case 'system':
      case 'developer':
        return ChatRole.system;
      case 'assistant':
      case 'model':
        return ChatRole.assistant;
      case 'tool':
      case 'function':
        return ChatRole.tool;
      default:
        return ChatRole.user;
    }
  }

  String get wireName => name;
}

/// A provider-agnostic chat message.
///
/// Keeping *one* class (rather than a sealed hierarchy per role) makes history
/// serialisation, trimming and UI rendering trivial, and mirrors how every
/// provider actually encodes messages.
class ChatMessage {
  ChatMessage({
    required this.role,
    this.content,
    this.parts,
    this.reasoningContent,
    this.reasoningSignature,
    List<ToolCall>? toolCalls,
    this.toolCallId,
    this.toolName,
    this.isError = false,
    this.metadata = const <String, Object?>{},
  }) : toolCalls = toolCalls ?? const <ToolCall>[];

  /// System / developer prompt.
  factory ChatMessage.system(String content) =>
      ChatMessage(role: ChatRole.system, content: content);

  /// A plain text user turn.
  factory ChatMessage.user(String content) =>
      ChatMessage(role: ChatRole.user, content: content);

  /// A multimodal user turn (text + images).
  factory ChatMessage.userParts(List<ContentPart> parts) =>
      ChatMessage(role: ChatRole.user, parts: parts);

  /// An assistant turn. [reasoningContent] holds the thinking text.
  factory ChatMessage.assistant({
    String? content,
    String? reasoningContent,
    String? reasoningSignature,
    List<ToolCall> toolCalls = const <ToolCall>[],
    Map<String, Object?> metadata = const <String, Object?>{},
  }) =>
      ChatMessage(
        role: ChatRole.assistant,
        content: content,
        reasoningContent: reasoningContent,
        reasoningSignature: reasoningSignature,
        toolCalls: toolCalls,
        metadata: metadata,
      );

  /// Feeds a tool result back to the model.
  factory ChatMessage.tool({
    required String toolCallId,
    required String content,
    String? name,
    bool isError = false,
  }) =>
      ChatMessage(
        role: ChatRole.tool,
        content: content,
        toolCallId: toolCallId,
        toolName: name,
        isError: isError,
      );

  final ChatRole role;

  /// Visible answer text.
  final String? content;

  /// Multimodal user content. When set, [content] is usually `null`.
  final List<ContentPart>? parts;

  /// The *thinking* text: DeepSeek `reasoning_content`, Anthropic `thinking`
  /// blocks, Gemini `thought` parts, or the body of an inline ` thinking` tag.
  final String? reasoningContent;

  /// Anthropic extended-thinking signature; must be echoed back verbatim for
  /// multi-turn thinking to work.
  final String? reasoningSignature;

  /// Tool calls requested by the assistant.
  final List<ToolCall> toolCalls;

  /// Set on [ChatRole.tool] messages: which call this answers.
  final String? toolCallId;

  /// Set on [ChatRole.tool] messages: the function name (Gemini requires it).
  final String? toolName;

  /// Set on [ChatRole.tool] messages: did the tool throw?
  final bool isError;

  /// Free-form slot for the host app (timestamps, cost, latency, …).
  final Map<String, Object?> metadata;

  bool get hasReasoning => reasoningContent != null && reasoningContent!.isNotEmpty;

  bool get hasToolCalls => toolCalls.isNotEmpty;

  /// Effective content segments, folding [content] into [parts].
  List<ContentPart> get effectiveParts {
    if (parts != null && parts!.isNotEmpty) return parts!;
    final text = content;
    if (text == null) return const <ContentPart>[];
    return <ContentPart>[TextPart(text)];
  }

  /// Plain-text projection (images become a short placeholder).
  String get text {
    if (parts == null || parts!.isEmpty) return content ?? '';
    return parts!
        .map((part) => switch (part) {
              TextPart(:final text) => text,
              ImagePart() => '[image]',
            })
        .join();
  }

  ChatMessage copyWith({
    ChatRole? role,
    String? content,
    List<ContentPart>? parts,
    String? reasoningContent,
    String? reasoningSignature,
    List<ToolCall>? toolCalls,
    String? toolCallId,
    String? toolName,
    bool? isError,
    Map<String, Object?>? metadata,
  }) =>
      ChatMessage(
        role: role ?? this.role,
        content: content ?? this.content,
        parts: parts ?? this.parts,
        reasoningContent: reasoningContent ?? this.reasoningContent,
        reasoningSignature: reasoningSignature ?? this.reasoningSignature,
        toolCalls: toolCalls ?? this.toolCalls,
        toolCallId: toolCallId ?? this.toolCallId,
        toolName: toolName ?? this.toolName,
        isError: isError ?? this.isError,
        metadata: metadata ?? this.metadata,
      );

  /// Round-trips through JSON so sessions can be persisted.
  Map<String, Object?> toJson() => pruneNulls({
        'role': role.name,
        'content': content,
        if (parts != null) 'parts': parts!.map((part) => part.toJson()).toList(),
        'reasoning_content': reasoningContent,
        'reasoning_signature': reasoningSignature,
        if (toolCalls.isNotEmpty) 'tool_calls': toolCalls.map((call) => call.toJson()).toList(),
        'tool_call_id': toolCallId,
        'tool_name': toolName,
        if (isError) 'is_error': true,
        if (metadata.isNotEmpty) 'metadata': metadata,
      });

  factory ChatMessage.fromJson(Map<String, Object?> json) => ChatMessage(
        role: ChatRole.parse(asString(json['role'])),
        content: asString(json['content']),
        parts: json.containsKey('parts') ? partsFromJson(json['parts']) : null,
        reasoningContent: asString(json['reasoning_content']) ?? asString(json['reasoning']),
        reasoningSignature: asString(json['reasoning_signature']),
        toolCalls: asList(json['tool_calls']).map(asMap).map(ToolCall.fromJson).toList(),
        toolCallId: asString(json['tool_call_id']),
        toolName: asString(json['tool_name']),
        isError: asBool(json['is_error']),
        metadata: asMap(json['metadata']),
      );

  @override
  String toString() => 'ChatMessage(${role.name}, '
      'text: ${text.length} chars, '
      'reasoning: ${reasoningContent?.length ?? 0} chars, '
      'toolCalls: ${toolCalls.length})';
}
