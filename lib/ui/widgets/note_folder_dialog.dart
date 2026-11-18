import 'package:flutter/material.dart';

/// 收纳箱（虚拟文件夹）选择弹层。
///
/// 返回选中的箱子名（已 trim，空字符串 = 移出收纳箱）；取消返回 `null`。
/// 只负责取名，真正的写入由调用方经 `AppState` 完成 —— 列表行菜单与
/// 笔记面板菜单共用这一个实现。
Future<String?> showNoteFolderDialog(
  BuildContext context, {
  required String current,
  List<String> known = const <String>[],
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => NoteFolderDialog(current: current, known: known),
  );
}

class NoteFolderDialog extends StatefulWidget {
  const NoteFolderDialog({super.key, required this.current, this.known = const <String>[]});

  /// 当前收纳箱名（空 = 未归箱）。
  final String current;

  /// 其它已有的收纳箱名（快捷选择用）。
  final List<String> known;

  @override
  State<NoteFolderDialog> createState() => _NoteFolderDialogState();
}

/// 收纳箱改名弹层：返回新名字（已 trim，非空）；取消返回 `null`。
///
/// 空名字不允许提交（按钮置灰）——「清空箱子」是箱子标题菜单里另一个动作。
Future<String?> showNoteFolderRenameDialog(
  BuildContext context, {
  required String current,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => NoteFolderRenameDialog(current: current),
  );
}

class NoteFolderRenameDialog extends StatefulWidget {
  const NoteFolderRenameDialog({super.key, required this.current});

  final String current;

  @override
  State<NoteFolderRenameDialog> createState() => _NoteFolderRenameDialogState();
}

class _NoteFolderRenameDialogState extends State<NoteFolderRenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名收纳箱'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '新名称'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (value) =>
            Navigator.of(context).pop(value.trim().isEmpty ? null : value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => FilledButton(
            onPressed: value.text.trim().isEmpty
                ? null
                : () => Navigator.of(context).pop(value.text.trim()),
            child: const Text('保存'),
          ),
        ),
      ],
    );
  }
}

class _NoteFolderDialogState extends State<NoteFolderDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final others = widget.known.where((name) => name != widget.current).toList();
    return AlertDialog(
      title: const Text('收纳箱'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '收纳箱名（留空 = 移出收纳箱）',
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('已有收纳箱', style: theme.textTheme.labelSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final name in others)
                  ActionChip(
                    label: Text(name, style: theme.textTheme.labelMedium),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(name),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
