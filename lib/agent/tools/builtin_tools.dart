import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ddgs/ddgs.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:llm_api/llm_api.dart';
import 'package:path/path.dart' as p;

import '../../models/proxy_config.dart';
import '../../models/search_engine_config.dart';
import 'browser_session.dart';
import 'path_guard.dart';
import 'tavily_api.dart';

/// The catalogue of built-in tools and their metadata.
class BuiltinTools {
  static const descriptions = <String, String>{
    'read_file': '读取文件内容（限会话沙箱目录）',
    'write_file': '写入文件（自动创建目录，限沙箱）',
    'edit_file': '对文件做精确字符串替换编辑',
    'list_dir': '列出目录内容',
    'glob': '按通配符匹配文件路径',
    'shell': '执行 shell 命令（桌面端，工作目录=沙箱）',
    'http_fetch': '抓取网页/接口文本内容',
    'web_search': '联网搜索（引擎可配置：bing/duckduckgo，可走代理）',
    'datetime': '获取当前日期时间',
  };

  /// Builds the tool objects enabled for a session.
  static List<LlmTool> build({
    required String sandbox,
    required Iterable<String> enabled,
    List<SearchEngineConfig> searchEngines = const <SearchEngineConfig>[],
    ProxyConfig? proxy,
    bool shellEnabled = true,
  }) {
    final guard = PathGuard(sandbox);
    final proxyConfig = proxy ?? ProxyConfig();
    final tools = <LlmTool>[];
    final set = enabled.toSet();
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
          if (shellEnabled) tools.add(_shell(sandbox));
        case 'http_fetch':
          tools.add(_httpFetch(proxyConfig));
        case 'web_search':
          tools.add(_webSearch(searchEngines, proxyConfig));
        case 'datetime':
          tools.add(_datetime());
      }
    }
    return tools;
  }

  static LlmTool _readFile(PathGuard guard) => FunctionTool(
        name: 'read_file',
        description: '读取文件内容。path 为相对沙箱的路径或绝对路径（必须在沙箱内）。',
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
          final content = await file.readAsString();
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

  static LlmTool _shell(String sandbox) => _ShellTool(sandbox);

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

  static LlmTool _webSearch(List<SearchEngineConfig> searchEngines, ProxyConfig proxy) => FunctionTool(
        name: 'web_search',
        description: '联网搜索并返回标题/链接/摘要。query 请用精炼关键词（不要整句长问题），结果已过滤广告/跳转链接/无关内容。',
        parameters: objectSchema(
          properties: {
            'query': stringSchema(description: '搜索关键词'),
            'max_results': integerSchema(description: '结果数量', minimum: 1, maximum: 20),
          },
          required: ['query'],
        ),
        handler: (args) async {
          final query = '${args['query'] ?? ''}'.trim();
          if (query.isEmpty) return 'ERROR: query required';
          final max = (args['max_results'] as num?)?.toInt() ?? 8;
          final proxied = BrowserSession(proxy: proxy);
          final direct = BrowserSession();
          try {
            final errors = <String>[];

            /// Tries every enabled engine against [q]; keeps only usable,
            /// relevant, de-duplicated results (HTML scrapers frequently get
            /// served cloaked SEO-spam that parses like real results).
            Future<Map<String, Object?>> run(String q) async {
              final seen = <String>{};
              for (final engine in searchEngines.where((e) => e.enabled && e.isReady)) {
                final session = (engine.useProxy && !proxy.isEmpty) ? proxied : direct;
                final searcher = _engineFor(engine, session, proxy);
                try {
                  final raw = await searcher.search(q, max * 3);
                  final kept = _usable(q, raw, max, seen: seen);
                  final dropped = raw.length - kept.length;
                  if (kept.isNotEmpty) {
                    return {'engine': searcher.name, 'query': q, 'results': kept, 'dropped': dropped};
                  }
                  errors.add('${searcher.name}: no relevant results (raw ${raw.length}, dropped $dropped)');
                } catch (error) {
                  errors.add('${searcher.name}: $error');
                }
              }
              return {'engine': '', 'query': q, 'results': const <Map<String, Object?>>[], 'dropped': 0};
            }

            var outcome = await run(query);
            if ((outcome['results'] as List).isEmpty) {
              // Long natural-language queries are the easiest target for
              // scraper-cloaking; retry once with a keyword-only query.
              final compact = _compactQuery(query);
              if (compact.isNotEmpty && compact != query) {
                errors.add('no usable results for the original query, retrying with keywords: $compact');
                final retry = await run(compact);
                if ((retry['results'] as List).isNotEmpty) outcome = retry;
              }
            }
            final results = outcome['results'] as List;
            if (results.isEmpty) {
              return 'ERROR: all search engines failed:\n${errors.join('\n')}';
            }
            final dropped = outcome['dropped'] as int;
            return const JsonEncoder.withIndent('  ').convert({
              'query': outcome['query'],
              'engine': outcome['engine'],
              'results': results,
              if ('${outcome['query']}' != query) 'note': '原 query 未命中，已退化为精炼关键词检索',
              if (dropped > 0) 'filtered': 'dropped $dropped junk/irrelevant/duplicate items',
            });
          } finally {
            proxied.close();
            direct.close();
          }
        },
      );

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

  /// Throws when the engine answered with a captcha / bot-challenge page —
  /// such pages still contain parsable blocks and would silently turn into
  /// garbage "results".
  static void _ensureNotBlocked(String body, String engine) {
    if (body.trim().length < 200) {
      throw StateError('$engine: empty or truncated response');
    }
    if (BrowserSession.looksBlocked(body)) {
      throw StateError('$engine: captcha / bot-challenge page returned');
    }
  }

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

  /// Junk / duplicate / irrelevant filter + snippet capping, shared by the
  /// engine tier and the outer run loop. [seen] may span engines for
  /// cross-engine de-duplication.
  static List<Map<String, Object?>> _usable(
    String query,
    List<Map<String, Object?>> raw,
    int max, {
    Set<String>? seen,
  }) {
    final urls = seen ?? <String>{};
    final kept = <Map<String, Object?>>[];
    for (final item in raw) {
      final title = '${item['title'] ?? ''}'.trim();
      final url = '${item['url'] ?? ''}'.trim();
      final snippet = '${item['snippet'] ?? ''}'.trim();
      if (_isJunk(title, url) || !urls.add(url) || !_relevant(query, title, snippet)) continue;
      kept.add({
        'title': title,
        'url': url,
        'snippet': snippet.length > 300 ? '${snippet.substring(0, 300)}…' : snippet,
      });
      if (kept.length >= max) break;
    }
    return kept;
  }

  /// Drops unusable entries: empty, in-page anchors, engine-internal links.
  static bool _isJunk(String title, String url) {
    if (title.isEmpty || url.isEmpty) return true;
    if (url.startsWith('javascript:') || url.startsWith('#')) return true;
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host.endsWith('bing.com') || host.endsWith('duckduckgo.com');
  }

  /// Latin words plus CJK bigrams — a language-agnostic relevance vocabulary.
  static Set<String> _terms(String text) {
    final out = <String>{};
    for (final m in RegExp(r'[a-zA-Z]{2,}').allMatches(text)) {
      out.add(m.group(0)!.toLowerCase());
    }
    for (final m in RegExp(r'[\u4e00-\u9fff]+').allMatches(text)) {
      final run = m.group(0)!;
      if (run.length == 1) {
        out.add(run);
      } else {
        for (var i = 0; i + 1 < run.length; i++) {
          out.add(run.substring(i, i + 2));
        }
      }
    }
    return out;
  }

  /// Cheap relevance gate: a usable result must share some vocabulary with the
  /// query — cloaked SEO-spam (e.g. 磨粉机站群) shares none of it.
  static bool _relevant(String query, String title, String snippet) {
    final wanted = _terms(query);
    if (wanted.isEmpty) return true;
    final got = _terms('$title $snippet');
    if (got.isEmpty) return false;
    var hits = 0;
    for (final term in wanted) {
      if (got.contains(term)) hits++;
    }
    return hits >= 2 || (wanted.length <= 3 && hits >= 1);
  }

  /// Strips digits/punctuation → keyword-only fallback query.
  static String _compactQuery(String query) {
    final compact = query
        .replaceAll(RegExp(r'[^a-zA-Z\u4e00-\u9fff]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return compact.length > 40 ? compact.substring(0, 40).trim() : compact;
  }

  /// Binds one configured engine to [session] / [proxy].
  static _SearchEngine _engineFor(
      SearchEngineConfig engine, BrowserSession session, ProxyConfig proxy) {
    switch (engine.kind) {
      case 'ddgs':
        return _SearchEngine(engine.name, (q, m) => _ddgs(engine, q, m, proxy));
      case 'tavily':
        return _SearchEngine(engine.name, (q, m) => _tavily(engine, q, m, session));
      case 'bing':
        return _SearchEngine(engine.name, (q, m) => _bing(q, m, session));
      case 'duckduckgo':
        return _SearchEngine(engine.name, (q, m) => _duckDuckGo(q, m, session));
      default:
        return _SearchEngine(engine.name, (q, m) => _custom(engine, q, m, session));
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

  /// Generic custom search: URL template + CSS selectors.
  static Future<List<Map<String, Object?>>> _custom(
    SearchEngineConfig engine,
    String query,
    int max,
    BrowserSession session,
  ) async {
    final template = engine.urlTemplate.trim();
    if (!template.contains('{query}')) {
      throw StateError('自定义引擎「${engine.name}」的 URL 模板缺少 {query} 占位符（否则每次搜索都返回同一页面）');
    }
    final resultSelector = engine.resultSelector.trim();
    if (resultSelector.isEmpty) {
      throw StateError('自定义引擎「${engine.name}」缺少结果条目选择器（避免抓到导航/页脚链接）');
    }
    final uri = Uri.parse(template.replaceAll('{query}', Uri.encodeQueryComponent(query)));
    final page = await _fetchPage(session, uri);
    if (page.statusCode >= 400) throw StateError('HTTP ${page.statusCode}');
    _ensureNotBlocked(page.body, engine.name);
    final doc = html_parser.parse(page.body);
    final results = <Map<String, Object?>>[];
    for (final node in doc.querySelectorAll(resultSelector)) {
      final linkSelector = engine.linkSelector.trim();
      var anchor = linkSelector.isEmpty ? node.querySelector('a') : node.querySelector(linkSelector);
      if (anchor == null && node.localName == 'a') anchor = node;
      final titleSelector = engine.titleSelector.trim();
      final titleNode = titleSelector.isEmpty ? anchor : node.querySelector(titleSelector);
      final url = _unwrapLink(anchor?.attributes['href'] ?? titleNode?.attributes['href'] ?? '', page.uri);
      final title = (titleNode?.text ?? anchor?.text ?? '').trim();
      final snippetSelector = engine.snippetSelector.trim();
      final snippet = snippetSelector.isEmpty ? '' : (node.querySelector(snippetSelector)?.text ?? '').trim();
      if (url.isEmpty && title.isEmpty) continue;
      results.add({'title': title, 'url': url, 'snippet': snippet});
      if (results.length >= max * 3) break;
    }
    return results;
  }

  /// Bing in three tiers: the clean RSS feed first, then a browser-consistent
  /// HTML scrape, and finally a real headless render of the SERP.
  static Future<List<Map<String, Object?>>> _bing(String query, int max, BrowserSession session) async {
    Object? lastError;

    // L1 — RSS feed (`format=rss`): an XML endpoint meant for feed readers,
    // hence not served the cloaked / SEO-spam HTML SERP.
    try {
      final usable = _usable(query, await _bingRss(query, max, session), max);
      if (usable.isNotEmpty) return usable;
    } catch (error) {
      lastError = error;
    }

    // L2 — HTML SERP scraped like a browser: the same URL params (form /
    // refig / pc) plus the warmed-up visitor cookies they must agree with.
    try {
      await _bingWarmUp(session);
      final uri = _bingUri(query, session);
      final page = await _fetchPage(session, uri);
      if (page.statusCode >= 400) throw StateError('HTTP ${page.statusCode}');
      _ensureNotBlocked(page.body, 'bing');
      final usable = _usable(query, _parseBingDom(page.body, page.uri, max * 3), max);
      if (usable.isNotEmpty) return usable;
    } catch (error) {
      lastError = error;
    }

    // L3 — the SERP executed in real headless Chrome: the JS that mints the
    // visitor tokens runs there, so the page cannot be cloaked to it.
    try {
      if (session.canRender) {
        final uri = _bingUri(query, session);
        final dom = await session.render(uri);
        final usable = _usable(query, _parseBingDom(dom, uri, max * 3), max);
        if (usable.isNotEmpty) return usable;
      }
    } catch (error) {
      lastError = error;
    }

    if (lastError != null) throw lastError;
    return const <Map<String, Object?>>[];
  }

  /// The SERP URL exactly as a browser builds it: search host, entry-form id,
  /// UI-config code and the per-visitor `refig` hash — Bing cross-checks these
  /// against its visitor cookies for consistency.
  static Uri _bingUri(String query, BrowserSession session) => Uri.https('cn.bing.com', '/search', {
        'q': query,
        'form': 'ANNNB1',
        'refig': session.refig,
        'pc': 'U531',
      });

  /// First visit to the search host: harvests the visitor cookies (MUID /
  /// _EDGE_S) that the `form`/`refig`/`pc` params must stay consistent with.
  static Future<void> _bingWarmUp(BrowserSession session) async {
    if (session.hasCookiesFor('bing.com')) return;
    try {
      await session.get(Uri.https('cn.bing.com', '/'));
    } catch (_) {
      // Warm-up is best-effort.
    }
  }

  /// L1 source: Bing's RSS endpoint — clean XML items, no `ck/a` redirects.
  static Future<List<Map<String, Object?>>> _bingRss(
      String query, int max, BrowserSession session) async {
    final uri = Uri.https('www.bing.com', '/search', {
      'q': query,
      'format': 'rss',
      'count': '$max',
    });
    final page = await session.get(uri);
    if (page.statusCode >= 400) return const <Map<String, Object?>>[];
    final results = <Map<String, Object?>>[];
    for (final m in RegExp(r'<item>([\s\S]*?)</item>').allMatches(page.body)) {
      final item = m.group(1) ?? '';
      results.add({
        'title': _rssField(item, 'title'),
        'url': _rssField(item, 'link'),
        'snippet': _rssField(item, 'description'),
      });
      if (results.length >= max * 2) break;
    }
    return results;
  }

  /// Extracts one RSS tag's text. Regex-based on purpose: `<link>` is a void
  /// element for the HTML parser and would swallow the URL.
  static String _rssField(String item, String tag) {
    final m = RegExp('<$tag>([\\s\\S]*?)</$tag>').firstMatch(item);
    var text = m?.group(1) ?? '';
    text = text.replaceAll(RegExp(r'^\s*<!\[CDATA\[|\]\]>\s*$'), '').trim();
    return (html_parser.parseFragment(text).text ?? text).trim();
  }

  static List<Map<String, Object?>> _parseBingDom(String html, Uri base, int limit) {
    final doc = html_parser.parse(html);
    final results = <Map<String, Object?>>[];
    for (final node in doc.querySelectorAll('li.b_algo')) {
      if (node.className.contains('b_ad')) continue; // sponsored blocks
      final anchor = node.querySelector('h2 a');
      if (anchor == null) continue;
      results.add({
        'title': anchor.text.trim(),
        'url': _unwrapLink(anchor.attributes['href'] ?? '', base),
        'snippet': node.querySelector('.b_caption p')?.text.trim() ??
            node.querySelector('.b_caption')?.text.trim() ??
            '',
      });
      if (results.length >= limit) break;
    }
    return results;
  }

  static Future<List<Map<String, Object?>>> _duckDuckGo(String query, int max, BrowserSession session) async {
    final uri = Uri.https('html.duckduckgo.com', '/html/', {'q': query});
    final page = await _fetchPage(session, uri);
    if (page.statusCode >= 400) throw StateError('HTTP ${page.statusCode}');
    _ensureNotBlocked(page.body, 'duckduckgo');
    final doc = html_parser.parse(page.body);
    final results = <Map<String, Object?>>[];
    for (final node in doc.querySelectorAll('.result')) {
      final anchor = node.querySelector('.result__a');
      if (anchor == null) continue;
      results.add({
        'title': anchor.text.trim(),
        'url': _unwrapLink(anchor.attributes['href'] ?? '', page.uri),
        'snippet': node.querySelector('.result__snippet')?.text.trim() ?? '',
      });
      if (results.length >= max * 3) break;
    }
    return results;
  }

  /// Multi-engine meta search via `package:ddgs` (no API key): several scraped
  /// backends cross-check each other, diluting single-engine cloaking.
  static Future<List<Map<String, Object?>>> _ddgs(
    SearchEngineConfig engine,
    String query,
    int max,
    ProxyConfig proxy,
  ) async {
    final backends = engine.backend
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (backends.isEmpty) backends.add('duckduckgo');
    final ddgs = DDGS(proxy: _proxyUrl(proxy), timeout: const Duration(seconds: 15));
    final results = <Map<String, Object?>>[];
    final seen = <String>{};
    try {
      for (final backend in backends) {
        try {
          final items = await ddgs.text(query, maxResults: max, backend: backend);
          for (final item in items) {
            final url = '${item['href'] ?? item['url'] ?? ''}'.trim();
            if (url.isEmpty || !seen.add(url)) continue;
            results.add({
              'title': '${item['title'] ?? ''}'.trim(),
              'url': url,
              'snippet': '${item['body'] ?? item['snippet'] ?? ''}'.trim(),
            });
          }
        } catch (_) {
          // One backend failing / rate-limited must not kill the aggregate.
        }
        if (results.length >= max) break;
      }
    } finally {
      ddgs.close();
    }
    return results;
  }

  /// Tavily Search API (`POST /search`, 1 credit per call).
  static Future<List<Map<String, Object?>>> _tavily(
    SearchEngineConfig engine,
    String query,
    int max,
    BrowserSession session,
  ) =>
      TavilyApi.search(session, engine.apiKey.trim(), query, max);

  static String? _proxyUrl(ProxyConfig proxy) {
    final raw = proxy.httpsProxy.trim().isNotEmpty
        ? proxy.httpsProxy.trim()
        : proxy.httpProxy.trim();
    return raw.isEmpty ? null : 'http://${proxyHostPort(raw)}';
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

class _SearchEngine {
  _SearchEngine(this.name, this.search);

  final String name;
  final Future<List<Map<String, Object?>>> Function(String query, int max) search;
}

/// Cancellable `shell` tool: kills the spawned child process when the turn is
/// stopped, so [停止] takes effect immediately instead of waiting for the
/// command (or its timeout) to finish.
class _ShellTool extends LlmTool {
  _ShellTool(this.sandbox);

  final String sandbox;

  @override
  String get name => 'shell';

  @override
  String get description => '执行 shell 命令（桌面端，工作目录=沙箱）并返回标准输出/错误。';

  @override
  Map<String, Object?> get parameters => objectSchema(
        properties: {
          'command': stringSchema(description: '要执行的命令'),
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
    final isWindows = Platform.isWindows;

    final process = await Process.start(
      isWindows ? 'cmd' : '/bin/bash',
      isWindows ? ['/c', command] : ['-lc', command],
      workingDirectory: sandbox,
    );
    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final out = process.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
    final err = process.stderr.transform(utf8.decoder).listen(stderrBuf.write);

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
    if (stdoutBuf.isNotEmpty) buffer.writeln(stdoutBuf);
    if (stderrBuf.isNotEmpty) buffer.writeln('[stderr]\n$stderrBuf');
    buffer.writeln('[exit code] $exitCode');
    return buffer.toString();
  }
}
