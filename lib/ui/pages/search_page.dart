import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../agent/tools/builtin_tools.dart';
import '../../agent/tools/script_registry.dart';
import '../../agent/tools/webview_extractor.dart';
import '../../agent/tools/webview_tools.dart';
import '../../models/search_engine_config.dart';
import '../../state/app_state.dart';
import '../../util/editor_launcher.dart';

/// Manual search page: pick an engine, run a query, inspect the results.
///
/// Each result can be opened in the system browser, or parsed by the hidden
/// WebView (the same path `webview_fetch` uses) to preview its content. This is
/// the GUI harness for validating `web_search` without going through the agent.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _query = TextEditingController();
  // Empty ⇒ use the engine's configured page count (webview engines aggregate
  // several SERP pages into one result list).
  final _pages = TextEditingController();
  String? _engineId;
  bool _busy = false;
  bool _filter = true;
  bool _raw = false;
  String? _error;
  WebSearchOutcome? _outcome;
  Uri? _lastUri;

  @override
  void dispose() {
    _query.dispose();
    _pages.dispose();
    super.dispose();
  }

  /// The engine to search with: the explicit pick, else the first enabled one.
  SearchEngineConfig? _selected(AppState state) {
    final engines = state.config.searchEngines;
    if (engines.isEmpty) return null;
    final id = _engineId;
    if (id != null) {
      for (final engine in engines) {
        if (engine.id == id) return engine;
      }
    }
    for (final engine in engines) {
      if (engine.enabled) return engine;
    }
    return engines.first;
  }

  Future<void> _run() async {
    final state = context.read<AppState>();
    final query = _query.text.trim();
    if (query.isEmpty) {
      setState(() => _error = '请输入搜索内容');
      return;
    }
    final engine = _selected(state);
    if (engine == null) {
      setState(() => _error = '没有可用的搜索引擎');
      return;
    }
    if (!engine.isReady) {
      setState(() => _error = '引擎「${engine.name}」未就绪：请检查配置（URL 模板 / API Key）');
      return;
    }
    // Manual search deliberately returns the full result list (no count cap).
    final pages = (int.tryParse(_pages.text.trim()) ?? engine.pageCount).clamp(1, 10);
    setState(() {
      _busy = true;
      _error = null;
      _outcome = null;
    });
    try {
      final picked = engine.copyWith(enabled: true);
      _lastUri = BuiltinTools.searchUrl(picked, query);
      final outcome = await BuiltinTools.search(
        // Manual testing should honor the explicit pick even if the engine is
        // disabled in settings.
        searchEngines: <SearchEngineConfig>[picked],
        query: query,
        max: null,
        filter: _filter,
        raw: _raw,
        // Aggregate this many SERP pages; the manual field overrides the
        // engine's own configured page count.
        pages: pages,
        // This page is the harness for fixing selectors/scripts: dump the SERP
        // HTML when nothing parses.
        diagnose: true,
      );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _busy = false;
        _error = outcome.results.isEmpty ? '未获取到结果：\n${outcome.errors.join('\n')}' : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  Future<void> _openInBrowser(String url) async {
    final result = await openUrl(url);
    if (!mounted || result.ok) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
  }

  /// Loads [url] in the hidden WebView and shows the rendered text.
  Future<void> _inspect(String url) async {
    final extractor = WebViewExtractor.shared;
    if (!extractor.available) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('隐藏 WebView 不可用：${extractor.unavailableReason}')),
      );
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    String content;
    try {
      final raw = await extractor.evaluate(
        Uri.parse(url),
        textProbeScript('', 8000),
        timeout: const Duration(seconds: 30),
      );
      content = _extractText(raw);
    } catch (error) {
      content = '解析失败：$error';
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('隐藏 WebView 解析'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: SingleChildScrollView(child: SelectableText(content)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  String _extractText(Object? raw) {
    if (raw is! String) return '$raw';
    try {
      final value = jsonDecode(raw);
      if (value is Map && value['text'] is String) return value['text'] as String;
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return raw;
    }
  }

  /// Dumps the last searched page's rendered HTML to disk for inspection.
  Future<void> _dumpHtml() async {
    final uri = _lastUri;
    if (uri == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先搜索一次')));
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    String path;
    try {
      final script = (await ScriptRegistry.instance()).resolve(uri);
      path = await BuiltinTools.dumpPageHtml(uri, waitSelector: script?.readySelector ?? '');
    } catch (error) {
      path = '落盘失败：$error';
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('页面已落盘：$path')));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final engines = state.config.searchEngines;
    final results = _outcome?.results ?? const <Map<String, Object?>>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('手动搜索'),
        actions: [
          IconButton(
            tooltip: '保存当前页面 HTML（供分析结构）',
            icon: const Icon(Icons.save_alt),
            onPressed: _lastUri == null ? null : _dumpHtml,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        initialValue: _selected(state)?.id,
                        decoration: const InputDecoration(
                          labelText: '搜索引擎',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final engine in engines)
                            DropdownMenuItem(
                              value: engine.id,
                              child: Text(
                                '${engine.name}${engine.enabled ? '' : '（已禁用）'} · 隐藏 WebView',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) => setState(() => _engineId = value),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _pages,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '聚合页数',
                          hintText: '引擎默认',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Checkbox(
                      value: _filter,
                      onChanged: _raw ? null : (value) => setState(() => _filter = value ?? true),
                    ),
                    const Expanded(
                      child: Text('相关性过滤（关闭可看引擎直出结果，便于对比）'),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Checkbox(
                      value: _raw,
                      onChanged: (value) => setState(() => _raw = value ?? false),
                    ),
                    const Expanded(
                      child: Text('完全原始（不去重/不筛选，显示全部条目）'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _query,
                        decoration: const InputDecoration(
                          labelText: '搜索内容',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) {
                          if (!_busy) _run();
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _busy ? null : _run,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search),
                      label: const Text('搜索'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_outcome != null && _outcome!.engine.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '引擎：${_outcome!.engine} · 显示 ${results.length} 条'
                  ' · 原始 ${_outcome!.rawCount} 条'
                  '${_outcome!.filtered ? '' : '（未过滤）'}'
                  '${_outcome!.dropped > 0 ? ' · ${_outcome!.filtered ? '过滤丢弃' : '去重/空值丢弃'} ${_outcome!.dropped} 条' : ''}',
                ),
              ),
            ),
          if (_outcome != null && _outcome!.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '翻页诊断：${_outcome!.notes.join('；')}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: results.isEmpty
                ? const Center(child: Text('暂无结果'))
                : ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = results[index];
                      final url = '${item['url'] ?? ''}';
                      final snippet = '${item['snippet'] ?? ''}';
                      return ListTile(
                        isThreeLine: snippet.isNotEmpty,
                        title: Text(
                          '${item['title'] ?? ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Theme.of(context).colorScheme.primary),
                            ),
                            if (snippet.isNotEmpty)
                              Text(snippet, maxLines: 2, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                        onTap: () => _openInBrowser(url),
                        trailing: IconButton(
                          icon: const Icon(Icons.travel_explore),
                          tooltip: '用隐藏 WebView 解析该页面',
                          onPressed: () => _inspect(url),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
