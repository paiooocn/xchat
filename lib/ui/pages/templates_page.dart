import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../agent/tools/builtin_tools.dart';
import '../../core/ids.dart';
import '../../models/session_message.dart';
import '../../models/session_params.dart';
import '../../models/session_template.dart';
import '../../state/app_state.dart';
import '../widgets/confirm_dialog.dart';

/// Lists, edits and creates session templates.
class TemplatesPage extends StatelessWidget {
  const TemplatesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('会话模板')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, state, null),
        icon: const Icon(Icons.add),
        label: const Text('新建模板'),
      ),
      body: ListView(
        children: [
          for (final template in state.templates)
            ListTile(
              title: Text(template.name.isEmpty ? '(未命名模板)' : template.name),
              subtitle: Text(
                '${template.provider} · ${template.model} · '
                'limit=${template.toolCallsLimit} · tools=${template.tools.length}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '复制',
                    icon: const Icon(Icons.copy),
                    onPressed: () => state.saveTemplate(template.copyWith(id: newId(), name: '${template.name} 副本')),
                  ),
                  IconButton(
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _edit(context, state, template),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await confirmDelete(
                        context,
                        '模板「${template.name.isEmpty ? template.id : template.name}」',
                      );
                      if (ok) await state.deleteTemplate(template.id);
                    },
                  ),
                ],
              ),
              onTap: () => _edit(context, state, template),
            ),
          if (state.templates.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('还没有模板')),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, AppState state, SessionTemplate? existing) async {
    final template = existing ??
        SessionTemplate(
          id: newId(),
          name: '新模板',
          toolCallsLimit: state.config.defaultToolCallsLimit,
        );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TemplateEditorPage(template: template),
      ),
    );
  }
}

class _TemplateEditorPage extends StatefulWidget {
  const _TemplateEditorPage({required this.template});

  final SessionTemplate template;

  @override
  State<_TemplateEditorPage> createState() => _TemplateEditorPageState();
}

class _TemplateEditorPageState extends State<_TemplateEditorPage> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _system = TextEditingController();
  final _model = TextEditingController();
  final _limit = TextEditingController();
  final Set<String> _tools = <String>{};
  late String _providerId;
  ThinkingSwitch _thinking = ThinkingSwitch.auto;
  ThinkingReplyMode _replyMode = ThinkingReplyMode.auto;

  /// '' = not sent; otherwise a verbatim `reasoning_effort` value.
  String _effort = '';

  static const _effortOptions = <String>[
    '',
    'max',
    'xhigh',
    'high',
    'medium',
    'low',
    'minimal',
    'none',
  ];

  @override
  void initState() {
    super.initState();
    final template = widget.template;
    final state = context.read<AppState>();
    _name.text = template.name;
    _description.text = template.description;
    _system.text = template.systemPrompt;
    _model.text = template.model;
    _limit.text = template.toolCallsLimit.toString();
    _tools.addAll(template.tools);
    _providerId = template.provider.isNotEmpty ? template.provider : state.config.currentProviderId;
    _thinking = template.params.thinking;
    _replyMode = template.thinkingReplyMode;
    _effort = template.params.reasoningEffort ?? '';
  }

  List<String> _modelOptions(AppState state) {
    final provider = state.providerById(_providerId);
    return <String>{
      ...provider.models,
      if (_model.text.trim().isNotEmpty) _model.text.trim(),
    }.toList();
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _system.dispose();
    _model.dispose();
    _limit.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final template = widget.template
      ..name = _name.text.trim()
      ..description = _description.text.trim()
      ..systemPrompt = _system.text
      ..provider = _providerId
      ..model = _model.text.trim()
      ..toolCallsLimit = int.tryParse(_limit.text.trim()) ?? 0
      ..thinkingReplyMode = _replyMode
      ..params = (widget.template.params
        ..thinking = _thinking
        ..reasoningEffort = _effort.isEmpty ? null : _effort)
      ..tools = _tools.toList();
    await state.saveTemplate(template);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('模板编辑'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: '名称')),
          const SizedBox(height: 12),
          TextField(controller: _description, decoration: const InputDecoration(labelText: '说明')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _providerId.isEmpty ? null : _providerId,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: [
              for (final provider in state.config.providers)
                DropdownMenuItem(value: provider.id, child: Text(provider.name)),
            ],
            onChanged: (value) => setState(() {
              _providerId = value ?? _providerId;
              final models = state.providerById(_providerId).models;
              _model.text = models.isNotEmpty ? models.first : '';
            }),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('template_model_$_providerId'),
            initialValue: _modelOptions(state).contains(_model.text) ? _model.text : null,
            decoration: const InputDecoration(labelText: 'Model（从提供商列表选择）'),
            items: [
              for (final model in _modelOptions(state))
                DropdownMenuItem(value: model, child: Text(model)),
            ],
            onChanged: (value) => setState(() => _model.text = value ?? ''),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _system,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '系统提示词（{sandbox} 自动替换为会话 sandbox 路径）',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _limit,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '工具调用上限（0=不允许调用工具）'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ThinkingSwitch>(
            initialValue: _thinking,
            decoration: const InputDecoration(labelText: '思考'),
            items: const [
              DropdownMenuItem(value: ThinkingSwitch.auto, child: Text('auto')),
              DropdownMenuItem(value: ThinkingSwitch.on, child: Text('on')),
              DropdownMenuItem(value: ThinkingSwitch.off, child: Text('off')),
            ],
            onChanged: (value) => setState(() => _thinking = value ?? ThinkingSwitch.auto),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('template_effort_$_effort'),
            initialValue: _effort,
            decoration: const InputDecoration(labelText: 'reasoning_effort'),
            items: [
              for (final value in _effortOptions)
                DropdownMenuItem(
                  value: value,
                  child: Text(value.isEmpty ? '（不传入）' : value),
                ),
            ],
            onChanged: (value) => setState(() => _effort = value ?? ''),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ThinkingReplyMode>(
            initialValue: _replyMode,
            decoration: const InputDecoration(labelText: '思考回发方式'),
            items: const [
              DropdownMenuItem(value: ThinkingReplyMode.auto, child: Text('auto')),
              DropdownMenuItem(value: ThinkingReplyMode.reasoningContent, child: Text('reasoning_content')),
              DropdownMenuItem(value: ThinkingReplyMode.thinkTag, child: Text('think_tag')),
            ],
            onChanged: (value) => setState(() => _replyMode = value ?? ThinkingReplyMode.auto),
          ),
          const SizedBox(height: 12),
          const Text('默认工具：'),
          Wrap(
            spacing: 8,
            children: [
              for (final name in BuiltinTools.descriptions.keys)
                FilterChip(
                  label: Text(name),
                  selected: _tools.contains(name),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      _tools.add(name);
                    } else {
                      _tools.remove(name);
                    }
                  }),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
