import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../llm/note_assistant.dart';
import '../../models/external_doc.dart';
import '../../models/note.dart';
import '../../state/app_state.dart';
import '../../util/editor_launcher.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/note_ai_panel.dart';
import '../widgets/note_diff_dialog.dart';
import '../widgets/note_editor.dart';

/// 笔记主区面板：上预览 / 下编辑 + 顶栏（标题 / 高度档位 / 收起 AI / 菜单）
/// + 状态条（已保存 / 保存中 / 未保存 · 字数 · 标签）。
///
/// 桌面：AI 边栏挂在右侧（[NoteAiPanel]，320 / 44 竖轨）。
/// 移动（[mobile]）：AI 换成底部抽屉，顶栏左侧是返回按钮。
///
/// 两种内容：
/// * 内部笔记（[noteId]）：front-matter + 正文，完整能力（标签/置顶/归档…）；
/// * 外部 md 文件（[externalPath]）：**默认只读**，需「开启编辑」后才写回原文件，
///   且不写 front-matter、不进索引。
class NotesPanel extends StatefulWidget {
  const NotesPanel({
    super.key,
    this.noteId,
    this.externalPath,
    this.mobile = false,
  });

  /// The note to show (null = nothing opened yet).
  final String? noteId;

  /// 外部 md 文件的绝对路径（与 [noteId] 互斥，优先）。
  final String? externalPath;

  /// Mobile layout: no right rail, AI opens as a bottom sheet.
  final bool mobile;

  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

/// 窗口窄于这个宽度时（侧栏 + 主区 + AI 边栏放不下）AI 边栏强制收起成竖轨。
const double kNoteAiAutoCollapseWidth = 1080;

enum _SaveStatus { saved, saving, dirty, failed }

class _NotesPanelState extends State<NotesPanel> {
  static const _ratioKey = 'notes_editor_split_ratio';

  Note? _note;
  ExternalDoc? _doc;
  String _body = '';
  _SaveStatus _status = _SaveStatus.saved;

  /// Height of the editor area (0 / 0.2 / 0.4).
  double _ratio = 0.4;

  /// The note file's mtime when it was loaded (external-change detection).
  DateTime? _loadedMtime;

  bool _loading = false;

  /// 外部文件是否处于只读态（默认只读；「开启编辑」后为 false）。
  bool _readOnly = true;

  /// 已经确认过「改动会写回原文件」的文件路径（每文件每会话一次）。
  final Set<String> _editConfirmed = <String>{};

  /// 自动保存的防抖计时器（停写 800ms 后落盘）。
  Timer? _saveTimer;

  /// AI 助手与编辑器之间的通道（读选区 / 写回缓冲）。
  final NoteEditorController _editorController = NoteEditorController();

  /// AI 边栏是否收起成 44px 竖轨。
  bool _aiCollapsed = false;

  /// AI 请求进行中（此时不允许收起 AI 边栏）。
  bool _aiBusy = false;

  static const _aiCollapsedKey = 'notes_ai_collapsed';

