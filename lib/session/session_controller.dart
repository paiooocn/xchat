import 'package:flutter/foundation.dart';

import '../agent/agent_engine.dart';
import '../agent/agent_events.dart';
import '../data/session_repository.dart';
import '../models/app_config.dart';
import '../models/agent_mode.dart';
import '../models/message_attachment.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_message.dart';
import '../models/session_params.dart';
import '../models/token_usage.dart';
import 'session_ops.dart';

/// Holds the currently-open session and its live streaming state.
class SessionController extends ChangeNotifier {
  SessionController({
    required this.repository,
    required this.config,
    required this.providerResolver,
  });

  final SessionRepository repository;
  final AppConfig config;
  final ProviderConfig Function(String providerId) providerResolver;

  /// Set by the UI to ask the user before running a tool. Returns `true` to
  /// allow, `false` to deny. The optional note explains why approval was asked.
  Future<bool> Function(String tool, String arguments, String? note)? approvalHandler;

  /// Set by the UI; invoked when the running turn is stopped so the global
  /// approval queue can drop this session's pending requests (the awaiting
  /// engine is cancelled and will never see the answer).
  VoidCallback? onStop;

  Session? _session;
  AgentEngine? _engine;
  bool _running = false;

  /// Task item the running turn belongs to (`null` = normal session, or a
  /// task-style session's turn that is somehow untagged).
  String? _runningTaskId;

  final StringBuffer _reasoning = StringBuffer();
  final StringBuffer _content = StringBuffer();
  final List<ToolCallData> _liveToolCalls = <ToolCallData>[];
  final Map<int, int> _liveSlotByIndex = <int, int>{};
  final List<String> _toolResults = <String>[];
  String? _error;
  String? _notice;

  Session? get session => _session;
  bool get isRunning => _running;

  /// The task item whose turn is currently streaming (see [_running]).
  String? get runningTaskId => _runningTaskId;
  String get streamReasoning => _reasoning.toString();
  String get streamContent => _content.toString();
  List<ToolCallData> get liveToolCalls =>
      List<ToolCallData>.unmodifiable(_liveToolCalls);
  List<String> get liveToolResults => List<String>.unmodifiable(_toolResults);
  String? get error => _error;
  String? get notice => _notice;

  ProviderConfig get activeProvider =>
      providerResolver(_session?.provider.isNotEmpty == true
          ? _session!.provider
          : config.currentProviderId);

  void open(Session session) {
    stop();
    _session = session;
    _clearStream();
    notifyListeners();
  }

  void close() {
    stop();
    _session = null;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    _notice = null;
    notifyListeners();
  }

  Future<void> send(
    String text, {
    List<MessageAttachment>? attachments,
    String? taskId,
  }) async {
    final session = _session;
    final files = attachments ?? const <MessageAttachment>[];
    if (session == null || _running) return;
    if (text.trim().isEmpty && files.isEmpty) return;
    _error = null;
    _notice = null;
    await _run(
      () => _engine!.run(userText: text, attachments: files),
      taskId: taskId,
    );
  }

  /// Re-runs using the existing history (after editing the last user message).
  Future<void> resend({String? taskId}) async {
    final session = _session;
    if (session == null || _running) return;
    if (SessionOps.lastUserIndex(session, onlyTaskId: taskId) < 0) {
      _error = '没有可重发的用户消息';
      notifyListeners();
      return;
    }
    _error = null;
    _notice = null;
    await repository.write(session);
    await _run(() => _engine!.run(), taskId: taskId);
  }

  void stop() {
    _engine?.stop();
    onStop?.call();
  }

  Future<void> save() async {
    final session = _session;
    if (session != null) await repository.write(session);
  }

  /// Switches the execution mode (persisted on the session).
  Future<void> setMode(AgentMode mode) async {
    final session = _session;
    if (session == null) return;
    session.mode = mode;
    await repository.write(session);
    notifyListeners();
  }

  /// Switches the session model (within the same provider).
  Future<void> setModel(String model) async {
    final session = _session;
    if (session == null || model.isEmpty) return;
    session.model = model;
    await repository.write(session);
    notifyListeners();
  }

  /// Switches the thinking switch (auto / on / off) of the session.
  ///
  /// Persisted on the session file (`meta/params/thinking`), so the next
  /// turn (and every later reload) uses the new setting.
  Future<void> setThinking(ThinkingSwitch value) async {
    final session = _session;
    if (session == null) return;
    session.params.thinking = value;
    await repository.write(session);
    notifyListeners();
  }

