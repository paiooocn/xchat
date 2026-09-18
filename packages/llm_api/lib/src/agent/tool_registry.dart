/// Tool abstraction and dispatch.
library;

import 'dart:async';

import '../core/errors.dart';
import '../core/json_utils.dart';
import '../core/tool.dart';
import '../transport/cancel_token.dart';

/// A callable capability exposed to the model.
abstract class LlmTool {
  const LlmTool();

  /// Function name the model calls. Keep it `snake_case` or `camelCase`, but
  /// be consistent: some providers reject anything else.
  String get name;

  /// Description shown to the model — this *is* the prompt for the tool.
  String get description;

  /// JSON Schema for the arguments.
  Map<String, Object?> get parameters;

  /// Wire representation.
  ToolDefinition get definition => ToolDefinition(
        name: name,
        description: description,
        parameters: parameters,
      );

  /// Runs the tool. Whatever is returned is JSON-encoded and fed back to the
  /// model; throwing turns into an error result the model can react to.
  Future<Object?> call(Map<String, Object?> arguments);
}

/// A tool backed by a plain Dart function.
///
/// ```dart
/// FunctionTool(
///   name: 'get_weather',
///   description: 'Current weather for a city',
///   parameters: objectSchema(
///     properties: {'city': stringSchema(description: 'City name')},
///     required: ['city'],
///   ),
///   handler: (args) async => await weatherApi.fetch('${args['city']}'),
/// )
/// ```
class FunctionTool extends LlmTool {
  FunctionTool({
    required this.name,
    required this.description,
    required this.handler,
    this.parameters = const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{},
      'additionalProperties': false,
    },
  });

  @override
  final String name;

  @override
  final String description;

  @override
  final Map<String, Object?> parameters;

  /// Receives the parsed arguments.
  final FutureOr<Object?> Function(Map<String, Object?> arguments) handler;

  @override
  Future<Object?> call(Map<String, Object?> arguments) async => handler(arguments);
}

/// Name → tool lookup used by `ChatSession`.
class ToolRegistry {
  ToolRegistry([Iterable<LlmTool> tools = const <LlmTool>[]]) {
    registerAll(tools);
  }

  final Map<String, LlmTool> _tools = <String, LlmTool>{};

  /// Maximum characters of a tool result handed back to the model; longer
  /// results are truncated (with a marker) so one chatty tool cannot blow up
  /// the context window.
  int maxResultCharacters = 24000;

  /// Per-call timeout.
  Duration timeout = const Duration(seconds: 60);

  Iterable<LlmTool> get tools => _tools.values;

  bool get isEmpty => _tools.isEmpty;

  bool get isNotEmpty => _tools.isNotEmpty;

  int get length => _tools.length;

  void register(LlmTool tool) {
    if (tool.name.isEmpty) {
      throw ArgumentError.value(tool.name, 'tool.name', 'must not be empty');
    }
    _tools[tool.name] = tool;
  }

  void registerAll(Iterable<LlmTool> tools) => tools.forEach(register);

  bool remove(String name) => _tools.remove(name) != null;

  bool contains(String name) => _tools.containsKey(name);

  LlmTool? operator [](String name) => _tools[name];

  /// Definitions for the request payload.
  List<ToolDefinition> get definitions =>
      <ToolDefinition>[for (final tool in _tools.values) tool.definition];

  /// Executes [call].
  ///
  /// Never throws: every failure becomes a [ToolResult] with `isError: true`,
  /// because models recover far better from a visible error message than from a
  /// broken conversation.
  Future<ToolResult> invoke(ToolCall call, {CancelToken? cancel}) async {
    final tool = _tools[call.name];
    if (tool == null) {
      return ToolResult.error(
        call.id,
        'Unknown tool "${call.name}". Available tools: ${_tools.keys.join(', ')}',
        name: call.name,
      );
    }

    final Map<String, Object?> arguments;
    try {
      arguments = call.argumentsAsMap();
    } on ToolCallFormatException catch (error) {
      return ToolResult.error(
        call.id,
        'Arguments for "${call.name}" were not valid JSON: ${error.message}. '
        'Received: ${error.rawArguments}',
        name: call.name,
      );
    }

    try {
      final value = await tool.call(arguments).timeout(timeout);
      return ToolResult.text(call.id, _truncate(ToolResult.encode(value)), name: call.name);
    } on TimeoutException {
      return ToolResult.error(
        call.id,
        'Tool "${call.name}" timed out after ${timeout.inSeconds}s',
        name: call.name,
      );
    } on RequestCancelledException {
      rethrow;
    } catch (error) {
      return ToolResult.error(call.id, 'Tool "${call.name}" failed: $error', name: call.name);
    }
  }

  String _truncate(String value) {
    if (value.length <= maxResultCharacters) return value;
    return '${value.substring(0, maxResultCharacters)}\n…[truncated '
        '${value.length - maxResultCharacters} characters]';
  }

  /// Convenience for building a registry from a map.
  factory ToolRegistry.fromMap(Map<String, LlmTool> tools) =>
      ToolRegistry(tools.values);

  /// Runs every call of a round (sequentially, order preserved).
  ///
  /// Parallel execution is possible (the model may request several calls at
  /// once) but sequential is the safe default: tools often mutate shared state.
  Future<List<ToolResult>> invokeAll(Iterable<ToolCall> calls, {CancelToken? cancel}) async {
    final results = <ToolResult>[];
    for (final call in calls) {
      cancel?.throwIfCancelled();
      results.add(await invoke(call, cancel: cancel));
    }
    return results;
  }

  /// Reads arguments from a raw event payload (helper for custom providers).
  static Map<String, Object?> parseArguments(Object? raw) => asMap(raw);
}
