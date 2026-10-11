import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:llm_api/llm_api.dart';
import 'package:path/path.dart' as p;

import '../../core/app_paths.dart';
import '../../models/app_config.dart';
import '../../models/extract_script.dart';
import '../../models/proxy_config.dart';
import '../../models/search_engine_config.dart';
import '../../models/shell_exec.dart';
import 'browser_session.dart';
import 'image_attach.dart';
import 'path_guard.dart';
import 'script_registry.dart';
import 'search_filter.dart';
import 'webview_extractor.dart';
import 'webview_tools.dart';

/// The catalogue of built-in tools and their metadata.
class BuiltinTools {
  static const descriptions = <String, String>{
    'read_file': '读取文件内容（限会话沙箱目录；图片文件会作为图像返回给模型）',
    'write_file': '写入文件（自动创建目录，限沙箱）',
    'edit_file': '对文件做精确字符串替换编辑',
    'list_dir': '列出目录内容',
    'glob': '按通配符匹配文件路径',
    'shell': '执行 shell 命令（桌面端，工作目录=沙箱）',
    'http_fetch': '抓取网页/接口文本内容',
    'web_search': '联网搜索（隐藏 WebView 渲染 SERP 后解析，可绕开反爬/验证码）',
    'webview_fetch': '用隐藏 WebView 加载 URL 并返回渲染后的内容（outline/html/text）',
    'webview_extract': '用隐藏 WebView 按解析脚本提取结构化结果',
    'webview_script_mount': '挂载/更新页面解析脚本（持久化，相同 URL 自动复用）',
    'webview_script_list': '列出已挂载的页面解析脚本',
    'webview_script_unmount': '卸载页面解析脚本',
    'attach_image': '把沙箱内的图片附加到对话（模型下一轮即可看到）',
    'datetime': '获取当前日期时间',
  };

  /// Agent tools that drive the hidden WebView (see [WebViewTools]).
  static const _webviewToolNames = <String>{
    'webview_fetch',
    'webview_extract',
    'webview_script_mount',
    'webview_script_list',
    'webview_script_unmount',
  };

  /// Builds the tool objects enabled for a session.
  static List<LlmTool> build({
    required String sandbox,
    required Iterable<String> enabled,
    List<SearchEngineConfig> searchEngines = const <SearchEngineConfig>[],
    ProxyConfig? proxy,
    bool shellEnabled = true,
    ShellExecConfig shellExec = const ShellExecConfig(),
    int maxAttachmentBytes = kDefaultMaxAttachmentBytes,
  }) {
    final guard = PathGuard(sandbox);
    final proxyConfig = proxy ?? ProxyConfig();
    final tools = <LlmTool>[];
    final set = enabled.toSet();
    // Hidden-WebView tools are built as a group, then filtered by name.
    final webviewWanted = set.intersection(_webviewToolNames);
    if (webviewWanted.isNotEmpty) {
      tools.addAll(WebViewTools.build().where((t) => webviewWanted.contains(t.name)));
    }
    for (final name in set) {
      switch (name) {
        case 'read_file':
          tools.add(_readFile(guard));
        case 'write_file':
          tools.add(_writeFile(guard));
        case 'edit_file':
          tools.add(_editFile(guard));
        case 'list_dir':
          tools.add(_listDir(guard));
        case 'glob':
          tools.add(_glob(guard));
        case 'shell':
          if (shellEnabled) tools.add(_shell(sandbox, shellExec));
        case 'http_fetch':
          tools.add(_httpFetch(proxyConfig));
        case 'web_search':
          tools.add(_webSearch(searchEngines));
        case 'attach_image':
          tools.add(_attachImage(guard, maxAttachmentBytes));
        case 'datetime':
          tools.add(_datetime());
      }
    }
    return tools;
  }

