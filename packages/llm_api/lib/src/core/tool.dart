/// Tool (function calling) definitions, invocations and results.
library;

import 'dart:convert';

import 'errors.dart';
import 'json_utils.dart';

/// A function the model may call, described with a JSON Schema.
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    this.parameters = const <String, Object?>{'type': 'object', 'properties': <String, Object?>{}},
    this.strict = false,
  });

  final String name;
  final String description;

  /// JSON Schema object describing the arguments.
  final Map<String, Object?> parameters;

  /// OpenAI structured-outputs strict mode (schema must be closed).
  final bool strict;

  /// OpenAI-compatible wire format (`{"type":"function","function":{…}}`).
  Map<String, Object?> toJson() => {
        'type': 'function',
        'function': pruneNulls({
          'name': name,
          'description': description,
          'parameters': parameters,
          if (strict) 'strict': true,
        }),
      };

  /// Anthropic wire format.
  Map<String, Object?> toAnthropicJson() => {
        'name': name,
        'description': description,
        'input_schema': parameters,
      };

  /// Gemini `functionDeclarations` entry.
  Map<String, Object?> toGeminiJson() => {
        'name': name,
        'description': description,
        'parameters': parameters,
      };

  /// Accepts both `{"type":"function","function":{…}}` and a bare function map.
  factory ToolDefinition.fromJson(Map<String, Object?> json) {
    final function = json['function'] is Map ? asMap(json['function']) : json;
    return ToolDefinition(
      name: asString(function['name']) ?? '',
      description: asString(function['description']) ?? '',
      parameters: asMap(function['parameters'] ?? function['input_schema'] ?? function['inputSchema']),
      strict: asBool(function['strict']),
    );
  }
}

/// A concrete "please call this" instruction produced by the model.
///
/// [arguments] stays the *raw JSON string* the provider emitted: streamed
/// arguments arrive as text fragments and re-encoding a parsed map would lose
/// fidelity (key order, big numbers) and break providers that hash the payload.
class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    this.arguments = '',
    this.extra = const <String, Object?>{},
  });

  final String id;
  final String name;
  final String arguments;
  final Map<String, Object?> extra;

  bool get isEmpty => name.isEmpty && arguments.isEmpty;

  /// Parses [arguments]; returns `{}` for an empty payload.
  ///
  /// Throws [ToolCallFormatException] when the model produced invalid JSON —
  /// models do that, so prefer [tryArguments] inside a tool loop.
  Map<String, Object?> argumentsAsMap() {
    final text = arguments.trim();
    if (text.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return asMap(decoded);
      throw ToolCallFormatException(
        'Tool call "$name" arguments must be a JSON object, got ${decoded.runtimeType}',
        toolName: name,
        toolCallId: id,
        rawArguments: arguments,
      );
    } on FormatException catch (error) {
      throw ToolCallFormatException(
        'Tool call "$name" produced invalid JSON: ${error.message}',
        toolName: name,
        toolCallId: id,
        rawArguments: arguments,
        cause: error,
      );
    }
  }

  /// Like [argumentsAsMap] but returns `null` instead of throwing.
  Map<String, Object?>? tryArguments() {
    try {
      return argumentsAsMap();
    } on ToolCallFormatException {
      return null;
    }
  }

  ToolCall copyWith({String? id, String? name, String? arguments}) => ToolCall(
        id: id ?? this.id,
        name: name ?? this.name,
        arguments: arguments ?? this.arguments,
        extra: extra,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };

  factory ToolCall.fromJson(Map<String, Object?> json) {
    final function = asMap(json['function']);
    return ToolCall(
      id: asString(json['id']) ?? asString(json['tool_call_id']) ?? '',
      name: asString(function['name']) ?? asString(json['name']) ?? '',
      arguments: _stringifyArguments(function['arguments'] ?? json['arguments'] ?? json['input']),
    );
  }

  static String _stringifyArguments(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    return jsonEncode(value);
  }

  @override
  String toString() => 'ToolCall($name, args: ${arguments.isEmpty ? '{}' : arguments})';
}

