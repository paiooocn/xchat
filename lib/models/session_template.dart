import '../core/ids.dart';
import '../core/json_utils.dart';
import 'session_message.dart';
import 'session_params.dart';

/// A reusable preset for creating sessions.
class SessionTemplate {
  SessionTemplate({
    required this.id,
    this.name = '',
    this.description = '',
    this.provider = '',
    this.model = '',
    this.thinkingReplyMode = ThinkingReplyMode.auto,
    this.toolCallsLimit = 0,
    this.systemPrompt = '',
    SessionParams? params,
    List<String>? tools,
    List<String>? tags,
  })  : params = params ?? SessionParams(),
        tools = tools ?? <String>[],
        tags = tags ?? <String>[];

  String id;
  String name;
  String description;
  String provider;
  String model;
  ThinkingReplyMode thinkingReplyMode;
  int toolCallsLimit;
  String systemPrompt;
  SessionParams params;
  List<String> tools;
  List<String> tags;

  SessionTemplate copyWith({String? id, String? name}) => SessionTemplate(
        id: id ?? newId(),
        name: name ?? this.name,
        description: description,
        provider: provider,
        model: model,
        thinkingReplyMode: thinkingReplyMode,
        toolCallsLimit: toolCallsLimit,
        systemPrompt: systemPrompt,
        params: params.copyWith(),
        tools: List<String>.of(tools),
        tags: List<String>.of(tags),
      );

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'id': id,
        'name': name,
        'description': description,
        'provider': provider,
        'model': model,
        'thinking_reply_mode': thinkingReplyMode.wire,
        'tool_calls_limit': toolCallsLimit,
        'system_prompt': systemPrompt,
        'params': params.toJson(),
        if (tools.isNotEmpty) 'tools': tools,
        if (tags.isNotEmpty) 'tags': tags,
      });

  factory SessionTemplate.fromJson(Object? value) {
    final json = asMap(value);
    return SessionTemplate(
      id: asString(json['id']) ?? newId(),
      name: asString(json['name']) ?? '',
      description: asString(json['description']) ?? '',
      provider: asString(json['provider']) ?? '',
      model: asString(json['model']) ?? '',
      thinkingReplyMode: ThinkingReplyMode.parse(asString(json['thinking_reply_mode'])),
      toolCallsLimit: asInt(json['tool_calls_limit']) ?? 0,
      systemPrompt: asString(json['system_prompt']) ?? '',
      params: SessionParams.fromJson(json['params']),
      tools: asStringList(json['tools']),
      tags: asStringList(json['tags']),
    );
  }
}
