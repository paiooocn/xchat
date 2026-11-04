import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../util/line_diff.dart';

/// Shows the difference between [oldText] and [newText] and asks the user to
/// accept or reject it.
///
/// Returns `true` when the user accepted (the caller then applies the new
/// text), `false` when rejected or dismissed.
///
/// Every AI change to a note goes through this dialog — there is no silent
/// overwrite (see ARCHITECTURE invariant 18).
Future<bool> showNoteDiffDialog(
  BuildContext context, {
  required String oldText,
  required String newText,
  String title = 'AI 修改预览',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => _NoteDiffDialog(
      oldText: oldText,
      newText: newText,
      title: title,
    ),
  );
  return result ?? false;
}

class _NoteDiffDialog extends StatefulWidget {
  const _NoteDiffDialog({
    required this.oldText,
    required this.newText,
    required this.title,
  });

  final String oldText;
  final String newText;
  final String title;

  @override
  State<_NoteDiffDialog> createState() => _NoteDiffDialogState();
}

class _NoteDiffDialogState extends State<_NoteDiffDialog> {
  /// Unchanged runs longer than this are collapsed.
  static const _collapseAfter = 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = diffLines(widget.oldText, widget.newText);
    final changes = diffChangeCount(lines);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Text(widget.title, style: theme.textTheme.titleMedium),
                  const SizedBox(width: 10),
                  Text(
                    '$changes 处改动',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 420),
                color: theme.colorScheme.surfaceContainerLow,
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  children: _buildRows(context, theme, lines),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: widget.newText));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制结果')),
                        );
                      }
                    },
                    label: const Text('复制结果'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('拒绝'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('接受并应用'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildRows(
    BuildContext context,
    ThemeData theme,
    List<DiffLine> lines,
  ) {
    final rows = <Widget>[];
    var index = 0;
    while (index < lines.length) {
      final line = lines[index];
      if (line.type == DiffLineType.equal) {
        // Collect the run of unchanged lines.
        var end = index;
        while (end < lines.length && lines[end].type == DiffLineType.equal) {
          end++;
        }
        final run = lines.sublist(index, end);
        if (run.length > _collapseAfter) {
          final head = run.take(_collapseAfter ~/ 2);
          final tail = run.skip(run.length - _collapseAfter ~/ 2);
          for (final item in head) {
            rows.add(_row(context, theme, item));
          }
          rows.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              child: Text(
                '省略 ${run.length - _collapseAfter} 行',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
          for (final item in tail) {
            rows.add(_row(context, theme, item));
          }
        } else {
          for (final item in run) {
            rows.add(_row(context, theme, item));
          }
        }
        index = end;
        continue;
      }
      rows.add(_row(context, theme, line));
      index++;
    }
    if (rows.isEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('（没有差异）', style: theme.textTheme.bodySmall),
        ),
      );
    }
    return rows;
  }

  Widget _row(BuildContext context, ThemeData theme, DiffLine line) {
    final isDelete = line.type == DiffLineType.delete;
    final isInsert = line.type == DiffLineType.insert;
    final background = isDelete
        ? theme.colorScheme.errorContainer.withValues(alpha: 0.45)
        : isInsert
            ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45)
            : null;
    final marker = isDelete
        ? '-'
        : isInsert
            ? '+'
            : ' ';
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            child: Text(
              marker,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: isDelete
                    ? theme.colorScheme.error
                    : isInsert
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              line.text,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: isDelete
                    ? theme.colorScheme.onErrorContainer
                    : isInsert
                        ? theme.colorScheme.onTertiaryContainer
                        : theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
