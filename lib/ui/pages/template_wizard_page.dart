import 'dart:async';

import 'package:flutter/material.dart';
import 'package:llm_api/llm_api.dart' as llm;
import 'package:provider/provider.dart';

import '../../agent/tools/builtin_tools.dart';
import '../../core/ids.dart';
import '../../llm/prompt_assistant.dart';
import '../../models/session_message.dart';
import '../../models/session_params.dart';
import '../../models/session_template.dart';
import '../../state/app_state.dart';

/// Guided ("wizard") creation of a session template:
/// 1. scenario/requirement → one-click LLM system prompt (preset categories),
/// 2. system prompt editing with LLM adjust/polish,
/// 3. model & thinking parameters → save.
class TemplateWizardPage extends StatefulWidget {
  const TemplateWizardPage({super.key});

  @override
  State<TemplateWizardPage> createState() => _TemplateWizardPageState();
}

class _TemplateWizardPageState extends State<TemplateWizardPage> {
  int _step = 0;

  final _name = TextEditingController();
  final _requirement = TextEditingController();
  final _system = TextEditingController();
  final _instruction = TextEditingController();
  final _model = TextEditingController();
  final _limit = TextEditingController();
  final Set<String> _tools = <String>{};

  String _category = '';
  late String _providerId;
  ThinkingSwitch _thinking = ThinkingSwitch.auto;
  ThinkingReplyMode _replyMode = ThinkingReplyMode.auto;

  /// '' = not sent; otherwise a verbatim `reasoning_effort` value.
  String _effort = '';

  // LLM generation state.
  bool _busy = false;
  llm.CancelToken? _cancel;
  String _liveText = '';
  String _preview = '';
  String? _error;

