import 'package:flutter/foundation.dart';

import '../agent/agent_engine.dart';
import '../agent/agent_events.dart';
import '../core/ids.dart';
import '../data/session_repository.dart';
import '../models/app_config.dart';
import '../models/agent_mode.dart';
import '../models/message_attachment.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_message.dart';
import '../models/session_params.dart';
import '../models/task_item.dart';
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

  // ---------------------------------------------------- 任务自动执行（需求三）
  //
  // 状态放在 controller 而不是 widget：自动执行必须跨面板存活（切会话、
  // 移动端压栈都不该断链），而 controller 由 AppState 按会话常驻。

  bool _autoRunning = false;
  bool _autoCancelled = false;
  bool _autoMarkDone = false;
  int _autoTotal = 0;
  String? _autoCurrentTaskId;
  int _autoDoneCount = 0;
  int _autoSkipped = 0;

  /// 自动执行中止原因（已翻成人话），为空表示没有硬失败。
  String? _autoFailure;

  /// 上次中断/报错的任务项：下次自动执行默认从这一项开始。
  String? _autoResumeTaskId;

  /// 自动执行开始时的累计用量，`autoUsage` = 当前累计 − 这个快照。
  TokenUsage _autoUsageStart = TokenUsage.empty;

  /// 当前（或刚结束的）这一轮是否被用户「停止」。
  bool _turnStopped = false;

  /// 测试注入点：自动执行里「跑一轮」的实现（默认走 [resend]，真联网）。
  ///
  /// 自动执行的编排（排队、跳过、勾完成、失败即停、断点续跑）需要能在
  /// 不联网的情况下验证，所以把这一小步抽成可替换的钩子。
  @visibleForTesting
  Future<void> Function(String taskId)? debugTaskTurn;

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

  // ------------------------------------------------- 任务自动执行 getter

  /// 是否正在「自动执行」整队任务。
  bool get autoRunning => _autoRunning;

  /// 自动执行当前（或刚刚跑完）的任务项 id；轮次之间的空档也有值。
  String? get autoCurrentTaskId => _autoCurrentTaskId;

  /// 本次自动执行的队列长度 / 已完成项数 / 被跳过项数。
  int get autoTotal => _autoTotal;
  int get autoDoneCount => _autoDoneCount;
  int get autoSkipped => _autoSkipped;

  /// 自动执行中止原因（为空 = 没有硬失败）。
  String? get autoFailure => _autoFailure;

  /// 上次中断/报错的任务项；下次自动执行默认从这一项开始。
  String? get autoResumeTaskId => _autoResumeTaskId;

  /// 本次自动执行消耗的 token（会话累计的增量）。
  TokenUsage get autoUsage =>
      (_session?.cumulativeUsage ?? TokenUsage.empty).diff(_autoUsageStart);
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
    // 自动执行期间点「停止」= 停掉整条链，不会偷偷继续跑下一项。
    if (_autoRunning) _autoCancelled = true;
    _engine?.stop();
    onStop?.call();
  }

  // ------------------------------------------------------- 任务自动执行

  /// 把任务内容写成该任务的第一条 `user` 消息（已有则不动）。
  ///
  /// 返回 `false` 表示这个任务没有可发送的内容（标题与内容都是空）。
  /// 面板里的「立即发送」与自动执行共用这一份，避免两处拼接不一致。
  Future<bool> seedTaskMessage(TaskItem task) async {
    final session = _session;
    if (session == null) return false;
    final hasUser = session
        .taskMessages(task.id)
        .any((m) => m.role == MessageRole.user);
    if (hasUser) return true;
    if (task.title.trim().isEmpty && task.content.trim().isEmpty) return false;
    session.messages.add(SessionMessage(
      role: MessageRole.user,
      id: newShortId(),
      content: task.promptText,
      taskId: task.id,
      // 标注与正文分开存：展示层只读 content（见 SessionMessage.premark）。
      premark: task.premark,
    ));
    session.updatedAt = DateTime.now();
    await save();
    notifyListeners();
    return true;
  }

  /// 按顺序逐个执行 [taskIds]（任务式会话的「自动执行」）。
  ///
  /// 每一项：seed 第一条 user 消息 → 跑一轮（等到流式结束）→ 可选勾选「完成」。
  /// 出错 / 被停止则停下，并把该项记进 [autoResumeTaskId]，下次从这里重跑。
  /// 同一会话串行（[_running] 挡并发），出站历史仍是整个会话。
  Future<void> runTasksAuto({
    required List<String> taskIds,
    bool markDoneWhenFinished = true,
  }) async {
    final session = _session;
    if (session == null || _running || _autoRunning) return;
    final queue = <String>[];
    for (final id in taskIds) {
      final task = session.taskById(id);
      if (task != null && !task.done) queue.add(id);
    }
    if (queue.isEmpty) return;

    _autoRunning = true;
    _autoCancelled = false;
    _autoMarkDone = markDoneWhenFinished;
    _autoTotal = queue.length;
    _autoCurrentTaskId = null;
    _autoDoneCount = 0;
    _autoSkipped = 0;
    _autoFailure = null;
    _autoUsageStart = session.cumulativeUsage;
    _error = null;
    _notice = null;
    notifyListeners();

    try {
      for (final id in queue) {
        if (_autoCancelled) {
          _autoResumeTaskId = id;
          break;
        }
        final task = session.taskById(id);
        if (task == null) continue;
        _autoCurrentTaskId = id;
        notifyListeners();

        if (!await seedTaskMessage(task)) {
          // 没有内容的任务发不出去：跳过但不打断整条链。
          _autoSkipped++;
          continue;
        }

        _turnStopped = false;
        try {
          await _runTaskTurn(id);
        } catch (error) {
          _error ??= '请求失败：$error';
        }

        if (_autoCancelled || _turnStopped) {
          _autoResumeTaskId = id;
          break;
        }
        if (_error != null) {
          _autoFailure =
              '第 ${_autoDoneCount + 1} 项「${task.displayTitle}」失败：$_error';
          _autoResumeTaskId = id;
          break;
        }

        _autoResumeTaskId = null;
        _autoDoneCount++;
        if (_autoMarkDone) {
          task.done = true;
          session.updatedAt = DateTime.now();
          await save();
        }
        notifyListeners();
      }
    } finally {
      _autoRunning = false;
      _autoCurrentTaskId = null;
      notifyListeners();
    }
  }

  /// 取消后续任务（当前这一轮也会被停下）。
  void cancelAutoRun() {
    if (!_autoRunning) return;
    _autoCancelled = true;
    stop();
    notifyListeners();
  }

  /// 自动执行里的「跑一轮」：测试可经 [debugTaskTurn] 替换。
  Future<void> _runTaskTurn(String taskId) async {
    final override = debugTaskTurn;
    if (override != null) {
      await override(taskId);
      return;
    }
    await resend(taskId: taskId);
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
    _turnStopped = false;
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
        _turnStopped = true;
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
