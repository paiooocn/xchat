import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/orphan_repository.dart';
import '../../models/orphan_file.dart';
import '../../state/app_state.dart';
import '../widgets/confirm_dialog.dart';

/// 「未索引文件管理」：`sessions/` 与 `projects/` 里存在、但 `index.json` 没有收录的
/// XML（删漏的文件）。可以把它**恢复到索引**（回到会话/项目列表），也可以**彻底删除**。
///
/// 这类文件不参与局域网同步（`SyncRepository.manifest` 只读索引），要处理只能在这里。
class OrphansPage extends StatefulWidget {
  const OrphansPage({super.key});

  @override
  State<OrphansPage> createState() => _OrphansPageState();
}

class _OrphansPageState extends State<OrphansPage> {
  late final AppState _state;
  late final OrphanRepository _repository;
  List<OrphanFile> _files = <OrphanFile>[];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _repository = OrphanRepository(
      paths: _state.paths,
      indexRepository: _state.indexRepository,
      sessionRepository: _state.sessionRepository,
      projectRepository: _state.projectRepository,
    );
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final files = await _repository.scan();
      if (!mounted) return;
      setState(() => _files = files);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restore(OrphanFile file) async {
    if (_busy) return;
    setState(() => _busy = true);
    final error = await _repository.restore(file);
    if (error == null) {
      await _state.refreshAfterSync(<String>[
        if (!file.isProject) file.id,
      ]);
    }
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(error ?? '已恢复到列表：${file.title}');
  }

  Future<void> _delete(OrphanFile file) async {
    if (_busy) return;
    final ok = await confirmDelete(
      context,
      '${file.isProject ? '项目文件' : '会话文件'}「${file.fileName}」（仅删除文件，不进索引）',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final error = await _repository.delete(file);
    await _reload();
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(error ?? '已删除：${file.fileName}');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = _files.where((f) => !f.isProject).toList();
    final projects = _files.where((f) => f.isProject).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('未索引文件'),
        actions: [
          IconButton(
            tooltip: '重新扫描',
            onPressed: _loading ? null : () => unawaited(_reload()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading || _busy) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'sessions/ 与 projects/ 里存在、但索引（index.json）没有收录的 XML。'
              '它们不出现在会话列表，也不参与局域网同步；可恢复回列表，或彻底删除。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: !_loading && _files.isEmpty
                ? Center(
                    child: Text(
                      '没有未索引的文件',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      if (projects.isNotEmpty) ...[
                        _sectionTitle(theme, '项目文件', projects.length),
                        for (final file in projects)
                          _row(theme, file),
                      ],
                      if (sessions.isNotEmpty) ...[
                        _sectionTitle(theme, '会话文件', sessions.length),
                        for (final file in sessions)
                          _row(theme, file),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text('$title · $count', style: theme.textTheme.titleSmall),
      );

  Widget _row(ThemeData theme, OrphanFile file) {
    final second = <String>[
      file.fileName,
      _formatTime(file.updatedAt),
      if (!file.parsed) '无法解析，只能删除' else if (file.owner.isNotEmpty) '项目：${file.owner}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      child: Row(
        children: [
          Icon(
            file.isProject ? Icons.folder_outlined : Icons.chat_bubble_outline,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 1),
                Text(
                  second,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: (_busy || !file.parsed) ? null : () => unawaited(_restore(file)),
            child: const Text('恢复'),
          ),
          TextButton(
            onPressed: _busy ? null : () => unawaited(_delete(file)),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
