import 'dart:async';
import 'dart:convert';

import 'package:webview_all/webview_all.dart';

import 'browser_session.dart';

/// Thrown when the page came back as a captcha / bot-challenge wall.
class WebViewBlockedException implements Exception {
  WebViewBlockedException(this.url);

  final String url;

  @override
  String toString() => 'WebView 返回验证码/反爬页面：$url';
}

/// Outcome of [WebViewExtractor.evaluatePaged]: the merged (cross-page
/// de-duplicated) result list plus how the paging actually went, so callers can
/// tell the user *why* a "30 results / 3 pages" request only produced 10.
class PagedExtraction {
  PagedExtraction({
    required this.items,
    required this.pagesFetched,
    required this.pagesRequested,
    required this.nextSelector,
    this.trace = const <String>[],
    this.stalledReason = '',
  });

  /// Results from every page, merged in rank order, duplicates removed.
  final List<Map<String, Object?>> items;

  /// SERP pages actually parsed (1 = the first page only).
  final int pagesFetched;

  /// The page budget the caller asked for.
  final int pagesRequested;

  /// The resolved "next page" selector (empty ⇒ paging was impossible).
  final String nextSelector;

  /// Per-page trace (`第 2 页：via click`, `第 2 页：解析 10 条，新增 10`), for
  /// offline analysis of a paging run.
  final List<String> trace;

  /// Why paging stopped before [pagesRequested] (empty ⇒ it reached the budget).
  final String stalledReason;

  /// A one-line explanation when fewer pages than requested were parsed, else
  /// `null` (nothing worth reporting).
  String? get note {
    if (pagesRequested <= 1) return null;
    if (nextSelector.trim().isEmpty) {
      return '未找到「下一页」选择器，只解析了第 1 页（请配置 next_selector 或挂载解析脚本）';
    }
    if (stalledReason.isNotEmpty) {
      return '翻页提前结束：请求 $pagesRequested 页，实际解析 $pagesFetched 页'
          ' —— $stalledReason';
    }
    if (pagesFetched < pagesRequested) {
      return '翻页提前结束：请求 $pagesRequested 页，实际解析 $pagesFetched 页'
          '（没有下一页链接，或该页没有新增结果）';
    }
    return null;
  }
}

/// Drives a hidden (offscreen) WebView to load a URL, let its JavaScript run,
/// then evaluate an extraction script in the page context.
///
/// A process-wide singleton: an offscreen session owns a native WebView and a
/// browser engine (heavy), so it is created lazily, reused, and every
/// evaluation is serialized behind a single-flight lock.
///
/// Platform support comes from `webview_all` (Android / iOS / macOS / Windows /
/// Linux via WebKitGTK). On unsupported platforms [available] turns `false` and
/// [evaluate] throws, so callers can fall back to the HTTP/headless tiers.
class WebViewExtractor {
  WebViewExtractor._();

  static final WebViewExtractor _shared = WebViewExtractor._();