  bool get _isExternal => widget.externalPath != null;

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
    // 外部文件只读时不允许把结果写进正文（否则会绕过「开启编辑」这道闸）。
    if (_isExternal && _readOnly) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('外部文件处于只读状态，先「开启编辑」再应用修改')),
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
    if (oldWidget.noteId != widget.noteId ||
        oldWidget.externalPath != widget.externalPath) {
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

  // ------------------------------------------------------------- 载入

  Future<void> _loadNote() async {
    _saveTimer?.cancel();
    if (_isExternal) {
      await _loadExternal(widget.externalPath!, keepMode: false);
      return;
    }
    final id = widget.noteId;
    if (id == null) {
      if (mounted) {
        setState(() {
          _note = null;
          _doc = null;
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
      _doc = null;
      _readOnly = true;
      _body = note?.body ?? '';
      _loadedMtime = mtime;
      _status = _SaveStatus.saved;
    });
  }

  Future<void> _loadExternal(String path, {bool keepMode = false}) async {
    _loading = true;
    final state = context.read<AppState>();
    final doc = await state.readExternalDoc(path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _note = null;
      _doc = doc;
      _body = doc.body;
      // 每次重新加载都回到只读（外部文件默认只读）。
      if (!keepMode) _readOnly = true;
      doc.readOnly = _readOnly;
      _status = _SaveStatus.saved;
    });
  }

  // ------------------------------------------------------------- 保存

  void _onBodyChanged(String body) {
    if (_isExternal && _readOnly) return;
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
    if (_isExternal) {
      await _saveExternal();
      return;
    }
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

  /// 外部文件写回：只读态不产生任何写盘。
  Future<void> _saveExternal() async {
    final doc = _doc;
    if (doc == null || _readOnly) return;
    final state = context.read<AppState>();
    setState(() => _status = _SaveStatus.saving);

    final current = await state.externalDocModifiedAt(doc.path);
    final changed = doc.loadedMtime != null &&
        current != null &&
        current.isAfter(doc.loadedMtime!);
    if (changed) {
      final reload = await _confirmExternalChange();
      if (!mounted) return;
      if (reload) {
        await _loadExternal(doc.path, keepMode: true);
        return;
      }
    }

    if (!await state.externalDocExists(doc.path)) {
      if (!mounted) return;
      final saveAsNote = await _confirmMissingFile();
      if (!mounted) return;
      if (saveAsNote) await _saveAsNote();
      setState(() => _status = _SaveStatus.failed);
      return;
    }

    final ok = await state.saveExternalDoc(doc, _body);
    if (!mounted) return;
    setState(() => _status = ok ? _SaveStatus.saved : _SaveStatus.failed);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('写回失败：可能没有写权限，或文件已被移动')),
      );
    }
  }

  Future<bool> _confirmExternalChange() async {
    final external = _isExternal;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(external ? '磁盘上的文件已变更' : '磁盘上的笔记已变更'),
        content: Text(
          external
              ? '这个文件在打开之后被其他程序改过。要重新加载（丢弃本地修改），还是保留本地修改并覆盖磁盘上的最新内容？'
              : '这篇笔记在打开之后被其他程序改过。要重新加载（丢弃本地修改），还是保留本地修改并覆盖？',
        ),
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

  /// 保存时发现原文件没了：是否另存为一篇内部笔记。
  Future<bool> _confirmMissingFile() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('文件已不存在'),
        content: const Text('保存时发现原文件已被移动或删除。要把当前内容另存为一篇内部笔记吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('放弃'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('另存为笔记'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _saveAsNote() async {
    final doc = _doc;
    if (doc == null) return;
    final state = context.read<AppState>();
    final title = p.basenameWithoutExtension(doc.path);
    final note = await state.createNote(title: title);
    note.body = _body;
    await state.saveNote(note);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已另存为笔记「$title」，可在笔记列表打开')),
    );
  }

  // -------------------------------------------------------- 外部文件操作