  static LlmTool _readFile(PathGuard guard) => FunctionTool(
        name: 'read_file',
        description: '读取文件内容。path 为相对沙箱的路径或绝对路径（必须在沙箱内）。'
            '图片文件（png/jpg/webp/gif/bmp）会被直接作为图像返回给模型，可用于看图识别。',
        parameters: objectSchema(
          properties: {
            'path': stringSchema(description: '文件路径'),
            'max_chars': integerSchema(description: '最多返回字符数', minimum: 1),
          },
          required: ['path'],
        ),
        handler: (args) async {
          final path = guard.resolveReal('${args['path']}');
          final file = File(path);
          if (!await file.exists()) return 'ERROR: file not found: $path';
          // Pictures are not text: the engine hangs the image off this tool
          // message, so answering with a marker (instead of decoded garbage)
          // is what lets the model actually look at it next turn.
          if (looksLikeImagePath(path)) {
            return 'IMAGE: ${p.basename(path)}（图片已随本条消息附加，可直接查看图像内容；'
                '如需裁剪/转换请用 shell 处理后再次读取）';
          }
          final bytes = await file.readAsBytes();
          String content;
          try {
            content = utf8.decode(bytes);
          } on FormatException {
            return 'ERROR: $path 不是 UTF-8 文本文件（二进制 ${bytes.length} 字节），无法按文本读取。';
          }
          final max = (args['max_chars'] as num?)?.toInt() ?? 200000;
          if (content.length <= max) return content;
          return '${content.substring(0, max)}\n…[truncated ${content.length - max} chars]';
        },
      );

  static LlmTool _writeFile(PathGuard guard) => FunctionTool(
        name: 'write_file',
        description: '写入文件（覆盖），自动创建父目录。',
        parameters: objectSchema(
          properties: {
            'path': stringSchema(description: '文件路径'),
            'content': stringSchema(description: '文件内容'),
          },
          required: ['path', 'content'],
        ),
        handler: (args) async {
          final path = guard.resolve('${args['path']}');
          final file = File(path);
          await file.parent.create(recursive: true);
          final content = '${args['content'] ?? ''}';
          await file.writeAsString(content, flush: true);
          return 'OK: wrote ${p.basename(path)} (${content.length} chars)';
        },
      );

  static LlmTool _editFile(PathGuard guard) => FunctionTool(
        name: 'edit_file',
        description: '在文件中用 new_string 精确替换 old_string（默认仅第一处）。',
        parameters: objectSchema(
          properties: {
            'path': stringSchema(description: '文件路径'),
            'old_string': stringSchema(description: '被替换的文本'),
            'new_string': stringSchema(description: '替换后的文本'),
            'replace_all': booleanSchema(description: '是否替换全部（默认 false）'),
          },
          required: ['path', 'old_string', 'new_string'],
        ),
        handler: (args) async {
          final path = guard.resolveReal('${args['path']}');
          final file = File(path);
          if (!await file.exists()) return 'ERROR: file not found: $path';
          final content = await file.readAsString();
          final old = '${args['old_string'] ?? ''}';
          final replacement = '${args['new_string'] ?? ''}';
          if (old.isEmpty) return 'ERROR: old_string must not be empty';
          if (!content.contains(old)) return 'ERROR: old_string not found';
          final all = args['replace_all'] == true;
          final updated = all ? content.replaceAll(old, replacement) : content.replaceFirst(old, replacement);
          await file.writeAsString(updated, flush: true);
          final count = all ? old.allMatches(content).length : 1;
          return 'OK: replaced $count occurrence(s)';
        },
      );

  static LlmTool _listDir(PathGuard guard) => FunctionTool(
        name: 'list_dir',
        description: '列出目录内容（相对沙箱路径）。',
        parameters: objectSchema(
          properties: {'path': stringSchema(description: '目录路径，默认 .')},
        ),
        handler: (args) async {
          final raw = '${args['path'] ?? '.'}';
          final path = guard.resolve(raw.isEmpty ? '.' : raw);
          final dir = Directory(path);
          if (!await dir.exists()) return 'ERROR: not a directory: $path';
          final entries = <Map<String, Object?>>[];
          await for (final entity in dir.list(followLinks: false)) {
            entries.add({
              'name': p.basename(entity.path),
              'type': entity is Directory ? 'dir' : 'file',
              if (entity is File) 'size': await entity.length(),
            });
          }
          return const JsonEncoder.withIndent('  ').convert(entries);
        },
      );

