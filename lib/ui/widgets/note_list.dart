import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/note.dart';
import '../../state/app_state.dart';
import '../widgets/confirm_dialog.dart';
import 'note_editor.dart';

/// 左栏「笔记」Tab 的列表：搜索 + 置顶 + 最近 + 标签筛选 + 归档。
class NoteList extends StatefulWidget {
  const NoteList({
    super.key,
    required this.notes,
    required this.archivedNotes,
    required this.selectedId,
    required this.onSelect,
  });

  /// Active notes (metadata only — the body is read on demand).
  final List<NoteSummary> notes;

  /// Archived notes.
  final List<NoteSummary> archivedNotes;

  /// The note currently open in the main area.
  final String? selectedId;

  /// Opens a note in the main area.
  final ValueChanged<String> onSelect;

  @override
  State<NoteList> createState() => _NoteListState();
}

class _NoteListState extends State<NoteList> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  String? _tagFilter;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<NoteSummary> _filtered(List<NoteSummary> source) {
    final query = _query.trim().toLowerCase();
    return source.where((note) {
      if (_tagFilter != null && !note.tags.contains(_tagFilter)) return false;
      if (query.isEmpty) return true;
      if (note.title.toLowerCase().contains(query)) return true;
      if (note.preview.toLowerCase().contains(query)) return true;
      return note.tags.any((t) => t.toLowerCase().contains(query));
    }).toList();
  }

  Future<void> _rename(NoteSummary note) async {
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
  }

  Future<void> _editTags(NoteSummary note) async {
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
    final tags =
        raw.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    await context.read<AppState>().setNoteTags(note.id, tags);
  }

  Future<void> _delete(NoteSummary note) async {
    final ok = await confirmDelete(
      context,
      '笔记「${note.title.isEmpty ? note.id : note.title}」',
    );
    if (!ok || !mounted) return;
    await context.read<AppState>().deleteNote(note.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _filtered(widget.notes);
    final pinned = visible.where((n) => n.pinned).toList();
    final recent = visible.where((n) => !n.pinned).toList();
    final archived = _filtered(widget.archivedNotes);
    final tags = <String>{
      for (final note in widget.notes) ...note.tags,
    }.toList()
      ..sort();

    if (widget.notes.isEmpty && widget.archivedNotes.isEmpty) {
      return Center(
        child: Text(
          '暂无笔记',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
          child: TextField(
            controller: _search,
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索笔记',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      iconSize: 16,
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainer,
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        if (tags.isNotEmpty)
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                for (final tag in tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(tag, style: theme.textTheme.labelSmall),
                      selected: _tagFilter == tag,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onSelected: (selected) =>
                          setState(() => _tagFilter = selected ? tag : null),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            children: [
              if (pinned.isNotEmpty) ...[
                _sectionHeader(context, '置顶'),
                for (final note in pinned) _row(context, note),
              ],
              if (recent.isNotEmpty) ...[
                _sectionHeader(context, '最近'),
                for (final note in recent) _row(context, note),
              ],
              if (archived.isNotEmpty) ...[
                _sectionHeader(context, '归档'),
                for (final note in archived) _row(context, note),
              ],
              if (visible.isEmpty && archived.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '没有匹配的笔记',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 2),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _row(BuildContext context, NoteSummary note) {
    return NoteSummaryTile(
      note: note,
      selected: note.id == widget.selectedId,
      onTap: () => widget.onSelect(note.id),
      trailing: PopupMenuButton<String>(
        tooltip: '笔记操作',
        iconSize: 18,
        padding: EdgeInsets.zero,
        onSelected: (value) async {
          final state = context.read<AppState>();
          switch (value) {
            case 'rename':
              await _rename(note);
            case 'tags':
              await _editTags(note);
            case 'pin':
              await state.setNotePinned(note.id, !note.pinned);
            case 'archive':
              await state.setNoteArchived(note.id, !note.archived);
            case 'delete':
              await _delete(note);
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'rename', child: Text('重命名')),
          const PopupMenuItem(value: 'tags', child: Text('编辑标签')),
          PopupMenuItem(
            value: 'pin',
            child: Text(note.pinned ? '取消置顶' : '置顶'),
          ),
          PopupMenuItem(
            value: 'archive',
            child: Text(note.archived ? '取消归档' : '归档'),
          ),
          const PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
    );
  }
}
