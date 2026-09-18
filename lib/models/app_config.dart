import '../core/json_utils.dart';
import 'proxy_config.dart';
import 'provider_config.dart';
import 'search_engine_config.dart';
import 'session_message.dart';
import 'session_params.dart';

/// Default auto-continue message sent when a session hits its tool budget.
const kDefaultContinuePrompt =
    '你本会话已累计调用工具 {n} 次（本轮上限 {limit}）。请判断任务是否已完成：\n'
        '若已完成，请直接输出最终答复，不要再调用工具；\n'
        '若仍需继续，请继续调用工具，我会重置本轮工具预算。';

/// What happens when a session hits its tool-call budget.
enum ContinueMode {
  /// Ask the model to decide (append a user-side message).
  model,

  /// Ask the user via a dialog.
  ask,

  /// Stop immediately.
  stop;

  static ContinueMode parse(String? value) => switch (value) {
        'ask' => ContinueMode.ask,
        'stop' => ContinueMode.stop,
        _ => ContinueMode.model,
      };

  String get wire => name;
}

/// Global application configuration (`Documents/XChat/config.json`).
class AppConfig {
  AppConfig({
    this.currentProviderId = '',
    this.currentModel = '',
    List<ProviderConfig>? providers,
    SessionParams? defaultParams,
    this.editorCommand = '',
    this.themeMode = 'system',
    this.continueMode = ContinueMode.model,
    this.defaultToolCallsLimit = 20,
    List<String>? defaultTools,
    this.continuePrompt = kDefaultContinuePrompt,
    this.maxToolCallsPerTurn = 0,
    List<SearchEngineConfig>? searchEngines,
    ProxyConfig? proxy,
    Map<String, int>? toolApprovals,
    List<String>? shellLevel1Commands,
    List<String>? shellLevel2Commands,
    List<String>? shellDeniedCommands,
    List<String>? compressPrompts,
  })  : providers = providers ?? defaultProviders(),
        defaultParams = defaultParams ?? SessionParams(),
        defaultTools = defaultTools ?? <String>['read_file'],
        searchEngines = searchEngines ?? SearchEngineConfig.defaults(),
        proxy = proxy ?? ProxyConfig(),
        toolApprovals = toolApprovals ?? defaultToolApprovals(),
        shellLevel1Commands = shellLevel1Commands ?? defaultShellLevel1Commands(),
        shellLevel2Commands = shellLevel2Commands ?? defaultShellLevel2Commands(),
        shellDeniedCommands = shellDeniedCommands ?? defaultShellDeniedCommands(),
        compressPrompts = compressPrompts ?? defaultCompressPrompts();

  String currentProviderId;
  String currentModel;
  List<ProviderConfig> providers;
  SessionParams defaultParams;

  /// External editor command template; `{file}` is replaced with the path.
  String editorCommand;

  /// system | light | dark
  String themeMode;

  ContinueMode continueMode;
  int defaultToolCallsLimit;
  List<String> defaultTools;

  /// Template for the auto-continue message (`{n}` / `{limit}` placeholders).
  String continuePrompt;

  /// Optional guard for a single turn's tool rounds; 0 = derive from budget.
  int maxToolCallsPerTurn;

  /// Search engines, in fallback order, with enable toggles.
  List<SearchEngineConfig> searchEngines;

  /// HTTP(S) proxy + bypass list for the network tools.
  ProxyConfig proxy;

  /// Per-tool approval level (0..3) used by the session approval flow.
  Map<String, int> toolApprovals;

  /// Shell command allow/deny lists (matched as command tokens / basenames).
  /// * level1 → approval level 1
  /// * level2 → approval level 2
  /// * denied → never executed (F级)
  List<String> shellLevel1Commands;
  List<String> shellLevel2Commands;
  List<String> shellDeniedCommands;

  /// Preset "compress session" prompts the user can pick from.
  List<String> compressPrompts;

  /// Enabled engines in configured order.
  List<SearchEngineConfig> get enabledSearchEngines =>
      searchEngines.where((e) => e.enabled).toList(growable: false);

  /// Whether every shell command list is non-empty. If any of the 1级/2级/F级
  /// lists is empty the shell tool is disabled entirely.
  bool get shellCommandsConfigured =>
      shellLevel1Commands.any((e) => e.trim().isNotEmpty) &&
      shellLevel2Commands.any((e) => e.trim().isNotEmpty) &&
      shellDeniedCommands.any((e) => e.trim().isNotEmpty);

  int toolApprovalLevel(String tool) => toolApprovals[tool] ?? 0;