  static WebViewExtractor get shared => _shared;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// Sent with every navigation: a real domestic Chrome user's requests carry
  /// a Chinese Accept-Language, and SERPs (Bing) do query understanding with it.
  static const _requestHeaders = <String, String>{
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  /// How long to wait, per trigger, for a page change to become observable.
  static const _pageChangeTimeout = Duration(seconds: 10);

  /// Paging triggers, tried in this order (a winning one is tried first next
  /// time). Clicking is first on purpose: engines like Bing build the paged URL
  /// in their own pager JS — a raw `href` fetched as a fresh navigation gets
  /// answered with page 1 again.
  static const _strategies = <String>['click', 'assign', 'loadRequest'];

  /// How many trigger rounds one "next page" attempt may take.
  ///
  /// A SERP can need more than one round: the *first* paged navigation of a
  /// session is answered with page 1 again (Bing does this for 45 s and longer,
  /// so it is not a matter of waiting), yet that hop rewrites the pager `href`
  /// (Bing appends a fresh `FPIG`), and triggering *that* link does advance.
  /// Measured in WebKitGTK: click #1 → still page 1, click #2 → page 2
  /// (`sb_pagS=2`, different first result). Hence: repeat, don't wait.
  static const _advanceRounds = 3;

  OffscreenWebViewSession? _session;
  bool _unavailable = false;
  String _reason = '';
  Future<void> _lock = Future<void>.value();

  /// Hosts whose session was already warmed up this run (see [_primeSession]).
  final Set<String> _primed = <String>{};

  /// Whether an offscreen WebView can be created on this platform.
  bool get available => !_unavailable;

  String get unavailableReason => _reason;

  /// Loads [url], waits for it to render, and evaluates [js] in the page.
  ///
  /// [js] is a self-executing function body; a script that `return`s a JSON
  /// string can be decoded with [decodeResults]. [waitSelector] delays
  /// evaluation until that CSS selector appears (for JS-rendered results).
  Future<Object?> evaluate(
    Uri url,
    String js, {
    String waitSelector = '',
    Duration timeout = const Duration(seconds: 30),
  }) =>
      _serial(() => _evaluate(url, js, waitSelector: waitSelector, timeout: timeout));

  Future<Object?> _evaluate(
    Uri url,
    String js, {
    required String waitSelector,
    required Duration timeout,
  }) async {
    final session = await _ensure();
    final controller = session.controller;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _applyUserAgent(controller);

    final loaded = Completer<void>();
    await controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) {
        if (!loaded.isCompleted) loaded.complete();
      },
    ));
    await controller.loadRequest(url, headers: _requestHeaders);
    try {
      await loaded.future.timeout(timeout);
    } on TimeoutException {
      // A partial render is still worth attempting to parse.
    }
    await _patchFingerprint(controller);
    // Check for a challenge page *before* waiting on a selector: otherwise a
    // captcha wall would just time the selector wait out and hide the cause.
    if (await _looksBlocked(controller)) {
      throw WebViewBlockedException(url.toString());
    }
    if (waitSelector.trim().isNotEmpty) {
      final found = await _waitFor(controller, waitSelector.trim(), timeout);
      if (!found) {
        throw StateError(
            '等待选择器 "$waitSelector" 超时。页面诊断：${await _diagnose(controller)}');
      }
    }
    if (await _looksBlocked(controller)) {
      throw WebViewBlockedException(url.toString());
    }
    // Scripts are self-executing functions that `return` a JSON string, so a
    // plain evaluation is what we want. `callAsyncJavaScript` wraps the body in
    // another function, which discards the IIFE's return value (→ null).
    return controller.runJavaScriptReturningResult(js);
  }

  /// Loads [url] and returns the rendered `outerHTML` of the document.
  ///
  /// Used to dump a page to disk for offline inspection when extraction fails.
  /// The desktop-Chrome UA is applied here too: without it the engine serves a
  /// *different* (lite) variant than the one [evaluatePaged] searches, which
  /// makes a dump actively misleading when debugging pagination.
  Future<String> captureHtml(
    Uri url, {
    String waitSelector = '',
    Duration timeout = const Duration(seconds: 30),
  }) =>
      _serial(() => _captureHtml(url, waitSelector: waitSelector, timeout: timeout));

  Future<String> _captureHtml(
    Uri url, {
    required String waitSelector,
    required Duration timeout,
  }) async {
    final session = await _ensure();
    final controller = session.controller;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _applyUserAgent(controller);
    final loaded = Completer<void>();
    await controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) {
        if (!loaded.isCompleted) loaded.complete();
      },
    ));
    await controller.loadRequest(url, headers: _requestHeaders);
    try {
      await loaded.future.timeout(timeout);
    } on TimeoutException {
      // A partial render is still useful for a dump.
    }
    await _patchFingerprint(controller);
    if (waitSelector.trim().isNotEmpty) {
      await _waitFor(controller, waitSelector.trim(), timeout);
    }
    try {
      return '${await controller.runJavaScriptReturningResult('document.documentElement.outerHTML')}';
    } catch (_) {
      return '';
    }
  }

  /// Loads [url], then advances to the next SERP page ([nextSelector]) up to
  /// [maxPages] times, merging every page into **one** de-duplicated list.
  ///
  /// Advancing is *verified*, not assumed. For each next page the triggers
  /// [_strategies] are tried in order — (1) a full mouse-event sequence on the
  /// "next" control, so the site's own pager JS runs and builds the real paged
  /// URL; (2) `location.assign(nextHref)` inside the page; (3) a plain
  /// `loadRequest(nextHref)` — and after every trigger the extraction script
  /// must return a *different* result set before the page counts as fetched.
  ///
  /// This matters because SERP pagination is context-sensitive: Bing's pager
  /// `href` (`…&first=11&FORM=PORE`) fetched as a fresh navigation is answered
  /// with page 1 again, and a stale DOM still satisfies the ready selector — so
  /// "the selector matched" is no evidence that the page advanced. A page that
  /// stayed identical stops paging and is reported via [PagedExtraction.note]
  /// instead of silently shortening the result list.
  Future<PagedExtraction> evaluatePaged(
    Uri url,
    String js, {
    String readySelector = '',
    String nextSelector = '',
    int maxPages = 1,
    Duration timeout = const Duration(seconds: 30),
  }) =>
      _serial(() => _evaluatePaged(
            url,
            js,
            readySelector: readySelector,
            nextSelector: nextSelector,
            maxPages: maxPages,
            timeout: timeout,
          ));

  Future<PagedExtraction> _evaluatePaged(
    Uri url,
    String js, {
    required String readySelector,
    required String nextSelector,
    required int maxPages,
    required Duration timeout,
  }) async {
    final session = await _ensure();
    final controller = session.controller;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _applyUserAgent(controller);

    final pages = maxPages < 1 ? 1 : maxPages;
    final all = <Map<String, Object?>>[];
    final seen = <String>{};
    final trace = <String>[];
    var fetched = 0;
    var stalled = '';
    var strategy = '';

    await _primeSession(controller, url);
    await _loadAndWait(controller, url, timeout);
    await _patchFingerprint(controller);
    if (await _looksBlocked(controller)) {
      throw WebViewBlockedException(url.toString());
    }

    for (var page = 0; page < pages; page++) {
      if (page > 0) {
        final advanced = await _advance(
          controller,
          nextSelector,
          js,
          prefer: strategy,
        );
        if (!advanced.ok) {
          stalled = advanced.reason;
          trace.add('第 ${page + 1} 页未加载：${advanced.reason}');
          break;
        }
        strategy = advanced.strategy;
        trace.add('第 ${page + 1} 页：via ${advanced.strategy}');
        await _patchFingerprint(controller);
        if (await _looksBlocked(controller)) {
          throw WebViewBlockedException(url.toString());
        }
      }
      if (readySelector.trim().isNotEmpty) {
        await _waitFor(controller, readySelector.trim(), timeout);
      }
      final items = decodeResults(await controller.runJavaScriptReturningResult(js));
      fetched++;
      var added = 0;
      for (final item in items) {
        final url0 = '${item['url'] ?? ''}';
        if (url0.isNotEmpty && seen.add(url0)) {
          all.add(item);
          added++;
        }
      }
      trace.add('第 ${page + 1} 页：解析 ${items.length} 条，新增 $added');
      // No new URL ⇒ the page did not advance (see _advance) or is empty —
      // asking for further pages would repeat the same result.
      if (added == 0) {
        stalled = stalled.isEmpty
            ? '第 ${page + 1} 页与上一页结果完全相同（引擎拒绝了翻页请求）'
            : stalled;
        break;
      }
    }
    return PagedExtraction(
      items: all,
      pagesFetched: fetched,
      pagesRequested: pages,
      nextSelector: nextSelector.trim(),
      trace: trace,
      stalledReason: stalled,
    );
  }

  /// Advances the web view to the next result page and verifies that the parsed
  /// result set actually changed. Returns the strategy that worked, or a reason
  /// why paging could not proceed.
  ///
  /// Up to [_advanceRounds] rounds are run, each re-reading the pager `href`
  /// from the (possibly rewritten) DOM: a hop that navigated but kept the same
  /// result set is *retried*, not treated as a dead end — see [_advanceRounds].
  Future<_PagingAttempt> _advance(
    WebViewController controller,
    String selector,
    String js, {
    String prefer = '',
  }) async {
    if (selector.trim().isEmpty) {
      return _PagingAttempt(false, '', '未配置「下一页」选择器');
    }
    // The previously successful strategy goes first; the rest keep their order.
    final order = <String>[
      if (prefer.isNotEmpty) prefer,
      ..._strategies.where((s) => s != prefer),
    ];
    var navigated = '';
    for (var round = 0; round < _advanceRounds; round++) {
      final before = await _signature(controller, js);
      final hrefBefore = await _currentHref(controller);
      final nextHref = await _nextHref(controller, selector);
      var triggered = false;
      for (final candidate in order) {
        if (!await _trigger(controller, candidate, selector, nextHref)) continue;
        triggered = true;
        if (await _waitForChange(controller, js, before, hrefBefore)) {
          return _PagingAttempt(true, candidate, '');
        }
        final hrefNow = await _currentHref(controller);
        if (hrefNow.isNotEmpty && hrefNow != hrefBefore) {
          // The hop went through, but the engine answered it with the same
          // result set (page 1) — the other triggers would only re-request that
          // very URL, so break out and retry from the rewritten DOM.
          navigated = hrefNow;
          break;
        }
      }
      if (!triggered) {
        return _PagingAttempt(false, '', '未找到可点击的「下一页」元素（$selector）');
      }
      if (navigated.isEmpty) {
        // The page did not move at all: repeating the trigger cannot help.
        return _PagingAttempt(
          false,
          '',
          '触发「下一页」($selector) 后页面未变化（location 仍为 $hrefBefore）',
        );
      }
    }
    return _PagingAttempt(
      false,
      '',
      '已导航到 $navigated，但结果集与上一页相同'
      '（引擎忽略了分页参数，已重试 $_advanceRounds 轮）',
    );
  }

  /// Runs one paging trigger; returns whether it could be issued at all.
  Future<bool> _trigger(
    WebViewController controller,
    String strategy,
    String selector,
    String nextHref,
  ) async {
    switch (strategy) {
      case 'click':
        return _click(controller, selector);
      case 'assign':
        return nextHref.isEmpty ? false : _assign(controller, nextHref);
      case 'loadRequest':
        if (!nextHref.startsWith('http')) return false;
        try {
          await controller.loadRequest(Uri.parse(nextHref), headers: _requestHeaders);
          return true;
        } catch (_) {
          return false;
        }
      default:
        return false;
    }
  }

  /// The "next page" URL the DOM advertises. Kept only as a fallback: for Bing
  /// this href is *not* the URL a browser ends up on (its pager JS rewrites it
  /// with the search context and `FORM=PERE`), so fetching it as a fresh
  /// navigation returns page 1 again.
  Future<String> _nextHref(WebViewController controller, String selector) async {
    final js = '''
(function () {
  var el = document.querySelector(${jsonEncode(selector)});
  if (!el) return '';
  var href = el.href || '';
  if (!href) return '';
  try { return new URL(href, location.href).href; } catch (e) { return href; }
})()''';
    return _clean(await _eval(controller, js));
  }

  /// Clicks the first element matching [selector] with a full mouse sequence:
  /// pager handlers are commonly bound to `mousedown` (Bing uses it for click
  /// telemetry and to build the paged URL) and a bare `el.click()` never runs
  /// them. Returns whether the element existed.
  Future<bool> _click(WebViewController controller, String selector) async {
    if (selector.trim().isEmpty) return false;
    final js = '''
(function () {
  var el = document.querySelector(${jsonEncode(selector)});
  if (!el) return 'no';
  if (typeof el.scrollIntoView === 'function') el.scrollIntoView({block: 'center'});
  var opts = {bubbles: true, cancelable: true, view: window};
  ['mousedown', 'mouseup', 'click'].forEach(function (type) {
    el.dispatchEvent(new MouseEvent(type, opts));
  });
  return 'yes';
})()''';
    try {
      return probeFound(await controller.runJavaScriptReturningResult(js));
    } catch (_) {
      return false;
    }
  }

  /// Navigates from inside the page (`location.assign`), so the request carries
  /// the browser context a real pager click would send (cookies, referer, and
  /// the JS-set context cookies like Bing's `SRCHHPGUSR`).
  Future<bool> _assign(WebViewController controller, String href) async {
    try {
      final result = await _eval(controller, 'location.assign(${jsonEncode(href)}), "ok"');
      return result.contains('ok');
    } catch (_) {
      return false;
    }
  }

  /// Polls until the extraction script sees a different result set (or the URL
  /// changed and results are gone). Returns `false` at the timeout.
  Future<bool> _waitForChange(
    WebViewController controller,
    String js,
    String before,
    String hrefBefore,
  ) async {
    final deadline = DateTime.now().add(_pageChangeTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final signature = await _signature(controller, js);
      if (signature == before) continue;
      // `_signature` renders as "<first-url>|<count>"; a page that parses to
      // nothing is not progress, it is a broken/empty page.
      if (!signature.endsWith('|0')) return true;
      final href = await _currentHref(controller);
      if (href.isEmpty || href == hrefBefore) continue;
      return true;
    }
    return false;
  }

  /// Cheap identity of the current result set: first result URL + item count.
  Future<String> _signature(WebViewController controller, String js) async {
    final items = decodeResults(await _eval(controller, js));
    final first = items.isEmpty ? '' : '${items.first['url'] ?? ''}';
    return '$first|${items.length}';
  }

  Future<String> _currentHref(WebViewController controller) =>
      _eval(controller, 'location.href').then(_clean);

  /// Evaluates [js] in the page, returning `''` on any failure (probing must
  /// never abort a paging run).
  Future<String> _eval(WebViewController controller, String js) async {
    try {
      return '${await controller.runJavaScriptReturningResult(js)}';
    } catch (_) {
      return '';
    }
  }

  /// Strips the JSON-ish quoting some engines put around string results.
  static String _clean(String raw) {
    var value = raw.trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value.replaceAll(r'\"', '"').trim();
  }

  /// Loads [url] and waits for the main frame to finish (bounded by [timeout]).
  Future<void> _loadAndWait(
    WebViewController controller,
    Uri url,
    Duration timeout,
  ) async {
    final loaded = Completer<void>();
    await controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) {
        if (!loaded.isCompleted) loaded.complete();
      },
    ));
    await controller.loadRequest(url, headers: _requestHeaders);
    try {
      await loaded.future.timeout(timeout);
    } on TimeoutException {
      // A partial render is still worth parsing.
    }
  }

  Future<void> _applyUserAgent(WebViewController controller) async {
    try {
      await controller.setUserAgent(_ua);
    } catch (_) {
      // Some engines refuse UA overrides — not fatal.
    }
  }

  /// Re-declares the JS-visible identity (`navigator.*`) to match [_ua] after
  /// each navigation: the underlying engine is WebKitGTK, so a UA override
  /// alone leaves `navigator.platform`/`userAgentData` telling a different
  /// story — engines (Bing) fingerprint that and serve a degraded SERP.
  ///
  /// Best-effort by design: patches cannot reach scripts that read `navigator`
  /// before injection, so the caller must not depend on them.
  Future<void> _patchFingerprint(WebViewController controller) async {
    await _eval(controller, _fingerprintPatchJs());
  }

  static String _fingerprintPatchJs() => '''
(function () {
  try {
    var ua = ${jsonEncode(_ua)};
    var defs = {
      userAgent: ua,
      appVersion: ua.replace('Mozilla/', ''),
      platform: 'Win32',
      vendor: 'Google Inc.',
      language: 'zh-CN',
      languages: ['zh-CN', 'zh', 'en']
    };
    Object.keys(defs).forEach(function (key) {
      try {
        Object.defineProperty(navigator, key, {
          get: function () { return defs[key]; },
          configurable: true
        });
      } catch (e) {}
    });
    var brands = [
      { brand: 'Chromium', version: '124' },
      { brand: 'Google Chrome', version: '124' },
      { brand: 'Not-A.Brand', version: '99' }
    ];
    var uad = {
      brands: brands,
      mobile: false,
      platform: 'Windows',
      toJSON: function () {
        return { brands: brands, mobile: false, platform: 'Windows' };
      },
      getHighEntropyValues: function () {
        return Promise.resolve({
          brands: brands,
          mobile: false,
          platform: 'Windows',
          platformVersion: '15.0.0',
          architecture: 'x86',
          bitness: '64',
          model: '',
          fullVersionList: brands,
          uaFullVersion: '124.0.0.0',
          wow64: false
        });
      }
    };
    Object.defineProperty(navigator, 'userAgentData', {
      get: function () { return uad; },
      configurable: true
    });
  } catch (e) {}
  return 'ok';
})()''';

  /// Warms the browser session on [url]'s host once per session, so the first
  /// search runs in a warmed context like a real user's: the engine's homepage
  /// has been opened and its market cookies are in place (Bing ranks a
  /// `11月…` query differently for a fresh, market-less session).
  ///
  /// Best-effort — a failed warm-up must never abort the actual request.
  Future<void> _primeSession(WebViewController controller, Uri url) async {
    final host = url.host;
    if (host.isEmpty || !_primed.add(host)) return;
    try {
      final origin = Uri(scheme: url.scheme, host: host);
      await _loadAndWait(controller, origin, const Duration(seconds: 15));
      final seed = _localeCookieJs(host);
      if (seed.isNotEmpty) await _eval(controller, seed);
    } catch (_) {
      // Warm-up is best-effort.
    }
  }

  /// Market/locale cookies seeded on the engine host, JS-run on the page so
  /// they belong to the right domain and jar.
  static String _localeCookieJs(String host) {
    if (host.endsWith('bing.com')) {
      return '''
(function () {
  var list = [
    'SRCHHPGUSR=SRCHLANG=zh-Hans&NEWWND=0&BRW=W&BRH=S&CW=1512&CH=824&DPR=1&UTC=480&DM=0&EXLTT=1',
    '_EDGE_S=mkt=zh-cn&ui=zh-cn&F=1'
  ];
  for (var i = 0; i < list.length; i++) {
    document.cookie = list[i] + '; path=/; max-age=31536000';
  }
  return 'ok';
})()''';
    }
    return '';
  }

  /// Releases the offscreen session (idempotent).
  Future<void> close() async {
    final session = _session;
    _session = null;
    if (session == null) return;
    try {
      await session.close();
    } catch (_) {
      // Best-effort: the finalizer also releases the native view.
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<OffscreenWebViewSession> _ensure() async {
    if (_unavailable) throw StateError(_reason);
    final existing = _session;
    if (existing != null) return existing;
    try {
      final session = await OffscreenWebViewSession.create();
      _session = session;
      return session;
    } catch (error) {
      _unavailable = true;
      _reason = '当前平台不支持离屏 WebView：$error';
      throw StateError(_reason);
    }
  }

  Future<bool> _waitFor(
    WebViewController controller,
    String selector,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    // The probe returns the *string* "yes"/"no", not a number: some engines
    // surface JS numbers as doubles, so `1` arrives as `1.0` and never
    // compares equal to "1" — which made the wait always time out even when
    // the selector was present.
    final probe = 'document.querySelector(${jsonEncode(selector)}) ? "yes" : "no"';
    while (DateTime.now().isBefore(deadline)) {
      try {
        if (probeFound(await controller.runJavaScriptReturningResult(probe))) return true;
      } catch (_) {
        // Keep polling until the deadline.
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  /// Whether a `runJavaScriptReturningResult` payload means "selector found".
  ///
  /// Accepts `yes` / `"yes"` / `true`; anything else (including `1`) is false.
  static bool probeFound(Object? raw) {
    final text = '$raw'.toLowerCase();
    return text.contains('yes') || text.contains('true');
  }

  Future<bool> _looksBlocked(WebViewController controller) async {
    try {
      final text = await controller.runJavaScriptReturningResult(
        'document.body ? document.body.innerText.slice(0, 600) : ""',
      );
      return BrowserSession.looksBlocked('$text');
    } catch (_) {
      return false;
    }
  }

  /// Collects page facts to explain why a selector never appeared: the final
  /// URL, title, visible text, and the class names of the first `<li>` elements
  /// so a stale result selector can be corrected from the output alone.
  Future<String> _diagnose(WebViewController controller) async {
    const probe = '''
(function () {
  var lis = [];
  var nodes = document.querySelectorAll('li');
  for (var i = 0; i < nodes.length && lis.length < 20; i++) {
    var c = (typeof nodes[i].className === 'string' ? nodes[i].className : '').trim();
    if (c) lis.push(c.split(/\\s+/).slice(0, 3).join('.'));
  }
  return JSON.stringify({
    url: location.href,
    title: document.title,
    text: (document.body ? document.body.innerText.slice(0, 200) : ''),
    liClasses: lis
  });
})()''';
    try {
      return '${await controller.runJavaScriptReturningResult(probe)}';
    } catch (error) {
      return '诊断失败：$error';
    }
  }

  /// Decodes an extraction script's JSON-string result into result maps.
  ///
  /// Handles engines that hand the JS string back JSON-encoded (with
  /// surrounding quotes), so it may need to decode twice.
  static List<Map<String, Object?>> decodeResults(Object? raw) {
    Object? value = raw;
    for (var i = 0; i < 2 && value is String; i++) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return const <Map<String, Object?>>[];
      try {
        value = jsonDecode(trimmed);
      } catch (_) {
        return const <Map<String, Object?>>[];
      }
    }
    if (value is! List) return const <Map<String, Object?>>[];
    final out = <Map<String, Object?>>[];
    for (final item in value) {
      if (item is! Map) continue;
      out.add({
        'title': '${item['title'] ?? ''}'.trim(),
        'url': '${item['url'] ?? ''}'.trim(),
        'snippet': '${item['snippet'] ?? ''}'.trim(),
      });
    }
    return out;
  }
}

/// Outcome of one paging attempt (see [WebViewExtractor._advance]).
class _PagingAttempt {
  _PagingAttempt(this.ok, this.strategy, this.reason);

  final bool ok;

  /// The trigger that made the page advance (`click` / `assign` / `loadRequest`).
  final String strategy;

  /// Why paging stopped (empty when [ok]).
  final String reason;
}