/// Thrown when a tool call's arguments are not valid JSON.
class ToolCallFormatException extends LlmApiException {
  ToolCallFormatException(
    String message, {
    this.toolName,
    this.toolCallId,
    this.rawArguments,
    Object? cause,
  }) : super(message, cause: cause, retryable: false);

  final String? toolName;
  final String? toolCallId;
  final String? rawArguments;
}

/// The outcome of running a [ToolCall], to be fed back to the model.
class ToolResult {
  const ToolResult({
    required this.toolCallId,
    required this.content,
    this.name,
    this.isError = false,
  });

  /// Convenience constructor for successful results.
  factory ToolResult.text(
    String toolCallId,
    Object? content, {
    String? name,
  }) =>
      ToolResult(toolCallId: toolCallId, content: encode(content), name: name);

  /// Convenience constructor for failures; the model gets to see the message
  /// and can often recover, so we never throw out of the tool loop.
  factory ToolResult.error(
    String toolCallId,
    Object? error, {
    String? name,
  }) =>
      ToolResult(toolCallId: toolCallId, content: encode(error), name: name, isError: true);

  final String toolCallId;
  final String content;
  final String? name;
  final bool isError;

  /// Serialises any Dart value into the text form providers expect.
  static String encode(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    try {
      return jsonEncode(value);
    } on JsonUnsupportedObjectError {
      return value.toString();
    }
  }

  @override
  String toString() => 'ToolResult($toolCallId, error: $isError, ${content.length} chars)';
}

/// How the model is allowed to use tools.
sealed class ToolChoice {
  const ToolChoice();

  const factory ToolChoice.auto() = AutoToolChoice;
  const factory ToolChoice.none() = NoToolChoice;
  const factory ToolChoice.required() = RequiredToolChoice;
  const factory ToolChoice.function(String name) = NamedToolChoice;

  Map<String, Object?> toOpenAiJson();

  Map<String, Object?> toAnthropicJson();

  Map<String, Object?> toGeminiJson();
}

final class AutoToolChoice extends ToolChoice {
  const AutoToolChoice();

  @override
  Map<String, Object?> toOpenAiJson() => const {'type': 'auto'};

  @override
  Map<String, Object?> toAnthropicJson() => const {'type': 'auto'};

  @override
  Map<String, Object?> toGeminiJson() =>
      const {'functionCallingConfig': {'mode': 'AUTO'}};
}

final class NoToolChoice extends ToolChoice {
  const NoToolChoice();

  @override
  Map<String, Object?> toOpenAiJson() => const {'type': 'none'};

  @override
  Map<String, Object?> toAnthropicJson() => const {'type': 'none'};

  @override
  Map<String, Object?> toGeminiJson() =>
      const {'functionCallingConfig': {'mode': 'NONE'}};
}

final class RequiredToolChoice extends ToolChoice {
  const RequiredToolChoice();

  @override
  Map<String, Object?> toOpenAiJson() => const {'type': 'required'};

  @override
  Map<String, Object?> toAnthropicJson() => const {'type': 'any'};

  @override
  Map<String, Object?> toGeminiJson() => const {'functionCallingConfig': {'mode': 'ANY'}};
}

final class NamedToolChoice extends ToolChoice {
  const NamedToolChoice(this.name);

  final String name;

  @override
  Map<String, Object?> toOpenAiJson() => {
        'type': 'function',
        'function': {'name': name},
      };

  @override
  Map<String, Object?> toAnthropicJson() => {'type': 'tool', 'name': name};

  @override
  Map<String, Object?> toGeminiJson() => {
        'functionCallingConfig': {
          'mode': 'ANY',
          'allowedFunctionNames': [name],
        },
      };
}