  static const _quickPolish = <String, String>{
    '润色': '润色这段提示词：保持原意与结构，让表达更专业、清晰、具体。',
    '精简': '精简这段提示词：删除冗余与重复，保留全部关键约束，控制在 200 字以内。',
    '扩写': '扩写这段提示词：补充角色定位、工作流程、输出规范与约束边界等细节。',
  };

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _providerId = state.config.currentProviderId;
    _model.text = state.config.currentModel;
    _limit.text = state.config.defaultToolCallsLimit.toString();
    _tools.addAll(state.config.defaultTools);
    _thinking = state.config.defaultParams.thinking;
    _effort = state.config.defaultParams.reasoningEffort ?? '';
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _name.dispose();
    _requirement.dispose();
    _system.dispose();
    _instruction.dispose();
    _model.dispose();
    _limit.dispose();
    super.dispose();
  }

  List<String> _modelOptions(AppState state) {
    final provider = state.providerById(_providerId);
    return <String>{
      ...provider.models,
      if (_model.text.trim().isNotEmpty) _model.text.trim(),
    }.toList();
  }

  /// The model used for prompt generation/polish: the app-feature model
  /// selected on the 模型服务 page.
  (String, String) _generationTarget(AppState state) {
    final (provider, model) = state.appFeatureTarget;
    return (provider.id, model);
  }

  // ------------------------------------------------------------------ LLM ops

  Future<void> _generate({String category = ''}) async {
    final state = context.read<AppState>();
    final (providerId, model) = _generationTarget(state);
    if (model.isEmpty) {
      setState(() => _error = '未配置全局模型，无法生成');
      return;
    }
    setState(() {
      if (category.isNotEmpty) _category = category;
      _busy = true;
      _error = null;
      _liveText = '';
      _preview = '';
    });
    _cancel = llm.CancelToken();
    try {
      final text = await generateSystemPrompt(
        provider: state.providerById(providerId),
        model: model,
        category: _category,
        requirement: _requirement.text,
        onProgress: (partial) => setState(() => _liveText = partial),
        cancel: _cancel,
      );
      if (!mounted) return;
      setState(() {
        _system.text = text;
        _step = 1;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '生成失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refine(String instruction) async {
    final prompt = _system.text.trim();
    if (prompt.isEmpty) {
      setState(() => _error = '请先填写或生成系统提示词');
      return;
    }
    if (instruction.trim().isEmpty) {
      setState(() => _error = '请填写调整要求');
      return;
    }
    final state = context.read<AppState>();
    final (providerId, model) = _generationTarget(state);
    if (model.isEmpty) {
      setState(() => _error = '未配置全局模型，无法调整');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _liveText = '';
      _preview = '';
    });
    _cancel = llm.CancelToken();
    try {
      final text = await refineSystemPrompt(
        provider: state.providerById(providerId),
        model: model,
        prompt: prompt,
        instruction: instruction,
        onProgress: (partial) => setState(() => _liveText = partial),
        cancel: _cancel,
      );
      if (!mounted) return;
      setState(() => _preview = text);
    } catch (e) {
      if (mounted) setState(() => _error = '调整失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _stop() {
    _cancel?.cancel();
    _cancel = null;
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final template = SessionTemplate(
      id: newId(),
      name: _name.text.trim(),
      description: _requirement.text.trim(),
      provider: _providerId,
      model: _model.text.trim(),
      thinkingReplyMode: _replyMode,
      toolCallsLimit: int.tryParse(_limit.text.trim()) ?? 0,
      systemPrompt: _system.text,
      params: SessionParams(thinking: _thinking, reasoningEffort: _effort.isEmpty ? null : _effort),
      tools: _tools.toList(),
    );
    await state.saveTemplate(template);
    if (mounted) Navigator.of(context).pop(template);
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final (providerId, model) = _generationTarget(state);
    return Scaffold(
      appBar: AppBar(title: const Text('新建模板 · 向导')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StepBar(current: _step, onSelect: (i) => setState(() => _step = i)),
          const SizedBox(height: 16),
          if (_step == 0) _buildScenario(state),
          if (_step == 1) _buildPrompt(state, providerId, model),
          if (_step == 2) _buildParams(state),
          const SizedBox(height: 16),
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              if (_step > 0)
                OutlinedButton(
                  onPressed: _busy ? null : () => setState(() => _step--),
                  child: const Text('上一步'),
                ),
              const SizedBox(width: 8),
              if (_step < 2)
                FilledButton(
                  onPressed: _busy ? null : () => setState(() => _step++),
                  child: const Text('下一步'),
                )
              else
                FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存模板'),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildScenario(AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: '模板名称')),
        const SizedBox(height: 12),
        TextField(
          controller: _requirement,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: '用途描述（可选）',
            helperText: '描述你想让这个模板的 AI 做什么，生成的提示词会更贴合需求',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        const Text('预置场景一键生成：'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final category in kPromptCategories)
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _generate(category: category),
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: Text(category),
              ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : () => _generate(),
          icon: const Icon(Icons.auto_awesome),
          label: const Text('按用途描述生成系统提示词'),
        ),
        if (_busy) ...[
          const SizedBox(height: 16),
          _BusyPanel(text: _liveText, onStop: _stop, label: '正在生成系统提示词…'),
        ],
      ],
    );
  }

  Widget _buildPrompt(AppState state, String providerId, String model) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'AI 生成/调整使用「应用功能调用模型」：$providerId · ${model.isEmpty ? '(未选模型)' : model}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _system,
          minLines: 6,
          maxLines: 14,
          decoration: const InputDecoration(
            labelText: '系统提示词（{sandbox} 自动替换为会话 sandbox 路径）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (final entry in _quickPolish.entries)
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _refine(entry.value),
                icon: const Icon(Icons.auto_fix_high, size: 16),
                label: Text(entry.key),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _instruction,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'AI 调整要求（例如：加上输出格式约束）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _refine(_instruction.text),
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('按要求调整/润色'),
            ),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: 16),
          _BusyPanel(text: _liveText, onStop: _stop, label: '正在调整系统提示词…'),
        ],
        if (!_busy && _preview.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('AI 调整结果：', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(_preview),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => setState(() {
                  _system.text = _preview;
                  _preview = '';
                }),
                icon: const Icon(Icons.check),
                label: const Text('采用替换'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => setState(() => _preview = ''),
                child: const Text('放弃'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildParams(AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _providerId.isEmpty ? null : _providerId,
          decoration: const InputDecoration(labelText: '提供商'),
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
          key: ValueKey('wizard_model_$_providerId'),
          initialValue: _modelOptions(state).contains(_model.text) ? _model.text : null,
          decoration: const InputDecoration(labelText: '模型（可手动填写模型 ID）'),
          items: [
            for (final model in _modelOptions(state))
              DropdownMenuItem(value: model, child: Text(model)),
          ],
          onChanged: (value) => setState(() => _model.text = value ?? ''),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _model,
          decoration: const InputDecoration(labelText: '或直接填写模型 ID'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<ThinkingSwitch>(
          initialValue: _thinking,
          decoration: const InputDecoration(labelText: '思考开关'),
          items: const [
            DropdownMenuItem(value: ThinkingSwitch.auto, child: Text('auto（默认）')),
            DropdownMenuItem(value: ThinkingSwitch.on, child: Text('on（开启思考）')),
            DropdownMenuItem(value: ThinkingSwitch.off, child: Text('off（关闭思考）')),
          ],
          onChanged: (value) => setState(() => _thinking = value ?? ThinkingSwitch.auto),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('wizard_effort_$_effort'),
          initialValue: _effort,
          decoration: const InputDecoration(labelText: '思考强度（reasoning_effort）'),
          items: [
            for (final value in kReasoningEffortOptions)
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
            DropdownMenuItem(value: ThinkingReplyMode.auto, child: Text('auto（自动识别）')),
            DropdownMenuItem(
              value: ThinkingReplyMode.reasoningContent,
              child: Text('reasoning_content'),
            ),
            DropdownMenuItem(value: ThinkingReplyMode.thinkTag, child: Text('think_tag')),
          ],
          onChanged: (value) => setState(() => _replyMode = value ?? ThinkingReplyMode.auto),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _limit,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '工具调用上限（0=不允许调用工具）'),
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
    );
  }
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.current, required this.onSelect});

  final int current;
  final ValueChanged<int> onSelect;

  static const _labels = ['1 场景需求', '2 系统提示词', '3 模型与参数'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _labels.length; i++) ...[
          if (i > 0) const Expanded(child: Divider(height: 1)),
          ChoiceChip(
            label: Text(_labels[i]),
            selected: current == i,
            onSelected: (_) => onSelect(i),
          ),
        ],
      ],
    );
  }
}

/// Streaming LLM progress panel with a stop button and live text.
class _BusyPanel extends StatelessWidget {
  const _BusyPanel({required this.text, required this.onStop, required this.label});

  final String text;
  final VoidCallback onStop;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.primary),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
              TextButton(onPressed: onStop, child: const Text('停止')),
            ],
          ),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(text, maxLines: 12, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }
}
