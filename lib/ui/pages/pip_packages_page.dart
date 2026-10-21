import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_paths.dart';
import '../../core/python_packages.dart';
import '../../core/python_runtime.dart';
import '../../state/app_state.dart';
import '../widgets/confirm_dialog.dart';

/// pip 库管理：查看/卸载已安装的第三方库，并配置 pip 镜像链。
class PipPackagesPage extends StatefulWidget {
  const PipPackagesPage({super.key});

  @override
  State<PipPackagesPage> createState() => _PipPackagesPageState();
}

class _PipPackagesPageState extends State<PipPackagesPage> {
  PythonRuntime? _runtime;
  String _version = '';
  List<PythonPackage> _packages = const <PythonPackage>[];
  bool _loading = true;
  bool _busy = false;
  String? _message;
  final List<TextEditingController> _indexControllers = <TextEditingController>[];
  final TextEditingController _pythonPathController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _pythonPathController.text = context.read<AppState>().config.pythonPath;
    for (final url in context.read<AppState>().config.pipIndexUrls) {
      _indexControllers.add(TextEditingController(text: url));
    }
    _refresh();
  }

  @override
  void dispose() {
    _pythonPathController.dispose();
    for (final c in _indexControllers) {
      c.dispose();
    }
    super.dispose();
  }

  String get _packagesDir =>
      AppPaths.isReady ? AppPaths.instance.pythonPackagesDir : '';

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    final state = context.read<AppState>();
    final config = state.config;
    final runtime = await PythonRuntimeLocator.locate(
      source: config.pythonSource,
      customPath: config.pythonPath,
      packagesDir: _packagesDir,
    );
    final version = runtime == null ? '' : await runtime.probeVersion();
    final packages = await PythonPackageStore.list(_packagesDir);
    if (!mounted) return;
    setState(() {
      _runtime = runtime;
      _version = version;
      _packages = packages;
      _loading = false;
    });
  }

  /// 按镜像链顺序尝试安装：清华 → 阿里 → 官方。
  Future<void> _install(String name) async {
    final runtime = _runtime;
    if (runtime == null) {
      setState(() => _message = '未找到可用的 Python 解释器，无法安装。');
      return;
    }
    final state = context.read<AppState>();
    final config = state.config;
    final indexes = config.pipIndexUrls
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (indexes.isEmpty) {
      setState(() => _message = '未配置 pip 镜像源。');
      return;
    }
    setState(() {
      _busy = true;
      _message = '正在通过 ${pipIndexName(indexes.first)} 镜像安装 $name …';
    });

    final errors = <String>[];
    var done = false;
    for (final index in indexes) {
      if (!mounted) break;
      setState(() => _message = '正在通过 ${pipIndexName(index)} 镜像安装 $name …');
      final result = await Process.run(
        runtime.executable,
        <String>[
          '-m',
          'pip',
          'install',
          '--target',
          _packagesDir,
          '--upgrade',
          '--no-warn-script-location',
          '-i',
          index,
          name,
        ],
        environment: runtime.childEnvironment(
          proxy: config.proxy,
          pipIndexes: config.pipIndexUrls,
          pipCacheDir: AppPaths.isReady ? AppPaths.instance.pipCacheDir : null,
        ),
        workingDirectory: _packagesDir.isEmpty ? null : _packagesDir,
      ).timeout(Duration(seconds: config.pythonTimeoutSeconds));
      final output = '${result.stdout}\n${result.stderr}';
      if (result.exitCode == 0) {
        setState(() {
          _busy = false;
          _message = '安装成功（镜像：${pipIndexName(index)}）。';
        });
        done = true;
        break;
      }
      errors.add('【${pipIndexName(index)}】${_tail(output)}');
    }
    if (!done && mounted) {
      setState(() {
        _busy = false;
        _message = '全部镜像均安装失败：\n${errors.join('\n')}';
      });
    }
    if (done) await _refresh();
  }

  Future<void> _uninstall(PythonPackage pkg) async {
    final ok = await confirmDelete(context, 'Python 包「${pkg.name}」');
    if (!ok) return;
    setState(() => _busy = true);
    final removed = await PythonPackageStore.uninstall(pkg, _packagesDir);
    await _refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = '已卸载 ${pkg.name}（清理 $removed 个文件）。';
    });
  }

  void _saveIndexes(AppState state) {
    final urls = _indexControllers
        .map((c) => c.text.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    state.config.pipIndexUrls = urls.isEmpty ? kDefaultPipIndexUrls : urls;
    state.saveConfig();
    setState(() => _message = '已保存 pip 镜像配置：'
        '${state.config.pipIndexUrls.map(pipIndexName).join(' → ')}');
  }

  String _tail(String output) {
    final lines = output
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '(无输出)';
    return lines.take(6).join('\n');
  }

  Future<void> _promptInstall() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安装 Python 包'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '包名',
            hintText: '例如 pandas / requests / openpyxl',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _install(name);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('pip 库管理'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading || _busy ? null : _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(theme, 'Python 解释器', [
            DropdownButton<String>(
              value: state.config.pythonSource,
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('自动（内置优先，回落系统）')),
                DropdownMenuItem(value: 'builtin', child: Text('仅内置')),
                DropdownMenuItem(value: 'system', child: Text('系统 Python')),
                DropdownMenuItem(value: 'custom', child: Text('自定义路径')),
              ],
              onChanged: (value) async {
                if (value == null) return;
                state.config.pythonSource = value;
                await state.saveConfig();
                await _refresh();
              },
            ),
            if (state.config.pythonSource == 'custom') ...[
              const SizedBox(height: 8),
              TextField(
                controller: _pythonPathController,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '解释器路径',
                  hintText: '/usr/bin/python3 或解释器所在目录',
                ),
                onSubmitted: (value) async {
                  state.config.pythonPath = value.trim();
                  await state.saveConfig();
                  await _refresh();
                },
              ),
            ],
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              )
            else if (_runtime == null)
              const Text('未找到可用的 Python 解释器。可切换为「系统 Python」或指定自定义路径。')
            else ...[
              Text('当前：${_runtime!.originLabel}'
                  '${_version.isEmpty ? '' : ' · 版本 $_version'}'),
              const SizedBox(height: 6),
              Text('路径：${_runtime!.executable}', style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              Text('包目录：$_packagesDir', style: theme.textTheme.bodySmall),
            ],
          ]),
          const SizedBox(height: 12),
          _card(theme, 'pip 镜像源（按顺序回退）', [
            for (var i = 0; i < _indexControllers.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _indexControllers[i],
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: pipIndexName(_indexControllers[i].text),
                          hintText: 'https://pypi.org/simple',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _indexControllers.removeAt(i).dispose();
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  _indexControllers.add(TextEditingController(text: ''));
                  setState(() {});
                },
                icon: const Icon(Icons.add),
                label: const Text('添加镜像'),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                FilledButton(
                  onPressed: () => _saveIndexes(state),
                  child: const Text('保存镜像配置'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () {
                    for (final c in _indexControllers) {
                      c.dispose();
                    }
                    _indexControllers.clear();
                    for (final url in kDefaultPipIndexUrls) {
                      _indexControllers.add(TextEditingController(text: url));
                    }
                    setState(() {});
                  },
                  child: const Text('恢复默认（清华→阿里→官方）'),
                ),
              ],
            ),
          ]),
          const SizedBox(height: 12),
          _card(theme, '已安装的库（${_packages.length}）', [
            if (_packages.isEmpty)
              const Text('暂无第三方库。可点右下角按钮安装，或让 Agent 用 pip 安装。')
            else
              for (final pkg in _packages)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${pkg.name} ${pkg.version}'.trim()),
                  subtitle: Text(pkg.description),
                  trailing: IconButton(
                    tooltip: '卸载',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy ? null : () => _uninstall(pkg),
                  ),
                ),
          ]),
          if (_message != null) ...[
            const SizedBox(height: 12),
            _card(theme, '提示', [Text(_message!)]),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy || _runtime == null ? null : _promptInstall,
        icon: const Icon(Icons.add),
        label: const Text('安装包'),
      ),
    );
  }

  Widget _card(ThemeData theme, String title, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}
