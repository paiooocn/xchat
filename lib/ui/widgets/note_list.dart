import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../models/external_doc.dart';
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
    this.externalRoot,
    this.externalFiles = const <ExternalMdEntry>[],
    this.externalTruncated = false,
    this.externalError,
    this.externalFilePath,
    this.selectedExternalPath,
    this.onOpenExternal,
    this.onCloseExternalFile,
    this.onPickExternalFile,
    this.onPickExternalDirectory,
    this.onRefreshExternal,
    this.onCloseExternalRoot,
  });

  /// Active notes (metadata only — the body is read on demand).
  final List<NoteSummary> notes;

  /// Archived notes.
  final List<NoteSummary> archivedNotes;

  /// The note currently open in the main area.
  final String? selectedId;

  /// Opens a note in the main area.
  final ValueChanged<String> onSelect;

  // ---- 外部 md 文件区（在笔记列表最上方，可折叠）----------------------

  /// 当前打开的外部目录（null = 未打开）。
  final String? externalRoot;

  /// 该目录内的 Markdown 文件（来自目录扫描，不读正文）。
  final List<ExternalMdEntry> externalFiles;

  /// 扫描命中上限（文件太多只显示前 N 个）。
  final bool externalTruncated;

  /// 扫描错误（目录不存在 / 无权限）。
  final String? externalError;

  /// 单独打开的外部文件路径。
  final String? externalFilePath;

  /// 主区当前显示的外部文件路径（高亮用）。
  final String? selectedExternalPath;

  /// 点击某个外部文件。
  final ValueChanged<String>? onOpenExternal;

  /// 取消「单独打开」这一行。
  final VoidCallback? onCloseExternalFile;

  /// 「打开 md 文件…」。
  final VoidCallback? onPickExternalFile;

  /// 「打开文件夹…」。
  final VoidCallback? onPickExternalDirectory;

  /// 重新扫描当前目录。
  final VoidCallback? onRefreshExternal;

  /// 关闭当前目录。
  final VoidCallback? onCloseExternalRoot;

  @override
  State<NoteList> createState() => _NoteListState();
}

