import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../llm/llm_factory.dart';
import '../../models/models_dev.dart';
import '../../models/provider_config.dart';
import '../../models/session_message.dart';
import '../../state/app_state.dart';
import '../widgets/confirm_dialog.dart';

/// Manages OpenAI-compatible provider endpoints.
class ProvidersPage extends StatelessWidget {
  const ProvidersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型服务'),
        actions: [
          IconButton(
            tooltip: '从 models.dev 一键更新服务/模型信息',
            icon: const Icon(Icons.sync),
            onPressed: () => _sync(context, state),
          ),
        ],
      ),
      body: RadioGroup<String>(
        groupValue: state.config.currentProviderId,
        onChanged: (value) async {
          if (value == null) return;
          state.config.currentProviderId = value;
          // 切换服务后，应用功能模型需属于该服务。
          final models = state.providerById(value).models;
          if (!models.contains(state.config.currentModel)) {
            state.config.currentModel = models.isNotEmpty ? models.first : '';
          }
          await state.saveConfig();
        },
        child: ListView(
          children: [
            _FeatureModelBanner(state: state),
            for (final provider in state.config.providers)
              ListTile(
                leading: Radio<String>(value: provider.id),
              title: Text(provider.name),
              subtitle: Text(
                '${provider.baseUrl} · ${provider.models.length} models',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '测试连接',
                    icon: const Icon(Icons.wifi_tethering),
                    onPressed: () => _test(context, provider),
                  ),
                  IconButton(
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _edit(context, state, provider),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await confirmDelete(context, '模型服务「${provider.name}」');
                      if (ok) await state.removeProvider(provider.id);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, state),
        icon: const Icon(Icons.add),
        label: const Text('添加'),
      ),
    );
  }

  /// Add flow: from the models.dev catalog (wizard) or a blank custom entry.
  Future<void> _add(BuildContext context, AppState state) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('从 models.dev 添加'),
              subtitle: const Text('挑选提供商与模型，自动填充端点与参数'),
              onTap: () => Navigator.of(context).pop('catalog'),
            ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('空白自定义'),
              subtitle: const Text('手动填写端点、模型与参数'),
              onTap: () => Navigator.of(context).pop('custom'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    if (choice == 'catalog') {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const _ModelsDevWizardPage()),
      );
    } else {
      await _edit(context, state, null);
    }
  }

  /// One-click refresh of every configured provider from the models.dev
  /// catalog (model lists, per-model parameters, untouched endpoints).
  Future<void> _sync(BuildContext context, AppState state) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在从 models.dev 更新…')));
    try {
      final result = await state.syncModelsDev();
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(content: Text(result.summary)));
    } catch (error) {
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(content: Text('models.dev 更新失败：$error')));
    }
  }

  Future<void> _test(BuildContext context, ProviderConfig provider) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('测试中…')));
    try {
      final result = await testProvider(provider);
      messenger.showSnackBar(SnackBar(content: Text(result)));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('失败：$error')));
    }
  }

  Future<void> _edit(BuildContext context, AppState state, ProviderConfig? existing) async {
    final provider = existing ?? ProviderConfig(id: 'custom_${state.config.providers.length}', name: '自定义');
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _ProviderEditorPage(provider: provider)),
    );
  }
}

/// Prominent notice + picker: the selected service/model is the
/// 「应用功能调用模型」 — the model app features call (the manual「AI 自动命名」
/// menu, prompt generation/polish, …).
class _FeatureModelBanner extends StatelessWidget {
  const _FeatureModelBanner({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (provider, model) = state.appFeatureTarget;
    final options = <String>{
      ...provider.models,
      if (state.config.currentModel.isNotEmpty) state.config.currentModel,
    }.toList();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tips_and_updates, size: 18, color: scheme.onPrimaryContainer),
              const SizedBox(width: 6),
              Text(
                '应用功能调用模型',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: scheme.onPrimaryContainer,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '在此选中的服务与模型即「应用功能调用模型」：会话「更多」菜单的 AI 自动命名、'
            '模板提示词生成/润色等应用功能都会调用它。'
            '（对话与第一轮结束后的自动命名使用会话/模板选定的模型）',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('feature_model_${provider.id}'),
            initialValue: options.contains(model) ? model : null,
            decoration: InputDecoration(
              labelText: '当前生效：${provider.name} · ${model.isEmpty ? '(未选模型)' : model}',
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: scheme.surface,
            ),
            items: [
              for (final id in options)
                DropdownMenuItem(value: id, child: Text(id)),
            ],
            onChanged: (value) async {
              state.config.currentModel = value ?? '';
              await state.saveConfig();
            },
          ),
        ],
      ),
    );
  }
}