  /// 开启编辑：先确认（每文件每会话一次），再解除只读。
  Future<void> _enableEditing() async {
    final doc = _doc;
    if (doc == null) return;
    if (!doc.writable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这个文件是其他应用给的临时副本，无法写回原文件')),
      );
      return;
    }
    if (doc.loadError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(doc.loadError!)));
      return;
    }
    if (!_editConfirmed.contains(doc.path)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开启编辑'),
          content: Text(
            '改动会直接写入原文件，可能覆盖其他工具（如 VSCode / Typora）的修改。\n\n${doc.path}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('开启编辑'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      _editConfirmed.add(doc.path);
    }
    setState(() {
      _readOnly = false;
      doc.readOnly = false;
    });
  }

  /// 结束编辑：先保存，落盘失败就停在编辑态（不丢内存内容）。
  Future<void> _disableEditing() async {
    await _save();
    if (!mounted || _status == _SaveStatus.failed) return;
    setState(() {
      _readOnly = true;
      _doc?.readOnly = true;
    });
  }

  Future<void> _reloadExternal() async {
    final doc = _doc;
    if (doc == null) return;
    await _loadExternal(doc.path, keepMode: false);
  }

  Future<void> _copyExternalPath() async {
    final doc = _doc;
    if (doc == null) return;
    await Clipboard.setData(ClipboardData(text: doc.path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('路径已复制到剪贴板')),
    );
  }

  Future<void> _revealExternal() async {
    final doc = _doc;
    if (doc == null) return;
    final result = await openDirectory(p.dirname(doc.path));
    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result.message)));
    }
  }

  // ------------------------------------------------------------ 笔记菜单

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
    final tags = raw
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
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
    final ok = await confirmDelete(
      context,
      '笔记「${note.title.isEmpty ? note.id : note.title}」',
    );
    if (!ok || !mounted) return;
    await context.read<AppState>().deleteNote(note.id);
    await _loadNote();
  }

  Future<void> _openInEditor() async {
    final String path;
    if (_isExternal) {
      final doc = _doc;
      if (doc == null) return;
      path = doc.path;
    } else {
      final note = _note;
      if (note == null) return;
      path = context.read<AppState>().paths.noteFile(note.id);
    }
    final command = context.read<AppState>().config.editorCommand;
    final result = await openInEditor(path, command);
    if (!mounted) return;
    final message = result.ok ? '已用外部编辑器打开' : result.message;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 移动端：AI 是底部抽屉（初值 70%，可上拉全屏，拖到 40% 以下关闭）。
  Future<void> _openAiSheet() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 1,
          expand: false,
          builder: (context, scrollController) => Material(
            color: theme.colorScheme.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              children: [
                // 拖拽条：提示可以上拉全屏。
                SizedBox(
                  height: 18,
                  child: Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: NoteAiPanel(
                    sheet: true,
                    scrollController: scrollController,
                    collapsed: false,
                    onToggleCollapsed: () => Navigator.of(context).pop(),
                    body: _body,
                    selection: _editorController.selection,
                    title: _title,
                    onApply: _applyAiResult,
                    onBusyChanged: (busy) {
                      if (mounted) setState(() => _aiBusy = busy);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------- 构建

  String get _title {
    if (_isExternal) {
      final doc = _doc;
      return doc == null ? '外部文件' : doc.name;
    }
    final note = _note;
    if (note == null) return '笔记';
    return note.title.isEmpty ? '未命名笔记' : note.title;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = _doc;
    final hasDoc = _isExternal ? doc != null : _note != null;
    final externalError = _isExternal ? doc?.loadError : null;
    final readOnly = _isExternal && _readOnly;

    final main = Column(
      children: [
        _topBar(context, theme),
        Expanded(
          child: !hasDoc
              ? Center(
                  child: Text(
                    _loading
                        ? '载入中…'
                        : _isExternal
                            ? '这个文件打不开'
                            : widget.mobile
                                ? '这篇笔记不存在或已删除'
                                : '选择或新建一篇笔记',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : externalError != null
                  ? _externalErrorView(theme, doc!, externalError)
                  : NoteSaveShortcut(
                      onSave: _save,
                      child: NoteEditor(
                        key: const Key('note-editor'),
                        controller: _editorController,
                        body: _body,
                        onChanged: _onBodyChanged,
                        onSave: _save,
                        readOnly: readOnly,
                        splitRatio: readOnly ? 0 : _ratio,
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
        if (hasDoc && externalError == null)
          _isExternal ? _statusBarExternal(theme, doc) : _statusBar(theme, _note!),
      ],
    );

    // 移动端：AI 走底部抽屉，不占右侧。
    if (widget.mobile) {
      return Material(color: Colors.transparent, child: main);
    }

    // 窗口太窄：AI 边栏放不下 → 强制竖轨（本次不可展开）。
    final locked = MediaQuery.sizeOf(context).width < kNoteAiAutoCollapseWidth;
    return Material(
      color: Colors.transparent,
      child: Row(
        children: [
          Expanded(child: main),
          NoteAiPanel(
            collapsed: _aiCollapsed || locked,
            locked: locked,
            onToggleCollapsed: _toggleAi,
            body: _body,
            selection: _editorController.selection,
            title: _title,
            onApply: _applyAiResult,
            onBusyChanged: (busy) {
              if (mounted) setState(() => _aiBusy = busy);
            },
          ),
        ],
      ),
    );
  }

  /// 外部文件读失败（不存在 / 过大 / 非文本）：给出说明和外部打开入口。
  Widget _externalErrorView(ThemeData theme, ExternalDoc doc, String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined,
                size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 10),
            Text(error, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              doc.path,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _openInEditor,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('用外部编辑器打开'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, ThemeData theme) {
    final doc = _doc;
    final hasDoc = _isExternal ? doc != null : _note != null;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          if (widget.mobile)
            IconButton(
              tooltip: '返回笔记列表',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).maybePop(),
            )
          else
            Icon(
              _isExternal ? Icons.article_outlined : Icons.description_outlined,
              size: 18,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
          ),
          if (_isExternal) ...[
            _modeBadge(
              theme,
              _readOnly ? '只读' : '编辑中',
              _readOnly
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            if (_readOnly)
              TextButton.icon(
                onPressed: hasDoc && doc != null && doc.writable
                    ? _enableEditing
                    : null,
                icon: const Icon(Icons.lock_open, size: 15),
                label: const Text('开启编辑'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                ),
              )
            else
              TextButton.icon(
                onPressed: _disableEditing,
                icon: const Icon(Icons.lock_outline, size: 15),
                label: const Text('结束编辑'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                ),
              ),
            if (!_readOnly) ...[
              const SizedBox(width: 4),
              _ratioControl(theme),
            ],
          ] else
            _ratioControl(theme),
          const SizedBox(width: 6),
          IconButton(
            tooltip: widget.mobile
                ? 'AI 助手'
                : (_aiCollapsed ? '展开 AI 助手' : '收起 AI 助手'),
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              !widget.mobile && !_aiCollapsed
                  ? Icons.auto_awesome
                  : Icons.auto_awesome_outlined,
            ),
            // 桌面：生成中不允许收起（正在跑的请求不中断）。
            // 移动端：抽屉随时可开（能看到正在生成的进度）。
            onPressed: !hasDoc
                ? null
                : widget.mobile
                    ? _openAiSheet
                    : (_aiBusy ? null : _toggleAi),
          ),
          if (_isExternal)
            _externalMenu(context, doc)
          else
            _noteMenu(context),
        ],
      ),
    );
  }

  Widget _modeBadge(ThemeData theme, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 外部文件菜单：没有重命名 / 标签 / 置顶 / 归档 / 删除（那归用户自己的工具管）。
  Widget _externalMenu(BuildContext context, ExternalDoc? doc) {
    return PopupMenuButton<String>(
      tooltip: '文件操作',
      iconSize: 18,
      onSelected: (value) async {
        switch (value) {
          case 'toggleEdit':
            _readOnly ? await _enableEditing() : await _disableEditing();
          case 'reload':
            await _reloadExternal();
          case 'copyPath':
            await _copyExternalPath();
          case 'reveal':
            await _revealExternal();
          case 'openExternal':
            await _openInEditor();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'toggleEdit',
          enabled: doc != null && doc.writable,
          child: Text(_readOnly ? '开启编辑' : '结束编辑'),
        ),
        const PopupMenuItem(value: 'reload', child: Text('重新加载')),
        const PopupMenuItem(value: 'copyPath', child: Text('复制路径')),
        const PopupMenuItem(value: 'reveal', child: Text('在文件管理器中显示')),
        const PopupMenuItem(value: 'openExternal', child: Text('用编辑工具打开')),
      ],
    );
  }

  Widget _noteMenu(BuildContext context) {
    return PopupMenuButton<String>(
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
          child: Text(_note?.pinned == true ? '取消置顶' : '置顶'),
        ),
        const PopupMenuItem(value: 'archive', child: Text('归档')),
        const PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
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
          segment(widget.mobile ? '0' : '收起', 0),
        ],
      ),
    );
  }

  Widget _statusBar(ThemeData theme, Note note) {
    final text = switch (_status) {
      _SaveStatus.saved => '已保存',
      _SaveStatus.saving => '保存中…',
      _SaveStatus.dirty => '未保存',
      _SaveStatus.failed => '保存失败',
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

  /// 外部文件状态条：锁 / 编辑中 + 大小 + 完整路径。
  Widget _statusBarExternal(ThemeData theme, ExternalDoc? doc) {
    final scheme = theme.colorScheme;
    final text = switch (_status) {
      _SaveStatus.saving => '保存中…',
      _SaveStatus.dirty => '未保存',
      _SaveStatus.failed => '保存失败',
      _SaveStatus.saved => _readOnly ? '只读' : '已保存',
    };
    final color =
        _status == _SaveStatus.failed ? scheme.error : scheme.onSurfaceVariant;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(
            _readOnly ? Icons.lock_outline : Icons.edit_outlined,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
          const SizedBox(width: 10),
          Text(
            '外部文件${doc == null ? '' : ' · ${doc.sizeLabel}'}',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Tooltip(
              message: doc?.path ?? '',
              child: InkWell(
                onTap: _copyExternalPath,
                child: Text(
                  doc?.path ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          if (!_readOnly)
            TextButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
        ],
      ),
    );
  }
}
