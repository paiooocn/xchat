import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/session.dart';
import '../../state/app_state.dart';

/// Shows the "compress session" dialog: pick a preset prompt or enter a custom
/// one. Returns the chosen prompt, or null when cancelled.
Future<String?> showCompressDialog(BuildContext context, Session session) async {
  final config = context.read<AppState>().config;
  String selected = config.compressPrompts.isNotEmpty ? config.compressPrompts.first : '';
  final custom = TextEditingController();

  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('压缩会话'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('选择预置压缩提示词：'),
              const SizedBox(height: 8),
              Flexible(
                child: RadioGroup<String>(
                  groupValue: selected,
                  onChanged: (value) =>
                      setDialogState(() => selected = value ?? selected),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final prompt in config.compressPrompts)
                        RadioListTile<String>(
                          dense: true,
                          value: prompt,
                          title: Text(
                            prompt,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text('或自定义提示词：'),
              TextField(
                controller: custom,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  hintText: '输入自定义压缩会话提示词（留空则使用上面选中的预置提示词）',
                ),
                onChanged: (_) => setDialogState(() {}),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final text = custom.text.trim();
              Navigator.pop(dialogContext, text.isNotEmpty ? text : selected);
            },
            child: const Text('压缩并新建会话'),
          ),
        ],
      ),
    ),
  );
  return (result == null || result.trim().isEmpty) ? null : result.trim();
}

/// Full-screen page for maintaining the preset compress prompts.
class CompressPromptsPage extends StatefulWidget {
  const CompressPromptsPage({super.key});

  @override
  State<CompressPromptsPage> createState() => _CompressPromptsPageState();
}

class _CompressPromptsPageState extends State<CompressPromptsPage> {
  Future<void> _edit(AppState state, {int? index}) async {
    final config = state.config;
    final controller = TextEditingController(
      text: index == null ? '' : config.compressPrompts[index],
    );
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(index == null ? '新增压缩提示词' : '编辑压缩提示词'),
        content: SizedBox(
          width: 560,
          child: TextField(controller: controller, maxLines: 8, minLines: 4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    if (index == null) {
      config.compressPrompts.add(text);
    } else {
      config.compressPrompts[index] = text;
    }
    await state.saveConfig();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final prompts = state.config.compressPrompts;
    return Scaffold(
      appBar: AppBar(
        title: const Text('压缩会话提示词'),
        actions: [
          IconButton(
            tooltip: '新增',
            icon: const Icon(Icons.add),
            onPressed: () => _edit(state),
          ),
        ],
      ),
      body: prompts.isEmpty
          ? const Center(child: Text('暂无预置压缩提示词，点击右上角新增'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (var i = 0; i < prompts.length; i++)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(prompts[i], maxLines: 3,
                          overflow: TextOverflow.ellipsis),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '编辑',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _edit(state, index: i),
                          ),
                          IconButton(
                            tooltip: '删除',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              state.config.compressPrompts.removeAt(i);
                              await state.saveConfig();
                            },
                          ),
                        ],
                      ),
                      onTap: () => _edit(state, index: i),
                    ),
                  ),
              ],
            ),
    );
  }
}
