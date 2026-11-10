import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Wraps [child] in a file drop target.
///
/// On desktop (and anywhere the platform delivers drag events) dragging files
/// over the area tints it and shows a hint; on drop the absolute paths are
/// handed to [onFiles]. Touch platforms simply never fire the callbacks, so the
/// same tree stays valid everywhere.
///
/// The target stays *disabled* while [enabled] is false — `DropTarget`
/// otherwise keeps receiving events even when covered by a pushed route
/// (see flutter-plugins#2), which would let a drop land in a background page.
class FileDropZone extends StatefulWidget {
  const FileDropZone({
    super.key,
    required this.child,
    required this.onFiles,
    this.enabled = true,
    this.hint = '松开鼠标，把文件加入这条对话',
  });

  final Widget child;
  final ValueChanged<List<String>> onFiles;
  final bool enabled;
  final String hint;

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

class _FileDropZoneState extends State<FileDropZone> {
  bool _hovering = false;

  void _setHovering(bool value) {
    if (_hovering == value || !mounted) return;
    setState(() => _hovering = value);
  }

  void _handleDone(DropDoneDetails details) {
    _setHovering(false);
    final paths = [
      for (final file in details.files)
        if (file.path.isNotEmpty) file.path,
    ];
    if (paths.isEmpty) return;
    widget.onFiles(paths);
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => _setHovering(true),
      onDragExited: (_) => _setHovering(false),
      onDragDone: _handleDone,
      child: Stack(
        children: [
          widget.child,
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: _DropOverlay(hint: widget.hint),
              ),
            ),
        ],
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        border: Border.all(color: scheme.primary, width: 2),
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.file_download_outlined, size: 42, color: scheme.primary),
          const SizedBox(height: 10),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '图片直接发给模型；文本与 Word/Excel/PPT 按原文内联；'
            '其他文件保存到会话目录，交给工具读取',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
