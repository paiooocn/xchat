import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/sync_item.dart';
import '../../state/app_state.dart';
import '../../sync/sync_service.dart';

/// 局域网双端配对同步：会话 / 项目在两个设备之间点对点传输。
///
/// 两侧界面完全一致（都既能显示配对码也能扫码配对，配对后都能看到两份清单），
/// 因为底层是「两端各开一个监听端口」的对称协议 —— 见 `SyncService`。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final SyncService _service;
  final Set<String> _checked = <String>{};

  /// 折叠起来的项目（默认全部展开：勾项目连带它的会话要看得见）。
  final Set<String> _collapsed = <String>{};
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _service = SyncService(context.read<AppState>());
    _service.addListener(_onServiceChanged);
    unawaited(_service.refreshLocal());
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _service.dispose();
    _codeController.dispose();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------------- actions

  Future<void> _scanAndPair() async {
    final target = await showModalBottomSheet<SyncPairTarget>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ScanSheet(),
    );
    if (target == null || !mounted) return;
    await _pair(host: target.host, port: target.port, code: target.code);
  }

  Future<void> _pair({
    required String host,
    required int port,
    required String code,
  }) async {
    final ok = await _service.pair(host: host, port: port, code: code);
    if (!mounted) return;
    if (ok) {
      setState(_checked.clear);
      _snack('已配对：${_service.peerDevice}');
    } else {
      _snack(_service.error ?? '配对失败');
    }
  }

  Future<void> _pairManual() async {
    final code = _codeController.text.trim();
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 0;
    if (code.length != 6) {
      _snack('配对码必须是 6 位数字');
      return;
    }
    if (host.isEmpty || port <= 0) {
      _snack('请填写对方显示的地址与端口');
      return;
    }
    await _pair(host: host, port: port, code: code);
  }

  Future<void> _runSync() async {
    final report = await _service.runSync(Set<String>.of(_checked));
    if (!mounted) return;
    final text = <String>[
      report.summary,
      if (report.notes.isNotEmpty) report.notes.take(3).join('；'),
    ].join('\n');
    _snack(text);
    if (report.ok) setState(_checked.clear);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('局域网同步'),
        actions: [
          if (_service.paired)
            IconButton(
              tooltip: '刷新两份清单',
              onPressed: _service.busy ? null : () => unawaited(_service.refresh()),
              icon: const Icon(Icons.refresh),
            ),
          if (_service.paired || _service.listening)
            IconButton(
              tooltip: _service.paired ? '断开配对' : '停止监听',
              onPressed: () {
                setState(_checked.clear);
                unawaited(_service.unpair());
              },
              icon: const Icon(Icons.link_off),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_service.busy) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _statusCard(theme),
          ),
          Expanded(
            child: _service.paired ? _pairedBody(theme) : _pairBody(theme),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(ThemeData theme) {
    final paired = _service.paired;
    final color = paired ? theme.colorScheme.primary : theme.colorScheme.outline;
    final text = paired
        ? '已配对：${_service.peerDevice}（${_service.peerAddress}）'
        : _service.listening
            ? '正在等待配对（端口 ${_service.port}）'
            : '未配对';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(paired ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                    size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(text, style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
            if (_service.error != null) ...[
              const SizedBox(height: 6),
              Text(
                _service.error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '只同步未归档的会话与项目；工作目录不随行，导入后使用本机各自的目录。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 未配对视图

  Widget _pairBody(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _codeCard(theme),
        const SizedBox(height: 12),
        _joinCard(theme),
      ],
    );
  }

  Widget _codeCard(ThemeData theme) {
    final code = _service.code;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本机配对码', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '让另一台设备打开同一页面，扫码或输入下面的配对码。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (code == null)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: () => unawaited(_service.startPairing()),
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('生成配对码'),
                ),
              )
            else ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: _service.qrPayload,
                    version: QrVersions.auto,
                    size: 176,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: SelectableText(
                  code,
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 10,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  '地址 ${_service.localAddress ?? '未知'} : ${_service.port}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => unawaited(_service.startPairing()),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('换一个配对码'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _joinCard(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('连接另一台设备', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              SyncService.canScan
                  ? '扫描对方屏幕上的二维码，或手动填写配对码与地址。'
                  : '本平台不支持摄像头扫码，请手动填写配对码与地址。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (SyncService.canScan) ...[
              FilledButton.tonalIcon(
                onPressed: _service.busy ? null : () => unawaited(_scanAndPair()),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码配对'),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: const InputDecoration(
                      labelText: '配对码',
                      hintText: '6 位数字',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostController,
                    decoration: const InputDecoration(
                      labelText: '对方地址',
                      hintText: '192.168.1.5',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 88,
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '端口',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _service.busy ? null : () => unawaited(_pairManual()),
                child: const Text('连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 配对视图

  Widget _pairedBody(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final local = _listCard(
          theme,
          title: '本机',
          items: _service.localItems,
          side: _Side.local,
        );
        final peer = _listCard(
          theme,
          title: '对端：${_service.peerDevice.isEmpty ? _service.peerAddress : _service.peerDevice}',
          items: _service.peerItems,
          side: _Side.peer,
        );
        final padding = const EdgeInsets.fromLTRB(16, 12, 16, 0);
        if (wide) {
          return Column(
            children: [
              Expanded(
                child: Padding(
                  padding: padding,
                  child: Row(
                    children: [
                      Expanded(child: local),
                      const SizedBox(width: 12),
                      Expanded(child: peer),
                    ],
                  ),
                ),
              ),
              _syncBar(theme),
            ],
          );
        }
        // 窄屏（手机）：两个列表改用 Tab，不做上下分屏。
        return DefaultTabController(
          length: 2,
          child: Column(
            children: [
              TabBar(
                tabs: [
                  Tab(text: '本机 · ${_service.localItems.length}'),
                  Tab(text: '对端 · ${_service.peerItems.length}'),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: padding,
                  child: TabBarView(children: [local, peer]),
                ),
              ),
              _syncBar(theme),
            ],
          ),
        );
      },
    );
  }

  Widget _listCard(
    ThemeData theme, {
    required String title,
    required List<SyncItemSummary> items,
    required _Side side,
  }) {
    final keys = <String>{for (final item in items) item.key};
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$title · ${items.length} 项',
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: items.isEmpty
                      ? null
                      : () => setState(() => _checked.addAll(keys)),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: keys.isEmpty
                      ? null
                      : () => setState(() => _checked.removeAll(keys)),
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        side == _Side.local
                            ? '本机没有可同步的会话或项目（已归档的不参与同步）'
                            : '对端没有可同步的会话或项目',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 8),
                    children: _rows(theme, items),
                  ),
          ),
        ],
      ),
    );
  }

  /// 勾选 / 取消一项；勾「项目」连带它名下的会话（两侧清单都算）。
  void _toggle(SyncItemSummary item, bool value) {
    setState(() {
      final keys = <String>{item.key};
      if (item.kind == SyncItemKind.project) {
        for (final other in <SyncItemSummary>[
          ..._service.localItems,
          ..._service.peerItems,
        ]) {
          if (other.kind == SyncItemKind.session && other.projectId == item.id) {
            keys.add(other.key);
          }
        }
      }
      if (value) {
        _checked.addAll(keys);
        // 勾上项目时展开它，让「连带同步的会话」看得见。
        if (item.kind == SyncItemKind.project) _collapsed.remove(item.key);
      } else {
        _checked.removeAll(keys);
      }
    });
  }

  /// 把平铺清单折成「项目 + 它名下的会话」；不属于任何项目的会话单列在最后。
  List<_SyncGroup> _groups(List<SyncItemSummary> items) {
    final projects = <String, SyncItemSummary>{
      for (final item in items)
        if (item.kind == SyncItemKind.project) item.id: item,
    };
    final owned = <String, List<SyncItemSummary>>{};
    final standalone = <SyncItemSummary>[];
    for (final item in items) {
      if (item.kind == SyncItemKind.project) continue;
      if (item.projectId.isNotEmpty && projects.containsKey(item.projectId)) {
        owned.putIfAbsent(item.projectId, () => <SyncItemSummary>[]).add(item);
      } else {
        standalone.add(item);
      }
    }
    return <_SyncGroup>[
      for (final item in items)
        if (item.kind == SyncItemKind.project)
          _SyncGroup(project: item, sessions: owned[item.id] ?? const <SyncItemSummary>[]),
      for (final item in standalone) _SyncGroup(project: null, sessions: <SyncItemSummary>[item]),
    ];
  }

  List<Widget> _rows(ThemeData theme, List<SyncItemSummary> items) {
    final rows = <Widget>[];
    for (final group in _groups(items)) {
      final project = group.project;
      if (project == null) {
        for (final session in group.sessions) {
          rows.add(_sessionRow(theme, session, nested: false));
        }
        continue;
      }
      final collapsed = _collapsed.contains(project.key);
      rows.add(_projectRow(theme, project, collapsed: collapsed));
      if (collapsed) continue;
      for (final session in group.sessions) {
        rows.add(_sessionRow(theme, session, nested: true));
      }
    }
    return rows;
  }

  /// 项目行：左边箭头折叠、图标、两行文字，复选框在最右。
  Widget _projectRow(
    ThemeData theme,
    SyncItemSummary project, {
    required bool collapsed,
  }) {
    final checked = _checked.contains(project.key);
    return InkWell(
      onTap: _service.busy
          ? null
          : () => setState(() {
                if (collapsed) {
                  _collapsed.remove(project.key);
                } else {
                  _collapsed.add(project.key);
                }
              }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 2, 6, 2),
        child: Row(
          children: [
            Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 2),
            // 侧栏里的项目图标：用它区分类型，不再写「项目」字样。
            Icon(Icons.folder_outlined,
                size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: _twoLines(
                theme,
                title: project.title.isEmpty ? project.id : project.title,
                time: _formatTime(project.updatedAt),
                second: project.sessionCount > 0
                    ? '${project.sessionCount} 个会话'
                    : '暂无会话',
              ),
            ),
            _checkBox(project, checked),
          ],
        ),
      ),
    );
  }

  /// 会话行：缩进挂在项目下面，复选框同样在最右。
  Widget _sessionRow(
    ThemeData theme,
    SyncItemSummary session, {
    required bool nested,
  }) {
    final checked = _checked.contains(session.key);
    return InkWell(
      onTap: _service.busy ? null : () => _toggle(session, !checked),
      child: Padding(
        padding: EdgeInsets.fromLTRB(nested ? 26 : 22, 2, 6, 2),
        child: Row(
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: _twoLines(
                theme,
                title: session.title.isEmpty ? session.id : session.title,
                time: _formatTime(session.updatedAt),
                // 会话的第 2 行 = 所属项目名。
                second: session.subtitle.isEmpty ? '未归属项目' : session.subtitle,
              ),
            ),
            _checkBox(session, checked),
          ],
        ),
      ),
    );
  }

  Widget _checkBox(SyncItemSummary item, bool checked) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Checkbox(
          value: checked,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged:
              _service.busy ? null : (value) => _toggle(item, value == true),
        ),
      );

  /// 第 1 行「名字 + 日期时间」，第 2 行由调用方给（会话数 / 所属项目）。
  Widget _twoLines(
    ThemeData theme, {
    required String title,
    required String time,
    required String second,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              time,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
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
    );
  }

  Widget _syncBar(ThemeData theme) {
    final localKeys = <String>{for (final item in _service.localItems) item.key};
    final peerKeys = <String>{for (final item in _service.peerItems) item.key};
    final up = _checked.where(localKeys.contains).length;
    final down = _checked.where(peerKeys.contains).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _checked.isEmpty
                  ? '勾选要同步的项（同一条目在两侧联动，勾项目连带它的会话）'
                  : '已勾选 ${_checked.length} 项：发送 $up · 接收 $down',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: (_service.busy || _checked.isEmpty)
                ? null
                : () => unawaited(_runSync()),
            icon: const Icon(Icons.sync),
            label: const Text('同步'),
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

enum _Side { local, peer }

/// 树里的一组：一个项目 + 它名下的会话；`project == null` 表示独立会话。
class _SyncGroup {
  _SyncGroup({required this.project, required this.sessions});

  final SyncItemSummary? project;
  final List<SyncItemSummary> sessions;
}

/// 摄像头扫码：识别配对二维码，成功即关闭并回传坐标。
class _ScanSheet extends StatefulWidget {
  const _ScanSheet();

  @override
  State<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<_ScanSheet> {
  late final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
  );
  bool _done = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final target = SyncPairTarget.parse(raw);
      if (target == null) continue;
      _done = true;
      Navigator.of(context).pop(target);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 380,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('扫描对方屏幕上的配对二维码',
                      style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
            ),
          ),
        ],
      ),
    );
  }
}
