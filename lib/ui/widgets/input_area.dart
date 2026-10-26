import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/agent_mode.dart';
import '../../models/app_config.dart';
import '../../models/message_attachment.dart';
import '../theme/app_theme.dart';
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
/// On desktop: Enter sends; Ctrl+Enter (or Shift+Enter / Alt+Enter) inserts a
/// newline. On Android/iOS: Enter always inserts a newline and the message is
/// sent only via the [发送] button.
///
/// The widget is a self-contained card: the text field sits on top, and the
/// toolbar (attach / mode / web search / model / send) lives on a single row
/// underneath — the same layout as the reference UI.
class InputArea extends StatefulWidget {
  const InputArea({
    super.key,
    required this.onSend,
    required this.onStop,
    required this.running,
    this.mode = AgentMode.auto,
    this.onModeChanged,
    this.webSearchAvailable = false,
    this.webSearchEnabled = true,
    this.onWebSearchChanged,
    this.onCompress,
    this.onScrollToRecent,
    this.onScrollToBottom,
    this.maxAttachmentBytes = kDefaultMaxAttachmentBytes,
    this.hint = 'Enter 发送，Ctrl+Enter 换行',
    this.header,
    this.trailing,
    this.afterMode,
    this.onTextChanged,
    this.compact = false,
  });

  /// Sends the message. Returns false when the message was *not* accepted
  /// (e.g. the welcome view still needs a session template): the draft text
  /// and the staged attachments are then kept so the user can retry.
  final bool Function(String text, List<MessageAttachment> attachments) onSend;
  final VoidCallback onStop;
  final bool running;
  final AgentMode mode;
  final ValueChanged<AgentMode>? onModeChanged;

  /// Whether the session can use `web_search` (i.e. it is among its tools).
  final bool webSearchAvailable;

  /// Whether `web_search` will be included in the next request.
  final bool webSearchEnabled;
  final ValueChanged<bool>? onWebSearchChanged;

  /// Optional "compress session" action shown in the toolbar.
  final VoidCallback? onCompress;

  /// Optional scroll-to-recent-message action shown in the toolbar.
  final VoidCallback? onScrollToRecent;

  /// Optional scroll-to-bottom action shown in the toolbar.
  final VoidCallback? onScrollToBottom;

  /// Per-image transfer cap; 0 = no limit (see `AppConfig.maxAttachmentBytes`).
  final int maxAttachmentBytes;

  final String hint;

  /// Optional context row rendered above the text field (e.g. project chip).
  final Widget? header;

  /// Optional widget rendered at the right end of the toolbar (e.g. model
  /// selector).
  final Widget? trailing;

  /// Widget rendered right after the mode pill (e.g. a template picker).
  final Widget? afterMode;

  /// Reports the current draft text (e.g. so the welcome view can send it
  /// together with a picked template).
  final ValueChanged<String>? onTextChanged;

  /// Renders the card without the drop shadow (used inside the welcome view).
  final bool compact;

  @override
  State<InputArea> createState() => _InputAreaState();
}

