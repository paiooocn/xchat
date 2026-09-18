import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_paths.dart';
import '../../models/app_config.dart';
import '../../models/search_engine_config.dart';
import '../../models/session_params.dart';
import '../../state/app_state.dart';
import 'compress_prompts_page.dart';
import '../../util/editor_launcher.dart';
import '../widgets/confirm_dialog.dart';

/// Global application settings.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _editor = TextEditingController();
  final _limit = TextEditingController();
  final _continuePrompt = TextEditingController();
  final _root = TextEditingController();
  final _httpProxy = TextEditingController();
  final _httpsProxy = TextEditingController();
  final _noProxy = TextEditingController();
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    final config = context.read<AppState>().config;
    _editor.text = config.editorCommand;
    _limit.text = config.defaultToolCallsLimit.toString();
    _continuePrompt.text = config.continuePrompt;
    _root.text = AppPaths.instance.root;
    _httpProxy.text = config.proxy.httpProxy;
    _httpsProxy.text = config.proxy.httpsProxy;
    _noProxy.text = config.proxy.noProxy;
    _loaded = true;
  }

  @override
  void dispose() {
    _editor.dispose();
    _limit.dispose();
    _continuePrompt.dispose();
    _root.dispose();
    _httpProxy.dispose();
    _httpsProxy.dispose();
    _noProxy.dispose();
    super.dispose();
  }

  Future<void> _save(AppState state) async {
    final config = state.config;
    config.editorCommand = _editor.text.trim();
    config.defaultToolCallsLimit = int.tryParse(_limit.text.trim()) ?? 0;
    config.continuePrompt = _continuePrompt.text;
    config.proxy
      ..httpProxy = _httpProxy.text.trim()
      ..httpsProxy = _httpsProxy.text.trim()
      ..noProxy = _noProxy.text.trim();
    await state.saveConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.config;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [TextButton(onPressed: () => _save(state), child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('数据目录'),
          Text(PathsSection.label(PathsSection.current)),
          TextField(
            controller: _root,
            decoration: const InputDecoration(labelText: 'XChat 根目录'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                onPressed: () async {
                  await AppPaths.setRoot(_root.text.trim());
                  if (context.mounted) setState(() {});
                },
                child: const Text('应用新目录'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => openInEditor(AppPaths.instance.configFile, config.editorCommand),
                child: const Text('打开 config.json'),
              ),
            ],
          ),
          _section('压缩会话'),
          Row(
            children: [
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CompressPromptsPage()),
                ),
                child: const Text('维护预置压缩提示词'),
              ),
            ],
          ),
          _section('默认参数'),
          TextField(
            controller: _limit,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '默认工具调用上限（0=不允许调用工具）'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ThinkingSwitch>(
            initialValue: config.defaultParams.thinking,
            decoration: const InputDecoration(labelText: '默认思考开关'),
            items: const [
              DropdownMenuItem(value: ThinkingSwitch.auto, child: Text('auto')),
              DropdownMenuItem(value: ThinkingSwitch.on, child: Text('on')),
              DropdownMenuItem(value: ThinkingSwitch.off, child: Text('off')),
            ],
            onChanged: (value) async {
              config.defaultParams.thinking = value ?? ThinkingSwitch.auto;
              await state.saveConfig();
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ContinueMode>(
            initialValue: config.continueMode,
            decoration: const InputDecoration(labelText: '达到工具上限后的处理'),
            items: const [
              DropdownMenuItem(value: ContinueMode.model, child: Text('模型自判（默认）')),
              DropdownMenuItem(value: ContinueMode.ask, child: Text('询问用户')),
              DropdownMenuItem(value: ContinueMode.stop, child: Text('直接结束')),
            ],
            onChanged: (value) async {
              config.continueMode = value ?? ContinueMode.model;
              await state.saveConfig();
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _continuePrompt,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '自动续判提示词（{n} 累计次数，{limit} 本轮上限）',
            ),
          ),
          _section('搜索引擎（按顺序依次回退）'),
          for (var i = 0; i < config.searchEngines.length; i++)
            Builder(builder: (context) {
              final engine = config.searchEngines[i];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Column(
                  children: [
                    ListTile(
                      title: Text(engine.name),
                      subtitle: Text(engine.isBuiltin
                          ? '内置 · ${engine.kind}'
                          : '自定义 · ${engine.urlTemplate}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '上移',
                            iconSize: 18,
                            icon: const Icon(Icons.arrow_upward),
                            onPressed: i == 0 ? null : () => _moveEngine(state, i, -1),
                          ),
                          IconButton(
                            tooltip: '下移',
                            iconSize: 18,
                            icon: const Icon(Icons.arrow_downward),
                            onPressed: i == config.searchEngines.length - 1
                                ? null
                                : () => _moveEngine(state, i, 1),
                          ),
                          if (!engine.isBuiltin) ...[
                            IconButton(
                              tooltip: '编辑',
                              iconSize: 18,
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _editEngine(state, i),
                            ),
                            IconButton(
                              tooltip: '删除',
                              iconSize: 18,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _removeEngine(state, i),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: SwitchListTile(
                            dense: true,
                            value: engine.enabled,
                            title: const Text('启用'),
                            onChanged: (value) async {
                              engine.enabled = value;
                              await state.saveConfig();
                            },
                          ),
                        ),
                        Expanded(
                          child: SwitchListTile(
                            dense: true,
                            value: engine.useProxy,
                            title: const Text('使用代理'),
                            onChanged: (value) async {
                              engine.useProxy = value;
                              await state.saveConfig();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _editEngine(state, -1),
              icon: const Icon(Icons.add),
              label: const Text('添加搜索引擎'),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _httpProxy,
            decoration: const InputDecoration(
              labelText: 'http_proxy（如 http://127.0.0.1:7890，留空直连）',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _httpsProxy,
            decoration: const InputDecoration(labelText: 'https_proxy'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _noProxy,
            decoration: const InputDecoration(
              labelText: 'no_proxy（如 localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12）',
            ),
          ),
          SwitchListTile(
            value: config.proxy.applyToHttpFetch,
            title: const Text('在 http_fetch 上启用代理'),
            onChanged: (value) async {
              config.proxy.applyToHttpFetch = value;
              setState(() {});
              await state.saveConfig();
            },
          ),
          _section('外观与编辑'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'system', label: Text('跟随系统')),
              ButtonSegment(value: 'light', label: Text('亮')),
              ButtonSegment(value: 'dark', label: Text('暗')),
            ],
            selected: {config.themeMode},
            onSelectionChanged: (value) async {
              config.themeMode = value.first;
              await state.saveConfig();
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _editor,
            decoration: const InputDecoration(
              labelText: '外部编辑器命令（{file} 占位，如 code --goto {file}）',
            ),
          ),
          _section('关于'),
          const Text('XChat · Flutter · ReAct Agent · XML 会话'),
        ],
      ),
    );
  }

  Future<void> _moveEngine(AppState state, int index, int delta) async {
    final list = state.config.searchEngines;
    final target = index + delta;
    if (target < 0 || target >= list.length) return;
    final item = list.removeAt(index);
    list.insert(target, item);
    await state.saveConfig();
  }

  Future<void> _removeEngine(AppState state, int index) async {
    final name = state.config.searchEngines[index].name;
    final ok = await confirmDelete(context, '搜索引擎「$name」');
    if (!ok) return;
    state.config.searchEngines.removeAt(index);
    await state.saveConfig();
  }

  Future<void> _editEngine(AppState state, int index) async {
    final existing = index >= 0 ? state.config.searchEngines[index] : null;
    final engine = existing ?? SearchEngineConfig(id: 'custom_${state.config.searchEngines.length}', name: '自定义');
    final name = TextEditingController(text: engine.name);
    final url = TextEditingController(text: engine.urlTemplate);
    final result = TextEditingController(text: engine.resultSelector);
    final title = TextEditingController(text: engine.titleSelector);
    final link = TextEditingController(text: engine.linkSelector);
    final snippet = TextEditingController(text: engine.snippetSelector);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? '添加搜索引擎' : '编辑搜索引擎'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: '名称')),
                const SizedBox(height: 12),
                TextField(
                  controller: url,
                  decoration: const InputDecoration(
                    labelText: '搜索 URL 模板（{query} 占位，如 https://example.com/search?q={query}）',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(controller: result, decoration: const InputDecoration(labelText: '结果条目选择器（CSS）')),
                const SizedBox(height: 12),
                TextField(controller: title, decoration: const InputDecoration(labelText: '标题选择器（CSS）')),
                const SizedBox(height: 12),
                TextField(controller: link, decoration: const InputDecoration(labelText: '链接选择器（CSS）')),
                const SizedBox(height: 12),
                TextField(controller: snippet, decoration: const InputDecoration(labelText: '摘要选择器（CSS）')),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    engine
      ..name = name.text.trim().isEmpty ? '自定义' : name.text.trim()
      ..kind = 'custom'
      ..urlTemplate = url.text.trim()
      ..resultSelector = result.text.trim()
      ..titleSelector = title.text.trim()
      ..linkSelector = link.text.trim()
      ..snippetSelector = snippet.text.trim();
    if (existing == null) state.config.searchEngines.add(engine);
    await state.saveConfig();
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      );
}

/// Helper to display platform-ish directory labels.
class PathsSection {
  const PathsSection._();

  static final String current = AppPaths.isReady ? AppPaths.instance.root : '';

  static String label(String value) => value;
}
