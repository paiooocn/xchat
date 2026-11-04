import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/note.dart';
import '../theme/app_fonts.dart';
import 'markdown_view.dart';

/// The three editor-area heights (as a fraction of the whole note area).
///
/// The splitter snaps to the nearest one, so the persisted value is always
/// one of `0 / 20 / 40`.
const List<double> noteSplitRatios = <double>[0, 0.2, 0.4];

/// Lets the owner (the notes panel) drive the editor's text — the AI
/// assistant needs to read the current selection and to write a result back
/// into the editor **buffer** (never straight to disk).
class NoteEditorController extends ChangeNotifier {
  TextEditingController? _text;
  void Function(String)? _onChanged;

  void _attach(TextEditingController text, void Function(String) onChanged) {
    _text = text;
    _onChanged = onChanged;
  }

  void _detach() {
    _text = null;
    _onChanged = null;
  }

  /// The currently selected text (empty when nothing is selected).
  String get selection {
    final text = _text;
    if (text == null) return '';
    final selection = text.selection;
    if (!selection.isValid || selection.isCollapsed) return '';
    final start = selection.start.clamp(0, text.text.length);
    final end = selection.end.clamp(0, text.text.length);
    if (end <= start) return '';
    return text.text.substring(start, end);
  }

  /// Replaces the selection (or inserts at the cursor) and notifies the owner
  /// so the change goes through the normal autosave path.
  void replaceSelection(String replacement) {
    final text = _text;
    if (text == null) return;
    final selection = text.selection;
    final start = selection.isValid ? selection.start : text.text.length;
    final end = selection.isValid ? selection.end : start;
    final newText = text.text.replaceRange(start, end, replacement);
    text.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
    _onChanged?.call(newText);
    notifyListeners();
  }

  /// Replaces the whole body.
  void replaceAll(String replacement) {
    final text = _text;
    if (text == null) return;
    text.value = TextEditingValue(
      text: replacement,
      selection: TextSelection.collapsed(offset: replacement.length),
    );
    _onChanged?.call(replacement);
    notifyListeners();
  }

  /// The current body.
  String get body => _text?.text ?? '';
}

