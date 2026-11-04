import 'package:flutter/material.dart';
import 'package:llm_api/llm_api.dart' as llm;
import 'package:provider/provider.dart';

import '../../llm/note_assistant.dart';
import '../../state/app_state.dart';
import '../pages/providers_page.dart';

/// One message of the AI conversation.
class NoteAiMessage {
  NoteAiMessage({
    required this.role,
    required this.text,
    this.error = false,
    this.action,
  });

  /// `user` or `assistant`.
  final String role;
  final String text;
  final bool error;

  /// The action that produced this message (assistant messages).
  final NoteAiAction? action;
}

/// The AI side bar of the note page.
///
/// Two states: expanded (320px, conversation) and collapsed (a 44px rail with
/// an icon and a "生成中" badge). While a request is running the panel can
/// **not** be collapsed.
class NoteAiPanel extends StatefulWidget {
  const NoteAiPanel({
    super.key,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.body,
    required this.selection,
    required this.title,
    required this.onApply,
    required this.onBusyChanged,
    this.sheet = false,
    this.locked = false,
    this.scrollController,
  });

  /// Renders as the content of the mobile bottom sheet: fills the width,
  /// shows a close button instead of the collapse button.
  final bool sheet;

  /// The AI panel is pinned to the rail (window too narrow to expand it).
  final bool locked;

  /// Scroll controller handed in by the bottom sheet (drag to resize).
  final ScrollController? scrollController;

  /// Whether the panel is collapsed to the rail.
  final bool collapsed;

  /// Collapses / expands the panel (ignored while a request is running).
  final VoidCallback onToggleCollapsed;

  /// The current note body (context for the model).
  final String body;

  /// The current selection (empty when nothing is selected).
  final String selection;

  /// The note title (mentioned in the system prompt).
  final String title;

  /// Applies an AI result to the note (the caller shows the diff first).
  final Future<void> Function(String text, NoteAiTarget target) onApply;

  /// Notifies the owner that a request started/ended.
  final ValueChanged<bool> onBusyChanged;

  @override
  State<NoteAiPanel> createState() => _NoteAiPanelState();
}

class _NoteAiPanelState extends State<NoteAiPanel> {
  final List<NoteAiMessage> _messages = <NoteAiMessage>[];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  NoteAiMode _mode = NoteAiMode.rewrite;
  bool _busy = false;
  bool _includeFull = true;
  llm.CancelToken? _cancel;

  @override
  void dispose() {
    _cancel?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<NoteAiAction> get _actions =>
      kNoteAiActions.where((a) => a.mode == _mode).toList();

  bool get _hasSelection => widget.selection.trim().isNotEmpty;

  /// The list's scroll controller (the sheet's one while inside the sheet).
  ScrollController get _listScroll => widget.scrollController ?? _scroll;

  void _scrollToEnd() {
    final scroll = _listScroll;
    if (!scroll.hasClients) return;
    scroll.animateTo(
      scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _run(NoteAiAction action, {String? extra}) async {
    if (_busy) return;
    final state = context.read<AppState>();
    final (provider, model) = state.appFeatureTarget;
    if (!isProviderConfigured(provider)) {
      setState(() {
        _messages.add(NoteAiMessage(
          role: 'assistant',
          text: '还没有配置模型服务。请先在「模型服务」里选一个服务商与模型。',
          error: true,
        ));
      });
      _scrollToEnd();
      return;
    }
    if (action.mode == NoteAiMode.rewrite && !_hasSelection) {
      setState(() {
        _messages.add(NoteAiMessage(
          role: 'assistant',
          text: '改写需要先选中一段文字。',
          error: true,
        ));
      });
      _scrollToEnd();
      return;
    }

    final instruction =
        extra == null || extra.trim().isEmpty ? action.instruction : '${action.instruction}\n补充要求：${extra.trim()}';

    final context_ = buildNoteContext(
      body: widget.body,
      charLimit: state.config.notesContextCharLimit,
      selection: widget.selection,
      instruction: instruction,
      forceFull: _includeFull,
    );
    final userPrompt = buildNoteUserPrompt(
      context: context_,
      instruction: instruction,
      selection: widget.selection,
    );

    setState(() {
      _busy = true;
      _messages.add(NoteAiMessage(role: 'user', text: instruction));
      _messages.add(NoteAiMessage(role: 'assistant', text: ''));
    });
    widget.onBusyChanged(true);
    _scrollToEnd();

    final token = llm.CancelToken();
    _cancel = token;
    try {
      final result = await runNoteAssistant(
        provider: provider,
        model: model,
        systemPrompt: buildNoteSystemPrompt(title: widget.title),
        userPrompt: userPrompt,
        temperature: action.temperature,
        onProgress: (partial) {
          if (!mounted) return;
          setState(() {
            if (_messages.isNotEmpty) {
              _messages[_messages.length - 1] =
                  NoteAiMessage(role: 'assistant', text: partial);
            }
          });
        },
        cancel: token,
      );
      if (!mounted) return;
      setState(() {
        _messages[_messages.length - 1] =
            NoteAiMessage(role: 'assistant', text: result, action: action);
      });
      await widget.onApply(result, action.target);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _messages[_messages.length - 1] = NoteAiMessage(
          role: 'assistant',
          text: '调用失败：$error',
          error: true,
          action: action,
        );
      });
    } finally {
      _cancel = null;
      if (mounted) {
        setState(() => _busy = false);
        widget.onBusyChanged(false);
      }
    }
  }

  Future<void> _ask(String question) async {
    if (question.trim().isEmpty) return;
    final action = const NoteAiAction(
      id: 'ask',
      label: '问答',
      mode: NoteAiMode.ask,
      target: NoteAiTarget.copy,
      instruction: '基于笔记内容回答问题，只读，不要改写笔记。',
      temperature: 0.2,
    );
    await _run(action, extra: question);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.collapsed) return _collapsedRail(context);
    return _expanded(context);
  }

