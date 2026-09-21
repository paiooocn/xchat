import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../llm/llm_factory.dart';
import '../../models/provider_config.dart';
import '../../state/app_state.dart';
import '../widgets/confirm_dialog.dart';

/// Manages OpenAI-compatible provider endpoints.
class ProvidersPage extends StatelessWidget {
  const ProvidersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('模型服务')),
      body: RadioGroup<String>(
        groupValue: state.config.currentProviderId,
        onChanged: (value) async {
          if (value == null) return;
          state.config.currentProviderId = value;
          await state.saveConfig();
        },
        child: ListView(
          children: [
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
        onPressed: () => _edit(context, state, null),
        icon: const Icon(Icons.add),
        label: const Text('添加'),
      ),
    );
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

  Future<void> _save() async {
    final state = context.read<AppState>();
    final provider = widget.provider
      ..id = _id.text.trim()
      ..name = _name.text.trim()
      ..baseUrl = _baseUrl.text.trim()
      ..apiKey = _apiKey.text.trim()
      ..preset = _preset
      ..reasoningSource = _reasoningSource
      ..reasoningStyle = _reasoningStyle
      ..useMaxCompletionTokens = _useMaxCompletionTokens
      ..contextWindow = int.tryParse(_contextWindow.text.trim())
      ..models = _models.text.split(',').map((m) => m.trim()).where((m) => m.isNotEmpty).toList();
    await state.upsertProvider(provider);
    if (mounted) Navigator.of(context).pop();
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
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
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
