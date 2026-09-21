import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../agent/tools/builtin_tools.dart';
import '../../models/agent_mode.dart';
import '../../models/app_config.dart';
import '../../state/app_state.dart';
import '../theme/app_fonts.dart';
import '../widgets/confirm_dialog.dart';

/// Tool management: review available tools, set approval levels, and configure
/// the shell command allow/deny lists.
class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  static List<String> _clean(List<String> input) =>
      input.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  /// Fills the lists with the built-in suggested lists and saves them.
  Future<void> _applyDefaults(AppState state) async {
    state.config
      ..shellLevel1Commands = AppConfig.defaultShellLevel1Commands()
      ..shellLevel2Commands = AppConfig.defaultShellLevel2Commands()
      ..shellDeniedCommands = AppConfig.defaultShellDeniedCommands();
    await state.saveConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已应用默认名单')));
    }
  }

  Future<void> _editLists(AppState state) async {
    final config = state.config;
    final result = await showDialog<_ShellListsResult>(
      context: context,
      builder: (_) => _ShellListsDialog(
        level1: config.shellLevel1Commands,
        level2: config.shellLevel2Commands,
        denied: config.shellDeniedCommands,
      ),
    );
    if (result == null) return;
    config
      ..shellLevel1Commands = _clean(result.level1)
      ..shellLevel2Commands = _clean(result.level2)
      ..shellDeniedCommands = _clean(result.denied);
    await state.saveConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存名单')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.config;
    return Scaffold(
      appBar: AppBar(title: const Text('工具管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              '审批等级 0..3 决定不同模式（普通/自动/托管）下是否需要在执行前确认：\n'
              '0 都不审批 · 1 自动/托管审批 · 2 托管审批 · 3 都审批',
              style: TextStyle(fontSize: 12),
            ),
          ),
          for (final entry in BuiltinTools.descriptions.entries)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(entry.key),
                subtitle: Text(entry.value),
                trailing: DropdownButton<int>(
                  value: config.toolApprovalLevel(entry.key).clamp(0, 3),
                  onChanged: (value) async {
                    config.toolApprovals[entry.key] = value ?? 0;
                    await state.saveConfig();
                  },
                  items: [
                    for (var level = 0; level <= 3; level++)
                      DropdownMenuItem(value: level, child: Text(approvalLevelLabel(level))),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text('Shell 命令名单', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '1级 → 审批等级1；2级 → 审批等级2；F级 → 全局拒绝执行。\n'
            '任一名单（1级/2级/F级）为空时 shell 工具不可调用。',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (!config.shellCommandsConfigured)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('存在空名单，shell 工具已被禁用。', style: TextStyle(color: Colors.orange)),
            ),
          Row(
            children: [
              Expanded(child: Text('1级 ${config.shellLevel1Commands.length} 条 · '
                  '2级 ${config.shellLevel2Commands.length} 条 · '
                  'F级 ${config.shellDeniedCommands.length} 条')),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => _editLists(state),
                icon: const Icon(Icons.list_alt),
                label: const Text('编辑/查看名单'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _applyDefaults(state),
                child: const Text('应用默认名单'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The three edited lists.
class _ShellListsResult {
  const _ShellListsResult(this.level1, this.level2, this.denied);

  final List<String> level1;
  final List<String> level2;
  final List<String> denied;
}

/// Popup panel that lists each shell command entry with edit/delete/add/copy.
class _ShellListsDialog extends StatefulWidget {
  const _ShellListsDialog({
    required this.level1,
    required this.level2,
    required this.denied,
  });

  final List<String> level1;
  final List<String> level2;
  final List<String> denied;

  @override
  State<_ShellListsDialog> createState() => _ShellListsDialogState();
}

class _ShellListsDialogState extends State<_ShellListsDialog> {
  late final List<String> _level1 = List<String>.of(widget.level1);
  late final List<String> _level2 = List<String>.of(widget.level2);
  late final List<String> _denied = List<String>.of(widget.denied);

  Future<String?> _prompt({String? initial, required String title}) async {
    final controller = TextEditingController(text: initial ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: r'正则，如 \brm\b'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
        ],
      ),
    );
    final text = controller.text.trim();
    if (ok != true || text.isEmpty) return null;
    return text;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: AlertDialog(
        title: const Text('Shell 命令名单'),
        contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
        content: SizedBox(
          width: 560,
          height: 460,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: '1级'),
                  Tab(text: '2级'),
                  Tab(text: 'F级（拒绝）'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _list(_level1, '1级'),
                    _list(_level2, '2级'),
                    _list(_denied, 'F级'),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              _ShellListsResult(_level1, _level2, _denied),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _list(List<String> items, String label) {
    return Column(
      children: [
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('（空）'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) => ListTile(
                    dense: true,
                    title: Text(
                      items[index],
                      style: const TextStyle(
                        fontFamily: AppFonts.mono,
                        fontFamilyFallback: AppFonts.monoFallback,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '编辑',
                          iconSize: 18,
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () async {
                            final value = await _prompt(initial: items[index], title: '编辑 $label 条目');
                            if (value != null) setState(() => items[index] = value);
                          },
                        ),
                        IconButton(
                          tooltip: '复制',
                          iconSize: 18,
                          icon: const Icon(Icons.copy),
                          onPressed: () => setState(() => items.insert(index + 1, items[index])),
                        ),
                        IconButton(
                          tooltip: '删除',
                          iconSize: 18,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final ok = await confirmDelete(context, '条目「${items[index]}」');
                            if (ok) setState(() => items.removeAt(index));
                          },
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              final value = await _prompt(title: '新增 $label 条目');
              if (value != null) setState(() => items.add(value));
            },
            icon: const Icon(Icons.add),
            label: const Text('新增'),
          ),
        ),
      ],
    );
  }
}
