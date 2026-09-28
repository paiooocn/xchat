import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../models/proxy_config.dart';

/// One decoded response of [BrowserSession.get].
class BrowserPage {
  BrowserPage({
    required this.uri,
    required this.statusCode,
    required this.contentType,
    required this.body,
  });

  /// Final URL after redirects.
  final Uri uri;
  final int statusCode;
  final String contentType;
  final String body;
}

/// Browser-faithful URL execution in two tiers:
///
/// 1. [get] — HTTP-level browser emulation: a full desktop-browser header set
///    (UA / Accept / Sec-CH-UA / Sec-Fetch-*), a persistent cookie jar and
///    redirect following. Bare `User-Agent`-only requests are trivially
///    fingerprinted as crawlers and served cloaked SEO-spam;
/// 2. [render] — real rendering fallback: runs the URL in a locally installed
///    Chromium (`--headless=new --dump-dom`) and returns the executed DOM for
///    JS challenges / captcha walls. It costs seconds per call, so it is only
///    used when the HTTP tier gets blocked.
///
/// Note: TLS/JA3 fingerprint and IP reputation cannot be faked from Dart —
/// route through the configured proxy (or use a search API) for those.
class BrowserSession {
  BrowserSession({
    ProxyConfig? proxy,
    this.renderTimeout = const Duration(seconds: 30),
  }) : _http = _buildHttp(proxy ?? ProxyConfig());

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  /// Markers of captcha / bot-challenge walls (matched lowercase).
  static const _blockedMarkers = <String>[
    'id="b_captcha"',
    'sb_captcha',
    'challenge-form',
    'anomaly-modal',
    'detected unusual traffic',
    '请验证您是真人',
    '输入验证码',
  ];

  final HttpClient _http;
  final Duration renderTimeout;
  final Map<String, List<Cookie>> _jar = <String, List<Cookie>>{};