  Widget _collapsedRail(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 44,
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                tooltip: widget.locked ? '窗口太窄，AI 边栏已收起' : '展开 AI 助手',
                iconSize: 20,
                icon: const Icon(Icons.auto_awesome_outlined),
                onPressed: widget.locked ? null : widget.onToggleCollapsed,
              ),
              if (_busy)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          Expanded(
            child: Center(
              child: RotatedBox(
                quarterTurns: 3,
                child: Text(
                  'AI 助手',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _expanded(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final (provider, model) = state.appFeatureTarget;
    return Container(
      width: widget.sheet ? double.infinity : 320,
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          // ---- 顶行：模型 + 收起 ---------------------------------------
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    provider.name.isEmpty ? '未配置模型' : '${provider.name} · $model',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
                IconButton(
                  tooltip: '模型服务',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ProvidersPage()),
                  ),
                ),
                if (widget.sheet)
                  IconButton(
                    tooltip: '关闭 AI 助手',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    onPressed: widget.onToggleCollapsed,
                  )
                else
                  IconButton(
                    tooltip: _busy ? '生成中，不能收起' : '收起 AI 助手',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.keyboard_double_arrow_right),
                    onPressed: _busy ? null : widget.onToggleCollapsed,
                  ),
              ],
            ),
          ),
          // ---- Tab：改写 / 生成 / 问答 ---------------------------------
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SegmentedButton<NoteAiMode>(
              segments: const [
                ButtonSegment(value: NoteAiMode.rewrite, label: Text('改写')),
                ButtonSegment(value: NoteAiMode.generate, label: Text('生成')),
                ButtonSegment(value: NoteAiMode.ask, label: Text('问答')),
              ],
              selected: <NoteAiMode>{_mode},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (selection) =>
                  setState(() => _mode = selection.first),
            ),
          ),
          // ---- 快捷动作 -----------------------------------------------
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: [
                for (final action in _actions)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(action.label, style: theme.textTheme.labelSmall),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onPressed: _busy ? null : () => _run(action),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // ---- 对话流 --------------------------------------------------
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _mode == NoteAiMode.rewrite
                            ? '选中一段文字，再点上面的动作。'
                            : _mode == NoteAiMode.generate
                                ? '选一个生成动作，结果会先进 diff 预览。'
                                : '问点什么，助手只会读笔记、不改笔记。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _listScroll,
                    padding: const EdgeInsets.all(8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      return _bubble(context, message);
                    },
                  ),
          ),
          const Divider(height: 1),
          // ---- 输入区 --------------------------------------------------
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '包含全文',
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                    Switch(
                      value: _includeFull,
                      onChanged: (value) => setState(() => _includeFull = value),
                    ),
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        style: theme.textTheme.bodySmall,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: _mode == NoteAiMode.ask ? '问点什么…' : '补充要求（可空）',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: theme.colorScheme.surface,
                        ),
                        onSubmitted: (value) {
                          if (_mode == NoteAiMode.ask) {
                            _ask(value);
                            _input.clear();
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (_busy)
                      IconButton(
                        tooltip: '停止',
                        icon: const Icon(Icons.stop_circle_outlined),
                        onPressed: () {
                          _cancel?.cancel();
                        },
                      )
                    else
                      IconButton.filled(
                        tooltip: _mode == NoteAiMode.ask ? '提问' : '发送',
                        iconSize: 18,
                        style: IconButton.styleFrom(
                          // 同侧栏「＋新建」：filled 底色是 primary，图标必须用
                          // onPrimary，否则被 iconTheme 的 onSurfaceVariant 盖掉。
                          foregroundColor: theme.colorScheme.onPrimary,
                          backgroundColor: theme.colorScheme.primary,
                        ),
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: () {
                          final value = _input.text;
                          if (_mode == NoteAiMode.ask) {
                            _ask(value);
                            _input.clear();
                            return;
                          }
                          final action = _actions.isNotEmpty
                              ? _actions.first
                              : const NoteAiAction(
                                  id: 'rewrite',
                                  label: '改写',
                                  mode: NoteAiMode.rewrite,
                                  target: NoteAiTarget.replaceSelection,
                                  instruction: '改写选区。',
                                );
                          _run(action, extra: value);
                          _input.clear();
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, NoteAiMessage message) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : message.error
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.action != null)
              Text(
                message.action!.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Text(
              message.text.isEmpty ? '…' : message.text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: message.error ? theme.colorScheme.onErrorContainer : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
