import '../core/json_utils.dart';
import 'provider_config.dart';

/// Provider/model metadata from the open [models.dev](https://models.dev)
/// database (`https://models.dev/api.json?type=all`).
///
/// The catalog drives the "一键更新" flow: it keeps provider endpoints, model
/// lists and per-model parameters (context window, output cap, reasoning
/// options, tool support) in sync with upstream, instead of hand-maintained
/// defaults drifting out of date.

/// models.dev provider id for each built-in preset. Used for matching when the
/// configured provider id itself is not the models.dev id (e.g. `qwen` →
/// `alibaba-cn`, `moonshot` → `moonshotai-cn`).
const kModelsDevPresetAliases = <String, String>{
  'deepseek': 'deepseek',
  'moonshot': 'moonshotai-cn',
  'zhipu': 'zhipuai',
  'qwen': 'alibaba-cn',
  'minimax': 'minimax-cn',
  'mimo': 'xiaomi',
  'openai': 'openai',
  'openrouter': 'openrouter',
};

/// Untouched default endpoints of the built-in presets. A sync only rewrites
/// the base URL when it is empty, on the same host, or still one of these
/// defaults — a custom mirror endpoint is never clobbered.
const kPresetDefaultBaseUrls = <String, String>{
  'deepseek': 'https://api.deepseek.com/v1',
  'moonshot': 'https://api.moonshot.cn/v1',
  'zhipu': 'https://open.bigmodel.cn/api/paas/v4',
  'qwen': 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  'minimax': '',
  'mimo': 'https://api.siliconflow.cn/v1',
  'openai': 'https://api.openai.com/v1',
  'openrouter': 'https://openrouter.ai/api/v1',
};

/// One reasoning knob advertised by a model (`toggle` / `effort` /
/// `budget_tokens`).
class ReasoningOption {
  const ReasoningOption({
    this.toggle = false,
    this.effort = false,
    this.budgetTokens = false,
    this.effortValues = const <String>[],
  });

  final bool toggle;
  final bool effort;
  final bool budgetTokens;
  final List<String> effortValues;

  factory ReasoningOption.fromJson(Object? value) {
    final json = asMap(value);
    final type = asString(json['type']) ?? '';
    return ReasoningOption(
      toggle: type == 'toggle',
      effort: type == 'effort',
      budgetTokens: type == 'budget_tokens',
      effortValues: asStringList(json['values']),
    );
  }
}

/// One model entry of a models.dev provider.
class ModelsDevModel {
  ModelsDevModel({
    required this.id,
    this.name = '',
    this.description = '',
    this.reasoning = false,
    this.toolCall = false,
    this.attachment = false,
    this.status = '',
    this.type = '',
    this.context,
    this.maxOutput,
    this.releaseDate = '',
    this.interleavedField,
    this.inlineThinking = false,
    List<ReasoningOption>? reasoningOptions,
  }) : reasoningOptions = reasoningOptions ?? const <ReasoningOption>[];

  final String id;
  final String name;
  final String description;
  final bool reasoning;
  final bool toolCall;
  final bool attachment;

  /// `''` | `beta` | `deprecated`.
  final String status;

  /// `''` (chat) | `decision` (specialized, not usable for chat).
  final String type;
  final int? context;
  final int? maxOutput;
  final String releaseDate;

  /// Thinking text arrives in a dedicated response field (e.g.
  /// `reasoning_content`) — maps to `ReasoningSource.field`.
  final String? interleavedField;

  /// Thinking text arrives inline (think tags) — maps to
  /// `ReasoningSource.inlineTags`.
  final bool inlineThinking;

  final List<ReasoningOption> reasoningOptions;