  ProviderConfig? providerById(String id) {
    for (final provider in providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  ProviderConfig? get currentProvider =>
      currentProviderId.isEmpty ? null : providerById(currentProviderId);

  Map<String, Object?> toJson() => <String, Object?>{
        'current_provider': currentProviderId,
        'current_model': currentModel,
        'providers': providers.map((p) => p.toJson()).toList(),
        'default_params': defaultParams.toJson(),
        'editor_command': editorCommand,
        'theme_mode': themeMode,
        'continue_mode': continueMode.wire,
        'default_tool_calls_limit': defaultToolCallsLimit,
        'default_tools': defaultTools,
        'continue_prompt': continuePrompt,
        'max_tool_calls_per_turn': maxToolCallsPerTurn,
        'search_engines': searchEngines.map((e) => e.toJson()).toList(),
        'proxy': proxy.toJson(),
        'tool_approvals': toolApprovals,
        'shell_level1_commands': shellLevel1Commands,
        'shell_level2_commands': shellLevel2Commands,
        'shell_denied_commands': shellDeniedCommands,
        'compress_prompts': compressPrompts,
      };

  factory AppConfig.fromJson(Object? value) {
    final json = asMap(value);
    final providers = asList(json['providers']).map(ProviderConfig.fromJson).toList();
    final config = AppConfig(
      currentProviderId: asString(json['current_provider']) ?? '',
      currentModel: asString(json['current_model']) ?? '',
      providers: providers.isEmpty ? defaultProviders() : providers,
      defaultParams: SessionParams.fromJson(json['default_params']),
      editorCommand: asString(json['editor_command']) ?? '',
      themeMode: asString(json['theme_mode']) ?? 'system',
      continueMode: ContinueMode.parse(asString(json['continue_mode'])),
      defaultToolCallsLimit: asInt(json['default_tool_calls_limit']) ?? 20,
      defaultTools: asStringList(json['default_tools']).isEmpty
          ? <String>['read_file']
          : asStringList(json['default_tools']),
      continuePrompt: asString(json['continue_prompt']) ?? kDefaultContinuePrompt,
      maxToolCallsPerTurn: asInt(json['max_tool_calls_per_turn']) ?? 0,
      searchEngines: _decodeSearchEngines(json),
      proxy: _decodeProxy(json),
      toolApprovals: _decodeApprovals(json['tool_approvals']),
      shellLevel1Commands: json.containsKey('shell_level1_commands')
          ? asStringList(json['shell_level1_commands'])
          : defaultShellLevel1Commands(),
      shellLevel2Commands: json.containsKey('shell_level2_commands')
          ? asStringList(json['shell_level2_commands'])
          : defaultShellLevel2Commands(),
      shellDeniedCommands: json.containsKey('shell_denied_commands')
          ? asStringList(json['shell_denied_commands'])
          : defaultShellDeniedCommands(),
      compressPrompts: json.containsKey('compress_prompts') &&
              asStringList(json['compress_prompts']).isNotEmpty
          ? asStringList(json['compress_prompts'])
          : defaultCompressPrompts(),
    );
    if (config.currentProviderId.isEmpty && config.providers.isNotEmpty) {
      config.currentProviderId = config.providers.first.id;
    }
    return config;
  }

  static List<SearchEngineConfig> _decodeSearchEngines(Map<String, Object?> json) {
    final list = asList(json['search_engines']);
    if (list.isNotEmpty) {
      return list.map(SearchEngineConfig.fromJson).toList();
    }
    // Migrate the legacy single-engine field.
    final legacy = (asString(json['search_engine']) ?? '').trim();
    final defaults = SearchEngineConfig.defaults();
    if (legacy.isEmpty) return defaults;
    for (final engine in defaults) {
      engine.enabled = engine.kind == legacy || engine.id == legacy;
    }
    if (defaults.every((e) => !e.enabled)) return defaults;
    return defaults;
  }

  static ProxyConfig _decodeProxy(Map<String, Object?> json) {
    final raw = json['proxy'];
    if (raw is Map) return ProxyConfig.fromJson(raw);
    final legacy = (asString(json['proxy_url']) ?? '').trim();
    if (legacy.isNotEmpty) {
      return ProxyConfig(httpProxy: legacy, httpsProxy: legacy);
    }
    return ProxyConfig();
  }

  static Map<String, int> _decodeApprovals(Object? value) {
    final map = asMap(value);
    final out = defaultToolApprovals();
    map.forEach((key, v) {
      final level = asInt(v);
      if (level != null) out[key] = level.clamp(0, 3);
    });
    return out;
  }

  /// Default preset prompts for the "compress session" feature.
  static List<String> defaultCompressPrompts() => <String>[
        '请把以下对话内容压缩为一份简洁的上下文摘要，保留：任务目标、关键结论、已做出的决定、'
            '重要的代码/文件/路径信息以及待办事项。摘要将作为后续对话的唯一上下文，'
            '请确保信息完整可用，直接输出摘要内容。',
        '请将以下对话历史压缩成结构化摘要，分为：1) 用户意图与目标；2) 关键讨论与结论；'
            '3) 涉及的文件与代码要点；4) 未完成事项。直接输出摘要，不要额外解释。',
        '请对以下多轮对话做无损要点压缩：保留所有技术细节、命令、参数与决定，'
            '删除寒暄与重复内容，输出一段可直接接续对话的上下文说明。',
      ];

  /// Default approval levels: read-only / network tools run unattended; file
  /// writes ask in managed mode; shell always asks.
  static Map<String, int> defaultToolApprovals() => <String, int>{
        'read_file': 0,
        'list_dir': 0,
        'glob': 0,
        'datetime': 0,
        'http_fetch': 0,
        'web_search': 0,
        'write_file': 2,
        'edit_file': 2,
        'shell': 3,
      };

  /// Suggested default shell command lists (applied with one click).
  ///
  /// Each entry is a case-insensitive **regular expression** matched against the
  /// whole command. Use `\b…\b` to match a command word (robust against flags
  /// and paths).
  /// * F级 (deny) — never executed;
  /// * 2级 — high-impact commands needing managed-mode approval;
  /// * 1级 — side-effecting everyday commands needing auto/managed approval.
  static List<String> defaultShellLevel1Commands() => <String>[
        r'\bgit\b',
        r'\bnpm\b',
        r'\bpnpm\b',
        r'\byarn\b',
        r'\bpip3?\b',
        r'\bpoetry\b',
        r'\bcargo\b',
        r'\bmake\b',
        r'\bdocker\b',
        r'\bcurl\b',
        r'\bwget\b',
      ];

  static List<String> defaultShellLevel2Commands() => <String>[
        r'\brm\b',
        r'\brmdir\b',
        r'\bmv\b',
        r'\bcp\b',
        r'\btruncate\b',
        r'\bkill(all)?\b',
        r'\bpkill\b',
        r'\bchmod\b',
        r'\bchown\b',
        r'\bchgrp\b',
        r'\btar\b',
        r'\bun?zip\b',
      ];

  static List<String> defaultShellDeniedCommands() => <String>[
        r'\bsudo\b',
        r'\bsu\b',
        r'\bdoas\b',
        r'\bmkfs(\.\w+)?\b',
        r'\bfdisk\b',
        r'\bparted\b',
        r'\bshutdown\b',
        r'\breboot\b',
        r'\bpoweroff\b',
        r'\bhalt\b',
        r'\bdd\b',
        // rm -rf / (and any -rf/-fr flag combination targeting the root).
        r'\brm\s+-\w*r\w*f\w*\s+/',
        r'\brm\s+-\w*f\w*r\w*\s+/',
        // Classic fork bomb.
        r':\(\)\s*\{',
      ];

  /// Built-in provider presets (api keys empty until the user fills them in).
  static List<ProviderConfig> defaultProviders() => <ProviderConfig>[
        ProviderConfig(
          id: 'deepseek',
          name: 'DeepSeek',
          baseUrl: 'https://api.deepseek.com/v1',
          preset: 'deepseek',
          reasoningSource: 'auto',
          reasoningStyle: 'none',
          models: <String>['deepseek-chat', 'deepseek-reasoner'],
          contextWindow: 65536,
        ),
        ProviderConfig(
          id: 'moonshot',
          name: 'Moonshot / Kimi',
          baseUrl: 'https://api.moonshot.cn/v1',
          preset: 'moonshot',
          reasoningSource: 'auto',
          reasoningStyle: 'none',
          models: <String>['kimi-k2-0905-preview', 'kimi-k2-thinking'],
          contextWindow: 262144,
        ),
        ProviderConfig(
          id: 'zhipu',
          name: 'Zhipu GLM',
          baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
          preset: 'zhipu',
          reasoningSource: 'auto',
          reasoningStyle: 'thinking_budget',
          models: <String>['glm-4.6', 'glm-4.5'],
          contextWindow: 131072,
        ),
        ProviderConfig(
          id: 'qwen',
          name: 'Qwen (DashScope)',
          baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
          preset: 'qwen',
          reasoningSource: 'auto',
          reasoningStyle: 'enable_thinking',
          models: <String>['qwen3-max', 'qwen-plus'],
          contextWindow: 131072,
        ),
        ProviderConfig(
          id: 'minimax',
          name: 'MiniMax (think tag)',
          preset: 'minimax',
          reasoningSource: 'auto',
          reasoningStyle: 'none',
          defaultThinkingReplyMode: ThinkingReplyMode.thinkTag,
          models: <String>['MiniMax-M2', 'abab6.5s-chat'],
          contextWindow: 204800,
        ),
        ProviderConfig(
          id: 'mimo',
          name: 'MiMo',
          baseUrl: 'https://api.siliconflow.cn/v1',
          preset: 'mimo',
          reasoningSource: 'auto',
          reasoningStyle: 'none',
          models: <String>['XiaomiMiMo/MiMo-VL-7B-RL'],
          contextWindow: 32768,
        ),
        ProviderConfig(
          id: 'openai',
          name: 'OpenAI',
          baseUrl: 'https://api.openai.com/v1',
          preset: 'openai',
          reasoningSource: 'auto',
          reasoningStyle: 'reasoning_effort',
          useMaxCompletionTokens: true,
          models: <String>['gpt-4o', 'gpt-4o-mini', 'o4-mini'],
          contextWindow: 128000,
        ),
        ProviderConfig(
          id: 'openrouter',
          name: 'OpenRouter',
          baseUrl: 'https://openrouter.ai/api/v1',
          preset: 'openrouter',
          reasoningSource: 'auto',
          reasoningStyle: 'reasoning_max_tokens',
          models: <String>[],
          contextWindow: 128000,
        ),
      ];
}
