import '../core/ids.dart';
import '../core/json_utils.dart';
import 'agent_mode.dart';
import 'session_message.dart';
import 'session_params.dart';
import 'token_usage.dart';

/// The in-memory representation of a session (mirrors the XML document).
///
/// XML mapping:
/// * `<meta>` holds id / created_at / updated_at / tool_calls /
///   tool_calls_limit / params.
/// * other chat-level elements map to the remaining fields.
/// * the `messages` list maps to the ordered `system`/`user`/`assistant`/`tool`
///   elements; the `system` element also carries the cumulative usage attrs.
class Session {
  Session({
    required this.id,
    required this.sandbox,
    required this.createdAt,
    required this.updatedAt,
    this.toolCalls = 0,
    this.toolCallsLimit = 0,
    this.title = '',
    this.projectId = '',
    this.archivedAt,
    List<String>? tags,
    this.provider = '',
    this.model = '',
    this.mode = AgentMode.auto,
    this.thinkingReplyMode = ThinkingReplyMode.auto,
    this.webSearchEnabled = true,
    List<String>? tools,
    SessionParams? params,
    List<SessionMessage>? messages,
    this.cumulativeUsage = TokenUsage.empty,
    this.contextTokens,
  })  : tags = tags ?? <String>[],
        tools = tools ?? <String>[],
        params = params ?? SessionParams(),
        messages = messages ?? <SessionMessage>[];

  String id;
  String sandbox;
  DateTime createdAt;
  DateTime updatedAt;

  /// Cumulative number of tool calls made in this session.
  int toolCalls;

  /// Tool-call budget; `0` means tools are disabled for this session.
  int toolCallsLimit;

  String title;

  /// Owning project id (empty = standalone session).
  String projectId;

  /// When set, the session is archived and hidden from the active list.
  DateTime? archivedAt;
  List<String> tags;
  String provider;
  String model;

  /// Execution mode controlling tool-call approval.
  AgentMode mode;
  ThinkingReplyMode thinkingReplyMode;

  /// Whether `web_search` is passed in the request (manual per-send switch).
  bool webSearchEnabled;
  List<String> tools;
  SessionParams params;
  List<SessionMessage> messages;

  /// Cumulative token usage across every assistant turn (stored on `<system>`).
  TokenUsage cumulativeUsage;

  /// `input + output` of the most recent assistant turn.
  int? contextTokens;

  bool get hasBudget => toolCallsLimit > 0;

  bool get isArchived => archivedAt != null;

  /// The system message; created lazily so cumulative usage always has a home.
  SessionMessage ensureSystem() {
    if (messages.isEmpty || messages.first.role != MessageRole.system) {
      messages.insert(0, SessionMessage(role: MessageRole.system, content: ''));
    }
    return messages.first;
  }

  String get systemPrompt => ensureSystem().content ?? '';

  set systemPrompt(String value) => ensureSystem().content = value;

  List<SessionMessage> get conversation => messages
      .where((m) => m.role != MessageRole.system)
      .toList(growable: false);

  /// Regenerates the cumulative usage from all assistant turns, and refreshes
  /// `contextTokens` from the last assistant turn.
  void recomputeUsage() {
    var total = TokenUsage.empty;
    TokenUsage last = TokenUsage.empty;
    var sawLast = false;
    for (final message in messages) {
      if (message.role == MessageRole.assistant && message.usage.isNotEmpty) {
        total = total.merge(message.usage);
        last = message.usage;
        sawLast = true;
      }
    }
    cumulativeUsage = total;
    contextTokens = sawLast ? last.contextTotal : null;
  }

  /// Counts tool calls from the message list (used after edits).
  void recomputeToolCalls() {
    var count = 0;
    for (final message in messages) {
      if (message.role == MessageRole.assistant) count += message.toolCalls.length;
    }
    toolCalls = count;
  }

  /// Clone keeping only the configuration (system prompt + settings), i.e. the
  /// state right before the first turn. Used for "clone before first turn".
  Session cloneEmpty() => _cloneWith(_messagesToSystem());

  /// Clone copying `system` + the first user element only.
  Session cloneToFirstUser() => _cloneWith(_messagesToFirstUser());

  /// Clone copying `system` + the first full exchange: the first user turn and
  /// every following message up to (but excluding) the next user turn.
  Session cloneWithFirstTurn() => _cloneWith(_messagesThroughFirstTurn());

  /// Clone copying the entire conversation verbatim.
  Session cloneFull() => _cloneWith(_copyAllMessages());

  /// Builds a new session (fresh id) copying this session's configuration and
  /// the given messages, recomputing the derived counters.
  Session _cloneWith(List<SessionMessage> messages) {
    final clone = Session(
      id: newId(),
      sandbox: sandbox,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      toolCallsLimit: toolCallsLimit,
      title: title,
      projectId: projectId,
      tags: List<String>.of(tags),
      provider: provider,
      model: model,
      mode: mode,
      thinkingReplyMode: thinkingReplyMode,
      webSearchEnabled: webSearchEnabled,
      tools: List<String>.of(tools),
      params: params.copyWith(),
      // Copy into a growable list: the clone must stay mutable (e.g.
      // `ensureSystem` inserts the system message on save) even when the
      // caller passes a fixed/const list.
      messages: List<SessionMessage>.of(messages),
    );
    clone.recomputeToolCalls();
    clone.recomputeUsage();
    return clone;
  }

