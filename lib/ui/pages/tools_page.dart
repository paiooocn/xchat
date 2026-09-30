import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../agent/tools/builtin_tools.dart';
import '../../core/json_utils.dart';
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

  // ------------------------------------------------------- import / export

  /// Exports the tool-related settings (approval levels + shell command lists)
  /// as a JSON file via the system save dialog.
  Future<void> _exportTools(AppState state) async {
    try {
      final config = state.config;
      final payload = <String, Object?>{
        'tool_approvals': config.toolApprovals,
        'shell_level1_commands': config.shellLevel1Commands,
        'shell_level2_commands': config.shellLevel2Commands,
        'shell_denied_commands': config.shellDeniedCommands,
      };
      final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(payload));
      final stamp = DateTime.now().toString().replaceAll(RegExp(r'[^0-9]'), '');
      final uri = await FilePicker.saveFile(
        fileName: 'xchat-tools-${stamp.substring(0, 14)}.json',
        bytes: bytes,
        mimeType: 'application/json',
        dialogTitle: '导出工具配置',
      );
      if (uri == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(uri.scheme == 'file' ? '已导出到 ${uri.path}' : '已导出')),
      );
    } catch (error) {
      _showError('导出失败：$error');
    }
  }

  /// Picks a JSON file and imports the tool-related settings it contains.
  /// Both the dedicated export format and a full `config.json` work — only
  /// the tool-related keys are read.
  Future<void> _importTools(AppState state) async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        dialogTitle: '导入工具配置',
      );
      final file = picked.isNotEmpty ? picked.first : null;
      final bytes = file != null ? await file.readAsBytes() : null;
      if (bytes == null) return;

      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException catch (error) {
        _showError('JSON 解析失败：${error.message}');
        return;
      }
      if (decoded is! Map) {
        _showError('文件格式不正确：顶层必须是 JSON 对象');
        return;
      }

      final _ToolSettingsImport parsed;
      try {
        parsed = _parseToolSettings(asMap(decoded));
      } on FormatException catch (error) {
        _showError(error.message);
        return;
      }

      final ok = await _confirmImport(parsed);
      if (!ok) return;

      final config = state.config;
      // Approvals merge (a partial file keeps the other tools' levels); the
      // shell lists are self-contained and get replaced wholesale.
      if (parsed.approvals != null) config.toolApprovals.addAll(parsed.approvals!);
      if (parsed.level1 != null) config.shellLevel1Commands = parsed.level1!;
      if (parsed.level2 != null) config.shellLevel2Commands = parsed.level2!;
      if (parsed.denied != null) config.shellDeniedCommands = parsed.denied!;
      await state.saveConfig();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已导入工具配置')));
      }
    } catch (error) {
      _showError('导入失败：$error');
    }
  }

  /// Extracts and validates the tool-related keys; throws [FormatException]
  /// with a readable message when anything is malformed.
  _ToolSettingsImport _parseToolSettings(Map<String, Object?> json) {
    Map<String, int>? approvals;
    if (json.containsKey('tool_approvals')) {
      final raw = asMap(json['tool_approvals']);
      final map = <String, int>{};
      raw.forEach((key, value) {
        final level = asInt(value);
        if (level == null || level < 0 || level > 3) {
          throw FormatException('tool_approvals["$key"] 必须是 0..3 的整数');
        }
        map[key] = level;
      });
      approvals = map;
    }

    List<String>? parseList(String key) {
      if (!json.containsKey(key)) return null;
      final raw = json[key];
      if (raw is! List) throw FormatException('$key 必须是数组');
      return [
        for (final entry in raw)
          if (entry is String && entry.trim().isNotEmpty) entry.trim(),
      ];
    }

    final parsed = _ToolSettingsImport(
      approvals: approvals,
      level1: parseList('shell_level1_commands'),
      level2: parseList('shell_level2_commands'),
      denied: parseList('shell_denied_commands'),
    );
    if (parsed.isEmpty) {
      throw const FormatException('文件中没有可导入的工具配置（审批等级 / Shell 名单）');
    }
    return parsed;
  }

  Future<bool> _confirmImport(_ToolSettingsImport parsed) {
    final rows = <String>[
      if (parsed.approvals != null) '工具审批等级 ${parsed.approvals!.length} 项（合并覆盖）',
      if (parsed.level1 != null) '1级名单 ${parsed.level1!.length} 条（整体替换）',
      if (parsed.level2 != null) '2级名单 ${parsed.level2!.length} 条（整体替换）',
      if (parsed.denied != null) 'F级名单 ${parsed.denied!.length} 条（整体替换）',
    ];
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入工具配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('文件包含以下设置，导入后将覆盖当前对应配置：'),
            const SizedBox(height: 8),
            for (final row in rows) Text('· $row'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('导入')),
        ],
      ),
    ).then((value) => value ?? false);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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

  /// Popup panel describing how the shell tool is classified for approval.
  void _showShellApprovalInfo(BuildContext context, AppConfig config) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('shell 审批详情', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(
                'shell 的基础审批等级固定为 3（不可在工具里调整）。'
                '每条命令按不区分大小写的正则对整条命令匹配，'
                '命中多个名单时按 F级 > 2级 > 1级 的优先级取等级。',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              _infoRow(theme, 'F级（拒绝）', '命中即永不执行，无需审批。'),
              _infoRow(theme, '2级', '审批等级 2 → 普通/自动模式需审批，托管模式自动执行。'),
              _infoRow(theme, '1级', '审批等级 1 → 仅普通模式需审批，自动/托管模式自动执行。'),
              _infoRow(theme, '未命中', '按基础等级 3 → 普通/自动/托管 均需审批；'
                  '审批弹窗会提示，可将该命令追加到 1级/2级名单以放宽。'),
              const SizedBox(height: 16),
              Text(
                '当前名单：1级 ${config.shellLevel1Commands.length} 条 · '
                '2级 ${config.shellLevel2Commands.length} 条 · '
                'F级 ${config.shellDeniedCommands.length} 条。',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                config.shellCommandsConfigured
                    ? '任一名单为空时 shell 将被禁用。'
                    : '存在空名单，shell 工具当前已被禁用。',
                style: TextStyle(
                  fontSize: 13,
                  color: config.shellCommandsConfigured ? null : Colors.orange,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(ThemeData theme, String tag, String detail) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(tag, style: TextStyle(fontSize: 12, color: theme.colorScheme.primary)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(detail, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.config;
    return Scaffold(
      appBar: AppBar(
        title: const Text('工具管理'),
        actions: [
          IconButton(
            tooltip: '导入',
            icon: const Icon(Icons.upload_outlined),
            onPressed: () => _importTools(state),
          ),
          IconButton(
            tooltip: '导出',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _exportTools(state),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              '审批等级 0..3 决定不同模式（普通/自动/托管）下是否需要在执行前确认：\n'
              '0 都不审批 · 1 普通审批 · 2 普通/自动审批 · 3 都审批\n'
              '（shell 的基础等级固定为 3，点右侧 ⓘ 查看其审批详情）\n'
              '工具配置（审批等级与 Shell 名单）可通过右上角按钮导入 / 导出，'
              '导出为 JSON 文件，便于备份或迁移到其他设备。',
              style: TextStyle(fontSize: 12),
            ),
          ),
          for (final entry in BuiltinTools.descriptions.entries)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(entry.key),
                subtitle: Text(entry.value),
                trailing: entry.key == 'shell'
                    ? IconButton(
                        tooltip: '审批详情',
                        icon: const Icon(Icons.info_outline),
                        onPressed: () => _showShellApprovalInfo(context, config),
                      )
                    : DropdownButton<int>(
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

/// The tool-related settings carried by an import file (all sections
/// optional — only the present ones are applied).
class _ToolSettingsImport {
  const _ToolSettingsImport({this.approvals, this.level1, this.level2, this.denied});

  final Map<String, int>? approvals;
  final List<String>? level1;
  final List<String>? level2;
  final List<String>? denied;

  bool get isEmpty => approvals == null && level1 == null && level2 == null && denied == null;
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