  static LlmTool _glob(PathGuard guard) => FunctionTool(
        name: 'glob',
        description: '按 glob 模式（如 **/*.dart）在沙箱内匹配文件。',
        parameters: objectSchema(
          properties: {
            'pattern': stringSchema(description: 'glob 模式'),
            'max_results': integerSchema(description: '最多返回数量', minimum: 1),
          },
          required: ['pattern'],
        ),
        handler: (args) async {
          final pattern = '${args['pattern'] ?? ''}';
          if (pattern.isEmpty) return 'ERROR: pattern required';
          final base = p.normalize(p.absolute(guard.sandbox));
          final matches = <String>[];
          final regExp = _globToRegExp(pattern);
          final max = (args['max_results'] as num?)?.toInt() ?? 200;
          await for (final entity in Directory(base).list(recursive: true, followLinks: false)) {
            final rel = p.relative(entity.path, from: base);
            if (regExp.hasMatch(rel)) {
              matches.add(rel);
              if (matches.length >= max) break;
            }
          }
          return matches.isEmpty ? 'No matches.' : matches.join('\n');
        },
      );

  static LlmTool _shell(String sandbox, ShellExecConfig shellExec) =>
      _ShellTool(sandbox, shellExec);

  static LlmTool _attachImage(PathGuard guard, int maxBytes) => FunctionTool(
        name: 'attach_image',
        description: '把沙箱内的一张图片附加到当前对话，模型下一轮即可直接看到它。'
            '典型用法：先用 shell 生成图片（如 '
            'chromium --headless --disable-gpu --screenshot=shot.png --window-size=1280,800 <url>），'
            '再用本工具附加；也可附加沙箱内已有的图片文件。',
        parameters: objectSchema(
          properties: {
            'path': stringSchema(description: '沙箱内的图片路径（相对沙箱或绝对路径）'),
          },
          required: ['path'],
        ),
        handler: (args) async {
          final result = await resolveAttachableImage(
            guard: guard,
            maxBytes: maxBytes,
            rawPath: '${args['path'] ?? ''}',
          );
          if (!result.ok) return result.error;
          final file = result.attachment!;
          return 'OK: 已附加图片 ${file.name}（${file.mimeType}，沙箱内路径 '
              '${guard.resolve(file.path ?? '')}），模型下一轮可直接查看该图。';
        },
      );

  static LlmTool _httpFetch(ProxyConfig proxy) => FunctionTool(
        name: 'http_fetch',
        description: 'GET 抓取 URL 并返回文本（HTML 会被转成纯文本）。',
        parameters: objectSchema(
          properties: {
            'url': stringSchema(description: '要抓取的 URL'),
            'max_chars': integerSchema(description: '最多返回字符数', minimum: 1),
          },
          required: ['url'],
        ),
        handler: (args) async {
          final url = '${args['url'] ?? ''}';
          if (url.isEmpty) return 'ERROR: url required';
          final session = BrowserSession(proxy: proxy.applyToHttpFetch ? proxy : ProxyConfig());
          try {
            final page = await _fetchPage(session, Uri.parse(url));
            if (page.statusCode >= 400) {
              return 'ERROR: HTTP ${page.statusCode}';
            }
            var text = page.body;
            if (page.contentType.contains('html')) {
              text = html_parser.parse(text).body?.text ?? text;
            }
            final max = (args['max_chars'] as num?)?.toInt() ?? 20000;
            if (text.length > max) {
              return '${text.substring(0, max)}\n…[truncated ${text.length - max} chars]';
            }
            return text;
          } finally {
            session.close();
          }
        },
      );

