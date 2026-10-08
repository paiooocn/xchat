import 'dart:convert';

import 'package:llm_api/llm_api.dart';

import '../../models/extract_script.dart';
import 'script_registry.dart';
import 'webview_extractor.dart';

/// Agent-facing tools that read a hidden WebView and manage the page-extraction
/// scripts used by it (and by `web_search`'s webview engine).
///
/// Workflow: `webview_fetch` (outline → html) to learn a page's structure →
/// write a script → `webview_extract` to verify it → `webview_script_mount` to
/// persist it, so the same URL pattern reuses it afterwards.
class WebViewTools {
  static List<LlmTool> build() => <LlmTool>[
        _fetch(),
        _extract(),
        _mount(),
        _list(),
        _unmount(),
      ];

  static LlmTool _fetch() => FunctionTool(
        name: 'webview_fetch',
        description: '用隐藏 WebView 加载 URL 并返回渲染后的内容（JS 动态站点可用）。'
            'mode=outline 返回 DOM 结构概要（默认，建议先用它了解页面结构）；'
            'mode=html 返回元素 HTML（配合 selector）；mode=text 返回纯文本。',
        parameters: objectSchema(
          properties: {
            'url': stringSchema(description: '要加载的 URL'),
            'mode': stringSchema(description: 'outline | html | text（默认 outline）'),
            'selector': stringSchema(description: 'CSS 选择器，限定提取范围（html/text 模式）'),
            'max_chars': integerSchema(description: '最多返回字符数', minimum: 1),
            'wait_selector': stringSchema(description: '等待该选择器出现再解析（JS 渲染站点）'),
          },
          required: ['url'],
        ),
        handler: (args) async {
          final url = '${args['url'] ?? ''}'.trim();
          final uri = Uri.tryParse(url);
          if (uri == null || !uri.hasScheme) return 'ERROR: invalid url: $url';
          final mode = '${args['mode'] ?? 'outline'}'.trim().toLowerCase();
          final selector = '${args['selector'] ?? ''}'.trim();
          final max = (args['max_chars'] as num?)?.toInt() ?? 20000;
          final waitSelector = '${args['wait_selector'] ?? ''}'.trim();
          final js = switch (mode) {
            'html' => htmlProbeScript(selector, max),
            'text' => textProbeScript(selector, max),
            _ => outlineProbeScript(),
          };
          final extractor = WebViewExtractor.shared;
          if (!extractor.available) return 'ERROR: ${extractor.unavailableReason}';
          try {
            final raw = await extractor.evaluate(uri, js, waitSelector: waitSelector);
            return _pretty(raw);
          } on WebViewBlockedException catch (error) {
            return 'ERROR: $error（可尝试配置代理或换用其它 URL）';
          } catch (error) {
            return 'ERROR: webview_fetch failed: $error';
          }
        },
      );

