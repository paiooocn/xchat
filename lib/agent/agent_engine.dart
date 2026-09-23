import 'dart:convert';
import 'dart:io';

import 'package:llm_api/llm_api.dart' as llm;

import '../data/session_repository.dart';
import '../llm/llm_factory.dart';
import '../llm/outbound_adapter.dart';
import '../models/agent_mode.dart';
import '../models/app_config.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_message.dart';
import '../models/session_params.dart';
import '../models/shell_policy.dart';
import '../models/token_usage.dart';
import 'agent_events.dart';
import 'tools/builtin_tools.dart';

/// Drives a ReAct turn for one session: model → tools → model … with a
/// tool-call budget and an automatic continue-decision when the budget is hit.
class AgentEngine {
  AgentEngine({
    required this.session,
    required this.providerConfig,
    required this.config,
    required this.repository,
    this.onApproval,
  });

  final Session session;
  final ProviderConfig providerConfig;
  final AppConfig config;
  final SessionRepository repository;

  /// Optional user-consent hook. Returns `true` to run the tool, `false` to
  /// deny it. Invoked for tools whose approval level demands it under the
  /// session's current [Session.mode]. [note] carries an optional human-readable
  /// reason (e.g. which shell list decided the level) for the UI to display.
  final Future<bool> Function(String tool, String arguments, String? note)? onApproval;

  llm.CancelToken? _cancel;
  bool get isRunning => _cancel != null;

  /// Hard safety cap on model round-trips within one turn.
  static const _hardRoundCap = 200;

  void stop() {
    _cancel?.cancel('user stopped');
  }

  Future<void> _persist() async {
    session.updatedAt = DateTime.now();
    await repository.write(session);
  }

  /// Runs a turn. When [userText] is provided it is appended as a new user
  /// message first (a plain send); otherwise the existing history is used
  /// (a resend after editing the last user message).
  Stream<AgentEvent> run({String? userText}) async* {
    if (isRunning) {
      yield const AgentError('a turn is already running');
      return;
    }
    final token = llm.CancelToken();
    _cancel = token;
    final provider = createProvider(providerConfig);
    // Make sure the session/project sandbox exists before tools run.
    try {
      await Directory(session.sandbox).create(recursive: true);
    } catch (_) {
      // Ignore; tools will report their own errors.
    }
    // `toolCallsLimit == 0` means tools are disabled for the session.
    // `web_search` is further gated by the per-session manual switch.
    final enabledTools = session.toolCallsLimit == 0
        ? const <String>[]
        : session.tools
            .where((t) => t != 'web_search' || session.webSearchEnabled)
            .toList();
    final registry = llm.ToolRegistry(BuiltinTools.build(
      sandbox: session.sandbox,
      enabled: enabledTools,
      searchEngines: config.searchEngines,
      proxy: config.proxy,
      shellEnabled: config.shellCommandsConfigured,
    ));

    try {
      if (userText != null && userText.trim().isNotEmpty) {
        session.messages.add(SessionMessage(
          role: MessageRole.user,
          id: _shortId(),
          content: userText,
        ));
        await _persist();
      }

      var budgetRound = 0;
      var round = 0;
      var stopReason = 'stop';

      while (true) {
        token.throwIfCancelled();
        round++;
        if (round > _hardRoundCap) {
          stopReason = 'round_limit';
          break;
        }
        yield AgentRoundStarted(round);

        final request = llm.ChatRequest(
          model: session.model,
          messages: buildChatMessages(session, provider: providerConfig),
          tools: registry.definitions,
          temperature: session.params.temperature,
          topP: session.params.topP,
          maxTokens: session.params.maxTokens,
          reasoning: _reasoningConfig(),
        );

        final aggregator = llm.ChatStreamAggregator(model: session.model);
        await for (final event in provider.stream(request, cancel: token)) {
          aggregator.feed(event);
          final mapped = _mapStreamEvent(event);
          if (mapped != null) yield mapped;
        }
        final response = aggregator.build();

        final assistant = SessionMessage(
          role: MessageRole.assistant,
          id: _shortId(),
          content: response.message.content,
          reasoning: response.message.reasoningContent,
          reasoningMode: _reasoningModeLabel(),
          toolCalls: response.message.toolCalls
              .map((call) => ToolCallData(
                    id: call.id,
                    name: call.name,
                    arguments: call.arguments,
                  ))
              .toList(),
          usage: _mapUsage(response.usage),
        );
        session.messages.add(assistant);
        if (assistant.usage.isNotEmpty) {
          session.cumulativeUsage = session.cumulativeUsage.merge(assistant.usage);
          session.contextTokens = assistant.usage.contextTotal;
        }
        await _persist();
        yield AgentAssistantCompleted(assistant);
        yield AgentUsageUpdated(
          cumulative: session.cumulativeUsage,
          context: session.contextTokens,
        );

        final calls = assistant.toolCalls;
        if (calls.isEmpty || registry.isEmpty) {
          stopReason = response.finishReason.name;
          break;
        }

        for (final call in calls) {
          token.throwIfCancelled();
          // shell 的基础等级锁定为 3：未命中任一名单的命令默认总是审批。
          final baseLevel = call.name == 'shell' ? 3 : config.toolApprovalLevel(call.name);
          var level = baseLevel;
          var forcedDeny = false;
          String? approvalNote;
          if (call.name == 'shell') {
            final classification = classifyShellCommand(
              _shellCommand(call.arguments),
              level1: config.shellLevel1Commands,
              level2: config.shellLevel2Commands,
              denied: config.shellDeniedCommands,
              baseLevel: baseLevel,
            );
            forcedDeny = classification.denied;
            level = classification.level;
            approvalNote = switch (classification.match) {
              ShellMatch.deny => null,
              ShellMatch.level2 => '该命令命中 Shell「2级」名单（高影响命令）。',
              ShellMatch.level1 => '该命令命中 Shell「1级」名单。',
              ShellMatch.base =>
                '该命令未命中任何 Shell 名单，按工具默认审批等级（shell=$baseLevel）处理。\n'
                    '如需更精细控制，可在「工具管理」将该命令追加到 1级/2级名单。',
            };
          }
          var denied = forcedDeny;
          if (!forcedDeny && requiresApproval(level, session.mode) && onApproval != null) {
            final approved = await _awaitApproval(call.name, call.arguments, approvalNote, token);
            denied = !approved;
          }
          final result = denied
              ? llm.ToolResult.error(
                  call.id,
                  forcedDeny
                      ? 'Command refused: it matches the F级 deny list and is never executed.'
                      : 'User denied execution of "${call.name}" (approval level $level, mode ${session.mode.label}).',
                  name: call.name,
                )
              : await registry.invoke(
                  llm.ToolCall(id: call.id, name: call.name, arguments: call.arguments),
                  cancel: token,
                );
          session.messages.add(SessionMessage(
            role: MessageRole.tool,
            id: _shortId(),
            toolCallId: call.id,
            toolName: call.name,
            content: result.content,
            isError: result.isError,
          ));
          session.toolCalls += 1;
          yield AgentToolResult(
            callId: call.id,
            name: call.name,
            content: result.content,
            isError: result.isError,
          );
        }
        budgetRound += calls.length;
        await _persist();

        final limit = session.toolCallsLimit;
        if (limit > 0 && budgetRound >= limit) {
          final mode = config.continueMode;
          if (mode == ContinueMode.stop) {
            stopReason = 'tool_limit';
            break;
          }
          yield AgentContinueDecision(cumulative: session.toolCalls, limit: limit);
          final prompt = config.continuePrompt
              .replaceAll('{n}', '${session.toolCalls}')
              .replaceAll('{limit}', '$limit');
          session.messages.add(SessionMessage(
            role: MessageRole.user,
            id: _shortId(),
            content: prompt,
          ));
          await _persist();
          budgetRound = 0;
        }
      }

      yield AgentFinished(reason: stopReason, rounds: round);
    } on llm.RequestCancelledException {
      yield const AgentStopped();
    } catch (error) {
      yield AgentError('$error');
    } finally {
      provider.close();
      _cancel = null;
    }
  }