  static LlmTool _webSearch(List<SearchEngineConfig> searchEngines) => FunctionTool(
        name: 'web_search',
        description: '联网搜索并返回标题/链接/摘要（在隐藏 WebView 中渲染 SERP 后解析，可绕开反爬/验证码）。'
            'query 请用精炼关键词（不要整句长问题），结果已过滤广告/跳转链接/无关内容。',
        parameters: objectSchema(
          properties: {
            'query': stringSchema(description: '搜索关键词'),
            'max_results': integerSchema(description: '结果数量', minimum: 1, maximum: 20),
            'pages': integerSchema(
              description: '聚合的 SERP 页数（覆盖引擎配置，1–10）',
              minimum: 1,
              maximum: 10,
            ),
          },
          required: ['query'],
        ),
        handler: (args) async {
          final query = '${args['query'] ?? ''}'.trim();
          if (query.isEmpty) return 'ERROR: query required';
          final max = (args['max_results'] as num?)?.toInt() ?? 8;
          final pages = (args['pages'] as num?)?.toInt();
          final outcome = await search(
            searchEngines: searchEngines,
            query: query,
            max: max,
            pages: pages,
          );
          if (outcome.results.isEmpty) {
            return 'ERROR: all search engines failed:\n${outcome.errors.join('\n')}';
          }
          return const JsonEncoder.withIndent('  ').convert({
            'query': outcome.query,
            'engine': outcome.engine,
            'results': outcome.results,
            if (outcome.query != query) 'note': '原 query 未命中，已用改写关键词重试命中',
            if (outcome.notes.isNotEmpty) 'paging': outcome.notes,
            if (outcome.dropped > 0)
              'filtered': 'dropped ${outcome.dropped} junk/irrelevant/duplicate items',
          });
        },
      );

  /// Runs a web search through the hidden WebView, trying each enabled engine in
  /// order until one yields results (a blocked or changed SERP simply falls
  /// through to the next engine).
  ///
  /// Shared by the `web_search` tool and the manual search page, so both go
  /// through the same paged extraction, relevance filtering and fallback.
  /// [max] caps the returned list; `null` returns everything the SERP yielded.
  static Future<WebSearchOutcome> search({
    required List<SearchEngineConfig> searchEngines,
    required String query,
    int? max = 8,
    bool filter = true,
    bool raw = false,
    int? pages,
    bool diagnose = false,
  }) async {
    Future<WebSearchOutcome> run(String q) async {
      final errors = <String>[];
      for (final engine in searchEngines.where((e) => e.enabled && e.isReady)) {
        try {
          final outcome = await _searchOne(
            engine: engine,
            query: q,
            max: max,
            filter: filter,
            raw: raw,
            pages: pages,
            diagnose: diagnose,
          );
          if (outcome.results.isNotEmpty) return outcome;
          errors.addAll(outcome.errors);
        } catch (error) {
          errors.add('${engine.name}: $error');
        }
      }
      return WebSearchOutcome(
        engine: '',
        query: q,
        results: const <Map<String, Object?>>[],
        rawCount: 0,
        dropped: 0,
        filtered: filter,
        errors: errors,
      );
    }

    final outcome = await run(query);
    if (!filter || outcome.results.isNotEmpty) return outcome;
    // Long natural-language queries are the easiest target for cloaking, and a
    // date-leading query (`11月-3月国内…`) is misread by the engines (SERPs
    // anchor on the leading token) — retry with rewritten keywords: qualifiers
    // moved behind the intent words, then a keyword-only form.
    for (final variant in SearchFilter.retryQueries(query)) {
      outcome.errors.add('no usable results for the original query, retrying with: $variant');
      final retry = await run(variant);
      if (retry.results.isNotEmpty) return retry;
    }
    return outcome;
  }

  static LlmTool _datetime() => FunctionTool(
        name: 'datetime',
        description: '获取当前日期时间（本地与 UTC）。',
        parameters: objectSchema(properties: const {}),
        handler: (_) async {
          final now = DateTime.now();
          return jsonEncode({
            'local': now.toIso8601String(),
            'utc': now.toUtc().toIso8601String(),
            'timezone': now.timeZoneName,
          });
        },
      );

  /// Resolves [href] against [base] and unwraps engine redirectors
  /// (DuckDuckGo `/l/?uddg=…`, Bing `/ck/a?…&u=a1<base64url>`).
  static String _unwrapLink(String href, Uri base) {
    final raw = href.trim();
    if (raw.isEmpty) return '';
    final Uri uri;
    try {
      uri = base.resolveUri(Uri.parse(raw));
    } catch (_) {
      return raw;
    }
    if (uri.host.endsWith('duckduckgo.com') && uri.path.startsWith('/l/')) {
      final target = uri.queryParameters['uddg'] ?? '';
      if (target.isNotEmpty) return target;
    }
    if (uri.host.endsWith('bing.com') && uri.path.startsWith('/ck/')) {
      final u = uri.queryParameters['u'] ?? '';
      final payload = u.startsWith('a1') ? u.substring(2) : u;
      if (payload.isNotEmpty) {
        try {
          final decoded =
              utf8.decode(base64Url.decode(base64Url.normalize(payload)), allowMalformed: true);
          if (decoded.startsWith('http')) return decoded;
        } catch (_) {
          // Not decodable — keep the redirect URL as-is.
        }
      }
    }
    return uri.toString();
  }