  factory ModelsDevModel.fromJson(String id, Object? value) {
    final json = asMap(value);
    final limit = asMap(json['limit']);
    final interleaved = json['interleaved'];
    String? field;
    var inline = false;
    if (interleaved is bool) {
      inline = interleaved;
    } else if (interleaved is Map) {
      field = asString(interleaved['field']);
      inline = field == null;
    }
    return ModelsDevModel(
      id: asString(json['id']) ?? id,
      name: asString(json['name']) ?? '',
      description: asString(json['description']) ?? '',
      reasoning: asBool(json['reasoning']),
      toolCall: asBool(json['tool_call']),
      attachment: asBool(json['attachment']),
      status: asString(json['status']) ?? '',
      type: asString(json['type']) ?? '',
      context: asInt(limit['context']),
      maxOutput: asInt(limit['output']),
      releaseDate: asString(json['release_date']) ?? '',
      interleavedField: field,
      inlineThinking: inline,
      reasoningOptions:
          asList(json['reasoning_options']).map(ReasoningOption.fromJson).toList(),
    );
  }

  /// Listed in the model picker: chat-capable and not deprecated/specialized.
  bool get usable => type != 'decision' && status != 'deprecated';

  /// Newly appended models must also support tool calls (agent sessions).
  bool get agentUsable => usable && toolCall;

  /// `ReasoningRequestStyle` hint: `thinking_budget` > `reasoning_effort` >
  /// `enable_thinking`; `null` when the model has no controllable reasoning.
  String? get derivedReasoningStyle {
    if (!reasoning) return null;
    if (reasoningOptions.any((o) => o.budgetTokens)) return 'thinking_budget';
    if (reasoningOptions.any((o) => o.effort)) return 'reasoning_effort';
    if (reasoningOptions.any((o) => o.toggle)) return 'enable_thinking';
    return null;
  }

  ModelSpec toSpec() => ModelSpec(
        id: id,
        name: name.isEmpty ? id : name,
        description: description,
        contextWindow: context,
        maxOutputTokens: maxOutput,
        reasoning: reasoning,
        toolCall: toolCall,
        status: status,
      );
}

/// One provider entry of the models.dev catalog.
class ModelsDevProvider {
  ModelsDevProvider({
    required this.id,
    this.name = '',
    this.api,
    this.npm = '',
    this.doc = '',
    List<String>? env,
    Map<String, ModelsDevModel>? models,
  })  : env = env ?? const <String>[],
        models = models ?? const <String, ModelsDevModel>{};

  final String id;
  final String name;

  /// OpenAI-compatible endpoint, `null` for providers served by their own SDK
  /// (OpenAI, Anthropic, Google, …).
  final String? api;
  final String npm;
  final String doc;
  final List<String> env;
  final Map<String, ModelsDevModel> models;

  factory ModelsDevProvider.fromJson(String id, Object? value) {
    final json = asMap(value);
    final rawModels = asMap(json['models']);
    return ModelsDevProvider(
      id: asString(json['id']) ?? id,
      name: asString(json['name']) ?? '',
      api: asString(json['api']),
      npm: asString(json['npm']) ?? '',
      doc: asString(json['doc']) ?? '',
      env: asStringList(json['env']),
      models: <String, ModelsDevModel>{
        for (final entry in rawModels.entries)
          entry.key: ModelsDevModel.fromJson(entry.key, entry.value),
      },
    );
  }

  /// The endpoint speaks the OpenAI-compatible protocol this app uses.
  bool get openAiCompatible {
    final npm = this.npm.toLowerCase();
    return npm.contains('openai-compatible') || npm.contains('openrouter');
  }

  /// Where thinking text shows up, aggregated over the models:
  /// `field` when every thinking model uses a named field, `inline` when any
  /// model interleaves it (think tags), `null` when unknown.
  String? get derivedReasoningSource {
    var sawField = false;
    var sawInline = false;
    for (final model in models.values) {
      if (model.interleavedField != null) sawField = true;
      if (model.inlineThinking) sawInline = true;
    }
    if (sawInline) return 'inline';
    if (sawField) return 'field';
    return null;
  }

  /// Aggregated `ReasoningRequestStyle` hint (`thinking_budget` >
  /// `reasoning_effort` > `enable_thinking`), `null` when nothing applies.
  String? get derivedReasoningStyle {
    var budget = false;
    var effort = false;
    var toggle = false;
    for (final model in models.values) {
      if (!model.reasoning) continue;
      for (final option in model.reasoningOptions) {
        budget = budget || option.budgetTokens;
        effort = effort || option.effort;
        toggle = toggle || option.toggle;
      }
    }
    if (budget) return 'thinking_budget';
    if (effort) return 'reasoning_effort';
    if (toggle) return 'enable_thinking';
    return null;
  }
}