class _ProviderEditorPage extends StatefulWidget {
  const _ProviderEditorPage({required this.provider});

  final ProviderConfig provider;

  @override
  State<_ProviderEditorPage> createState() => _ProviderEditorPageState();
}

class _ProviderEditorPageState extends State<_ProviderEditorPage> {
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _models = TextEditingController();
  final _contextWindow = TextEditingController();
  late String _preset;
  late String _reasoningSource;
  late String _reasoningStyle;
  bool _useMaxCompletionTokens = false;
  Map<String, ModelSpec> _specs = <String, ModelSpec>{};

  @override
  void initState() {
    super.initState();
    final provider = widget.provider;
    _id.text = provider.id;
    _name.text = provider.name;
    _baseUrl.text = provider.baseUrl;
    _apiKey.text = provider.apiKey;
    _models.text = provider.models.join(', ');
    _contextWindow.text = provider.contextWindow?.toString() ?? '';
    _preset = provider.preset;
    _reasoningSource = provider.reasoningSource;
    _reasoningStyle = provider.reasoningStyle;
    _useMaxCompletionTokens = provider.useMaxCompletionTokens;
    _specs = Map<String, ModelSpec>.of(provider.modelSpecs);
  }

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _models.dispose();
    _contextWindow.dispose();
    super.dispose();
  }

  List<String> get _modelList => _models.text
      .split(',')
      .map((m) => m.trim())
      .where((m) => m.isNotEmpty)
      .toList();

  /// Writes the form fields onto [target]; per-model specs are pruned to the
  /// models currently in the list.
  ProviderConfig _applyTo(ProviderConfig target) {
    final models = _modelList;
    return target
      ..id = _id.text.trim()
      ..name = _name.text.trim()
      ..baseUrl = _baseUrl.text.trim()
      ..apiKey = _apiKey.text.trim()
      ..preset = _preset
      ..reasoningSource = _reasoningSource
      ..reasoningStyle = _reasoningStyle
      ..useMaxCompletionTokens = _useMaxCompletionTokens
      ..contextWindow = int.tryParse(_contextWindow.text.trim())
      ..models = models
      ..modelSpecs = <String, ModelSpec>{
        for (final id in models) if (_specs[id] != null) id: _specs[id]!,
      };
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    _applyTo(widget.provider);
    await state.upsertProvider(widget.provider);
    if (mounted) Navigator.of(context).pop();
  }

  /// Fills the form from the matching models.dev entry (endpoint, model list,
  /// per-model parameters, reasoning style). The user reviews and saves.
  Future<void> _fillFromModelsDev() async {
    final messenger = ScaffoldMessenger.of(context);
    final state = context.read<AppState>();
    messenger.showSnackBar(const SnackBar(content: Text('正在读取 models.dev…')));
    try {
      final filled = await state.fillFromModelsDev(_applyTo(widget.provider.copyWith()));
      if (!mounted) return;
      if (filled == null) {
        messenger.clearSnackBars();
        messenger.showSnackBar(const SnackBar(
            content: Text('未在 models.dev 匹配到该服务（请先填写正确的 ID 或 Base URL）')));
        return;
      }
      setState(() {
        _name.text = filled.name;
        _baseUrl.text = filled.baseUrl;
        _models.text = filled.models.join(', ');
        _contextWindow.text = filled.contextWindow?.toString() ?? '';
        _reasoningSource = filled.reasoningSource;
        _reasoningStyle = filled.reasoningStyle;
        _specs = Map<String, ModelSpec>.of(filled.modelSpecs);
      });
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(
          content: Text('已按 models.dev「${filled.name}」填充 ${filled.models.length} 个模型，请核对后保存')));
    } catch (error) {
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(content: Text('models.dev 读取失败：$error')));
    }
  }

  Future<void> _fetchModels() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final models = await fetchModels(widget.provider);
      setState(() => _models.text = models.join(', '));
      messenger.showSnackBar(SnackBar(content: Text('获取到 ${models.length} 个模型')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务编辑'),
        actions: [
          IconButton(
            tooltip: '从 models.dev 填充',
            icon: const Icon(Icons.auto_fix_high),
            onPressed: _fillFromModelsDev,
          ),
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _id, decoration: const InputDecoration(labelText: 'ID（唯一）')),
          const SizedBox(height: 12),
          TextField(controller: _name, decoration: const InputDecoration(labelText: '名称')),
          const SizedBox(height: 12),
          TextField(controller: _baseUrl, decoration: const InputDecoration(labelText: 'Base URL')),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'API Key'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _contextWindow,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '上下文窗口（tokens，可选）'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('preset-$_preset'),
            initialValue: _preset,
            decoration: const InputDecoration(labelText: '预设（决定思考读取/回发）'),
            items: const [
              DropdownMenuItem(value: 'custom', child: Text('custom')),
              DropdownMenuItem(value: 'openai', child: Text('openai')),
              DropdownMenuItem(value: 'deepseek', child: Text('deepseek')),
              DropdownMenuItem(value: 'moonshot', child: Text('moonshot')),
              DropdownMenuItem(value: 'zhipu', child: Text('zhipu')),
              DropdownMenuItem(value: 'qwen', child: Text('qwen')),
              DropdownMenuItem(value: 'mimo', child: Text('mimo')),
              DropdownMenuItem(value: 'minimax', child: Text('minimax')),
              DropdownMenuItem(value: 'openrouter', child: Text('openrouter')),
            ],
            onChanged: (value) => setState(() => _preset = value ?? 'custom'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('source-$_reasoningSource'),
            initialValue: _reasoningSource,
            decoration: const InputDecoration(labelText: '思考读取来源'),
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('auto')),
              DropdownMenuItem(value: 'field', child: Text('field (reasoning_content)')),
              DropdownMenuItem(value: 'inline', child: Text('inline (think tag)')),
              DropdownMenuItem(value: 'none', child: Text('none')),
            ],
            onChanged: (value) => setState(() => _reasoningSource = value ?? 'auto'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('style-$_reasoningStyle'),
            initialValue: _reasoningStyle,
            decoration: const InputDecoration(labelText: '思考请求方式'),
            items: const [
              DropdownMenuItem(value: 'none', child: Text('none')),
              DropdownMenuItem(value: 'reasoning_effort', child: Text('reasoning_effort')),
              DropdownMenuItem(value: 'enable_thinking', child: Text('enable_thinking')),
              DropdownMenuItem(value: 'thinking_budget', child: Text('thinking_budget')),
              DropdownMenuItem(value: 'reasoning_max_tokens', child: Text('reasoning_max_tokens')),
            ],
            onChanged: (value) => setState(() => _reasoningStyle = value ?? 'none'),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _useMaxCompletionTokens,
            title: const Text('使用 max_completion_tokens'),
            onChanged: (value) => setState(() => _useMaxCompletionTokens = value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _models,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: '模型列表（逗号分隔）',
              suffixIcon: IconButton(
                icon: const Icon(Icons.download),
                tooltip: '从服务获取',
                onPressed: _fetchModels,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Adds a provider from the models.dev catalog: pick the provider, pick the
/// models, then review the prefilled entry in the editor (API key) and save.
class _ModelsDevWizardPage extends StatefulWidget {
  const _ModelsDevWizardPage();

  @override
  State<_ModelsDevWizardPage> createState() => _ModelsDevWizardPageState();
}

class _ModelsDevWizardPageState extends State<_ModelsDevWizardPage> {
  final _search = TextEditingController();
  late Future<ModelsDevCatalog> _future;
  String _query = '';
  ModelsDevProvider? _provider;
  List<ModelsDevModel> _models = const <ModelsDevModel>[];
  final Set<String> _selected = <String>{};

  /// How many newest tool-capable models are preselected per provider.
  static const int _preselect = 10;

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().loadModelsDev();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reload() => setState(() => _future = context.read<AppState>().loadModelsDev());

  void _setQuery(String value) => setState(() {
        _query = value;
      });

  void _clearQuery() {
    _search.clear();
    _setQuery('');
  }

  /// Step 1 → 2: keep the newest tool-capable models preselected.
  void _pickProvider(ModelsDevProvider provider) {
    final models = provider.models.values.where((m) => m.usable).toList()
      ..sort(compareModelsDevNewestFirst);
    setState(() {
      _provider = provider;
      _models = models;
      _selected
        ..clear()
        ..addAll(
          models.where((m) => m.agentUsable).take(_preselect).map((m) => m.id),
        );
      _clearQuery();
    });
  }

  void _back() => setState(() {
        _provider = null;
        _models = const <ModelsDevModel>[];
        _selected.clear();
        _clearQuery();
      });

  /// Builds the prefilled provider and hands it to the editor for review.
  void _create() {
    final state = context.read<AppState>();
    final source = _provider!;
    final preset = modelsDevPresetFor(source.id);
    final config = ProviderConfig(
      id: _uniqueId(state, source.id),
      name: source.name.isEmpty ? source.id : source.name,
      preset: preset,
      defaultThinkingReplyMode:
          preset == 'minimax' ? ThinkingReplyMode.thinkTag : ThinkingReplyMode.auto,
      models: [for (final model in _models) if (_selected.contains(model.id)) model.id],
    );
    applyModelsDev(config, source, full: true, appendNew: false);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => _ProviderEditorPage(provider: config)),
    );
  }

  String _uniqueId(AppState state, String base) {
    var id = base;
    var n = 2;
    while (state.config.providerById(id) != null) {
      id = '$base-${n++}';
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final pickingModels = _provider != null;
    return Scaffold(
      appBar: AppBar(
        leading: pickingModels
            ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _back)
            : null,
        title: Text(pickingModels
            ? '选择模型（${_selected.length}）· ${_provider!.name}'
            : '从 models.dev 添加'),
        actions: [
          if (pickingModels)
            TextButton(
              onPressed: _selected.isEmpty ? null : _create,
              child: const Text('创建'),
            ),
        ],
      ),
      body: FutureBuilder<ModelsDevCatalog>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _ErrorView(error: '${snapshot.error}', onRetry: _reload);
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return pickingModels ? _modelList() : _providerList(snapshot.data!);
        },
      ),
    );
  }

  Widget _providerList(ModelsDevCatalog catalog) {
    final query = _query.trim().toLowerCase();
    final providers = catalog.providers
        .where((p) =>
            query.isEmpty ||
            p.id.toLowerCase().contains(query) ||
            p.name.toLowerCase().contains(query))
        .toList(growable: false);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _search,
            onChanged: _setQuery,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: '搜索提供商（名称 / ID）',
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(icon: const Icon(Icons.clear), onPressed: _clearQuery),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: providers.length,
            itemBuilder: (context, index) {
              final provider = providers[index];
              final endpoint = provider.openAiCompatible
                  ? (_hostOf(provider.api) ?? '未提供端点')
                  : '非 OpenAI 兼容协议';
              return ListTile(
                title: Text(provider.name.isEmpty ? provider.id : provider.name),
                subtitle: Text(
                  '$endpoint · ${provider.id} · ${provider.models.length} 个模型',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickProvider(provider),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _modelList() {
    final query = _query.trim().toLowerCase();
    final models = _models
        .where((m) =>
            query.isEmpty ||
            m.id.toLowerCase().contains(query) ||
            m.name.toLowerCase().contains(query) ||
            m.description.toLowerCase().contains(query))
        .toList(growable: false);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _search,
            onChanged: _setQuery,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: '搜索模型（默认选中最新 $_preselect 个支持工具的模型）',
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(icon: const Icon(Icons.clear), onPressed: _clearQuery),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              TextButton(
                onPressed: () => setState(() {
                  _selected.addAll(_models.where((m) => m.agentUsable).map((m) => m.id));
                }),
                child: const Text('全选（支持工具）'),
              ),
              TextButton(
                onPressed: () => setState(_selected.clear),
                child: const Text('清空'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: models.length,
            itemBuilder: (context, index) {
              final model = models[index];
              final tags = <String>[
                if (model.reasoning) '思考',
                if (model.toolCall) '工具',
                if (model.attachment) '附件',
                if (model.status == 'beta') 'beta',
              ];
              return CheckboxListTile(
                value: _selected.contains(model.id),
                onChanged: (checked) => setState(() {
                  if (checked ?? false) {
                    _selected.add(model.id);
                  } else {
                    _selected.remove(model.id);
                  }
                }),
                title: Text(model.name.isEmpty ? model.id : model.name),
                isThreeLine: model.description.isNotEmpty,
                subtitle: Text(
                  '${model.id} · 上下文 ${_fmtLimit(model.context)} · 输出 ${_fmtLimit(model.maxOutput)}'
                  '${tags.isEmpty ? '' : ' · ${tags.join(' / ')}'}'
                  '${model.description.isEmpty ? '' : '\n${model.description}'}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text('models.dev 读取失败：$error', textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

String? _hostOf(String? url) {
  final host = Uri.tryParse(url?.trim() ?? '')?.host ?? '';
  return host.isEmpty ? null : host;
}

/// `1048576` → `1M`, `65536` → `65.5K` (limit labels only).
String _fmtLimit(int? value) {
  if (value == null || value <= 0) return '—';
  if (value >= 1000000) {
    final v = value / 1000000;
    return '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}M';
  }
  if (value >= 1000) {
    final v = value / 1000;
    return '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}K';
  }
  return '$value';
}