  /// The SERP URL a WebView request should load for [engine], or `null` when the
  /// engine has no browsable page (its template lacks the `{query}` placeholder).
  static Uri? searchUrl(SearchEngineConfig engine, String query) {
    final template = engine.urlTemplate.trim();
    if (!template.contains('{query}')) return null;
    return Uri.tryParse(template.replaceAll('{query}', Uri.encodeQueryComponent(query)));
  }

  /// Resolves the extraction script for [engine] on [uri], in precedence order:
  /// inline `extractScript` → [ScriptRegistry] match → CSS selectors → error.
  static Future<ExtractScript> _resolveScript(SearchEngineConfig engine, Uri uri) async {
    if (engine.extractScript.trim().isNotEmpty) {
      return ExtractScript.inline(
        id: engine.id,
        body: engine.extractScript.trim(),
        readySelector: engine.readySelector,
        nextSelector: engine.nextSelector,
      );
    }
    final matched = (await ScriptRegistry.instance()).resolve(uri);
    if (matched != null) return matched;
    if (engine.resultSelector.trim().isNotEmpty) {
      return ExtractScript.fromSelectors(
        id: engine.id,
        name: engine.name,
        resultSelector: engine.resultSelector,
        titleSelector: engine.titleSelector,
        linkSelector: engine.linkSelector,
        snippetSelector: engine.snippetSelector,
        readySelector: engine.readySelector,
        nextSelector: engine.nextSelector,
        originUrl: uri.toString(),
      );
    }
    throw StateError(
        '引擎「${engine.name}」无可用解析脚本：请配置 CSS 选择器或用 webview_script_mount 挂载脚本');
  }

  /// The "next page" selector for a webview search: the script's own selector
  /// wins (built-in / agent-mounted scripts know their SERP), else the engine
  /// config's. Empty ⇒ single-page search.
  static String _nextSelector(ExtractScript script, SearchEngineConfig engine) {
    final fromScript = script.nextSelector.trim();
    return fromScript.isNotEmpty ? fromScript : engine.nextSelector.trim();
  }

  /// Loads [engine]'s SERP in the hidden WebView, applies the junk/relevance
  /// filter and returns the outcome.
  ///
  /// [pages] overrides the engine's configured page count; [diagnose] also dumps
  /// the SERP HTML to disk when the script parses nothing (manual search page).
  static Future<WebSearchOutcome> _searchOne({
    required SearchEngineConfig engine,
    required String query,
    int? max = 8,
    bool filter = true,
    bool raw = false,
    int? pages,
    bool diagnose = false,
  }) async {
    final uri = searchUrl(engine, query);
    if (uri == null) {
      throw StateError('引擎「${engine.name}」缺少含 {query} 的搜索 URL 模板');
    }
    final script = await _resolveScript(engine, uri);
    final extractor = WebViewExtractor.shared;
    if (!extractor.available) throw StateError(extractor.unavailableReason);
    // Paged extraction: follows the "next" link up to [pages] times, merging
    // every page into one de-duplicated list.
    final count = (pages ?? engine.pageCount).clamp(1, 10);
    final paged = await extractor.evaluatePaged(
      uri,
      script.body,
      readySelector: script.readySelector,
      nextSelector: _nextSelector(script, engine),
      maxPages: count,
    );
    final decoded = _unwrapLinks(paged.items, uri);
    final List<Map<String, Object?>> results;
    final int dropped;
    if (raw) {
      // No filtering at all: every parsed item, duplicates included, no cap.
      results = decoded;
      dropped = 0;
    } else {
      final matched = filter ? SearchFilter.usable(query, decoded) : SearchFilter.dedupe(decoded);
      results = max == null ? matched : matched.take(max).toList();
      dropped = decoded.length - matched.length;
    }
    final errors = <String>[];
    final notes = <String>[];
    final pagingNote = paged.note;
    if (pagingNote != null) notes.add(pagingNote);
    // Persist the paging trace (page URLs + per-page counts): afterwards it is
    // the only way to tell "the engine refused to page" from "our trigger
    // failed" — the live UI only shows the one-line note.
    if (pagingNote != null) await _logPaging(query, uri, paged);
    if (decoded.isEmpty) {
      final dump = diagnose
          ? '（页面 HTML 已落盘：${await dumpPageHtml(uri, waitSelector: script.readySelector)}）'
          : '';
      errors.add('WebView 已加载 ${uri.host}${uri.path}，但脚本（${script.id}）未解析到结果：'
          '页面结构可能变化，或选择器/脚本不匹配$dump');
    } else if (results.isEmpty) {
      errors.add('脚本解析到 ${decoded.length} 条，但被过滤规则全部丢弃'
          '（可关闭「相关性过滤」查看原始结果）');
    }
    return WebSearchOutcome(
      engine: '${engine.name} · WebView'
          '${count > 1 ? ' · 聚合${paged.pagesFetched}/$count页' : ''}${raw ? '（原始）' : ''}',
      query: query,
      results: results,
      rawCount: decoded.length,
      dropped: dropped,
      filtered: raw ? false : filter,
      errors: errors,
      notes: notes,
    );
  }

