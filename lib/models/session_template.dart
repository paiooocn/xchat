import '../core/ids.dart';
import '../core/json_utils.dart';
import 'expertise.dart';
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
    this.quickEnabled = false,
    this.promptMode = SystemPromptMode.text,
    this.manualPrompt = '',
    List<String>? expertiseIds,
  })  : params = params ?? SessionParams(),
        tools = tools ?? <String>[],
        tags = tags ?? <String>[],
        expertiseIds = expertiseIds ?? <String>[];

  String id;
  String name;
  String description;
  String provider;
  String model;
  ThinkingReplyMode thinkingReplyMode;
  int toolCallsLimit;

  /// 生效的系统提示词正文（保存时已按 [promptMode] 解析好）。
  String systemPrompt;
  SessionParams params;
  List<String> tools;
  List<String> tags;

  /// 系统提示词的配置方式。[current mode][SystemPromptMode] 决定
  /// [systemPrompt] 是「手动文本」还是「专长组合结果」。
  SystemPromptMode promptMode;

  /// 「文本输入」一侧的内容，切到 AI 专长后仍保留，便于切回时还原。
  String manualPrompt;

  /// 已选专长 id（仅 [SystemPromptMode.expertise] 生效；顺序以专长库为准）。
  List<String> expertiseIds;

  /// Whether the template is exposed as a quick session on the home page.
  bool quickEnabled;

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
        quickEnabled: quickEnabled,
        promptMode: promptMode,
        manualPrompt: manualPrompt,
        expertiseIds: List<String>.of(expertiseIds),
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
        if (quickEnabled) 'quick_enabled': true,
        'prompt_mode': promptMode.wire,
        if (manualPrompt.isNotEmpty) 'manual_prompt': manualPrompt,
        if (expertiseIds.isNotEmpty) 'expertise_ids': expertiseIds,
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
      quickEnabled: json['quick_enabled'] == true,
      promptMode: SystemPromptMode.parse(asString(json['prompt_mode'])),
      manualPrompt: asString(json['manual_prompt']) ?? '',
      expertiseIds: asStringList(json['expertise_ids']),
    );
  }
}
