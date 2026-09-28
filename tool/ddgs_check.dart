// DDGS 网页搜索验证工具：评估 `ddgs` 各后端的召回是否准确。
//
// 用法（在项目根目录运行，依赖随 pubspec 解析）：
//   dart run tool/ddgs_check.dart "2025-2026 冬季邮轮 中国母港 日本 航线"
//   dart run tool/ddgs_check.dart -n 5 -b duckduckgo,brave "查询词"
//   dart run tool/ddgs_check.dart -r cn-zh -t y "查询词"
//   dart run tool/ddgs_check.dart --json "查询词"
//   dart run tool/ddgs_check.dart --proxy http://127.0.0.1:7890 "查询词"
//
// 参数：
//   -n, --max <N>        每个后端的结果数上限（默认 8）
//   -b, --backend <list> 后端列表，逗号分隔（默认 duckduckgo,brave,ecosia）
//   -r, --region <code>  区域，如 wt-wt / cn-zh / us-en
//   -t, --timelimit <d|w|m|y>  时间范围
//      --proxy <url>     代理（http/https，可带 user:pass@），如 http://127.0.0.1:7890。
//                        注：ddgs 0.3.2 自身的 proxy 参数形同虚设（见下文
//                        _ProxyOverrides），本工具通过 HttpOverrides 强制全局生效。
//      --json            以 JSON 输出（便于程序化对比）
//
// 「命中 x/y」= 标题+摘要覆盖的查询词元数 / 查询词元总数（y 越大、x 越接近 y
// 越相关），用于快速判断该后端是否返回了跑题/投毒内容。

import 'dart:convert';
import 'dart:io';

import 'package:ddgs/ddgs.dart';

Future<void> main(List<String> argv) async {
  var max = 8;
  var backends = <String>['duckduckgo', 'brave', 'ecosia'];
  var asJson = false;
  String? region;
  String? timelimit;
  String? proxy;
  final queryParts = <String>[];

  String nextValue(String flag) {
    final index = argv.indexOf(flag);
    if (index + 1 >= argv.length) _fail('缺少 $flag 的取值');
    return argv[index + 1];
  }

  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    switch (arg) {
      case '-h' || '--help':
        _usage();
        return;
      case '-n' || '--max':
        max = int.tryParse(nextValue(arg)) ?? 8;
        i++;
      case '-b' || '--backend' || '--backends':
        backends = nextValue(arg)
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        i++;
      case '-r' || '--region':
        region = nextValue(arg);
        i++;
      case '-t' || '--timelimit':
        timelimit = nextValue(arg);
        i++;
      case '--proxy':
        proxy = nextValue(arg);
        i++;
      case '--json':
        asJson = true;
      default:
        if (arg.startsWith('-')) _fail('未知参数: $arg');
        queryParts.add(arg);
    }
  }
  final query = queryParts.join(' ').trim();
  if (query.isEmpty) {
    _usage();
    exitCode = 64;
    return;
  }
  if (backends.isEmpty) _fail('后端列表不能为空');

  // ddgs 0.3.2 的 DDGS(proxy:) 只透传不生效，必须在创建任何连接前装上全局代理。
  if (proxy != null && proxy.trim().isNotEmpty) {
    _ProxyOverrides.install(proxy.trim());
  }

  final ddgs = DDGS(proxy: proxy, timeout: const Duration(seconds: 15));
  final perBackend = <String, Map<String, Object?>>{};
  final merged = <Map<String, Object?>>[];
  final seen = <String>{};
  try {
    for (final backend in backends) {
      final watch = Stopwatch()..start();
      try {
        final items = await ddgs.text(
          query,
          maxResults: max,
          backend: backend,
          region: region ?? 'us-en',
          timelimit: timelimit,
        );
        final results = <Map<String, Object?>>[];
        for (final item in items) {
          final result = _normalize(item);
          if ('${result['url']}'.isEmpty) continue;
          results.add(result);
          if (seen.add('${result['url']}')) merged.add(result);
        }
        perBackend[backend] = {
          'status': results.isEmpty ? '空结果（可能被限流/网络不可达）' : 'ok',
          'count': results.length,
          'ms': watch.elapsedMilliseconds,
          'results': results,
        };
      } catch (error) {
        perBackend[backend] = {
          'status': '$error',
          'count': 0,
          'ms': watch.elapsedMilliseconds,
          'results': const <Map<String, Object?>>[],
        };
      }
    }
  } finally {
    ddgs.close();
  }

  final terms = _terms(query);
  if (asJson) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'query': query,
      'max': max,
      'backends': backends,
      'per_backend': perBackend,
      'merged': merged,
    }));
  } else {
    _printReport(query, max, backends, perBackend, merged, terms);
  }
  exitCode = merged.isEmpty ? 1 : 0;
}

