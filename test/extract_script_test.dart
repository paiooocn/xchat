import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/agent/tools/builtin_tools.dart';
import 'package:xchat/agent/tools/webview_extractor.dart';
import 'package:xchat/models/extract_script.dart';
import 'package:xchat/models/search_engine_config.dart';

/// Tests for the hidden-WebView search path: URL building, script matching and
/// result decoding — the pieces that decide whether a WebView search returns
/// anything at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UrlMatcher', () {
    test('matches host suffix with path prefix', () {
      final matcher = UrlMatcher(hosts: ['bing.com'], pathPrefix: '/search');
      expect(matcher.matches(Uri.parse('https://cn.bing.com/search?q=x')), isTrue);
      expect(matcher.matches(Uri.parse('https://bing.com/search?q=x')), isTrue);
      expect(matcher.matches(Uri.parse('https://cn.bing.com/images?q=x')), isFalse);
      expect(matcher.matches(Uri.parse('https://example.com/search')), isFalse);
    });

    test('url_pattern takes precedence', () {
      final matcher = UrlMatcher(urlPattern: r'example\.com/search');
      expect(matcher.matches(Uri.parse('https://example.com/search')), isTrue);
      expect(matcher.matches(Uri.parse('https://example.com/other')), isFalse);
    });

    test('score ranks exact host above suffix', () {
      final exact = UrlMatcher(hosts: ['cn.bing.com'], pathPrefix: '/search');
      final suffix = UrlMatcher(hosts: ['bing.com'], pathPrefix: '/search');
      final url = Uri.parse('https://cn.bing.com/search?q=x');
      expect(exact.score(url), greaterThan(suffix.score(url)));
    });

    test('empty matcher matches nothing', () {
      expect(UrlMatcher().matches(Uri.parse('https://a.com')), isFalse);
    });
  });

  group('ExtractScript', () {
    test('json round-trip preserves fields', () {
      final script = ExtractScript(
        id: 'bing',
        name: 'Bing',
        body: 'return JSON.stringify([])',
        matcher: UrlMatcher(hosts: ['bing.com'], pathPrefix: '/search'),
        readySelector: 'li.b_algo',
        nextSelector: 'a.sb_pagN',
        priority: 10,
        createdBy: 'builtin',
      );
      final restored = ExtractScript.fromJson(script.toJson());
      expect(restored.id, 'bing');
      expect(restored.readySelector, 'li.b_algo');
      expect(restored.nextSelector, 'a.sb_pagN');
      expect(restored.priority, 10);
      expect(restored.createdBy, 'builtin');
      expect(restored.matcher.matches(Uri.parse('https://cn.bing.com/search?q=x')), isTrue);
    });

    test('isValid requires id and body', () {
      expect(ExtractScript(id: 'a', name: 'a', body: '').isValid, isFalse);
      expect(ExtractScript(id: '', name: 'a', body: 'return []').isValid, isFalse);
      expect(ExtractScript(id: 'a', name: 'a', body: 'return []').isValid, isTrue);
    });

    test('fromSelectors builds a script that returns JSON', () {
      final script = ExtractScript.fromSelectors(
        id: 'x',
        name: 'X',
        resultSelector: 'li.item',
        titleSelector: 'h3',
        linkSelector: 'a',
        snippetSelector: 'p',
        nextSelector: 'a.next',
      );
      expect(script.body, contains('querySelectorAll'));
      expect(script.body, contains('JSON.stringify'));
      expect(script.body, contains('li.item'));
      expect(script.nextSelector, 'a.next');
    });
  });

  group('SearchEngineConfig paging', () {
    test('json round-trip preserves next selector and page count', () {
      final engine = SearchEngineConfig(
        id: 'w',
        name: 'W',
        urlTemplate: 'https://example.com/search?q={query}',
        nextSelector: 'a.next',
        pages: 3,
      );
      final restored = SearchEngineConfig.fromJson(engine.toJson());
      expect(restored.nextSelector, 'a.next');
      expect(restored.pages, 3);
      expect(restored.pageCount, 3);
    });

    test('page count is clamped and defaults to a single page', () {
      final engine = SearchEngineConfig(id: 'w', name: 'W');
      expect(engine.pageCount, 1);
      expect(engine.copyWith(pages: 99).pageCount, 10);
      expect(SearchEngineConfig.fromJson({'pages': 0}).pageCount, 1);
    });

    test('legacy direct-request engines get their SERP template back', () {
      final bing = SearchEngineConfig.fromJson({'id': 'bing', 'name': 'Bing', 'kind': 'bing'});
      expect(bing.isReady, isTrue);
      expect(BuiltinTools.searchUrl(bing, 'x')!.host, 'cn.bing.com');
      // API engines of the removed mode have no browsable SERP.
      final tavily = SearchEngineConfig.fromJson({'id': 'tavily', 'name': 'T', 'kind': 'tavily'});
      expect(tavily.isReady, isFalse);
    });
  });

  group('WebViewExtractor.decodeResults', () {
    test('decodes a JSON string array', () {
      final out = WebViewExtractor.decodeResults(
        '[{"title":"t","url":"https://a.com","snippet":"s"}]',
      );
      expect(out.length, 1);
      expect(out.first['title'], 't');
      expect(out.first['url'], 'https://a.com');
    });

    test('tolerates empty / invalid / null / non-list', () {
      expect(WebViewExtractor.decodeResults(''), isEmpty);
      expect(WebViewExtractor.decodeResults('not json'), isEmpty);
      expect(WebViewExtractor.decodeResults(null), isEmpty);
      expect(WebViewExtractor.decodeResults('{}'), isEmpty);
    });

    test('decodes a double-encoded JSON string (engine returns it quoted)', () {
      final inner = '[{"title":"t","url":"https://a.com","snippet":"s"}]';
      final out = WebViewExtractor.decodeResults(jsonEncode(inner));
      expect(out.length, 1);
      expect(out.first['url'], 'https://a.com');
    });
  });

  group('WebViewExtractor.probeFound', () {
    test('accepts string yes / quoted yes / true', () {
      expect(WebViewExtractor.probeFound('yes'), isTrue);
      expect(WebViewExtractor.probeFound('"yes"'), isTrue);
      expect(WebViewExtractor.probeFound('true'), isTrue);
    });

    test('rejects no and bare numbers (the old numeric-compare bug)', () {
      // Regression: the probe used `? 1 : 0`, but WebKitGTK returns JS numbers
      // as doubles, so `1` arrived as `1.0` and never matched "1" — the
      // selector wait always timed out even when the element was present.
      expect(WebViewExtractor.probeFound('no'), isFalse);
      expect(WebViewExtractor.probeFound('1'), isFalse);
      expect(WebViewExtractor.probeFound('1.0'), isFalse);
      expect(WebViewExtractor.probeFound('0'), isFalse);
    });
  });

  group('PagedExtraction diagnostics', () {
    PagedExtraction paged({
      required int fetched,
      required int requested,
      String next = 'a.next',
      String stalled = '',
    }) =>
        PagedExtraction(
          items: const <Map<String, Object?>>[],
          pagesFetched: fetched,
          pagesRequested: requested,
          nextSelector: next,
          stalledReason: stalled,
        );

    test('is silent when every requested page was parsed', () {
      expect(paged(fetched: 3, requested: 3).note, isNull);
      expect(paged(fetched: 1, requested: 1).note, isNull);
    });

    test('explains a missing next selector', () {
      expect(paged(fetched: 1, requested: 3, next: '').note, contains('下一页'));
    });

    test('explains an early stop', () {
      // First page only ⇒ the next-link was never usable.
      expect(paged(fetched: 1, requested: 3).note, contains('实际解析 1 页'));
      // Some pages parsed, then paging stopped ⇒ report the shortfall.
      final note = paged(fetched: 2, requested: 3).note!;
      expect(note, contains('实际解析 2 页'));
      expect(note, contains('请求 3 页'));
    });

    test('carries the paging-run reason (why the engine refused to page)', () {
      final note = paged(
        fetched: 2,
        requested: 3,
        stalled: '已导航到 https://cn.bing.com/search?first=11，但结果集与上一页相同',
      ).note!;
      expect(note, contains('实际解析 2 页'));
      expect(note, contains('结果集与上一页相同'));
    });
  });

  group('BuiltinTools.searchUrl', () {
    test('fills the {query} placeholder', () {
      final engine = SearchEngineConfig(
        id: 'w',
        name: 'W',
        urlTemplate: 'https://example.com/search?q={query}',
      );
      final uri = BuiltinTools.searchUrl(engine, 'a b');
      expect(uri.toString(), 'https://example.com/search?q=a+b');
    });

    test('returns null without a {query} placeholder', () {
      expect(BuiltinTools.searchUrl(SearchEngineConfig(id: 'x', name: 'X'), 'x'), isNull);
    });
  });
}