  static LlmTool _extract() => FunctionTool(
        name: 'webview_extract',
        description: '用隐藏 WebView 加载 URL 并按解析脚本提取结构化结果（标题/链接/摘要）。'
            'script_id 用已挂载脚本；或直接用 script 传入内联脚本先验证。'
            '未指定时按 URL 自动匹配已挂载脚本。',
        parameters: objectSchema(
          properties: {
            'url': stringSchema(description: '要加载的 URL'),
            'script_id': stringSchema(description: '已挂载脚本 id（与 script 二选一）'),
            'script': stringSchema(description: '内联解析脚本（与 script_id 二选一）'),
            'max_results': integerSchema(description: '结果数量', minimum: 1, maximum: 50),
            'wait_selector': stringSchema(description: '等待该选择器出现再解析'),
          },
          required: ['url'],
        ),
        handler: (args) async {
          final url = '${args['url'] ?? ''}'.trim();
          final uri = Uri.tryParse(url);
          if (uri == null || !uri.hasScheme) return 'ERROR: invalid url: $url';
          final max = (args['max_results'] as num?)?.toInt() ?? 8;
          final waitSelector = '${args['wait_selector'] ?? ''}'.trim();
          final inline = '${args['script'] ?? ''}'.trim();
          final scriptId = '${args['script_id'] ?? ''}'.trim();

          final registry = await ScriptRegistry.instance();
          final ExtractScript? script;
          if (inline.isNotEmpty) {
            script = ExtractScript.inline(id: 'inline', body: inline, readySelector: waitSelector);
          } else if (scriptId.isNotEmpty) {
            script = registry.byId(scriptId);
            if (script == null) {
              return 'ERROR: 未找到脚本 $scriptId（可用 webview_script_list 查看）';
            }
          } else {
            script = registry.resolve(uri);
            if (script == null) {
              return 'ERROR: 未指定脚本且无匹配脚本，请提供 script_id 或 script';
            }
          }

          final extractor = WebViewExtractor.shared;
          if (!extractor.available) return 'ERROR: ${extractor.unavailableReason}';
          try {
            final raw = await extractor.evaluate(
              uri,
              script.body,
              waitSelector: script.readySelector.trim().isNotEmpty
                  ? script.readySelector.trim()
                  : waitSelector,
            );
            final results = WebViewExtractor.decodeResults(raw).take(max).toList();
            if (results.isEmpty) {
              return 'ERROR: 脚本未提取到结果（页面结构可能已变化）';
            }
            return const JsonEncoder.withIndent('  ').convert({
              'script': script.id,
              'count': results.length,
              'results': results,
            });
          } on WebViewBlockedException catch (error) {
            return 'ERROR: $error';
          } catch (error) {
            return 'ERROR: webview_extract failed: $error';
          }
        },
      );

  static LlmTool _mount() => FunctionTool(
        name: 'webview_script_mount',
        description: '挂载（或更新）一份页面解析脚本并持久化到磁盘，之后相同 URL 模式会自动复用。'
            'body 必须是自执行函数且 return JSON.stringify([{title,url,snippet}])。',
        parameters: objectSchema(
          properties: {
            'id': stringSchema(description: '唯一标识（文件名：字母数字._-）'),
            'name': stringSchema(description: '展示名'),
            'body': stringSchema(description: '解析脚本（自执行函数，return JSON 字符串）'),
            'hosts': stringSchema(description: '逗号分隔 host（后缀匹配），如 example.com'),
            'path_prefix': stringSchema(description: '路径前缀，如 /search'),
            'url_pattern': stringSchema(description: '完整 URL 正则（优先级最高）'),
            'ready_selector': stringSchema(description: '等待该选择器出现再解析'),
            'priority': integerSchema(description: '匹配优先级（大者优先）'),
            'origin_url': stringSchema(description: '分析来源 URL（可追溯）'),
          },
          required: ['id', 'body'],
        ),
        handler: (args) async {
          final id = '${args['id'] ?? ''}'.trim();
          if (!ScriptRegistry.isValidId(id)) {
            return 'ERROR: id 非法（仅字母数字._-，且以字母数字开头）';
          }
          final body = '${args['body'] ?? ''}'.trim();
          if (body.isEmpty) return 'ERROR: body required';
          if (!body.contains('return')) {
            return 'ERROR: body 必须包含 return（返回 JSON 字符串）';
          }
          final hosts = '${args['hosts'] ?? ''}'
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          final pathPrefix = '${args['path_prefix'] ?? ''}'.trim();
          final urlPattern = '${args['url_pattern'] ?? ''}'.trim();
          if (hosts.isEmpty && pathPrefix.isEmpty && urlPattern.isEmpty) {
            return 'ERROR: 至少提供 hosts / path_prefix / url_pattern 之一作为匹配规则';
          }
          final name = '${args['name'] ?? ''}'.trim();
          final registry = await ScriptRegistry.instance();
          final existing = registry.byId(id);
          final now = DateTime.now();
          await registry.mount(ExtractScript(
            id: id,
            name: name.isEmpty ? id : name,
            body: body,
            matcher: UrlMatcher(hosts: hosts, pathPrefix: pathPrefix, urlPattern: urlPattern),
            readySelector: '${args['ready_selector'] ?? ''}'.trim(),
            priority: (args['priority'] as num?)?.toInt() ?? 0,
            createdBy: 'agent',
            originUrl: '${args['origin_url'] ?? ''}'.trim(),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
          ));
          return 'OK: 已挂载脚本 $id（${jsonEncode(UrlMatcher(hosts: hosts, pathPrefix: pathPrefix, urlPattern: urlPattern).toJson())}），'
              '相同 URL 模式将自动复用';
        },
      );