  /// Waits for the user's tool approval but aborts immediately when the turn
  /// is stopped, so a pending dialog can't pin the agent.
  Future<bool> _awaitApproval(
    String tool,
    String arguments,
    String? note,
    llm.CancelToken token,
  ) {
    final approval = onApproval!.call(tool, arguments, note);
    return Future.any<bool>([
      approval,
      token.whenCancelled.then<bool>(
        (_) => throw llm.RequestCancelledException(token.reason?.toString()),
      ),
    ]);
  }

  llm.ReasoningConfig? _reasoningConfig() {
    final echo = resolveEchoMode(session, providerConfig) == ThinkingReplyMode.reasoningContent;
    final enabled = switch (session.params.thinking) {
      ThinkingSwitch.on => true,
      ThinkingSwitch.off => false,
      ThinkingSwitch.auto => null,
    };
    return llm.ReasoningConfig(
      enabled: enabled,
      effort: llm.ReasoningEffort.parse(session.params.reasoningEffort),
      effortName: session.params.reasoningEffort,
      budgetTokens: session.params.reasoningBudget,
      includeInHistory: session.params.thinkingEnabled && echo,
    );
  }

  String _reasoningModeLabel() => switch (providerConfig.reasoningSource) {
        'inline' => 'think_tag',
        _ => 'reasoning_content',
      };

  TokenUsage _mapUsage(llm.TokenUsage usage) => TokenUsage(
        input: usage.inputTokens,
        output: usage.outputTokens,
        cache: usage.cachedInputTokens,
      );

  AgentEvent? _mapStreamEvent(llm.ChatEvent event) {
    switch (event) {
      case llm.ReasoningDelta(:final text):
        return AgentReasoningDelta(text);
      case llm.ContentDelta(:final text):
        return AgentContentDelta(text);
      case llm.ToolCallStarted(:final index, :final id, :final name):
        final callId = id ?? '';
        final callName = name ?? '';
        // Drop empty placeholder fragments some gateways stream (id and name
        // both blank) so they can't surface as blank tool-call boxes.
        if (callId.isEmpty && callName.isEmpty) return null;
        return AgentToolCallStarted(index: index, id: callId, name: callName);
      case llm.ToolCallArgumentsDelta(:final index, :final fragment):
        return AgentToolCallArgumentsDelta(index: index, fragment: fragment);
      default:
        return null;
    }
  }

  /// Extracts the `command` argument from a shell tool call's raw JSON.
  String _shellCommand(String arguments) {
    try {
      final decoded = jsonDecode(arguments);
      if (decoded is Map && decoded['command'] is String) {
        return decoded['command'] as String;
      }
    } catch (_) {
      // Fall through to empty → falls back to the tool's base level.
    }
    return '';
  }

  String _shortId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      (DateTime.now().microsecond % 1000).toString();
}
