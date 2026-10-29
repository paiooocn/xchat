import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ids.dart';
import '../../core/prompt_utils.dart';
import '../../models/project.dart';
import '../../models/provider_config.dart';
import '../../models/session.dart';
import '../../models/session_message.dart';
import '../../models/session_params.dart';
import '../../models/session_template.dart';
import '../../models/task_item.dart';
import '../../state/app_state.dart';
import '../widgets/task_session_view.dart';

/// Creates a session from a single configuration page, optionally seeded from
/// a template. Model/params and tools/budget are inherited from the template
/// (or the global defaults for a blank session); provider, model and the
/// thinking options can be overridden in the "advanced" section. A template
/// never donates its name as the session title — an empty title is auto-named
/// by the session's own model after the first turn.
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

  /// 会话提示词：模板带入或手写的会话级系统提示词。
  final _system = TextEditingController();

  /// 新增提示词：本次会话额外追加的一段提示词。
  final _extra = TextEditingController();

  final _sandbox = TextEditingController();
  final _seedUser = TextEditingController();
  final _seedAssistant = TextEditingController();

  /// 会话模式：普通 / 任务式（任务式需至少一个任务项）。
  SessionKind _kind = SessionKind.normal;

  /// 任务式会话的任务项草稿（创建时写进会话）。
  final List<TaskItem> _draftTasks = <TaskItem>[];
  final _taskTitle = TextEditingController();
  final _taskContent = TextEditingController();

  /// 是否把所选项目的「项目提示词」并入会话系统提示词。
  bool _useProjectPrompt = false;

  /// 是否把项目记忆协议（`.memory/` 索引）注入会话系统提示词。
  ///
  /// 跟随所选项目：项目启用了记忆索引时默认开启，用户可再关掉。
  bool _useMemoryProtocol = false;

  /// Manual model ID field — mirrors [_model] both ways.
  final _modelInput = TextEditingController();
  String? _projectId;

  // Resolved settings (from the template, or the global defaults).
  late String _providerId;
  String _model = '';
  int _limit = 0;
  List<String> _tools = <String>[];
  ThinkingSwitch _thinking = ThinkingSwitch.auto;
  ThinkingReplyMode _replyMode = ThinkingReplyMode.auto;

  /// '' = not sent; otherwise a verbatim `reasoning_effort` value.
  String _effort = '';

  @override
  void initState() {
    super.initState();
    _projectId = widget.initialProjectId;
    _applyDefaults();
    // 带着项目进来时，若该项目有提示词则默认启用。
    final initial = _projectId == null
        ? null
        : context.read<AppState>().projectById(_projectId!);
    _useProjectPrompt = initial?.systemPrompt.trim().isNotEmpty ?? false;
    _useMemoryProtocol = _memoryAvailable(initial);
  }

  /// Whether the project carries a memory index (`.memory/`).
  ///
  /// The project's explicit switch decides; a project that predates the
  /// switch counts as enabled when its `.memory/` directory already exists.
  bool _memoryAvailable(Project? project) {
    if (project == null) return false;
    return context.read<AppState>().isMemoryEnabled(project);
  }

  /// The project currently selected in the project dropdown (null = none).
  Project? get _project => _projectId == null ? null : context.read<AppState>().projectById(_projectId!);

  /// Builds the final system prompt: 会话提示词 / 项目提示词 / 新增提示词,
  /// each non-empty section separated by a `---` line.
  String _composeSystemPrompt() {
    final project = _project;
    return composePromptSections(<String>[
      _system.text,
      if (_useProjectPrompt && project != null) project.systemPrompt,
      _extra.text,
    ]);
  }

  void _applyDefaults() {
    final state = context.read<AppState>();
    _providerId = state.config.currentProviderId;
    final provider = state.providerById(_providerId);
    _model = state.config.currentModel.isNotEmpty
        ? state.config.currentModel
        : (provider.models.isNotEmpty ? provider.models.first : '');
    _modelInput.text = _model;
    _limit = state.config.defaultToolCallsLimit;
    _tools = List<String>.of(state.config.defaultTools);
    _thinking = state.config.defaultParams.thinking;
    _replyMode = ThinkingReplyMode.auto;
    _effort = state.config.defaultParams.reasoningEffort ?? '';
  }

  void _applyTemplate(SessionTemplate template) {
    final state = context.read<AppState>();
    setState(() {
      // 模板名不写入标题：留空则创建后由 LLM 自动命名。
      _template = template;
      _system.text = template.systemPrompt;
      _providerId = template.provider.isNotEmpty ? template.provider : state.config.currentProviderId;
      _model = template.model.isNotEmpty
          ? template.model
          : (state.providerById(_providerId).models.isNotEmpty
              ? state.providerById(_providerId).models.first
              : '');
      _modelInput.text = _model;
      _limit = template.toolCallsLimit;
      _tools = List<String>.of(template.tools);
      _thinking = template.params.thinking;
      _replyMode = template.thinkingReplyMode;
      _effort = template.params.reasoningEffort ?? '';
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _system.dispose();
    _extra.dispose();
    _sandbox.dispose();
    _seedUser.dispose();
    _seedAssistant.dispose();
    _taskTitle.dispose();
    _taskContent.dispose();
    _modelInput.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final state = context.read<AppState>();
    if (_kind == SessionKind.task && _draftTasks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('任务式会话至少需要一个任务项（可新增或批量导入）')),
      );
      return;
    }
    final extras = _seedMessages();
    final params = (_template?.params ?? SessionParams()).copyWith()
      ..thinking = _thinking
      ..reasoningEffort = _effort.isEmpty ? null : _effort;
    final session = await state.createSession(
      title: _title.text.trim(),
      providerId: _providerId,
      model: _model,
      systemPrompt: _composeSystemPrompt(),
      tools: _tools,
      toolCallsLimit: _limit,
      thinkingReplyMode: _replyMode,
      tags: _template != null ? List<String>.of(_template!.tags) : null,
      params: params,
      projectId: _projectId,
      sandbox: _sandbox.text.trim(),
      extraMessages: extras.isEmpty ? null : extras,
      useMemoryProtocol: _useMemoryProtocol,
      kind: _kind,
      tasks: _kind == SessionKind.task ? List<TaskItem>.of(_draftTasks) : null,
    );
    // 标题留空时，会在第一轮对话结束后由会话模型自动命名。
    if (mounted) Navigator.of(context).pop(session);
  }

  /// Adds one task item from the two draft fields.
  void _addDraftTask() {
    final title = _taskTitle.text.trim();
    final content = _taskContent.text.trim();
    if (title.isEmpty && content.isEmpty) return;
    setState(() {
      _draftTasks.add(TaskItem(
        id: newShortId(),
        title: title,
        content: content,
      ));
      _taskTitle.clear();
      _taskContent.clear();
    });
  }

  /// Batch import from Markdown (`## 标题` sections).
  Future<void> _importDraftTasks() async {
    final imported = await showTaskImportDialog(context);
    if (imported == null || imported.isEmpty || !mounted) return;
    setState(() => _draftTasks.addAll(imported));
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

  /// 思考强度候选值：服务开了「同步思考强度」就用同步档位，否则用完整候选
  /// 列表；已选的值不在候选里时保留一项，避免下拉框找不到当前值。
  List<String> _effortOptions(AppState state) {
    final values = reasoningEffortOptionsFor(
      state.config.providerById(_providerId),
      _model.trim(),
    );
    return <String>[
      '',
      ...values,
      if (_effort.isNotEmpty && !values.contains(_effort)) _effort,
    ];
  }

  /// Sets the model (and keeps the manual input field in sync).
  void _setModel(String value) {
    setState(() {
      _model = value;
      if (_modelInput.text != value) _modelInput.text = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // The provider may no longer offer the configured model (catalogue
    // changed): keep it as an extra entry so the dropdown value always
    // matches exactly one item.
    final providerModels = state.providerById(_providerId).models;
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
          _SectionLabel(
            label: '会话模式',
            hint: '任务式会话打开后先显示任务列表，点进某一项后才是对话；'
                '发给模型的历史仍是整个会话。',
          ),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('普通会话'),
                selected: _kind == SessionKind.normal,
                onSelected: (_) => setState(() => _kind = SessionKind.normal),
              ),
              ChoiceChip(
                label: const Text('任务式会话'),
                selected: _kind == SessionKind.task,
                onSelected: (_) => setState(() => _kind = SessionKind.task),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: '标题',
              helperText: '留空则在第一轮对话结束后由会话模型自动命名；标签可在会话的「更多」菜单中设置',
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
                if (project != null) {
                  _sandbox.text = project.sandbox;
                  // 选了带提示词的项目就默认启用，用户可再关掉。
                  _useProjectPrompt = project.systemPrompt.trim().isNotEmpty;
                  // 记忆协议跟随项目的记忆开关。
                  _useMemoryProtocol = _memoryAvailable(project);
                }
              } else {
                _useProjectPrompt = false;
                _useMemoryProtocol = false;
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
          if (_kind == SessionKind.task) ...[
            const SizedBox(height: 16),
            _TaskDraftSection(
              tasks: _draftTasks,
              titleController: _taskTitle,
              contentController: _taskContent,
              onImport: _importDraftTasks,
              onAdd: _addDraftTask,
              onRemove: (index) => setState(() => _draftTasks.removeAt(index)),
            ),
          ],
          const SizedBox(height: 12),
          _PromptSection(
            label: '① 会话提示词',
            hint: '模板带入或手写的会话级提示词（顶行自动写入 工作空间根目录: <sandbox 绝对路径>）',
            child: TextField(
              controller: _system,
              minLines: 4,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: '会话提示词',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _ProjectPromptSection(
            project: _project,
            enabled: _useProjectPrompt,
            onChanged: (value) => setState(() => _useProjectPrompt = value),
          ),
          const SizedBox(height: 12),
          _PromptSection(
            label: '③ 新增提示词',
            hint: '本次会话额外追加的一段提示词（排在最后）',
            child: TextField(
              controller: _extra,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '新增提示词（可选）',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _MemoryPromptSection(
            project: _project,
            enabled: _useMemoryProtocol,
            onChanged: (value) => setState(() => _useMemoryProtocol = value),
          ),
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('高级：提供商、模型与思考设置'),
            subtitle: Text(
              '$_providerId · ${_model.isEmpty ? '(未选模型)' : _model} · '
              '思考=${_thinking.name}${_effort.isEmpty ? '' : ' · 强度=$_effort'}',
            ),
            childrenPadding: const EdgeInsets.only(top: 4),
            children: [
              DropdownButtonFormField<String>(
                initialValue:
                    state.config.providers.any((p) => p.id == _providerId)
                        ? _providerId
                        : null,
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
                    _modelInput.text = _model;
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
                  for (final model in providerModels)
                    DropdownMenuItem(value: model, child: Text(model)),
                  if (_model.isNotEmpty && !providerModels.contains(_model))
                    DropdownMenuItem(
                      value: _model,
                      child: Text('$_model（不在列表中）'),
                    ),
                ],
                onChanged: (value) => _setModel(value ?? ''),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _modelInput,
                decoration: const InputDecoration(labelText: '或直接填写模型 ID'),
                onChanged: (value) => _setModel(value.trim()),
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
                onChanged: (value) =>
                    setState(() => _thinking = value ?? ThinkingSwitch.auto),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('wizard_effort_$_effort'),
                initialValue:
                    _effortOptions(state).contains(_effort) ? _effort : null,
                decoration: const InputDecoration(labelText: '思考强度'),
                items: [
                  for (final value in _effortOptions(state))
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
                onChanged: (value) =>
                    setState(() => _replyMode = value ?? ThinkingReplyMode.auto),
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
            '模型与参数、工具与预算均沿用模板（或全局默认）配置，'
            '提供商、模型与思考设置可在上方「高级」中调整。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// 任务式会话的「任务项」小节：草稿列表 + 批量导入 + 逐项新增。
///
/// 单独抽成 widget，是为了把「新建任务项」放在「工作目录」之后（任务项与生成
/// 方式无关，属于会话内容的一部分）。
class _TaskDraftSection extends StatelessWidget {
  const _TaskDraftSection({
    required this.tasks,
    required this.titleController,
    required this.contentController,
    required this.onImport,
    required this.onAdd,
    required this.onRemove,
  });

  final List<TaskItem> tasks;
  final TextEditingController titleController;
  final TextEditingController contentController;
  final VoidCallback onImport;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '任务项（${tasks.length}）',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.playlist_add, size: 18),
              label: const Text('批量导入（## 标题分段）'),
            ),
          ],
        ),
        Text(
          '每个任务项进入后各自一段对话；发给模型的历史仍是整个会话。',
          style: theme.textTheme.bodySmall,
        ),
        for (var i = 0; i < tasks.length; i++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Text('${i + 1}'),
            title: Text(
              tasks[i].displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: tasks[i].content.isEmpty
                ? null
                : Text(
                    tasks[i].content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: IconButton(
              tooltip: '移除',
              iconSize: 18,
              onPressed: () => onRemove(i),
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ),
        TextField(
          controller: titleController,
          decoration: const InputDecoration(
            labelText: '任务标题（留空则用内容首行）',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: contentController,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: '任务内容（开始该任务时作为第一条 user 消息）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加任务项'),
          ),
        ),
      ],
    );
  }
}

/// A titled block without a child input (会话模式 etc.).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.hint});

  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(hint, style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
      ],
    );
  }
}

/// A titled block holding one prompt section (会话提示词 / 新增提示词).
class _PromptSection extends StatelessWidget {
  const _PromptSection({
    required this.label,
    required this.hint,
    required this.child,
  });

  final String label;
  final String hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(hint, style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// The 「启用项目提示词」 switch: it folds the selected project's own prompt
/// into the session's system prompt. Disabled when no project is selected or
/// the project has no prompt yet (the prompt is edited in the project panel).
class _ProjectPromptSection extends StatelessWidget {
  const _ProjectPromptSection({
    required this.project,
    required this.enabled,
    required this.onChanged,
  });

  /// The selected project (null = the session belongs to no project).
  final Project? project;

  /// Whether the project prompt is currently folded into the session prompt.
  final bool enabled;

  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prompt = project?.systemPrompt.trim() ?? '';
    final hasPrompt = prompt.isNotEmpty;
    final subtitle = project == null
        ? '未选择项目；项目提示词在「项目编辑面板」中维护'
        : (hasPrompt
            ? '将项目「${project!.name.isEmpty ? project!.id : project!.name}」的提示词并入会话提示词'
            : '该项目尚未设置提示词，可在「项目编辑面板」中补充');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '② 项目提示词',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: theme.textTheme.bodySmall),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: enabled && hasPrompt,
          onChanged: hasPrompt ? onChanged : null,
          title: const Text('启用项目提示词'),
        ),
        if (hasPrompt)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.dividerColor),
            ),
            child: SelectableText(
              prompt,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
      ],
    );
  }
}

/// The 「④ 项目记忆协议」 switch: it injects the project memory protocol
/// (`.memory/` index) into the session's system prompt, so the agent reads
/// and maintains the index across sessions.
///
/// Disabled when no project is selected or the project has no memory index.
class _MemoryPromptSection extends StatelessWidget {
  const _MemoryPromptSection({
    required this.project,
    required this.enabled,
    required this.onChanged,
  });

  /// The selected project (null = the session belongs to no project).
  final Project? project;

  /// Whether the memory protocol is currently injected.
  final bool enabled;

  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = project != null;
    final subtitle = project == null
        ? '未选择项目；记忆索引属于项目，会话需先加入项目'
        : '会话开始时注入记忆协议，agent 会读写 ${project!.sandbox}/.memory'
            '（README / STATE / ARCHITECTURE / GOTCHAS / MAP / PROMPT）';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '④ 项目记忆协议',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: theme.textTheme.bodySmall),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: enabled && available,
          onChanged: available ? onChanged : null,
          title: const Text('启用项目记忆协议'),
        ),
      ],
    );
  }
}