  static LlmTool _list() => FunctionTool(
        name: 'webview_script_list',
        description: '列出已挂载的页面解析脚本（内置 + agent/用户自建）。',
        parameters: objectSchema(properties: const <String, Object?>{}),
        handler: (_) async {
          final registry = await ScriptRegistry.instance();
          final scripts = registry.all;
          if (scripts.isEmpty) return 'No scripts mounted.';
          return const JsonEncoder.withIndent('  ').convert([
            for (final s in scripts)
              {
                'id': s.id,
                'name': s.name,
                'source': s.createdBy,
                'enabled': s.enabled,
                'priority': s.priority,
                'match': s.matcher.toJson(),
                if (s.originUrl.isNotEmpty) 'origin_url': s.originUrl,
              },
          ]);
        },
      );

  static LlmTool _unmount() => FunctionTool(
        name: 'webview_script_unmount',
        description: '卸载解析脚本（内置脚本仅禁用，agent/用户脚本删除文件）。',
        parameters: objectSchema(
          properties: {'id': stringSchema(description: '脚本 id')},
          required: ['id'],
        ),
        handler: (args) async {
          final id = '${args['id'] ?? ''}'.trim();
          if (id.isEmpty) return 'ERROR: id required';
          final registry = await ScriptRegistry.instance();
          final script = registry.byId(id);
          if (script == null) return 'ERROR: 未找到脚本 $id';
          final builtin = script.createdBy == 'builtin';
          await registry.unmount(id);
          return builtin ? 'OK: 内置脚本 $id 已禁用' : 'OK: 脚本 $id 已删除';
        },
      );

  static String _pretty(Object? raw) {
    if (raw is! String) return '$raw';
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'ERROR: empty result';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed));
    } catch (_) {
      return trimmed;
    }
  }
}

/// Renders a depth/node-limited `tag.class#id` outline of `document.body`.
String outlineProbeScript() => '''
(function () {
  var maxDepth = 6, maxNodes = 300;
  var count = 0, lines = [];
  function sig(el) {
    var tag = el.tagName ? el.tagName.toLowerCase() : "?";
    if (el.id) tag += "#" + el.id;
    var cls = (typeof el.className === "string" ? el.className : "").trim();
    if (cls) tag += "." + cls.split(/\\s+/).slice(0, 3).join(".");
    return tag;
  }
  function walk(el, depth) {
    if (count >= maxNodes || depth > maxDepth || !el.tagName) return;
    if (el.tagName === "SCRIPT" || el.tagName === "STYLE" || el.tagName === "NOSCRIPT") return;
    lines.push(new Array(depth + 1).join("  ") + sig(el));
    count++;
    var kids = el.children;
    for (var i = 0; i < kids.length; i++) walk(kids[i], depth + 1);
  }
  walk(document.body, 0);
  return JSON.stringify({ url: location.href, nodes: count, outline: lines.join("\\n") });
})()''';

/// Returns the outer HTML of the first element matching [selector].
String htmlProbeScript(String selector, int maxChars) {
  final sel = selector.isEmpty ? 'body' : selector;
  return '''
(function () {
  var el = document.querySelector(${jsonEncode(sel)});
  if (!el) return JSON.stringify({ found: false, selector: ${jsonEncode(sel)} });
  var html = el.outerHTML || "";
  return JSON.stringify({
    found: true,
    selector: ${jsonEncode(sel)},
    truncated: html.length > $maxChars,
    html: html.slice(0, $maxChars)
  });
})()''';
}

/// Returns the visible text of the first element matching [selector].
String textProbeScript(String selector, int maxChars) {
  final target = selector.isEmpty ? 'document.body' : 'document.querySelector(${jsonEncode(selector)})';
  return '''
(function () {
  var el = $target;
  if (!el) return JSON.stringify({ found: false });
  var text = (el.innerText || el.textContent || "");
  return JSON.stringify({
    found: true,
    truncated: text.length > $maxChars,
    text: text.slice(0, $maxChars)
  });
})()''';
}
