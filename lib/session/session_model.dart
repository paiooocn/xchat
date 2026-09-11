import '../util/uuid.dart';

enum Role { system, user, assistant, tool }

class ChatMeta {
  String? providerId;
  String? modelId;
  String thinking; // adaptive|enabled|disabled
  String reasoningEffort; // max|xhigh|high|medium|low|minimal|none
  double temperature;
  int toolOutputLimit;
  double contextCompressThreshold;
  String? confirmMode; // normal|yolo|shell | null = 全局
  bool allowSymlinks;
  String? shellBlocklistLayerA;
  String? shellBlocklistLayerB;
  String? shellBlocklistLayerBExceptions;

  ChatMeta({
    this.providerId,
    this.modelId,
    this.thinking = 'disabled',
    this.reasoningEffort = 'medium',
    this.temperature = 1.0,
    this.toolOutputLimit = 8000,
    this.contextCompressThreshold = 0.8,
    this.confirmMode,
    this.allowSymlinks = false,
    this.shellBlocklistLayerA,
    this.shellBlocklistLayerB,
    this.shellBlocklistLayerBExceptions,
  });

  /// 序列化为 XML 属性映射。
  /// 修复: 原实现 provider/model 都写 'id' 冲突,且 reasoningEffort/temperature 都用 'value' 互相覆盖。
  /// 当前未在写路径使用(写路径直接 selfClose 各子元素),保留为防御性 API。
  Map<String, String> toAttrs() {
    final m = <String, String>{};
    if (providerId != null) m['provider_id'] = providerId!;
    if (modelId != null) m['model_id'] = modelId!;
    m['thinking'] = thinking;
    m['reasoning_effort'] = reasoningEffort;
    m['temperature'] = temperature.toString();
    m['tool_output_limit'] = toolOutputLimit.toString();
    m['context_compress_threshold'] = contextCompressThreshold.toString();
    if (confirmMode != null) m['confirm_mode'] = confirmMode!;
    return m;
  }
}

class ToolDef {
  final String name;
  final bool enabled;
  ToolDef(this.name, {this.enabled = true});
}

class ToolCall {
  final String id;
  final String name;
  final String arguments; // JSON 字符串
  ToolCall({required this.id, required this.name, required this.arguments});
}

class Message {
  final Role role;
  String text;
  final String? toolCallId;
  final String? toolName;
  final List<ToolCall> toolCalls;
  // 累计 token 字段（assistant 用）
  int input = 0;
  int output = 0;
  int cache = 0;
  String? model;

  Message({
    required this.role,
    this.text = '',
    this.toolCallId,
    this.toolName,
    List<ToolCall>? toolCalls,
    this.input = 0,
    this.output = 0,
    this.cache = 0,
    this.model,
  }) : toolCalls = toolCalls ?? [];

  Map<String, String> get attrs {
    final m = <String, String>{};
    if (role == Role.assistant) {
      m['input'] = input.toString();
      m['output'] = output.toString();
      m['cache'] = cache.toString();
      if (model != null) m['model'] = model!;
    } else if (role == Role.tool) {
      if (toolCallId != null) m['tool_call_id'] = toolCallId!;
      if (toolName != null) m['name'] = toolName!;
    }
    return m;
  }
}

class ChatSession {
  String id;
  String sandbox;
  String? title;
  DateTime created;
  DateTime updated;
  int maxRounds;
  ChatMeta meta;
  String systemPrompt;
  // 累计 tokens (system 元素)
  int sysInput = 0;
  int sysOutput = 0;
  int sysCache = 0;
  int sysContext = 0;
  List<ToolDef> tools;
  List<Message> messages;
  String? archiveSummary;
  List<Message> archive;
  // C 增量
  String? projectId;       // 隶属项目,null = 未编组
  List<String> tags;        // 自由标签(小写、去重)

  ChatSession({
    required this.id,
    required this.sandbox,
    DateTime? created,
    DateTime? updated,
    this.title,
    this.maxRounds = 20,
    ChatMeta? meta,
    this.systemPrompt = '',
    List<ToolDef>? tools,
    List<Message>? messages,
    this.archiveSummary,
    List<Message>? archive,
    this.projectId,
    List<String>? tags,
  })  : created = created ?? DateTime.now().toUtc(),
        updated = updated ?? DateTime.now().toUtc(),
        meta = meta ?? ChatMeta(),
        tools = tools ?? [],
        messages = messages ?? [],
        archive = archive ?? [],
        tags = tags ?? <String>[];

  /// 上下文 = 最近一次 input + output
  int get context {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == Role.assistant && messages[i].input > 0) {
        return messages[i].input + messages[i].output;
      }
    }
    return 0;
  }

  /// 第一条 user 文本（用于列表标题）
  String firstUserText({int limit = 30}) {
    for (final m in messages) {
      if (m.role == Role.user) {
        return m.text.replaceAll('\n', ' ').trim().substring(
              0,
              m.text.length > limit ? limit : m.text.length,
            );
      }
    }
    return '(空会话)';
  }

  ChatSession clone({String? newId}) {
    final nid = newId ?? uuidV4();
    return ChatSession(
      id: nid,
      sandbox: sandbox,
      title: title,
      created: DateTime.now().toUtc(),
      updated: DateTime.now().toUtc(),
      maxRounds: maxRounds,
      meta: ChatMeta(
        providerId: meta.providerId,
        modelId: meta.modelId,
        thinking: meta.thinking,
        reasoningEffort: meta.reasoningEffort,
        temperature: meta.temperature,
        toolOutputLimit: meta.toolOutputLimit,
        contextCompressThreshold: meta.contextCompressThreshold,
        confirmMode: meta.confirmMode,
        allowSymlinks: meta.allowSymlinks,
        shellBlocklistLayerA: meta.shellBlocklistLayerA,
        shellBlocklistLayerB: meta.shellBlocklistLayerB,
        shellBlocklistLayerBExceptions: meta.shellBlocklistLayerBExceptions,
      ),
      systemPrompt: systemPrompt,
      tools: tools.map((t) => ToolDef(t.name, enabled: t.enabled)).toList(),
      messages: messages
          .map((m) => Message(
                role: m.role,
                text: m.text,
                toolCallId: m.toolCallId,
                toolName: m.toolName,
                toolCalls: m.toolCalls
                    .map((c) => ToolCall(id: c.id, name: c.name, arguments: c.arguments))
                    .toList(),
                input: m.input,
                output: m.output,
                cache: m.cache,
                model: m.model,
              ))
          .toList(),
      archiveSummary: archiveSummary,
      archive: archive
          .map((m) => Message(
                role: m.role,
                text: m.text,
                toolCallId: m.toolCallId,
                toolName: m.toolName,
              ))
          .toList(),
      projectId: projectId,
      tags: List<String>.from(tags),
    );
  }
}