/// The note editor: **preview on top, source below**, with a draggable
/// splitter between them.
///
/// The editor owns the text (and its selection); the owner
/// ([NotesPanel]) owns persistence — it receives the new text through
/// [onChanged] and decides when to save.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.body,
    required this.onChanged,
    required this.onSave,
    required this.splitRatio,
    required this.onSplitRatioChanged,
    this.controller,
    this.readOnly = false,
    this.extraActions = const [],
  });

  /// The current body. When it changes from the outside (e.g. the user
  /// reloaded a file changed outside the app) the editor is re-synced.
  final String body;

  /// Called on every keystroke with the new body.
  final ValueChanged<String> onChanged;

  /// Called for `Ctrl+S` (manual save).
  final VoidCallback onSave;

  /// Current height of the editor area (0 = collapsed, 0.2, 0.4).
  final double splitRatio;

  /// Called when the splitter settles on a new height.
  final ValueChanged<double> onSplitRatioChanged;

  /// 只读态（外部 md 文件未开启编辑时）：只渲染预览，不建输入框、不渲染工具栏。
  final bool readOnly;

  /// Extra toolbar buttons (e.g. 「用编辑工具打开」).
  final List<Widget> extraActions;

  /// Optional handle the owner uses to read the selection / write results
  /// back into the editor buffer.
  final NoteEditorController? controller;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late final TextEditingController _controller;
  Timer? _previewTimer;

  /// The text currently rendered in the preview (debounced).
  String _preview = '';

  /// Ratio while the splitter is being dragged (null = use the widget's).
  double? _dragRatio;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.body);
    _preview = widget.body;
    widget.controller?._attach(_controller, _onChanged);
  }

  @override
  void didUpdateWidget(NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach();
      widget.controller?._attach(_controller, _onChanged);
    }
    if (widget.body != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.body,
        selection: TextSelection.collapsed(offset: widget.body.length),
      );
      _schedulePreview(widget.body);
    }
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    widget.controller?._detach();
    _controller.dispose();
    super.dispose();
  }

  /// The preview lags 300ms behind the keystrokes (re-rendering Markdown is
  /// the expensive part).
  void _schedulePreview(String text) {
    _previewTimer?.cancel();
    _previewTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _preview = text);
    });
  }

  void _onChanged(String text) {
    _schedulePreview(text);
    widget.onChanged(text);
  }

  double get _ratio => (_dragRatio ?? widget.splitRatio).clamp(0.0, 0.9);

  static double _snap(double ratio) {
    var best = noteSplitRatios.first;
    var bestDistance = (ratio - best).abs();
    for (final candidate in noteSplitRatios) {
      final distance = (ratio - candidate).abs();
      if (distance < bestDistance) {
        best = candidate;
        bestDistance = distance;
      }
    }
    return best;
  }

  // ------------------------------------------------------------- editing

  /// Wraps the selection with [prefix]/[suffix]; without a selection it
  /// inserts the pair and puts the cursor in the middle.
  void _wrap(String prefix, String suffix, {String placeholder = ''}) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? start : selection.end;
    final selected = text.substring(start, end);
    final inner = selected.isEmpty ? placeholder : selected;
    final replacement = '$prefix$inner$suffix';
    final newText = text.replaceRange(start, end, replacement);
    _controller.value = TextEditingValue(
      text: newText,
      selection: selected.isEmpty
          ? TextSelection.collapsed(offset: start + prefix.length)
          : TextSelection(
              baseOffset: start + prefix.length,
              extentOffset: start + prefix.length + inner.length,
            ),
    );
    _onChanged(newText);
  }

  /// Prefixes every line of the current selection (headings, lists, quotes).
  void _prefixLines(String prefix, {bool replaceHeading = false}) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? start : selection.end;
    final lineStart = (start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1);
    final lineEndIndex = text.indexOf('\n', end);
    final lineEnd = lineEndIndex < 0 ? text.length : lineEndIndex;
    final block = text.substring(lineStart, lineEnd);
    final newBlock = block
        .split('\n')
        .map((line) {
          final stripped = replaceHeading
              ? line.replaceFirst(RegExp(r'^#{1,6}\s*'), '')
              : line;
          return '$prefix$stripped';
        })
        .join('\n');
    final newText = text.replaceRange(lineStart, lineEnd, newBlock);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: lineStart + newBlock.length),
    );
    _onChanged(newText);
  }

  /// Inserts a snippet at the cursor.
  void _insert(String snippet, {int cursorOffset = 0}) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? start : selection.end;
    final newText = text.replaceRange(start, end, snippet);
    _controller.value = TextEditingValue(
      text: newText,
      selection:
          TextSelection.collapsed(offset: start + cursorOffset.clamp(0, snippet.length)),
    );
    _onChanged(newText);
  }

  static const _tableSkeleton = '''| 列 1 | 列 2 | 列 3 |
| --- | --- | --- |
|  |  |  |
''';

  // -------------------------------------------------------------- widgets

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 只读：纯预览（没有编辑区、没有分隔条、没有工具栏）。
    if (widget.readOnly) {
      return Column(
        children: [Expanded(child: _previewArea(theme))],
      );
    }
    final ratio = _ratio;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxHeight.isFinite ? constraints.maxHeight : 600.0;
        return Column(
          children: [
            // ---- 上区：预览 --------------------------------------------
            Expanded(
              child: ratio > 0
                  ? _previewArea(theme)
                  : _previewArea(theme),
            ),
            if (ratio > 0) ...[
              _splitter(theme, total),
              SizedBox(
                height: total * ratio,
                child: _editorArea(theme),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _previewArea(ThemeData theme) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surface,
      child: _preview.trim().isEmpty
          ? Center(
              child: Text(
                '预览为空',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: markdownView(_preview),
            ),
    );
  }

  Widget _splitter(ThemeData theme, double total) {
    return GestureDetector(
      key: const Key('note-splitter'),
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        final current = _dragRatio ?? widget.splitRatio;
        setState(() {
          _dragRatio = (current - details.delta.dy / total).clamp(0.0, 0.9);
        });
      },
      onVerticalDragEnd: (_) {
        final snapped = _snap(_dragRatio ?? widget.splitRatio);
        setState(() => _dragRatio = null);
        widget.onSplitRatioChanged(snapped);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: Container(
          height: 8,
          color: theme.colorScheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Container(
            width: 36,
            height: 3,
            decoration: BoxDecoration(
              color: theme.colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _editorArea(ThemeData theme) {
    return Column(
      children: [
        _toolbar(theme),
        Expanded(
          child: TextField(
            controller: _controller,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: TextStyle(
              fontFamily: AppFonts.mono,
              fontSize: 13,
              height: 1.5,
              color: theme.colorScheme.onSurface,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.fromLTRB(14, 10, 14, 14),
            ),
            onChanged: _onChanged,
          ),
        ),
      ],
    );
  }

  Widget _toolbar(ThemeData theme) {
    Widget button(
      IconData icon,
      String tooltip,
      VoidCallback onTap,
    ) =>
        IconButton(
          tooltip: tooltip,
          iconSize: 17,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          padding: EdgeInsets.zero,
          icon: Icon(icon),
          onPressed: onTap,
        );
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            button(Icons.format_bold, '粗体', () => _wrap('**', '**', placeholder: '粗体')),
            button(Icons.format_italic, '斜体', () => _wrap('*', '*', placeholder: '斜体')),
            button(Icons.looks_one, '标题 1', () => _prefixLines('# ', replaceHeading: true)),
            button(Icons.looks_two, '标题 2', () => _prefixLines('## ', replaceHeading: true)),
            button(Icons.format_size, '标题 3', () => _prefixLines('### ', replaceHeading: true)),
            button(Icons.format_list_bulleted, '无序列表', () => _prefixLines('- ')),
            button(Icons.checklist, '任务列表', () => _prefixLines('- [ ] ')),
            button(Icons.format_list_numbered, '有序列表', () => _prefixLines('1. ')),
            button(Icons.code, '代码块', () => _wrap('```\n', '\n```', placeholder: '代码')),
            button(Icons.terminal, '行内代码', () => _wrap('`', '`', placeholder: '代码')),
            button(Icons.link, '链接', () => _wrap('[', '](url)', placeholder: '链接文字')),
            button(Icons.table_chart, '表格', () => _insert(_tableSkeleton)),
            button(Icons.format_quote, '引用', () => _prefixLines('> ')),
            button(Icons.functions, '公式', () => _wrap('\$\$', '\$\$', placeholder: '公式')),
            button(Icons.image, '图片', () => _insert('![说明](图片路径)')),
            const SizedBox(width: 8),
            ...widget.extraActions,
          ],
        ),
      ),
    );
  }
}

/// `Ctrl+S` → save.
class NoteSaveIntent extends Intent {
  const NoteSaveIntent();
}

/// Wraps [child] so `Ctrl+S` triggers [onSave].
class NoteSaveShortcut extends StatelessWidget {
  const NoteSaveShortcut({super.key, required this.onSave, required this.child});

  final VoidCallback onSave;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyS, control: true): NoteSaveIntent(),
        SingleActivator(LogicalKeyboardKey.keyS, meta: true): NoteSaveIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          NoteSaveIntent: CallbackAction<NoteSaveIntent>(
            onInvoke: (_) {
              onSave();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

/// A note summary row (title + preview + tags) used by the note list.
class NoteSummaryTile extends StatelessWidget {
  const NoteSummaryTile({
    super.key,
    required this.note,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final NoteSummary note;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
      leading: Icon(
        note.pinned ? Icons.push_pin : Icons.description_outlined,
        size: 20,
        color: note.pinned ? theme.colorScheme.primary : null,
      ),
      title: Text(
        note.title.isEmpty ? '未命名笔记' : note.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: note.preview.isEmpty
          ? null
          : Text(
              note.preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