class _NoteListState extends State<NoteList> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  String? _tagFilter;

  /// 外部文件区是否展开（本次会话内存态，不持久化）。
  bool _externalExpanded = true;

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
    final external = _filteredExternal();
    final tags = <String>{
      for (final note in widget.notes) ...note.tags,
    }.toList()
      ..sort();
    final noNotes = widget.notes.isEmpty && widget.archivedNotes.isEmpty;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
          child: TextField(
            controller: _search,
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索笔记 / 文件名',
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
              // 外部区始终在最上方：没笔记时也不会被空态卡片吃掉。
              _externalSection(context, theme, external),
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
                _emptyHint(
                  theme,
                  icon: noNotes ? Icons.description_outlined : Icons.search_off,
                  title: noNotes ? '还没有笔记' : '没有匹配的笔记',
                  hint: noNotes
                      ? '点右上角 ＋ 新建一篇，或用顶行「打开」查看外部 md 文件'
                      : '换个关键词，或清掉标签筛选',
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 列表内的软空态（外部区仍在上方可见，所以不能用整列替换的空态卡片）。
  Widget _emptyHint(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String hint,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.outline),
              const SizedBox(width: 8),
              Text(title, style: theme.textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 外部文件按搜索框过滤（名称 + 相对目录）。
  List<ExternalMdEntry> _filteredExternal() {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.externalFiles;
    return widget.externalFiles
        .where((e) =>
            e.name.toLowerCase().contains(query) ||
            e.relativeDir.toLowerCase().contains(query))
        .toList();
  }

  /// 侧栏最上方的「外部文件」区：目录内 md 列表 / 单独打开的文件 / 两个入口。
  Widget _externalSection(
    BuildContext context,
    ThemeData theme,
    List<ExternalMdEntry> entries,
  ) {
    final scheme = theme.colorScheme;
    final root = widget.externalRoot;
    final single = widget.externalFilePath;
    // 单独打开的文件若已在当前目录里，就不重复画一行。
    final showSingle = single != null &&
        (root == null || !p.isWithin(p.normalize(root), p.normalize(single)));
    final matchesQuery = _query.trim().isEmpty ||
        entries.length != widget.externalFiles.length;
    final emptyDir = widget.externalFiles.isEmpty && matchesQuery;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _externalExpanded = !_externalExpanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 2),
            child: Row(
              children: [
                Text(
                  '外部文件',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Icon(
                  _externalExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (_externalExpanded) ...[
          if (root == null) ...[
            _entryRow(
              theme,
              Icons.description_outlined,
              '打开 md 文件…',
              widget.onPickExternalFile,
            ),
            _entryRow(
              theme,
              Icons.folder_open_outlined,
              '打开文件夹…',
              widget.onPickExternalDirectory,
            ),
          ] else ...[
            _rootRow(theme, root, widget.externalFiles.length),
            if (widget.externalError != null)
              _hint(theme, widget.externalError!),
            if (emptyDir && widget.externalError == null)
              _hint(theme, '该目录下没有 md 文件'),
            for (final entry in entries) _externalRow(theme, entry),
            if (widget.externalTruncated)
              _hint(
                theme,
                '文件太多，只显示前 ${widget.externalFiles.length} 个',
              ),
          ],
          if (showSingle) _singleFileRow(theme, single),
        ],
        Divider(height: 1, color: scheme.outlineVariant),
      ],
    );
  }

  Widget _hint(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 6),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _entryRow(
    ThemeData theme,
    IconData icon,
    String label,
    VoidCallback? onTap,
  ) {
    final enabled = onTap != null;
    final color = enabled
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rootRow(ThemeData theme, String root, int count) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
      child: Row(
        children: [
          Tooltip(
            message: root,
            child: Icon(Icons.folder_open, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              p.basename(root).isEmpty ? root : p.basename(root),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            '$count 个 md',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            tooltip: '重新扫描目录',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.refresh),
            onPressed: widget.onRefreshExternal,
          ),
          IconButton(
            tooltip: '关闭目录',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.close),
            onPressed: widget.onCloseExternalRoot,
          ),
        ],
      ),
    );
  }

  Widget _externalRow(ThemeData theme, ExternalMdEntry entry) {
    final selected =
        widget.selectedExternalPath != null &&
        p.equals(p.normalize(widget.selectedExternalPath!), entry.path);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
      contentPadding: const EdgeInsets.only(left: 14, right: 6),
      leading: Icon(
        entry.isInternalNote
            ? Icons.description_outlined
            : Icons.article_outlined,
        size: 18,
      ),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      subtitle: entry.relativeDir.isEmpty
          ? null
          : Text(
              entry.relativeDir,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
      trailing: entry.isInternalNote
          ? Tooltip(
              message: '这篇是本机笔记，点击按笔记打开',
              child: Icon(
                Icons.bookmark_border,
                size: 14,
                color: theme.colorScheme.outline,
              ),
            )
          : null,
      onTap: widget.onOpenExternal == null
          ? null
          : () => widget.onOpenExternal!(entry.path),
    );
  }

  Widget _singleFileRow(ThemeData theme, String path) {
    final selected = widget.selectedExternalPath != null &&
        p.equals(p.normalize(widget.selectedExternalPath!), p.normalize(path));
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
      contentPadding: const EdgeInsets.only(left: 14, right: 6),
      leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
      title: Text(
        p.basename(path),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      subtitle: Text(
        '单独打开 · ${p.dirname(path)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: IconButton(
        tooltip: '移除',
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.close),
        onPressed: widget.onCloseExternalFile,
      ),
      onTap: widget.onOpenExternal == null
          ? null
          : () => widget.onOpenExternal!(path),
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