class _InputAreaState extends State<InputArea> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// Files staged for the next send. Cleared once the message is handed off.
  final List<MessageAttachment> _pending = <MessageAttachment>[];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    // Only the send button's enabled state depends on the text; rebuild it
    // without rebuilding the whole card.
    widget.onTextChanged?.call(_controller.text);
    setState(() {});
  }

  bool get _canSend =>
      !widget.running &&
      (_controller.text.trim().isNotEmpty || _pending.isNotEmpty);

  void _send() {
    final text = _controller.text.trim();
    if (widget.running) return;
    if (text.isEmpty && _pending.isEmpty) return;
    final files = List<MessageAttachment>.of(_pending);
    // The message is only cleared when it is actually accepted: a rejected
    // send (missing session template) keeps the draft for a retry.
    final accepted = widget.onSend(text, files);
    if (!accepted) return;
    _controller.clear();
    setState(_pending.clear);
    _focus.requestFocus();
  }

  /// Opens the system picker and stages whatever comes back.
  Future<void> _pickImages() async {
    const extensions = <String>['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'];
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
      );
      if (files.isEmpty) return;
      final staged = <MessageAttachment>[];
      final rejected = <String>[];
      final oversized = <String>[];
      for (final file in files) {
        final path = file.path;
        if (path == null) {
          rejected.add(file.name);
          continue;
        }
        final attachment = MessageAttachment.fromFile(path, name: file.name);
        if (attachment == null) {
          rejected.add(file.name);
          continue;
        }
        // Images go out base64-inline; an oversized one is a transport
        // problem, so refuse it here rather than letting the request fail.
        final cap = widget.maxAttachmentBytes;
        final size = await File(path).length();
        if (cap > 0 && size > cap) {
          oversized.add(file.name);
          continue;
        }
        staged.add(attachment);
      }
      if (!mounted) return;
      setState(() => _pending.addAll(staged));
      final notes = <String>[
        if (rejected.isNotEmpty) '已忽略不支持的文件：${rejected.join('、')}',
        if (oversized.isNotEmpty)
          '已忽略超过体积上限的文件：${oversized.join('、')}'
              '（上限 ${(widget.maxAttachmentBytes / (1024 * 1024)).toStringAsFixed(0)} MB，'
              '可在设置中调整）',
      ];
      if (notes.isNotEmpty) _toast(notes.join('\n'));
    } catch (error) {
      if (mounted) _toast('选择文件失败：$error');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  void _removePending(MessageAttachment attachment) {
    setState(() => _pending.remove(attachment));
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
    final scheme = theme.colorScheme;
    // Enter-to-send is a desktop affordance only: on touch devices the
    // on-screen keyboard's Enter must insert a newline; sending goes through
    // the [发送] button.
    final isTouchPlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final hint = isTouchPlatform ? '点击 [发送] 按钮发送，Enter 换行' : widget.hint;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: widget.compact
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.35 : 0.06,
                  ),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: widget.header,
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              widget.header == null ? 14 : 6,
              16,
              6,
            ),
            child: Shortcuts(
              shortcuts: <ShortcutActivator, Intent>{
                if (!isTouchPlatform) ...<ShortcutActivator, Intent>{
                  const SingleActivator(LogicalKeyboardKey.enter): const _SendIntent(),
                  const SingleActivator(LogicalKeyboardKey.numpadEnter):
                      const _SendIntent(),
                },
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    const _NewlineIntent(),
                const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                    const _NewlineIntent(),
                const SingleActivator(LogicalKeyboardKey.enter, alt: true):
                    const _NewlineIntent(),
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
                    hintText: hint,
                    filled: false,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Staged attachments: they ride along with the next message and are
          // deliberately kept out of the text controller.
          if (_pending.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
              child: SizedBox(
                height: 72,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _pending.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final file = _pending[index];
                    return InputChip(
                      avatar: const Icon(Icons.image, size: 18),
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(file.name, overflow: TextOverflow.ellipsis),
                      ),
                      onDeleted: () => _removePending(file),
                      deleteIcon: const Icon(Icons.close, size: 16),
                    );
                  },
                ),
              ),
            ),
          ],
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(
              children: [
                // 左半区可横向滚动：窄屏（移动端）上执行模式 / 模板 / 联网再多，
                // 也只会滚动这一组，右侧的发送键永远留在可视区内，不会被挤出
                // （之前模型选择与思考开关就在右侧，把发送键顶掉了）。
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: widget.running ? null : _pickImages,
                          tooltip: '添加图片',
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                        ),
                        _ModePill(
                          mode: widget.mode,
                          onChanged: widget.onModeChanged,
                        ),
                        if (widget.afterMode != null) ...[
                          const SizedBox(width: 6),
                          widget.afterMode!,
                        ],
                        if (widget.webSearchAvailable) ...[
                          const SizedBox(width: 6),
                          _WebSearchPill(
                            enabled: widget.webSearchEnabled,
                            onChanged: widget.onWebSearchChanged,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (widget.onScrollToRecent != null)
                  IconButton(
                    onPressed: widget.onScrollToRecent,
                    tooltip: '回到最近消息',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.vertical_align_top),
                  ),
                if (widget.onScrollToBottom != null)
                  IconButton(
                    onPressed: widget.onScrollToBottom,
                    tooltip: '回到底部',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.vertical_align_bottom),
                  ),
                if (widget.onCompress != null)
                  IconButton(
                    onPressed: widget.running ? null : widget.onCompress,
                    tooltip: '压缩会话',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.compress),
                  ),
                if (widget.trailing != null) ...[
                  const SizedBox(width: 4),
                  widget.trailing!,
                ],
                const SizedBox(width: 6),
                if (widget.running)
                  _RoundActionButton(
                    icon: Icons.stop_rounded,
                    tooltip: '停止',
                    onPressed: widget.onStop,
                    filled: false,
                  )
                else
                  _RoundActionButton(
                    icon: Icons.arrow_upward_rounded,
                    tooltip: '发送',
                    onPressed: _canSend ? _send : null,
                    filled: true,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 执行模式下拉（普通 / 自动 / 托管）。
class _ModePill extends StatelessWidget {
  const _ModePill({required this.mode, this.onChanged});

  final AgentMode mode;
  final ValueChanged<AgentMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<AgentMode>(
      tooltip: '执行模式',
      onSelected: (value) => onChanged?.call(value),
      itemBuilder: (context) => [
        for (final value in AgentMode.values)
          CheckedPopupMenuItem(
            value: value,
            checked: value == mode,
            child: Text(value.label),
          ),
      ],
      child: ToolbarPill(
        icon: Icons.shield_outlined,
        label: mode.label,
        trailing: true,
      ),
    );
  }
}

/// 联网搜索开关（仅在会话工具包含 web_search 时出现）。
class _WebSearchPill extends StatelessWidget {
  const _WebSearchPill({required this.enabled, this.onChanged});

  final bool enabled;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '是否在本轮请求中携带 web_search 工具',
      child: InkWell(
        onTap: () => onChanged?.call(!enabled),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        child: ToolbarPill(
          icon: Icons.travel_explore,
          label: '联网',
          active: enabled,
          iconColor: enabled ? scheme.primary : null,
        ),
      ),
    );
  }
}

/// 工具栏里的胶囊按钮：图标 + 文案（+ 下拉箭头）。
class ToolbarPill extends StatelessWidget {
  const ToolbarPill({
    super.key,
    required this.icon,
    required this.label,
    this.trailing = false,
    this.active = false,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final bool trailing;
  final bool active;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: active
            ? scheme.primary.withValues(alpha: 0.12)
            : scheme.surfaceContainerHigh.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: iconColor ?? color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: active ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          if (trailing) ...[
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 16, color: color),
          ],
        ],
      ),
    );
  }
}

/// 发送 / 停止按钮：圆角方块，跟随参考图的箭头造型。
class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.filled,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final background = filled
        ? (enabled ? scheme.primary : scheme.onSurface.withValues(alpha: 0.12))
        : scheme.surfaceContainerHighest;
    final foreground = filled
        ? (enabled ? scheme.onPrimary : scheme.onSurface.withValues(alpha: 0.38))
        : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 20, color: foreground),
          ),
        ),
      ),
    );
  }
}
