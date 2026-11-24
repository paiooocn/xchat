import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/ids.dart';
import '../../models/expertise.dart';
import '../../state/app_state.dart';
import '../widgets/confirm_dialog.dart';

/// 「AI专长管理」：查看 / 添加 / 编辑 / 停用 / 删除专长。
///
/// 列表 = `AppState.expertises`（内置库 ⊕ `<root>/expertises.json` 的用户改动）。
/// 任何修改都整表写回用户文件（`ExpertiseRepository.save`），因此内置项被删除
/// 会记进墓碑、下次启动不会复活。
class ExpertisePage extends StatefulWidget {
  const ExpertisePage({super.key});

  @override
  State<ExpertisePage> createState() => _ExpertisePageState();
}

class _ExpertisePageState extends State<ExpertisePage> {
  Future<void> _persist(List<Expertise> next) async {
    final state = context.read<AppState>();
    await state.saveExpertises(sortExpertiseLibrary(next));
  }

  Future<void> _toggleEnabled(AppState state, Expertise item) async {
    final next = <Expertise>[
      for (final entry in state.expertises)
        if (entry.id == item.id) entry.copyWith(enabled: !item.enabled) else entry,
    ];
    await _persist(next);
  }

  Future<void> _delete(AppState state, Expertise item) async {
    final ok = await confirmDelete(context, 'AI专长「${item.name}」');
    if (!ok || !mounted) return;
    final next = state.expertises.where((entry) => entry.id != item.id).toList();
    await _persist(next);
  }

  Future<void> _edit(AppState state, Expertise? existing) async {
    final result = await Navigator.of(context).push<Expertise>(
      MaterialPageRoute(builder: (_) => ExpertiseEditPage(existing: existing)),
    );
    if (result == null || !mounted) return;
    final next = <Expertise>[
      for (final entry in state.expertises)
        if (entry.id == result.id) result else entry,
    ];
    if (!next.any((entry) => entry.id == result.id)) next.add(result);
    await _persist(next);
  }

  /// 查看详情：完整说明 + 提示词（可复制，作为给 Agent 的参考）。
  Future<void> _view(AppState state, Expertise item) async {
    final theme = Theme.of(context);
    final copied = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Flexible(child: Text(item.name)),
            const SizedBox(width: 8),
            _StatusTag(
              text: state.expertiseBuiltinIds.contains(item.id) ? '内置' : '自定义',
            ),
            if (!item.enabled) ...[
              const SizedBox(width: 6),
              const _StatusTag(text: '已停用', highlight: true),
            ],
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _MetaRow(label: '专长 ID', value: item.id),
              if (item.aliases.isNotEmpty)
                _MetaRow(label: '别名', value: item.aliases.join(' / ')),
              _MetaRow(label: '排序序号', value: '${item.sort}'),
              _MetaRow(label: '状态', value: item.enabled ? '启用' : '已停用'),
              if (item.description.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(item.description, style: theme.textTheme.bodyMedium),
              ],
              const Divider(height: 24),
              Text('提示词（可直接提供给 Agent）', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  item.prompt,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('复制提示词'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (copied == true && mounted) await _copyPrompt(item);
  }

  Future<void> _copyPrompt(Expertise item) async {
    await Clipboard.setData(ClipboardData(text: item.prompt));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已复制「${item.name}」的提示词')));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final items = state.expertises;
    return Scaffold(
      appBar: AppBar(title: const Text('AI专长管理')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(state, null),
        icon: const Icon(Icons.add),
        label: const Text('添加专长'),
      ),
      body: items.isEmpty
          ? Center(
              child: Text(
                '暂无可用的 AI 专长。',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final builtin = state.expertiseBuiltinIds.contains(item.id);
                return ListTile(
                  leading: Icon(
                    Icons.auto_awesome,
                    size: 22,
                    color: item.enabled
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  onTap: () => _view(state, item),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: item.enabled
                                ? null
                                : scheme.onSurfaceVariant,
                            decoration: item.enabled
                                ? null
                                : TextDecoration.lineThrough,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatusTag(text: builtin ? '内置' : '自定义'),
                      if (!item.enabled) ...[
                        const SizedBox(width: 6),
                        _StatusTag(text: '已停用', highlight: true),
                      ],
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (item.description.trim().isNotEmpty)
                        Text(
                          item.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        '排序 ${item.sort} · 提示词 ${item.prompt.length} 字',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: item.enabled,
                        onChanged: (_) => _toggleEnabled(state, item),
                      ),
                      IconButton(
                        tooltip: '复制提示词',
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.copy_outlined),
                        onPressed: () => _copyPrompt(item),
                      ),
                      IconButton(
                        tooltip: '编辑',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _edit(state, item),
                      ),
                      IconButton(
                        tooltip: '删除',
                        icon: Icon(
                          Icons.delete_outline,
                          color: scheme.error,
                        ),
                        onPressed: () => _delete(state, item),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.text, this.highlight = false});

  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = highlight ? scheme.error : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color),
      ),
    );
  }
}

/// 添加 / 编辑专长。已有专长不允许改 id（模板按 id 引用）。
class ExpertiseEditPage extends StatefulWidget {
  const ExpertiseEditPage({super.key, this.existing});

  final Expertise? existing;

  @override
  State<ExpertiseEditPage> createState() => _ExpertiseEditPageState();
}

class _ExpertiseEditPageState extends State<ExpertiseEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _prompt;
  late final TextEditingController _sort;
  late bool _enabled;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _description = TextEditingController(text: existing?.description ?? '');
    _prompt = TextEditingController(text: existing?.prompt ?? '');
    _sort = TextEditingController(
      text: (existing?.sort ??
              (context.read<AppState>().expertises.isEmpty
                  ? 10
                  : context.read<AppState>().expertises.last.sort + 10))
          .toString(),
    );
    _enabled = existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _prompt.dispose();
    _sort.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    if (name.isEmpty || prompt.isEmpty) return;
    final existing = widget.existing;
    final id = existing?.id ?? 'custom_${newShortId(8)}';
    final result = (existing ??
            Expertise(
              id: id,
              name: name,
              description: '',
              prompt: prompt,
              sort: int.tryParse(_sort.text.trim()) ?? 0,
            ))
        .copyWith(
      id: id,
      name: name,
      description: _description.text.trim(),
      prompt: prompt,
      sort: int.tryParse(_sort.text.trim()) ?? 0,
      enabled: _enabled,
    );
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '添加专长' : '编辑专长'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '说明（在模板页 badge 悬停 / 长按时展示）',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _prompt,
            minLines: 6,
            maxLines: 16,
            decoration: const InputDecoration(
              labelText: '提示词内容（多个专长时按排序拼接，段间用 --- 分隔）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _sort,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '排序序号（越小越靠前；多个专长按此顺序组合）',
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用'),
            subtitle: const Text('停用后不出现在模板的专长选择里'),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          if (!_isNew)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '专长 ID：${widget.existing!.id}（不可修改）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