  /// Rewrites engine redirector links (Bing `ck/a`, DuckDuckGo `/l/?uddg=`) into
  /// their real destination, so the model (and the UI) sees the final URL.
  static List<Map<String, Object?>> _unwrapLinks(List<Map<String, Object?>> items, Uri base) => [
        for (final item in items)
          {...item, 'url': _unwrapLink('${item['url'] ?? ''}', base)},
      ];

  /// Appends a paging trace to `<logs>/webview/paging.log` (best-effort).
  static Future<void> _logPaging(String query, Uri uri, PagedExtraction paged) async {
    if (!AppPaths.isReady) return;
    try {
      final dir = Directory(p.join(AppPaths.instance.logsDir, 'webview'));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'paging.log'));
      final stamp = DateTime.now().toIso8601String();
      await file.writeAsString(
        '[$stamp] query=$query\n'
        '  url=$uri\n'
        '  next_selector=${paged.nextSelector.isEmpty ? '(空)' : paged.nextSelector}\n'
        '  ${paged.note}\n'
        '${paged.trace.map((line) => '  $line').join('\n')}\n\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Diagnostics must never fail a search.
    }
  }

  /// Dumps the rendered page HTML to `<logs>/webview/last.html` for offline
  /// inspection; returns the path, or a short failure note.
  static Future<String> dumpPageHtml(Uri url, {String waitSelector = ''}) async {
    try {
      final html = await WebViewExtractor.shared.captureHtml(url, waitSelector: waitSelector);
      if (html.isEmpty) return '(页面为空，未能落盘)';
      if (!AppPaths.isReady) return '(数据目录未就绪，未能落盘)';
      final dir = Directory(p.join(AppPaths.instance.logsDir, 'webview'));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'last.html'));
      await file.writeAsString(html, flush: true);
      return file.path;
    } catch (error) {
      return '(落盘失败：$error)';
    }
  }

  /// Browser-tier fetch: plain HTTP first; when the answer is a JS/captcha
  /// wall and a local Chromium exists, falls back to real headless rendering.
  static Future<BrowserPage> _fetchPage(BrowserSession session, Uri uri) async {
    var page = await session.get(uri);
    if (BrowserSession.looksBlocked(page.body) && session.canRender) {
      final dom = await session.render(page.uri);
      if (dom.trim().isNotEmpty) {
        page = BrowserPage(
          uri: page.uri,
          statusCode: page.statusCode,
          contentType: 'text/html',
          body: dom,
        );
      }
    }
    return page;
  }

  static RegExp _globToRegExp(String glob) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final char = glob[i];
      if (char == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          buffer.write('.*');
          i++;
        } else {
          buffer.write('[^/]*');
        }
      } else if (char == '?') {
        buffer.write('[^/]');
      } else if (r'\^$.|+()[]{}'.contains(char)) {
        buffer.write('\\$char');
      } else {
        buffer.write(char);
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }
}