  /// Sets the reasoning effort of the session (empty = not sent).
  ///
  /// Persisted on the session file (`meta/params/reasoning_effort`).
  Future<void> setReasoningEffort(String effort) async {
    final session = _session;
    if (session == null) return;
    session.params.reasoningEffort = effort.isEmpty ? null : effort;
    await repository.write(session);
    notifyListeners();
  }

  /// Toggles whether `web_search` is included in outgoing requests.
  Future<void> setWebSearch(bool enabled) async {
    final session = _session;
    if (session == null) return;
    session.webSearchEnabled = enabled;
    await repository.write(session);
    notifyListeners();
  }

  Future<void> _run(
    Stream<AgentEvent> Function() build, {
    String? taskId,
  }) async {
    final session = _session;
    if (session == null) return;
    _running = true;
    _runningTaskId = taskId;
    _clearStream();
    notifyListeners();

    final engine = AgentEngine(
      session: session,
      providerConfig: activeProvider,
      config: config,
      repository: repository,
      onApproval: approvalHandler,
      taskId: taskId,
    );
    _engine = engine;

    try {
      await for (final event in build()) {
        _handle(event);
        notifyListeners();
      }
    } finally {
      _running = false;
      _runningTaskId = null;
      _engine = null;
      notifyListeners();
    }
  }

  void _handle(AgentEvent event) {
    switch (event) {
      case AgentRoundStarted():
        // Keep accumulated buffers only within a single assistant message;
        // a new round means the previous assistant was persisted.
        _reasoning.clear();
        _content.clear();
      case AgentReasoningDelta(:final text):
        _reasoning.write(text);
      case AgentContentDelta(:final text):
        _content.write(text);
      case AgentToolCallStarted(:final index, :final id, :final name):
        _upsertLiveToolCall(index: index, id: id, name: name);
      case AgentToolCallArgumentsDelta(:final index, :final fragment):
        _appendLiveToolArguments(index, fragment);
      case AgentToolResult(:final name, :final content, :final isError):
        _toolResults.add('${isError ? '✗' : '✓'} $name: ${_preview(content)}');
      case AgentAssistantCompleted():
        _reasoning.clear();
        _content.clear();
        _liveToolCalls.clear();
        _liveSlotByIndex.clear();
      case AgentContinueDecision(:final cumulative, :final limit):
        _notice = '已达工具调用上限（累计 $cumulative / 本轮 $limit），自动发起续判对话…';
      case AgentUsageUpdated():
        break;
      case AgentError(:final message):
        _error = message;
      case AgentFinished():
        _notice = null;
      case AgentStopped():
        _notice = '已停止';
    }
  }

  String _preview(String content) {
    final flat = content.replaceAll('\n', ' ').trim();
    return flat.length <= 120 ? flat : '${flat.substring(0, 120)}…';
  }

  void _clearStream() {
    _reasoning.clear();
    _content.clear();
    _liveToolCalls.clear();
    _liveSlotByIndex.clear();
    _toolResults.clear();
  }

  /// Upserts the live entry for a streamed tool call, keyed by the stream
  /// [index]. Some gateways re-send `id`/`name` on every fragment; repeats only
  /// backfill missing fields instead of appending duplicate entries.
  void _upsertLiveToolCall({
    required int index,
    required String id,
    required String name,
  }) {
    final slot = _liveSlotByIndex[index];
    if (slot == null) {
      _liveSlotByIndex[index] = _liveToolCalls.length;
      _liveToolCalls.add(ToolCallData(id: id, name: name, arguments: ''));
      return;
    }
    final existing = _liveToolCalls[slot];
    _liveToolCalls[slot] = ToolCallData(
      id: existing.id.isEmpty ? id : existing.id,
      name: existing.name.isEmpty ? name : existing.name,
      arguments: existing.arguments,
    );
  }

  /// Appends an arguments fragment to the call at stream [index], creating the
  /// entry lazily when no "started" event preceded it (mirrors the aggregator).
  void _appendLiveToolArguments(int index, String fragment) {
    var slot = _liveSlotByIndex[index];
    if (slot == null) {
      slot = _liveToolCalls.length;
      _liveSlotByIndex[index] = slot;
      _liveToolCalls.add(ToolCallData(id: '', name: '', arguments: ''));
    }
    final existing = _liveToolCalls[slot];
    _liveToolCalls[slot] = ToolCallData(
      id: existing.id,
      name: existing.name,
      arguments: existing.arguments + fragment,
    );
  }

  TokenUsage get cumulativeUsage =>
      _session?.cumulativeUsage ?? TokenUsage.empty;

  int? get contextTokens => _session?.contextTokens;
}
