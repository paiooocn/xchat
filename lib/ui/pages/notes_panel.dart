import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../llm/note_assistant.dart';
import '../../models/note.dart';
import '../../state/app_state.dart';
import '../../util/editor_launcher.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/note_ai_panel.dart';
import '../widgets/note_diff_dialog.dart';
import '../widgets/note_editor.dart';

/// 笔记主区面板：上预览 / 下编辑 + 顶栏（标题 / 高度档位 / 收起 AI / 菜单）
/// + 状态条（已保存 / 保存中 / 未保存 · 字数 · 标签）。
class NotesPanel extends StatefulWidget {
  const NotesPanel({super.key, this.noteId});

  /// The note to show (null = nothing opened yet).
  final String? noteId;

  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

enum _SaveStatus { saved, saving, dirty }

class _NotesPanelState extends State<NotesPanel> {
  static const _ratioKey = 'notes_editor_split_ratio';

  Note? _note;
  String _body = '';
  _SaveStatus _status = _SaveStatus.saved;

  /// Height of the editor area (0 / 0.2 / 0.4).
  double _ratio = 0.4;

  /// The note file's mtime when it was loaded (external-change detection).
  DateTime? _loadedMtime;

  bool _loading = false;

  /// 自动保存的防抖计时器（停写 800ms 后落盘）。
  Timer? _saveTimer;

  /// AI 助手与编辑器之间的通道（读选区 / 写回缓冲）。
  final NoteEditorController _editorController = NoteEditorController();

  /// AI 边栏是否收起成 44px 竖轨。
  bool _aiCollapsed = false;

  /// AI 请求进行中（此时不允许收起 AI 边栏）。
  bool _aiBusy = false;

  static const _aiCollapsedKey = 'notes_ai_collapsed';

  @override
  void initState() {
    super.initState();
    _loadRatio();
    _loadAiState();
    _loadNote();
  }