/// Where a catalog snapshot came from (the loader falls back in this order).
enum ModelsDevSource {
  network('实时（models.dev）'),
  cache('本地缓存'),
  bundled('内置预置');

  const ModelsDevSource(this.label);

  final String label;
}

/// The parsed models.dev catalog (`api.json`).
class ModelsDevCatalog {
  ModelsDevCatalog(List<ModelsDevProvider> providers)
      : providers = <ModelsDevProvider>[...providers]
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
        _byId = <String, ModelsDevProvider>{
          for (final provider in providers) provider.id.toLowerCase(): provider,
        };

  factory ModelsDevCatalog.fromJson(Object? value) => ModelsDevCatalog([
        for (final entry in asMap(value).entries)
          ModelsDevProvider.fromJson(entry.key, entry.value),
      ]);

  final List<ModelsDevProvider> providers;
  final Map<String, ModelsDevProvider> _byId;

  ModelsDevProvider? byId(String id) => _byId[id.trim().toLowerCase()];

  /// Best catalog entry for a configured provider: exact id → same endpoint
  /// host → built-in preset alias (only for untouched/empty endpoints).
  ModelsDevProvider? matchFor(ProviderConfig config) {
    final byExactId = byId(config.id);
    if (byExactId != null) return byExactId;
    final host = _hostOf(config.baseUrl);
    if (host.isNotEmpty) {
      for (final provider in providers) {
        if (host == _hostOf(provider.api ?? '')) return provider;
      }
    }
    final alias = kModelsDevPresetAliases[config.preset];
    if (alias != null) {
      final base = config.baseUrl.trim();
      if (base.isEmpty || base == kPresetDefaultBaseUrls[config.preset]) {
        return byId(alias);
      }
    }
    return null;
  }
}

/// Built-in preset id matching a models.dev provider id (for new providers
/// added from the catalog); `custom` when there is no built-in counterpart.
String modelsDevPresetFor(String modelsDevId) {
  for (final entry in kModelsDevPresetAliases.entries) {
    if (entry.value == modelsDevId) return entry.key;
  }
  return 'custom';
}

/// Newest-release-first, then id — the order fresh models are appended/listed.
int compareModelsDevNewestFirst(ModelsDevModel a, ModelsDevModel b) {
  final byDate = b.releaseDate.compareTo(a.releaseDate);
  return byDate != 0 ? byDate : a.id.compareTo(b.id);
}

/// Outcome of applying catalog data to one provider.
class ModelsDevApplyResult {
  const ModelsDevApplyResult({
    required this.models,
    required this.added,
    required this.removed,
    this.notes = const <String>[],
  });

  /// Model count after the update.
  final int models;
  final int added;
  final int removed;
  final List<String> notes;
}

/// Outcome of the one-click catalog sync.
class ModelsDevSyncResult {
  const ModelsDevSyncResult({
    required this.updatedProviders,
    required this.totalModels,
    required this.unmatched,
    this.source = ModelsDevSource.network,
  });

  final int updatedProviders;
  final int totalModels;
  final List<String> unmatched;

  /// Where the applied snapshot came from (network / cache / bundled).
  final ModelsDevSource source;

  String get summary {
    final parts = <String>[
      updatedProviders == 0
          ? 'models.dev：没有可更新的服务'
          : 'models.dev 已更新 $updatedProviders 个服务 · $totalModels 个模型',
      if (unmatched.isNotEmpty) '未匹配：${unmatched.join('、')}',
      if (source != ModelsDevSource.network) '（网络不可用，使用${source.label}）',
    ];
    return parts.join('；');
  }
}

