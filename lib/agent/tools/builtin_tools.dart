import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:llm_api/llm_api.dart';
import 'package:path/path.dart' as p;

import '../../models/proxy_config.dart';
import '../../models/search_engine_config.dart';
import 'path_guard.dart';

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
          final client = _client(proxy.applyToHttpFetch ? proxy : ProxyConfig());
          try {
            final response = await client.get(
              Uri.parse(url),
              headers: const {'User-Agent': _ua},
            ).timeout(const Duration(seconds: 30));
            if (response.statusCode >= 400) {
              return 'ERROR: HTTP ${response.statusCode}';
            }
            final contentType = response.headers['content-type'] ?? '';
            var text = utf8.decode(response.bodyBytes, allowMalformed: true);
            if (contentType.contains('html')) {
              text = html_parser.parse(text).body?.text ?? text;
            }
            final max = (args['max_chars'] as num?)?.toInt() ?? 20000;
            if (text.length > max) {
              return '${text.substring(0, max)}\n…[truncated ${text.length - max} chars]';
            }
            return text;
          } finally {
            client.close();
          }
        },
      );

  static LlmTool _webSearch(List<SearchEngineConfig> searchEngines, ProxyConfig proxy) => FunctionTool(
        name: 'web_search',
        description: '联网搜索并返回标题/链接/摘要。',
        parameters: objectSchema(
          properties: {
            'query': stringSchema(description: '搜索关键词'),
            'max_results': integerSchema(description: '结果数量', minimum: 1, maximum: 20),
          },
          required: ['query'],
        ),
        handler: (args) async {
          final query = '${args['query'] ?? ''}';
          if (query.isEmpty) return 'ERROR: query required';
          final max = (args['max_results'] as num?)?.toInt() ?? 8;
          final proxied = _client(proxy);
          final direct = _client(ProxyConfig());
          try {
            final errors = <String>[];
            for (final engine in searchEngines.where((e) => e.enabled)) {
              final client = (engine.useProxy && !proxy.isEmpty) ? proxied : direct;
              final searcher = _engineFor(engine, client);
              try {
                final results = await searcher.search(query, max);
                if (results.isNotEmpty) {
                  return const JsonEncoder.withIndent('  ').convert({
                    'query': query,
                    'engine': searcher.name,
                    'results': results,
                  });
                }
                errors.add('${searcher.name}: no results');
              } catch (error) {
                errors.add('${searcher.name}: $error');
              }
            }
            return 'ERROR: all search engines failed:\n${errors.join('\n')}';
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

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  /// Binds one configured engine to [client].
  static _SearchEngine _engineFor(SearchEngineConfig engine, http.Client client) {
    switch (engine.kind) {
      case 'bing':
        return _SearchEngine(engine.name, (q, m) => _bing(q, m, client));
      case 'duckduckgo':
        return _SearchEngine(engine.name, (q, m) => _duckDuckGo(q, m, client));
      default:
        return _SearchEngine(engine.name, (q, m) => _custom(engine, q, m, client));
    }
  }

  /// Builds an HTTP client honoring the configured proxy + bypass list.
  static http.Client _client(ProxyConfig proxy) {
    try {
      return IOClient(buildProxiedHttpClient(proxy));
    } catch (_) {
      return http.Client();
    }
  }

  /// Generic custom search: URL template + CSS selectors.
  static Future<List<Map<String, Object?>>> _custom(
    SearchEngineConfig engine,
    String query,
    int max,
    http.Client client,
  ) async {
    final template = engine.urlTemplate.trim();
    if (template.isEmpty) return const <Map<String, Object?>>[];
    final uri = Uri.parse(template.replaceAll('{query}', Uri.encodeQueryComponent(query)));
    final response = await client.get(uri, headers: const {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
    final doc = html_parser.parse(utf8.decode(response.bodyBytes, allowMalformed: true));
    final nodes = engine.resultSelector.trim().isEmpty
        ? doc.querySelectorAll('a')
        : doc.querySelectorAll(engine.resultSelector.trim());
    final results = <Map<String, Object?>>[];
    for (final node in nodes) {
      final anchor = engine.linkSelector.trim().isEmpty
          ? node.querySelector('a')
          : node.querySelector(engine.linkSelector.trim());
      final titleNode = engine.titleSelector.trim().isEmpty
          ? anchor
          : node.querySelector(engine.titleSelector.trim());
      final url = anchor?.attributes['href'] ?? titleNode?.attributes['href'] ?? '';
      final title = titleNode?.text.trim() ?? anchor?.text.trim() ?? '';
      final snippet = engine.snippetSelector.trim().isEmpty
          ? ''
          : (node.querySelector(engine.snippetSelector.trim())?.text.trim() ?? '');
      if (url.isEmpty && title.isEmpty) continue;
      results.add({'title': title, 'url': url, 'snippet': snippet});
      if (results.length >= max) break;
    }
    return results;
  }

  static Future<List<Map<String, Object?>>> _bing(String query, int max, http.Client client) async {
    final uri = Uri.parse('https://www.bing.com/search?q=${Uri.encodeQueryComponent(query)}&count=$max');
    final response = await client.get(uri, headers: const {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
    final doc = html_parser.parse(utf8.decode(response.bodyBytes, allowMalformed: true));
    final results = <Map<String, Object?>>[];
    for (final node in doc.querySelectorAll('li.b_algo')) {
      final anchor = node.querySelector('h2 a');
      if (anchor == null) continue;
      results.add({
        'title': anchor.text.trim(),
        'url': anchor.attributes['href'] ?? '',
        'snippet': node.querySelector('.b_caption p')?.text.trim() ?? '',
      });
      if (results.length >= max) break;
    }
    return results;
  }

  static Future<List<Map<String, Object?>>> _duckDuckGo(String query, int max, http.Client client) async {
    final uri = Uri.parse('https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(query)}');
    final response = await client.get(uri, headers: const {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
    final doc = html_parser.parse(utf8.decode(response.bodyBytes, allowMalformed: true));
    final results = <Map<String, Object?>>[];
    for (final node in doc.querySelectorAll('.result')) {
      final anchor = node.querySelector('.result__a');
      if (anchor == null) continue;
      results.add({
        'title': anchor.text.trim(),
        'url': anchor.attributes['href'] ?? '',
        'snippet': node.querySelector('.result__snippet')?.text.trim() ?? '',
      });
      if (results.length >= max) break;
    }
    return results;
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
