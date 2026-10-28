import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/memory_protocol.dart';
import '../../models/memory_status.dart';
import '../../models/project.dart';
import '../../state/app_state.dart';

/// What the project dialog returns.
typedef ProjectDialogResult = ({
  String name,
  String description,
  String sandbox,
  String systemPrompt,
  bool memoryEnabled,
});


/// The project create/edit dialog.
///
/// A stateful widget so the text controllers live exactly as long as the
/// dialog does: they are disposed in [dispose], i.e. after the route's
/// closing animation — disposing them earlier makes the still-mounted
/// `TextField`s throw "used after being disposed".
class ProjectDialog extends StatefulWidget {
  const ProjectDialog({super.key, this.existing});

  /// The project being edited (null = create a new one).
  final Project? existing;

  @override
  State<ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<ProjectDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _desc =
      TextEditingController(text: widget.existing?.description ?? '');
  late final TextEditingController _sandbox =
      TextEditingController(text: widget.existing?.sandbox ?? '');
  late final TextEditingController _prompt =
      TextEditingController(text: widget.existing?.systemPrompt ?? '');

  /// 新项目默认开启记忆索引；老项目按当前生效值（显式开关优先，
  /// 没设置过的老项目看 `.memory/` 是否已存在）。
  late bool _memoryEnabled;

  /// 记忆索引状态；点「初始化」后重建 future 刷新。
  Future<MemoryStatus>? _statusFuture;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    final existing = widget.existing;
    _memoryEnabled = existing == null ? true : state.isMemoryEnabled(existing);
    _statusFuture =
        existing == null ? null : state.projectMemoryStatus(existing);
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _sandbox.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop((
      name: _name.text.trim(),
      description: _desc.text.trim(),
      sandbox: _sandbox.text.trim(),
      systemPrompt: _prompt.text.trim(),
      memoryEnabled: _memoryEnabled,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final existing = widget.existing;
    // 取一次 messenger，避免在 async 间隙之后再用 BuildContext。
    final messenger = ScaffoldMessenger.of(context);
    return AlertDialog(
      title: Text(existing == null ? '新建项目' : '编辑项目'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '项目名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _desc,
                decoration: const InputDecoration(labelText: '说明'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _sandbox,
                decoration: const InputDecoration(
                  labelText: '工作目录（留空=默认 projects/<项目id>）',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _prompt,
                minLines: 3,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: '项目提示词（可选）',
                  helperText: '本项目新建会话时可在「启用项目提示词」中并入系统提示词',
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _memoryEnabled,
                onChanged: (value) => setState(() => _memoryEnabled = value),
                title: const Text('启用项目记忆（.memory/ 索引）'),
                subtitle: const Text(
                  '在工作目录里维护 .memory/：README / STATE / ARCHITECTURE / '
                  'GOTCHAS / MAP / PROMPT。本项目新建会话时自动注入记忆协议，'
                  'agent 会读写它。',
                ),
              ),
              if (existing != null)
                _MemoryStatusRow(
                  statusFuture: _statusFuture,
                  onInit: () async {
                    final ok = await state.ensureProjectMemory(existing);
                    if (!mounted) return;
                    setState(() {
                      _statusFuture = state.projectMemoryStatus(existing);
                    });
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(ok
                            ? '已初始化记忆索引：${existing.sandbox}/.memory'
                            : '初始化失败：工作目录不可写'),
                      ),
                    );
                  },
                )
              else
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '创建后会在工作目录里生成 .memory/ 骨架（README / STATE / '
                    'ARCHITECTURE / GOTCHAS / MAP / PROMPT）。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}


/// The 「记忆索引」status line inside the project dialog.
///
/// Shows whether the project's `.memory/` index exists and offers a
/// non-destructive "initialise / fill in the missing files" action.
class _MemoryStatusRow extends StatelessWidget {
  const _MemoryStatusRow({required this.statusFuture, required this.onInit});

  /// The (refreshable) status of the project's memory index.
  final Future<MemoryStatus>? statusFuture;

  /// Creates the index (or fills in the missing skeleton files).
  final Future<void> Function() onInit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<MemoryStatus>(
      future: statusFuture,
      builder: (context, snapshot) {
        final status = snapshot.data;
        final text = status == null
            ? '记忆索引：读取中…'
            : '记忆索引：${status.summary}'
                '${status.exists && status.isIncomplete ? '（缺 ${kMemoryFileNames.length - status.files.length} 个骨架文件）' : ''}';
        return Row(
          children: [
            Expanded(
              child: Text(text, style: theme.textTheme.bodySmall),
            ),
            TextButton(
              onPressed: () => onInit(),
              child: const Text('初始化 / 补齐'),
            ),
          ],
        );
      },
    );
  }
}
