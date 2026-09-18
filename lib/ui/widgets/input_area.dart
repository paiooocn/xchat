import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/agent_mode.dart';
/// Intent: send the current text.
class _SendIntent extends Intent {
  const _SendIntent();
}

/// Intent: insert a newline at the cursor.
class _NewlineIntent extends Intent {
  const _NewlineIntent();
}

/// Bottom input area with send / stop.
///
/// Enter sends; Ctrl+Enter (or Shift+Enter / Alt+Enter) inserts a newline.
class InputArea extends StatefulWidget {
  const InputArea({
    super.key,
    required this.onSend,
    required this.onStop,
    required this.running,
    this.mode = AgentMode.normal,
    this.onModeChanged,
    this.webSearchAvailable = false,
    this.webSearchEnabled = true,
    this.onWebSearchChanged,
    this.onCompress,
    this.hint = 'Enter 发送，Ctrl+Enter 换行',
  });

  final void Function(String text) onSend;
  final VoidCallback onStop;
  final bool running;
  final AgentMode mode;
  final ValueChanged<AgentMode>? onModeChanged;

  /// Whether the session can use `web_search` (i.e. it is among its tools).
  final bool webSearchAvailable;

  /// Whether `web_search` will be included in the next request.
  final bool webSearchEnabled;
  final ValueChanged<bool>? onWebSearchChanged;

  /// Optional "compress session" action shown next to 发送.
  final VoidCallback? onCompress;
  final String hint;

  @override
  State<InputArea> createState() => _InputAreaState();
}

class _InputAreaState extends State<InputArea> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.running) return;
    _controller.clear();
    widget.onSend(text);
    _focus.requestFocus();
  }

  void _insertNewline() {
    final value = _controller.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final updated = text.replaceRange(start, end, '\n');
    _controller.value = value.copyWith(
      text: updated,
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
              SingleActivator(LogicalKeyboardKey.numpadEnter): _SendIntent(),
              SingleActivator(LogicalKeyboardKey.enter, control: true): _NewlineIntent(),
              SingleActivator(LogicalKeyboardKey.enter, shift: true): _NewlineIntent(),
              SingleActivator(LogicalKeyboardKey.enter, alt: true): _NewlineIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _SendIntent: CallbackAction<_SendIntent>(
                  onInvoke: (_) {
                    _send();
                    return null;
                  },
                ),
                _NewlineIntent: CallbackAction<_NewlineIntent>(
                  onInvoke: (_) {
                    _insertNewline();
                    return null;
                  },
                ),
              },
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                minLines: 1,
                maxLines: 8,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              PopupMenuButton<AgentMode>(
                tooltip: '执行模式',
                onSelected: (value) => widget.onModeChanged?.call(value),
                itemBuilder: (context) => [
                  for (final value in AgentMode.values)
                    CheckedPopupMenuItem(
                      value: value,
                      checked: value == widget.mode,
                      child: Text(value.label),
                    ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.tune, size: 16),
                      const SizedBox(width: 4),
                      Text(widget.mode.label),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (widget.webSearchAvailable)
                FilterChip(
                  avatar: Icon(
                    Icons.travel_explore,
                    size: 16,
                    color: widget.webSearchEnabled ? null : theme.disabledColor,
                  ),
                  label: const Text('联网'),
                  selected: widget.webSearchEnabled,
                  onSelected: (value) => widget.onWebSearchChanged?.call(value),
                  tooltip: '是否在本轮请求中携带 web_search 工具',
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              const Spacer(),
              if (widget.onCompress != null)
                IconButton(
                  onPressed: widget.running ? null : widget.onCompress,
                  tooltip: '压缩会话',
                  icon: const Icon(Icons.compress),
                ),
              if (widget.running)
                IconButton.filledTonal(
                  onPressed: widget.onStop,
                  tooltip: '停止',
                  icon: const Icon(Icons.stop),
                )
              else
                IconButton.filled(
                  onPressed: _send,
                  tooltip: '发送',
                  icon: const Icon(Icons.send),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