  /// The leading `system` message only (deep copy), so "clone before first
  /// turn" keeps the system prompt. Falls back to an empty system message when
  /// the source has none.
  List<SessionMessage> _messagesToSystem() {
    final first = messages.isEmpty ? null : messages.first;
    return [
      (first != null && first.role == MessageRole.system)
          ? _copyMessage(first)
          : SessionMessage(role: MessageRole.system, content: ''),
    ];
  }

  List<SessionMessage> _messagesToFirstUser() {
    final out = <SessionMessage>[];
    for (final message in messages) {
      if (message.role == MessageRole.system) {
        out.add(SessionMessage(
          role: MessageRole.system,
          content: message.content,
        ));
        continue;
      }
      if (message.role == MessageRole.user) {
        out.add(SessionMessage(
          role: MessageRole.user,
          id: newShortId(),
          content: message.content,
        ));
        break;
      }
    }
    if (out.isEmpty || out.first.role != MessageRole.system) {
      out.insert(0, SessionMessage(role: MessageRole.system, content: ''));
    }
    return out;
  }

  /// `system` messages plus the first user turn and every following message up
  /// to (but excluding) the next user turn.
  List<SessionMessage> _messagesThroughFirstTurn() {
    final out = <SessionMessage>[];
    var seenUser = false;
    for (final message in messages) {
      if (message.role == MessageRole.system) {
        out.add(_copyMessage(message));
        continue;
      }
      if (message.role == MessageRole.user) {
        if (seenUser) break; // second user turn starts the next exchange
        seenUser = true;
        out.add(_copyMessage(message));
        continue;
      }
      if (seenUser) out.add(_copyMessage(message));
    }
    if (out.isEmpty || out.first.role != MessageRole.system) {
      out.insert(0, SessionMessage(role: MessageRole.system, content: ''));
    }
    return out;
  }

  /// Deep copy of every message (fresh ids, independent tool-call lists).
  List<SessionMessage> _copyAllMessages() =>
      [for (final message in messages) _copyMessage(message)];

  static SessionMessage _copyMessage(SessionMessage message) => SessionMessage(
        role: message.role,
        id: message.id ?? newShortId(),
        content: message.content,
        reasoning: message.reasoning,
        reasoningMode: message.reasoningMode,
        toolCalls: [
          for (final call in message.toolCalls)
            ToolCallData(id: call.id, name: call.name, arguments: call.arguments),
        ],
        toolCallId: message.toolCallId,
        toolName: message.toolName,
        isError: message.isError,
        usage: message.usage,
      );

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'id': id,
        'sandbox': sandbox,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'tool_calls': toolCalls,
        'tool_calls_limit': toolCallsLimit,
        'title': title,
        if (projectId.isNotEmpty) 'project': projectId,
        if (archivedAt != null) 'archived_at': archivedAt!.toUtc().toIso8601String(),
        if (tags.isNotEmpty) 'tags': tags,
        'provider': provider,
        'model': model,
        'mode': mode.wire,
        'thinking_reply_mode': thinkingReplyMode.wire,
        'web_search_enabled': webSearchEnabled,
        if (tools.isNotEmpty) 'tools': tools,
        'params': params.toJson(),
        'messages': messages.map((m) => m.toJson()).toList(),
      });

  factory Session.fromJson(Object? value, {required String sandbox}) {
    final json = asMap(value);
    return Session(
      id: asString(json['id']) ?? newId(),
      sandbox: asString(json['sandbox']) ?? sandbox,
      createdAt: DateTime.tryParse(asString(json['created_at']) ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(asString(json['updated_at']) ?? '') ?? DateTime.now(),
      toolCalls: asInt(json['tool_calls']) ?? 0,
      toolCallsLimit: asInt(json['tool_calls_limit']) ?? 0,
      title: asString(json['title']) ?? '',
      projectId: asString(json['project']) ?? '',
      archivedAt: DateTime.tryParse(asString(json['archived_at']) ?? ''),
      tags: asStringList(json['tags']),
      provider: asString(json['provider']) ?? '',
      model: asString(json['model']) ?? '',
      mode: AgentMode.parse(asString(json['mode'])),
      thinkingReplyMode: ThinkingReplyMode.parse(asString(json['thinking_reply_mode'])),
      webSearchEnabled: asBool(json['web_search_enabled'], fallback: true),
      tools: asStringList(json['tools']),
      params: SessionParams.fromJson(json['params']),
      messages: asList(json['messages']).map(SessionMessage.fromJson).toList(),
    )..recomputeUsage();
  }
}
