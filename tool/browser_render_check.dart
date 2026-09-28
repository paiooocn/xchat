// headless Chrome/Edge 渲染链路检验工具：验证 web_search / http_fetch 在遇到
// JS/captcha 壁时回退到本机 Chromium（`--headless=new --dump-dom`）的处理方式。
//
// 用法（在项目根目录运行，直接复用 lib/agent/tools/browser_session.dart 的真实实现）：
//   dart run tool/browser_render_check.dart
//   dart run tool/browser_render_check.dart --selector 'li.b_algo' 'https://cn.bing.com/search?q=Dart'
//   dart run tool/browser_render_check.dart --proxy http://127.0.0.1:7890 --render-proxy
//
// 参数：
//   --proxy <url>     代理（只作用于 HTTP 层，与 web_search 的 ProxyConfig 一致）
//   --render-proxy    渲染层追加 --proxy-server=<proxy> 做对照测试
//                     （线上 render() 不带该参数，只能直连的 URL 渲染必失败——已知缺口）
//   --selector <css>  统计两层 DOM 的命中选择器（未给 URL 时覆盖内置选择器，默认 'a'）
//   -h, --help
//
// 未给 URL 时跑内置用例：example.com（对照）+ bing SERP + google SERP（已知 JS 壁）。
// 每个 URL 检验四项：HTTP 层状态与反爬标记、真实 render() 产出的 DOM、渲染是否突破
// JS 壁（选择器命中 0 → >0）、失败时无头浏览器的退出码/stderr。
//
// 已知两处坑（本工具会顺带暴露）：
//   1. render() 不传 --proxy-server，渲染层不走 web_search 配置的代理；
//   2. BrowserSession.looksBlocked 的标记未覆盖 google 的 JS 跳板页
//      （"enablejs" / "Please click here if you are not redirected"），此时
//       _fetchPage 不会触发渲染回退——工具会打出「JS 跳板(looksBlocked 未覆盖)」提示。

import 'dart:async';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:xchat/agent/tools/browser_session.dart';
import 'package:xchat/models/proxy_config.dart';

typedef _Case = (String url, String selector);

const _defaults = <_Case>[
  ('https://example.com/', 'a'),
  ('https://cn.bing.com/search?q=Dart+programming&form=ANNNB1&pc=U531', 'li.b_algo'),
  ('https://www.google.com/search?q=Dart+programming&hl=en&gl=us&num=10', 'div.g'),
];