  Future<void> _loadAiState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final collapsed = prefs.getBool(_aiCollapsedKey) ?? false;
      if (mounted) setState(() => _aiCollapsed = collapsed);
    } catch (_) {
      // 读不到偏好就用默认值（展开）。
    }
  }

  Future<void> _toggleAi() async {
    if (_aiBusy) return;
    final collapsed = !_aiCollapsed;
    setState(() => _aiCollapsed = collapsed);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_aiCollapsedKey, collapsed);
    } catch (_) {
      // 存不住也不影响本次使用。
    }
  }

  /// 应用 AI 的结果：**先过 diff 预览**，接受后才写进编辑器缓冲。
  Future<void> _applyAiResult(String text, NoteAiTarget target) async {
    if (!mounted) return;
    if (target == NoteAiTarget.copy) {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('结果已复制到剪贴板')),
      );
      return;
    }

    final current = _editorController.body;
    final String oldText;
    final String newText;
    final String title;
    if (target == NoteAiTarget.replaceSelection) {
      final selection = _editorController.selection;
      if (selection.trim().isEmpty) {
        // 没有选区 → 当作插入到光标处。
        oldText = current;
        newText = current + text;
        title = 'AI 插入预览';
      } else {
        oldText = selection;
        newText = text;
        title = 'AI 改写预览';
      }
    } else {
      oldText = current;
      newText = current.isEmpty ? text : '$current\n\n$text';
      title = 'AI 追加预览';
    }

    final accepted = await showNoteDiffDialog(
      context,
      oldText: oldText,
      newText: newText,
      title: title,
    );
    if (!accepted || !mounted) return;

    if (target == NoteAiTarget.replaceSelection &&
        _editorController.selection.trim().isNotEmpty) {
      _editorController.replaceSelection(newText);
    } else {
      _editorController.replaceAll(newText);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(NotesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.noteId != widget.noteId) {
      _loadNote();
    }
  }

  Future<void> _loadRatio() async {
    final value = await _readRatio();
    final ratio = switch (value) {
      '0' => 0.0,
      '20' => 0.2,
      '40' => 0.4,
      _ => 0.4,
    };
    if (mounted) setState(() => _ratio = ratio);
    // 首次打开也落一次盘，档位始终有值。
    _persistRatio(ratio);
  }

  Future<String?> _readRatio() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_ratioKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistRatio(double ratio) async {
    final value = ratio <= 0.001
        ? '0'
        : ratio < 0.3
            ? '20'
            : '40';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_ratioKey, value);
    } catch (_) {
      // 偏好写不进去也不影响使用（档位只是这次的内存状态）。
    }
  }

  Future<void> _loadNote() async {
    final id = widget.noteId;
    _saveTimer?.cancel();
    if (id == null) {
      if (mounted) {
        setState(() {
          _note = null;
          _body = '';
          _status = _SaveStatus.saved;
        });
      }
      return;
    }
    _loading = true;
    final state = context.read<AppState>();
    final note = await state.readNote(id);
    final mtime = await state.noteModifiedAt(id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _note = note;
      _body = note?.body ?? '';
      _loadedMtime = mtime;
      _status = _SaveStatus.saved;
    });
  }

  void _onBodyChanged(String body) {
    _body = body;
    if (_status != _SaveStatus.dirty) {
      setState(() => _status = _SaveStatus.dirty);
    }
    // 自动保存：停写 800ms 后落盘。
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) _save();
    });
  }

  Future<void> _save() async {
    final note = _note;
    if (note == null) return;
    final state = context.read<AppState>();
    setState(() => _status = _SaveStatus.saving);

    // 外部改动检测：磁盘上的文件在打开之后被改过 → 先问用户。
    final current = await state.noteModifiedAt(note.id);
    final changed = _loadedMtime != null &&
        current != null &&
        current.isAfter(_loadedMtime!);
    if (changed) {
      final reload = await _confirmExternalChange();
      if (reload) {
        await _loadNote();
        return;
      }
    }

    note.body = _body;
    await state.saveNote(note);
    final mtime = await state.noteModifiedAt(note.id);
    if (!mounted) return;
    setState(() {
      _loadedMtime = mtime;
      _status = _SaveStatus.saved;
    });
  }

  Future<bool> _confirmExternalChange() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('磁盘上的笔记已变更'),
        content: const Text('这篇笔记在打开之后被其他程序改过。要重新加载（丢弃本地修改），还是保留本地修改并覆盖？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('保留本地（覆盖）'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重新加载'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _rename() async {
    final note = _note;
    if (note == null) return;
    final controller = TextEditingController(text: note.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名笔记'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标题'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || !mounted) return;
    await context.read<AppState>().renameNote(note.id, title);
    await _loadNote();
  }

  Future<void> _editTags() async {
    final note = _note;
    if (note == null) return;
    final controller = TextEditingController(text: note.tags.join(', '));
    final raw = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标签（逗号分隔）'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null || !mounted) return;
    final tags = raw.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    await context.read<AppState>().setNoteTags(note.id, tags);
    await _loadNote();
  }

  Future<void> _archive() async {
    final note = _note;
    if (note == null) return;
    await context.read<AppState>().setNoteArchived(note.id, true);
    await _loadNote();
  }

  Future<void> _togglePin() async {
    final note = _note;
    if (note == null) return;
    await context.read<AppState>().setNotePinned(note.id, !note.pinned);
    await _loadNote();
  }

  Future<void> _delete() async {
    final note = _note;
    if (note == null) return;
    final ok = await confirmDelete(context, '笔记「${note.title.isEmpty ? note.id : note.title}」');
    if (!ok || !mounted) return;
    await context.read<AppState>().deleteNote(note.id);
    await _loadNote();
  }

  Future<void> _openInEditor() async {
    final note = _note;
    if (note == null) return;
    final state = context.read<AppState>();
    final path = state.paths.noteFile(note.id);
    final command = state.config.editorCommand;
    final result = await openInEditor(path, command);
    if (!mounted) return;
    final message = result.ok ? '已用外部编辑器打开' : result.message;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = _note;
    return Material(
      color: Colors.transparent,
      child: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                _topBar(context, theme, note),
                Expanded(
                  child: note == null
                      ? Center(
                          child: Text(
                            _loading ? '载入中…' : '选择或新建一篇笔记',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : NoteSaveShortcut(
                          onSave: _save,
                          child: NoteEditor(
                            key: const Key('note-editor'),
                            controller: _editorController,
                            body: _body,
                            onChanged: _onBodyChanged,
                            onSave: _save,
                            splitRatio: _ratio,
                            onSplitRatioChanged: (ratio) {
                              setState(() => _ratio = ratio);
                              _persistRatio(ratio);
                            },
                            extraActions: [
                              IconButton(
                                tooltip: '用编辑工具打开',
                                iconSize: 17,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints.tightFor(
                                  width: 30,
                                  height: 30,
                                ),
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.open_in_new),
                                onPressed: _openInEditor,
                              ),
                            ],
                          ),
                        ),
                ),
                if (note != null) _statusBar(context, theme, note),
              ],
            ),
          ),
          NoteAiPanel(
            collapsed: _aiCollapsed,
            onToggleCollapsed: _toggleAi,
            body: _body,
            selection: _editorController.selection,
            title: note?.title ?? '',
            onApply: _applyAiResult,
            onBusyChanged: (busy) {
              if (mounted) setState(() => _aiBusy = busy);
            },
          ),
        ],
      ),
    );
  }

  Widget _topBar(BuildContext context, ThemeData theme, Note? note) {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          const Icon(Icons.description_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note == null
                  ? '笔记'
                  : (note.title.isEmpty ? '未命名笔记' : note.title),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
          ),
          _ratioControl(theme),
          const SizedBox(width: 6),
          IconButton(
            tooltip: _aiCollapsed ? '展开 AI 助手' : '收起 AI 助手',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _aiCollapsed ? Icons.auto_awesome_outlined : Icons.auto_awesome,
            ),
            // 生成中不允许收起（正在跑的请求不中断）。
            onPressed: _aiBusy ? null : _toggleAi,
          ),
          PopupMenuButton<String>(
            tooltip: '笔记操作',
            iconSize: 18,
            onSelected: (value) async {
              switch (value) {
                case 'rename':
                  await _rename();
                case 'tags':
                  await _editTags();
                case 'pin':
                  await _togglePin();
                case 'archive':
                  await _archive();
                case 'delete':
                  await _delete();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'rename', child: Text('重命名')),
              const PopupMenuItem(value: 'tags', child: Text('编辑标签')),
              PopupMenuItem(
                value: 'pin',
                child: Text(note?.pinned == true ? '取消置顶' : '置顶'),
              ),
              const PopupMenuItem(value: 'archive', child: Text('归档')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ratioControl(ThemeData theme) {
    Widget segment(String label, double ratio) {
      final selected = (_ratio - ratio).abs() < 0.01;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          setState(() => _ratio = ratio);
          _persistRatio(ratio);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w600 : null,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment('40%', 0.4),
          segment('20%', 0.2),
          segment('收起', 0),
        ],
      ),
    );
  }

  Widget _statusBar(BuildContext context, ThemeData theme, Note note) {
    final text = switch (_status) {
      _SaveStatus.saved => '已保存',
      _SaveStatus.saving => '保存中…',
      _SaveStatus.dirty => '未保存',
    };
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Text(text, style: theme.textTheme.labelSmall),
          const SizedBox(width: 12),
          Text('${_body.characters.length} 字', style: theme.textTheme.labelSmall),
          if (note.tags.isNotEmpty) ...[
            const SizedBox(width: 12),
            Text(note.tags.join(' · '), style: theme.textTheme.labelSmall),
          ],
          const Spacer(),
          TextButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