/// Rewrites [target] with fresh metadata from [source].
///
/// Always updated: model list (with [appendNew], fresh tool-capable catalog
/// models are appended newest-first), per-model specs, provider context window.
/// Guarded (only when the field is empty/untouched, or when [full]): name,
/// base URL. Reasoning parameters are only derived when [full], or for
/// `custom` providers whose style is still `none` — curated preset tuning and
/// user edits always win.
ModelsDevApplyResult applyModelsDev(
  ProviderConfig target,
  ModelsDevProvider source, {
  bool full = false,
  bool appendNew = true,
}) {
  final notes = <String>[];

  // Model list: the user's entries keep their order (and unknown ids survive —
  // custom gateway deployments); catalog-dead entries are dropped and fresh
  // tool-capable models are appended newest-first.
  final kept = <String>[];
  final seen = <String>{};
  var removed = 0;
  for (final id in target.models) {
    final known = source.models[id];
    if (known != null && !known.usable) {
      removed++;
      continue;
    }
    if (seen.add(id)) kept.add(id);
  }
  final fresh = <ModelsDevModel>[
    if (appendNew)
      ...source.models.values.where((m) => m.agentUsable && !seen.contains(m.id)),
  ]..sort(compareModelsDevNewestFirst);
  final added = fresh.length;
  kept.addAll(fresh.map((m) => m.id));

  // Per-model specs (context window / output cap / capabilities).
  final specs = <String, ModelSpec>{};
  for (final id in kept) {
    final model = source.models[id];
    if (model != null && model.usable) {
      specs[id] = model.toSpec();
    } else {
      final old = target.modelSpecs[id];
      if (old != null) specs[id] = old;
    }
  }
  target.models = kept;
  target.modelSpecs = specs;
  if (added > 0 || removed > 0) {
    notes.add('模型 +$added/-$removed');
  }

  // Provider context window = widest known model window (per-model values live
  // in the specs and drive the context bar).
  var maxContext = target.contextWindow;
  for (final spec in specs.values) {
    final context = spec.contextWindow;
    if (context != null && (maxContext == null || context > maxContext)) {
      maxContext = context;
    }
  }
  target.contextWindow = maxContext;

  // Name: catalog name once the user has not customized it.
  if (full || target.name.trim().isEmpty || target.name == target.id) {
    final name = source.name.isEmpty ? target.name : source.name;
    if (name != target.name) notes.add('名称 → $name');
    target.name = name;
  }

  // Base URL: only OpenAI-compatible endpoints, and never a custom mirror.
  final api = source.api;
  if (api != null && source.openAiCompatible) {
    final normalized = _normalizeBase(api);
    final base = target.baseUrl.trim();
    final untouched = base.isEmpty ||
        _hostOf(base) == _hostOf(api) ||
        kPresetDefaultBaseUrls.values.contains(base);
    if (full || untouched) {
      if (normalized != target.baseUrl) notes.add('端点 → $normalized');
      target.baseUrl = normalized;
    }
  }

  // Reasoning parameters.
  final style = source.derivedReasoningStyle;
  final reasoningSource = source.derivedReasoningSource;
  if (full) {
    if (style != null) target.reasoningStyle = style;
    if (reasoningSource != null) target.reasoningSource = reasoningSource;
    if (style != null || reasoningSource != null) {
      notes.add('思考参数 ${target.reasoningSource}/${target.reasoningStyle}');
    }
  } else if (target.preset == 'custom' &&
      style != null &&
      target.reasoningStyle == 'none') {
    target.reasoningStyle = style;
    notes.add('思考参数 → $style');
  }

  return ModelsDevApplyResult(
    models: kept.length,
    added: added,
    removed: removed,
    notes: notes,
  );
}

String _hostOf(String url) =>
    Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';

/// `https://host` → `https://host/v1` (the app appends `/chat/completions`).
String _normalizeBase(String api) {
  final uri = Uri.tryParse(api.trim());
  if (uri == null || !uri.hasScheme) return api.trim();
  final path = uri.path;
  final normalized = (path.isEmpty || path == '/')
      ? uri.replace(path: '/v1')
      : uri.replace(path: path.replaceAll(RegExp(r'/+$'), ''));
  return normalized.toString().replaceAll(RegExp(r'/+$'), '');
}