  /// Per-visitor tracking hash (`refig`): random per session but stable, so
  /// consecutive requests look like one browser visit.
  late final String refig = List.generate(16, (_) => _random.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  static final Random _random = Random.secure();

  static HttpClient _buildHttp(ProxyConfig proxy) {
    final client = buildProxiedHttpClient(proxy);
    client.autoUncompress = true;
    client.connectionTimeout = const Duration(seconds: 15);
    return client;
  }

  /// Whether [body] is a captcha / bot-challenge page instead of real content.
  static bool looksBlocked(String body) {
    final lower = body.toLowerCase();
    for (final marker in _blockedMarkers) {
      if (lower.contains(marker.toLowerCase())) return true;
    }
    return false;
  }

  /// GETs [uri] like a desktop browser (top-level navigation).
  /// [bearer] adds an `Authorization: Bearer …` header for API calls.
  Future<BrowserPage> get(Uri uri, {String? bearer}) =>
      _get(uri, bearer).timeout(const Duration(seconds: 30));

  Future<BrowserPage> _get(Uri uri, String? bearer) async {
    final request = await _http.getUrl(uri);
    final cookie = _cookieHeader(uri.host);
    <String, String>{
      'user-agent': _ua,
      'accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
      'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'sec-ch-ua': '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
      'sec-ch-ua-mobile': '?0',
      'sec-ch-ua-platform': '"Windows"',
      'sec-fetch-dest': 'document',
      'sec-fetch-mode': 'navigate',
      'sec-fetch-site': 'none',
      'sec-fetch-user': '?1',
      'upgrade-insecure-requests': '1',
      if (cookie.isNotEmpty) 'cookie': cookie,
    }.forEach(request.headers.set);
    if (bearer != null && bearer.isNotEmpty) {
      request.headers.set('authorization', 'Bearer $bearer');
    }

    final response = await request.close();
    _storeCookies(uri.host, response.cookies);
    var finalUri = uri;
    for (final redirect in response.redirects) {
      finalUri = finalUri.resolve('${redirect.location}');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return BrowserPage(
      uri: finalUri,
      statusCode: response.statusCode,
      contentType: response.headers.contentType?.mimeType ?? '',
      body: _decode(bytes, response.headers.contentType?.charset),
    );
  }

  /// POSTs a JSON [body] (REST API calls); [bearer] adds `Authorization`.
  Future<BrowserPage> postJson(Uri uri, Map<String, Object?> body, {String? bearer}) =>
      _post(uri, jsonEncode(body), bearer).timeout(const Duration(seconds: 30));

  Future<BrowserPage> _post(Uri uri, String payload, String? bearer) async {
    final request = await _http.postUrl(uri);
    request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    if (bearer != null && bearer.isNotEmpty) {
      request.headers.set('authorization', 'Bearer $bearer');
    }
    request.write(payload);
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return BrowserPage(
      uri: uri,
      statusCode: response.statusCode,
      contentType: response.headers.contentType?.mimeType ?? '',
      body: _decode(bytes, response.headers.contentType?.charset),
    );
  }

  /// Executes [uri] in a headless Chromium and returns the rendered DOM
  /// (empty string when no local browser is available).
  Future<String> render(Uri uri) async {
    final String exe;
    final cached = _cachedExe;
    if (cached != null) {
      exe = cached;
    } else {
      final found = await _locateBrowser();
      _cachedExe = found;
      exe = found;
    }
    if (exe.isEmpty) return '';

    Future<String> run(List<String> mode) async {
      final result = await Process.run(exe, <String>[
        ...mode,
        '--disable-gpu',
        '--disable-dev-shm-usage',
        '--virtual-time-budget=8000',
        '--dump-dom',
        uri.toString(),
      ]).timeout(renderTimeout);
      return result.exitCode == 0 ? '${result.stdout}' : '';
    }

    var dom = await run(const ['--headless=new']);
    if (dom.trim().isEmpty) dom = await run(const ['--headless']);
    return dom;
  }

  /// Whether a local Chromium binary exists for [render]
  /// (optimistically `true` until the first lookup runs).
  bool get canRender => _cachedExe?.isNotEmpty ?? true;

  /// The Chromium binary [render] will use (empty when none is installed).
  static Future<String> locateBrowser() => _locateBrowser();

  static String? _cachedExe;

  static Future<String> _locateBrowser() async {
    if (Platform.isWindows) {
      const candidates = <String>[
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      ];
      for (final path in candidates) {
        if (File(path).existsSync()) return path;
      }
    }
    const names = <String>[
      'google-chrome',
      'google-chrome-stable',
      'chromium',
      'chromium-browser',
      'microsoft-edge',
      'msedge',
    ];
    for (final name in names) {
      try {
        final result = await Process.run(Platform.isWindows ? 'where' : 'which', [name]);
        final line = '${result.stdout}'.trim().split('\n').first.trim();
        if (result.exitCode == 0 && line.isNotEmpty) return line;
      } catch (_) {
        // Locator not available — try the next candidate.
      }
    }
    return '';
  }

  /// Whether the jar already holds cookies for [domain] (or a related host).
  bool hasCookiesFor(String domain) => _jar.keys
      .any((d) => domain == d || domain.endsWith('.$d') || d.endsWith('.$domain'));

  void _storeCookies(String host, List<Cookie> cookies) {
    if (cookies.isEmpty) return;
    final jar = _jar.putIfAbsent(host.toLowerCase(), () => <Cookie>[]);
    for (final cookie in cookies) {
      final expired = cookie.expires?.isBefore(DateTime.now()) ?? false;
      jar.removeWhere((c) => c.name == cookie.name);
      if (expired || cookie.value.isEmpty || cookie.value == 'deleted') continue;
      jar.add(cookie);
    }
  }

  String _cookieHeader(String host) {
    final out = <String>[];
    _jar.forEach((domain, cookies) {
      if (host == domain || host.endsWith('.$domain')) {
        out.addAll(cookies.map((c) => '${c.name}=${c.value}'));
      }
    });
    return out.join('; ');
  }

  /// Charset-aware decoding (falls back to UTF-8 for unknown charsets).
  static String _decode(List<int> bytes, String? charset) {
    final encoding = Encoding.getByName(charset ?? '');
    if (encoding == null || encoding.name == 'utf-8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    try {
      return encoding.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  void close() => _http.close(force: true);
}