Future<void> main(List<String> argv) async {
  var proxy = '';
  var renderProxy = false;
  var selector = '';
  final urls = <String>[];

  String next(int i, String flag) =>
      i + 1 < argv.length ? argv[i + 1] : _fail('缺少 $flag 的取值');

  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '-h' || '--help':
        _usage();
        return;
      case '--proxy':
        proxy = next(i, '--proxy');
        i++;
      case '--render-proxy':
        renderProxy = true;
      case '--selector':
        selector = next(i, '--selector');
        i++;
      default:
        if (argv[i].startsWith('-')) _fail('未知参数: ${argv[i]}');
        urls.add(argv[i]);
    }
  }
  if (renderProxy && proxy.trim().isEmpty) {
    _fail('--render-proxy 需与 --proxy 同时指定（否则无代理可对照）');
  }

  var cases = <_Case>[
    if (urls.isEmpty)
      ..._defaults
    else
      for (final url in urls) (url, selector.isEmpty ? 'a' : selector),
  ];
  if (selector.isNotEmpty) {
    cases = [for (final c in cases) (c.$1, selector)];
  }

  final session = BrowserSession(
    proxy: proxy.trim().isEmpty
        ? null
        : ProxyConfig(httpProxy: proxy.trim(), httpsProxy: proxy.trim()),
  );
  var rendered = 0;
  var breakthrough = 0;
  try {
    stdout.writeln('== 浏览器探测 ==');
    final exe = await BrowserSession.locateBrowser();
    if (exe.isEmpty) {
      stdout.writeln('  ⚠ 未找到 Chrome/Edge/Chromium —— render() 将返回空 DOM');
    } else {
      stdout.writeln('  可执行: $exe');
      final version = await Process.run(exe, const ['--version']);
      stdout.writeln('  版本:   ${'${version.stdout}'.trim()}');
    }
    stdout.writeln('  调用参数: --headless=new --disable-gpu --disable-dev-shm-usage'
        ' --virtual-time-budget=8000 --dump-dom <url>');
    stdout.writeln('  代理:   HTTP 层=${proxy.trim().isEmpty ? '直连' : proxy.trim()}'
        ' · 渲染层=${renderProxy ? '--proxy-server=${proxyHostPort(proxy.trim())}' : '不走代理（与线上 render() 一致）'}');
    stdout.writeln('');

    for (var i = 0; i < cases.length; i++) {
      final (url, css) = cases[i];
      final uri = Uri.parse(url);
      stdout.writeln('── [${i + 1}/${cases.length}] $url  (选择器: $css)');

      // L1 —— HTTP 层（BrowserSession.get：完整浏览器头 + cookie jar）
      var httpHits = -1;
      try {
        final page = await session.get(uri);
        httpHits = _hits(page.body, css);
        stdout.writeln('  L1 HTTP层  : ${page.statusCode} ${page.contentType}'
            ' · ${page.body.length} B · ${_blockedLabel(page.body)}'
            ' · 命中 ${_hitLabel(httpHits)} · ${_title(page.body)}${_hint(page.body)}');
      } catch (error) {
        stdout.writeln('  L1 HTTP层  : 失败 $error');
      }

      // L2 —— 渲染层（真实 BrowserSession.render）
      var renderHits = -1;
      if (exe.isEmpty) {
        stdout.writeln('  L2 渲染层  : 跳过（无浏览器）');
      } else {
        final watch = Stopwatch()..start();
        String dom;
        try {
          dom = await session.render(uri);
        } catch (error) {
          dom = '';
          stdout.writeln('  L2 渲染层  : 异常 $error');
        }
        watch.stop();
        if (dom.trim().isEmpty) {
          stdout.writeln('  L2 渲染层  : 空 DOM · ${watch.elapsedMilliseconds} ms');
          await _diagnose(exe, uri, const []);
        } else {
          rendered++;
          renderHits = _hits(dom, css);
          stdout.writeln('  L2 渲染层  : ${dom.length} B · ${_blockedLabel(dom)}'
              ' · 命中 ${_hitLabel(renderHits)} · ${_title(dom)}'
              ' · ${watch.elapsedMilliseconds} ms');
        }
      }

      // L3 —— 渲染层 + --proxy-server 对照（仅 --render-proxy）
      if (renderProxy) {
        final watch = Stopwatch()..start();
        final out = await _runBrowser(exe, uri, ['--proxy-server=${proxyHostPort(proxy.trim())}']);
        watch.stop();
        if (out.$1.trim().isEmpty) {
          stdout.writeln('  L3 渲染+代理: 空 DOM · ${watch.elapsedMilliseconds} ms');
          _printDiag(out);
        } else {
          rendered++;
          final hits = _hits(out.$1, css);
          stdout.writeln('  L3 渲染+代理: ${out.$1.length} B · ${_blockedLabel(out.$1)}'
              ' · 命中 ${_hitLabel(hits)} · ${_title(out.$1)} · ${watch.elapsedMilliseconds} ms');
          renderHits = renderHits < 0 ? hits : renderHits;
        }
      }

      stdout.writeln('  判定      : ${_verdict(httpHits, renderHits)}');
      if (httpHits == 0 && (renderHits > 0)) breakthrough++;
      stdout.writeln('');
    }
  } finally {
    session.close();
  }

  stdout.writeln('── 汇总 ${'─' * 30}');
  stdout.writeln('  渲染层成功 $rendered/${cases.length + (renderProxy ? cases.length : 0)} 次'
      ' · 渲染突破 JS/captcha 壁 $breakthrough 个');
  stdout.writeln('  （命中 = DOM 中选择器命中条目数；0 → >0 即渲染层突破了封锁）');
  exitCode = rendered > 0 ? 0 : 1;
}

