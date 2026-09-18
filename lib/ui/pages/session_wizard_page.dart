import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ids.dart';
import '../../models/session_message.dart';
import '../../models/session_params.dart';
import '../../models/session_template.dart';
import '../../state/app_state.dart';

/// Creates a session from a single configuration page, optionally seeded from
/// a template. Model/params and tools/budget are inherited from the template
/// (or the global defaults for a blank session) and are not adjusted here.
class SessionWizardPage extends StatefulWidget {
  const SessionWizardPage({super.key, this.initialProjectId});

  /// Pre-selected project (its sandbox is inherited by the new session).
  final String? initialProjectId;

  @override
  State<SessionWizardPage> createState() => _SessionWizardPageState();
}

class _SessionWizardPageState extends State<SessionWizardPage> {
  SessionTemplate? _template;
  final _title = TextEditingController();
  final _system = TextEditingController();
  final _sandbox = TextEditingController();
  final _seedUser = TextEditingController();
  final _seedAssistant = TextEditingController();
  String? _projectId;

  // Resolved settings (from the template, or the global defaults).
  late String _providerId;
  String _model = '';
  int _limit = 0;
  List<String> _tools = <String>[];
  ThinkingSwitch _thinking = ThinkingSwitch.auto;
  ThinkingReplyMode _replyMode = ThinkingReplyMode.auto;

  @override
  void initState() {
    super.initState();
    _projectId = widget.initialProjectId;
    _applyDefaults();
  }

  void _applyDefaults() {
    final state = context.read<AppState>();
    _providerId = state.config.currentProviderId;
    final provider = state.providerById(_providerId);
    _model = state.config.currentModel.isNotEmpty
        ? state.config.currentModel
        : (provider.models.isNotEmpty ? provider.models.first : '');
    _limit = state.config.defaultToolCallsLimit;
    _tools = List<String>.of(state.config.defaultTools);
    _thinking = state.config.defaultParams.thinking;
    _replyMode = ThinkingReplyMode.auto;
  }

  void _applyTemplate(SessionTemplate template) {
    final state = context.read<AppState>();
    setState(() {
      _template = template;
      _title.text = template.name;
      _system.text = template.systemPrompt;
      _providerId = template.provider.isNotEmpty ? template.provider : state.config.currentProviderId;
      _model = template.model.isNotEmpty
          ? template.model
          : (state.providerById(_providerId).models.isNotEmpty
              ? state.providerById(_providerId).models.first
              : '');
      _limit = template.toolCallsLimit;
      _tools = List<String>.of(template.tools);
      _thinking = template.params.thinking;
      _replyMode = template.thinkingReplyMode;
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _system.dispose();
    _sandbox.dispose();
    _seedUser.dispose();
    _seedAssistant.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final state = context.read<AppState>();
    final extras = _seedMessages();
    final session = await state.createSession(
      title: _title.text.trim(),
      providerId: _providerId,
      model: _model,
      systemPrompt: _system.text,
      tools: _tools,
      toolCallsLimit: _limit,
      thinkingReplyMode: _replyMode,
      tags: _template != null ? List<String>.of(_template!.tags) : null,
      params: (_template?.params ?? SessionParams())..thinking = _thinking,
      projectId: _projectId,
      sandbox: _sandbox.text.trim(),
      extraMessages: extras.isEmpty ? null : extras,
    );
    if (mounted) Navigator.of(context).pop(session);
  }

  /// Builds the optional pre-seeded first turn. The assistant entry is only
  /// inserted when a user entry exists (a dangling assistant is invalid).
  List<SessionMessage> _seedMessages() {
    final user = _seedUser.text.trim();
    if (user.isEmpty) return const <SessionMessage>[];
    final assistant = _seedAssistant.text.trim();
    return <SessionMessage>[
      SessionMessage(role: MessageRole.user, id: newShortId(), content: user),
      if (assistant.isNotEmpty)
        SessionMessage(role: MessageRole.assistant, id: newShortId(), content: assistant),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('新建会话')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('起点：空白会话，或从模板创建'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('空白'),
                selected: _template == null,
                onSelected: (_) => setState(() {
                  _template = null;
                  _title.text = '';
                  _system.text = '';
                  _seedUser.clear();
                  _seedAssistant.clear();
                  _applyDefaults();
                }),
              ),
              for (final template in state.templates)
                ChoiceChip(
                  label: Text(template.name.isEmpty ? '(未命名模板)' : template.name),
                  selected: _template?.id == template.id,
                  onSelected: (_) => _applyTemplate(template),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: '标题',
              helperText: '标签可在会话的「更多」菜单中设置',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _projectId,
            decoration: const InputDecoration(labelText: '所属项目（可选）'),
            items: [
              const DropdownMenuItem(value: null, child: Text('不加入项目')),
              for (final project in state.projects)
                DropdownMenuItem(
                  value: project.id,
                  child: Text(project.name.isEmpty ? '(未命名项目)' : project.name),
                ),
            ],
            onChanged: (value) => setState(() {
              _projectId = value;
              if (value != null) {
                final project = state.projectById(value);
                if (project != null) _sandbox.text = project.sandbox;
              }
            }),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _sandbox,
            decoration: const InputDecoration(
              labelText: '工作目录 sandbox（留空=默认 sandboxs/<会话id> 或项目目录）',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _system,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: '系统提示词（{sandbox} 自动替换为会话 sandbox 路径）',
            ),
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('高级：重新选择提供商和模型'),
            subtitle: Text('$_providerId · ${_model.isEmpty ? '(未选模型)' : _model}'),
            childrenPadding: const EdgeInsets.only(top: 4),
            children: [
              DropdownButtonFormField<String>(
                initialValue: _providerId,
                decoration: const InputDecoration(labelText: '提供商'),
                items: [
                  for (final provider in state.config.providers)
                    DropdownMenuItem(
                      value: provider.id,
                      child: Text(provider.name.isEmpty ? provider.id : provider.name),
                    ),
                ],
                onChanged: (value) {
                  if (value == null || value == _providerId) return;
                  final provider = state.providerById(value);
                  setState(() {
                    _providerId = value;
                    _model = provider.models.isNotEmpty ? provider.models.first : '';
                  });
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _model.isNotEmpty ? _model : null,
                decoration: const InputDecoration(
                  labelText: '模型',
                  helperText: '可手动输入不在列表中的模型',
                ),
                items: [
                  for (final model in state.providerById(_providerId).models)
                    DropdownMenuItem(value: model, child: Text(model)),
                ],
                onChanged: (value) => setState(() => _model = value ?? ''),
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(labelText: '或直接填写模型 ID'),
                onSubmitted: (value) {
                  if (value.trim().isNotEmpty) setState(() => _model = value.trim());
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('高级：预置首轮对话（可选）'),
            subtitle: const Text('预先插入一对 user / assistant 消息作为上下文起点'),
            childrenPadding: const EdgeInsets.only(top: 4),
            children: [
              TextField(
                controller: _seedUser,
                minLines: 3,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: '预设用户消息（留空则不插入）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _seedAssistant,
                minLines: 3,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: '预设助手回复（需先填写用户消息）',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _finish, child: const Text('创建')),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(height: 12),
          Text(
            '模型与参数、工具与预算均沿用模板（或全局默认）配置。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