Map<String, Object?> _normalize(Map<String, dynamic> item) {
  final url = '${item['href'] ?? item['url'] ?? ''}'.trim();
  final title = '${item['title'] ?? ''}'.trim();
  var snippet = '${item['body'] ?? item['content'] ?? item['snippet'] ?? ''}'.trim();
  if (snippet.length > 160) snippet = '${snippet.substring(0, 160)}…';
  return {'title': title, 'url': url, 'snippet': snippet};
}

void _printReport(
  String query,
  int max,
  List<String> backends,
  Map<String, Map<String, Object?>> perBackend,
  List<Map<String, Object?>> merged,
  Set<String> terms,
) {
  final out = stdout;
  out.writeln('# query: $query');
  out.writeln('# backends: ${backends.join(',')} · max: $max · 词元数: ${terms.length}');
  out.writeln('');
  for (var b = 0; b < backends.length; b++) {
    final backend = backends[b];
    final meta = perBackend[backend] ?? const {};
    out.writeln('── [${b + 1}/${backends.length}] $backend · '
        '${meta['count']} 条 · ${meta['ms']} ms · ${meta['status']} '
        '${'─' * 20}');
    final results = (meta['results'] as List?)?.cast<Map<String, Object?>>() ?? const [];
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      final hits = _hits(terms, '${r['title']} ${r['snippet']}');
      out.writeln('  [${i + 1}] ${r['title']}   (命中 $hits/${terms.length})');
      out.writeln('      ${r['url']}');
      out.writeln('      ${r['snippet']}');
    }
    out.writeln('');
  }
  out.writeln('── 汇总 ${'─' * 30}');
  for (final backend in backends) {
    final meta = perBackend[backend] ?? const {};
    out.writeln('  ${backend.padRight(14)} ${'${meta['count']}'.padLeft(3)} 条  '
        '${'${meta['ms']} ms'.padLeft(9)}  ${meta['status']}');
  }
  out.writeln('  合并去重后共 ${merged.length} 条');
  out.writeln('  （命中 x/y：标题+摘要覆盖的查询词元数/词元总数，越大越相关）');
}

/// 查询词元：拉丁词 + CJK 二元组（与主程序 web_search 的相关性口径一致）。
Set<String> _terms(String text) {
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

int _hits(Set<String> terms, String text) {
  final got = _terms(text);
  var hits = 0;
  for (final term in terms) {
    if (got.contains(term)) hits++;
  }
  return hits;
}

void _usage() {
  stdout.writeln('用法: dart run tool/ddgs_check.dart [选项] "搜索内容"\n'
      '  -n, --max <N>             每后端结果数上限（默认 8）\n'
      '  -b, --backend <list>      后端列表，逗号分隔（默认 duckduckgo,brave,ecosia）\n'
      '  -r, --region <code>       区域（wt-wt / cn-zh / us-en …）\n'
      '  -t, --timelimit <d|w|m|y> 时间范围\n'
      '      --proxy <url>         代理\n'
      '      --json                JSON 输出');
}

Never _fail(String message) {
  stderr.writeln('错误: $message');
  exit(65);
}

/// 强制全局代理：绕过 ddgs 0.3.2 的缺陷。
///
/// ddgs 0.3.2 的 `HttpClient.proxy` 字段只保存、从不使用——内部仍创建默认
/// `http.Client()`（→ IOClient → `HttpClient()`），从未设置 `findProxy`，
/// 因此传入的代理被静默忽略，请求全部直连（直连被墙/被拒时表现为超时）。
/// 由于 DDGS 未暴露注入 http.Client 的入口，这里改用 `HttpOverrides.global`：
/// `http.Client()` 默认走 IOClient，其 `HttpClient()` 受 HttpOverrides 影响，
/// 从而覆盖 ddgs 内部所有请求（含 InstantAnswerService）。
///
/// 注意 dart:io 的代理串只识别 `PROXY host:port` / `DIRECT`（SOCKS5 前缀会抛
/// "Invalid proxy configuration"），故 socks 代理直接报错提示改用 http 代理。
class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides(this._directive);

  /// findProxy 返回串，如 `PROXY 127.0.0.1:7890` 或 `PROXY user:pass@host:port`。
  final String _directive;

  static void install(String proxy) {
    final text = proxy.contains('://') ? proxy : 'http://$proxy';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty || !uri.hasPort) {
      _fail('代理地址无效（需要 scheme://host:port）: $proxy');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme.startsWith('socks')) {
      _fail('dart:io 不支持 $scheme 代理，请改用 http 代理端口'
          '（如 Clash 的 mixed/port 7890 通常即 http）');
    }
    if (scheme != 'http' && scheme != 'https') {
      _fail('不支持的代理协议: ${uri.scheme}（可用 http/https）');
    }
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final auth = uri.userInfo.isEmpty ? '' : '${uri.userInfo}@';
    HttpOverrides.global = _ProxyOverrides('PROXY $auth$host:${uri.port}');
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => _directive;
    return client;
  }
}
