import 'package:flutter/foundation.dart';

import '../agent/agent_engine.dart';
import '../agent/agent_events.dart';
import '../data/session_repository.dart';
import '../models/app_config.dart';
import '../models/agent_mode.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_message.dart';
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
  /// allow, `false` to deny.
  Future<bool> Function(String tool, String arguments)? approvalHandler;

  Session? _session;
  AgentEngine? _engine;
  bool _running = false;

  final StringBuffer _reasoning = StringBuffer();
  final StringBuffer _content = StringBuffer();
  final List<ToolCallData> _liveToolCalls = <ToolCallData>[];
  final List<String> _toolResults = <String>[];
  String? _error;
  String? _notice;

  Session? get session => _session;
  bool get isRunning => _running;
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

  Future<void> send(String text) async {
    final session = _session;
    if (session == null || _running || text.trim().isEmpty) return;
    _error = null;
    _notice = null;
    await _run(() => _engine!.run(userText: text));
  }

  /// Re-runs using the existing history (after editing the last user message).
  Future<void> resend() async {
    final session = _session;
    if (session == null || _running) return;
    if (SessionOps.lastUserIndex(session) < 0) {
      _error = '没有可重发的用户消息';
      notifyListeners();
      return;
    }
    _error = null;
    _notice = null;
    await repository.write(session);
    await _run(() => _engine!.run());
  }

  void stop() {
    _engine?.stop();
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

  /// Toggles whether `web_search` is included in outgoing requests.
  Future<void> setWebSearch(bool enabled) async {
    final session = _session;
    if (session == null) return;
    session.webSearchEnabled = enabled;
    await repository.write(session);
    notifyListeners();
  }

  Future<void> _run(Stream<AgentEvent> Function() build) async {
    final session = _session;
    if (session == null) return;
    _running = true;
    _clearStream();
    notifyListeners();

    final engine = AgentEngine(
      session: session,
      providerConfig: activeProvider,
      config: config,
      repository: repository,
      onApproval: approvalHandler,
    );
    _engine = engine;

    try {
      await for (final event in build()) {
        _handle(event);
        notifyListeners();
      }
    } finally {
      _running = false;
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
      case AgentToolCallStarted(:final id, :final name):
        _liveToolCalls.add(ToolCallData(id: id, name: name, arguments: ''));
      case AgentToolResult(:final name, :final content, :final isError):
        _toolResults.add('${isError ? '✗' : '✓'} $name: ${_preview(content)}');
      case AgentAssistantCompleted():
        _reasoning.clear();
        _content.clear();
        _liveToolCalls.clear();
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
    _toolResults.clear();
  }

  TokenUsage get cumulativeUsage =>
      _session?.cumulativeUsage ?? TokenUsage.empty;

  int? get contextTokens => _session?.contextTokens;
}