String _verdict(int httpHits, int renderHits) {
  if (httpHits < 0 && renderHits < 0) return '两层均失败';
  if (httpHits == 0 && renderHits > 0) return '✓ 渲染层突破 JS/captcha 壁';
  if (httpHits > 0 && renderHits == 0) return '⚠ 渲染层反而更差（虚拟时间预算不足/挑战页）';
  if (httpHits > 0 && renderHits > 0) return '两层均可用（渲染无额外收益）';
  if (httpHits == 0 && renderHits < 0) return '⚠ HTTP 层空结果且渲染失败';
  return '两层均无结果';
}

String _blockedLabel(String body) =>
    BrowserSession.looksBlocked(body) ? '⚠ 命中反爬标记' : '未触发反爬';

/// Google 的 JS 跳板页不在 looksBlocked 标记内，单独提示（否则不会触发渲染回退）。
String _hint(String body) {
  final lower = body.toLowerCase();
  if (lower.contains('enablejs') || lower.contains('not redirected within a few seconds')) {
    return ' · ⚠ JS 跳板(looksBlocked 未覆盖,线上不会触发渲染回退)';
  }
  return '';
}

String _hitLabel(int hits) => hits < 0 ? '选择器无效' : '$hits';

String _title(String body) {
  final match = RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true).firstMatch(body);
  final title = match?.group(1)?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
  return 'title=${title.isEmpty ? '(无)' : title}';
}

int _hits(String body, String css) {
  try {
    return html_parser.parse(body).querySelectorAll(css).length;
  } catch (_) {
    return -1;
  }
}

/// render() 失败时回放同一命令，打出退出码与 stderr 便于定位。
Future<void> _diagnose(String exe, Uri uri, List<String> extra) async {
  _printDiag(await _runBrowser(exe, uri, extra, again: true));
}

void _printDiag((String, int, String) out) {
  stdout.writeln('      诊断   : exit=${out.$2}'
      '${out.$3.isEmpty ? '' : ' · stderr=${out.$3.split('\n').take(2).join(' | ')}'}');
}

/// 与 BrowserSession.render 相同的命令行，但保留退出码/stderr（again=true 跳过
/// 已失败的 --headless=new 复跑，避免重复等待）。
Future<(String, int, String)> _runBrowser(
  String exe,
  Uri uri,
  List<String> extra, {
  bool again = false,
}) async {
  Future<(String, int, String)> run(List<String> mode) async {
    final result = await Process.run(exe, <String>[
      ...mode,
      ...extra,
      '--disable-gpu',
      '--disable-dev-shm-usage',
      '--virtual-time-budget=8000',
      '--dump-dom',
      uri.toString(),
    ]).timeout(const Duration(seconds: 40));
    final dom = result.exitCode == 0 ? '${result.stdout}' : '';
    return (dom, result.exitCode, '${result.stderr}'.trim());
  }

  var out = await run(again ? const ['--headless'] : const ['--headless=new']);
  if (!again && out.$1.trim().isEmpty) out = await run(const ['--headless']);
  return out;
}

void _usage() {
  stdout.writeln('用法: dart run tool/browser_render_check.dart [选项] [url ...]\n'
      '  --proxy <url>     代理（仅 HTTP 层）\n'
      '  --render-proxy    渲染层加 --proxy-server 对照测试（需同时给 --proxy）\n'
      '  --selector <css>  统计命中数的选择器（默认 a）');
}

Never _fail(String message) {
  stderr.writeln('错误: $message');
  exit(65);
}