/// Structured outcome of a web search — shared by the `web_search` tool and the
/// manual search page so both render the same results.
class WebSearchOutcome {
  WebSearchOutcome({
    required this.query,
    required this.engine,
    required this.results,
    required this.rawCount,
    required this.dropped,
    required this.filtered,
    required this.errors,
    this.notes = const <String>[],
  });

  /// The query actually used (may be a compacted fallback).
  final String query;

  /// Name of the engine that produced the results (empty when none did).
  final String engine;

  final List<Map<String, Object?>> results;

  /// Number of raw items the engine returned (before any filtering).
  final int rawCount;

  /// Count of items rejected by the filter rules (junk/duplicate/irrelevant) —
  /// does **not** include items cut off by the result limit.
  final int dropped;

  /// Whether the relevance/junk filter was applied (false = raw engine output).
  final bool filtered;

  /// Per-engine failure notes, for diagnostics when [results] is empty.
  final List<String> errors;

  /// Non-fatal remarks about a *successful* run (e.g. "翻页提前结束：请求 3 页，
  /// 实际解析 1 页") — never a reason to discard the results.
  final List<String> notes;

  bool get isEmpty => results.isEmpty;
}

/// Cancellable `shell` tool: kills the spawned child process when the turn is
/// stopped, so [停止] takes effect immediately instead of waiting for the
/// command (or its timeout) to finish.
class _ShellTool extends LlmTool {
  _ShellTool(this.sandbox, this.shellExec);

  final String sandbox;

  /// User-configured shell launcher (executable + args template).
  final ShellExecConfig shellExec;

  @override
  String get name => 'shell';

  @override
  String get description {
    final resolved = shellExec.resolve(isWindows: Platform.isWindows);
    return '执行 shell 命令（桌面端，工作目录=沙箱）并返回标准输出/错误。'
        '命令由 ${resolved.executable} 以「${resolved.argsTemplate}」方式执行，'
        '参数模板中 {command} 处替换为完整命令。命令书写规范：\n'
        '${commandSyntaxNotes(shellFamilyFor(resolved.executable))}';
  }

  @override
  Map<String, Object?> get parameters => objectSchema(
        properties: {
          'command': stringSchema(
            description:
                '要执行的命令（按 ${shellExec.resolve(isWindows: Platform.isWindows).executable} 的语法编写；引号/转义规范见工具说明）',
          ),
          'timeout_seconds': integerSchema(description: '超时秒数', minimum: 1),
        },
        required: ['command'],
      );

  @override
  Future<Object?> call(Map<String, Object?> args, {CancelToken? cancel}) async {
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return 'ERROR: shell is not available on this platform';
    }
    final command = '${args['command'] ?? ''}';
    if (command.isEmpty) return 'ERROR: command required';
    final timeout = (args['timeout_seconds'] as num?)?.toInt() ?? 60;
    final resolved = shellExec.resolve(isWindows: Platform.isWindows);

    final Process process;
    try {
      process = await Process.start(
        resolved.executable,
        resolved.argumentsFor(command),
        workingDirectory: sandbox,
      );
    } on ProcessException catch (error) {
      // A misconfigured/missing shell must not crash the turn; report it as a
      // tool error so the model (or the user) can adjust the setting.
      return 'ERROR: failed to start shell ${resolved.executable}: ${error.message}';
    }
    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];
    final out = process.stdout.listen(stdoutBytes.addAll);
    final err = process.stderr.listen(stderrBytes.addAll);

    void kill() {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {
        // Already exited.
      }
    }

    unawaited(cancel?.whenCancelled.then((_) => kill()));

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(Duration(seconds: timeout));
    } on TimeoutException {
      kill();
      await out.cancel();
      await err.cancel();
      return 'ERROR: command timed out after ${timeout}s';
    }

    // Turn was stopped → abort the whole agent turn.
    cancel?.throwIfCancelled();
    await out.cancel();
    await err.cancel();

    final buffer = StringBuffer();
    final stdoutText = decodeShellOutput(stdoutBytes);
    final stderrText = decodeShellOutput(stderrBytes);
    if (stdoutText.isNotEmpty) buffer.writeln(stdoutText);
    if (stderrText.isNotEmpty) buffer.writeln('[stderr]\n$stderrText');
    buffer.writeln('[exit code] $exitCode');
    return buffer.toString();
  }
}
