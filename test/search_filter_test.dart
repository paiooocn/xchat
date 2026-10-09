import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/agent/tools/search_filter.dart';

/// Regression tests for the web-search relevance filter.
///
/// The gate is the most likely reason a search "returns no results": it drops
/// anything whose title/snippet does not share enough vocabulary with the
/// query. These tests pin the behaviour for mixed numeric + CJK queries.
void main() {
  group('SearchFilter.terms', () {
    test('keeps digit runs as terms (numeric query parts must count)', () {
      final terms = SearchFilter.terms('2026昆明商业论坛');
      expect(terms, contains('2026'));
      expect(terms, contains('昆明'));
      expect(terms, contains('商业'));
      expect(terms, contains('论坛'));
    });

    test('splits latin words and digits', () {
      final terms = SearchFilter.terms('iPhone 15 Pro');
      expect(terms, containsAll(<String>['iphone', 'pro', '15']));
    });

    test('a single CJK character is its own term', () {
      expect(SearchFilter.terms('中'), contains('中'));
    });

    test('punctuation and single digits are ignored', () {
      final terms = SearchFilter.terms('a-b 5 !!');
      expect(terms, isNot(contains('a')));
      expect(terms, isNot(contains('5')));
    });
  });

  group('SearchFilter.isRelevant', () {
    test('empty query vocabulary passes everything', () {
      expect(SearchFilter.isRelevant('', 'anything', ''), isTrue);
    });

    test('query sharing the page vocabulary passes', () {
      expect(
        SearchFilter.isRelevant('2026昆明商业论坛', '2026昆明商业论坛盛大开幕', ''),
        isTrue,
      );
    });

    test('two shared bigrams pass even for a long query', () {
      // wanted = {2026, 昆明, 明商, 商业, 业论, 论坛}; "昆明…论坛" hits 2.
      expect(SearchFilter.isRelevant('2026昆明商业论坛', '昆明经济发展论坛', ''), isTrue);
    });

    test('a single shared bigram is rejected for a long query', () {
      expect(SearchFilter.isRelevant('2026昆明商业论坛', '云南商业峰会', ''), isFalse);
    });

    test('unrelated SEO-spam is rejected', () {
      expect(SearchFilter.isRelevant('flutter webview', '磨粉机厂家直销', ''), isFalse);
    });

    test('short query (<=3 terms) accepts a single hit', () {
      expect(SearchFilter.isRelevant('昆明论坛', '昆明生活', ''), isTrue);
    });
  });

  group('SearchFilter.isJunk', () {
    test('empty title or url is junk', () {
      expect(SearchFilter.isJunk('', 'https://a.com'), isTrue);
      expect(SearchFilter.isJunk('t', ''), isTrue);
    });

    test('in-page anchors and javascript urls are junk', () {
      expect(SearchFilter.isJunk('t', '#section'), isTrue);
      expect(SearchFilter.isJunk('t', 'javascript:void(0)'), isTrue);
    });

    test('engine-internal links are junk', () {
      expect(SearchFilter.isJunk('t', 'https://cn.bing.com/search?q=x'), isTrue);
      expect(SearchFilter.isJunk('t', 'https://duckduckgo.com/y.js'), isTrue);
    });

    test('an ordinary external link is not junk', () {
      expect(SearchFilter.isJunk('标题', 'https://example.com/a'), isFalse);
    });
  });

  group('SearchFilter.usable', () {
    test('drops junk/duplicate/irrelevant', () {
      final raw = <Map<String, Object?>>[
        {'title': '2026昆明商业论坛开幕', 'url': 'https://a.com/1', 'snippet': ''},
        {'title': '2026昆明商业论坛开幕', 'url': 'https://a.com/1', 'snippet': 'dup'},
        {'title': '磨粉机直销', 'url': 'https://spam.com', 'snippet': ''},
        {'title': '', 'url': 'https://empty.com', 'snippet': ''},
        {'title': '昆明商业论坛报名', 'url': 'https://b.com/2', 'snippet': '论坛信息'},
      ];
      final kept = SearchFilter.usable('2026昆明商业论坛', raw);
      expect(kept.map((e) => e['url']), <String>['https://a.com/1', 'https://b.com/2']);
    });

    test('does not truncate to a count (caller applies the limit)', () {
      final raw = <Map<String, Object?>>[
        for (var i = 0; i < 20; i++)
          {'title': '昆明论坛 $i', 'url': 'https://a.com/$i', 'snippet': ''},
      ];
      expect(SearchFilter.usable('昆明论坛', raw).length, 20);
    });

    test('caps snippet at 300 chars', () {
      final long = 'x' * 400;
      final kept = SearchFilter.usable(
        'q',
        <Map<String, Object?>>[
          {'title': 'q', 'url': 'https://a.com', 'snippet': long},
        ],
      );
      expect('${kept.first['snippet']}'.endsWith('…'), isTrue);
      expect('${kept.first['snippet']}'.length, lessThanOrEqualTo(301));
    });

    test('shares the seen set across calls for cross-engine de-dup', () {
      final seen = <String>{};
      SearchFilter.usable('q', <Map<String, Object?>>[
        {'title': 'q', 'url': 'https://a.com', 'snippet': ''},
      ], seen: seen);
      final second = SearchFilter.usable('q', <Map<String, Object?>>[
        {'title': 'q', 'url': 'https://a.com', 'snippet': ''},
      ], seen: seen);
      expect(second, isEmpty);
    });
  });

  group('SearchFilter.dedupe', () {
    test('keeps irrelevant results but drops duplicates/empties', () {
      final raw = <Map<String, Object?>>[
        {'title': '无关内容', 'url': 'https://a.com', 'snippet': ''},
        {'title': '无关内容', 'url': 'https://a.com', 'snippet': ''},
        {'title': '', 'url': 'https://b.com', 'snippet': ''},
      ];
      final kept = SearchFilter.dedupe(raw);
      expect(kept.length, 1);
      expect(kept.first['url'], 'https://a.com');
    });
  });

  group('SearchFilter.compactQuery', () {
    test('strips punctuation and collapses whitespace', () {
      expect(SearchFilter.compactQuery('昆明,商业论坛!'), '昆明 商业论坛');
    });

    test('caps length at 40 chars', () {
      final long = 'a' * 100;
      expect(SearchFilter.compactQuery(long).length, lessThanOrEqualTo(40));
    });

    test('keeps date units and ranges instead of stripping their digits', () {
      expect(SearchFilter.compactQuery('11月-3月国内海边旅游推荐目的地'),
          '11月 3月 国内海边旅游推荐目的地');
      expect(SearchFilter.compactQuery('11月到3月去海边'), '11月到3月 去海边');
      expect(SearchFilter.compactQuery('2025年旅行攻略合集'), '2025年 旅行攻略合集');
    });
  });

  group('SearchFilter query rewriting', () {
    test('normalizeRanges rewrites range hyphens to 至', () {
      expect(SearchFilter.normalizeRanges('11月-3月国内海边旅游推荐目的地'),
          '11月至3月国内海边旅游推荐目的地');
      expect(SearchFilter.normalizeRanges('2025年~2026年规划'), '2025年至2026年规划');
    });

    test('moveQualifiersBack puts intent words first', () {
      expect(SearchFilter.moveQualifiersBack('11月-3月国内海边旅游推荐目的地'),
          '海边旅游推荐目的地 11月-3月 国内');
      expect(SearchFilter.moveQualifiersBack('11月 海边旅游'), '海边旅游 11月');
      expect(SearchFilter.moveQualifiersBack('2025年 海边旅游推荐'), '海边旅游推荐 2025年');
      expect(SearchFilter.moveQualifiersBack('海边旅游'), '海边旅游');
    });

    test('retryQueries offers rewritten variants, best first', () {
      expect(SearchFilter.retryQueries('11月-3月国内海边旅游推荐目的地'),
          <String>[
            '海边旅游推荐目的地 11月至3月 国内',
            '11月 3月 国内海边旅游推荐目的地',
          ]);
      expect(SearchFilter.retryQueries('海边旅游'), isEmpty);
    });
  });

  group('SearchFilter regression: number-pivot SERPs', () {
    // Bing answers date-leading queries with pages about the *number*
    // ("Windows 11", "iPhone 12"): they echo `11`/`12` and a date-stamp `月`
    // but none of the query's intent words — they must not count as relevant.
    const windowsJunkTitle = '认识 Windows 11:功能、外观、优势及更多优秀功能 | Microsoft';
    const windowsJunkSnippet = '2025年3月27日 · 这是 Microsoft 发布的最新 Windows 版本。';

    test('rejects number-only matches (needs a strong term hit)', () {
      expect(
        SearchFilter.isRelevant(
            '11月-3月国内海边旅游推荐目的地', windowsJunkTitle, windowsJunkSnippet),
        isFalse,
      );
      expect(
        SearchFilter.isRelevant('12月 海边旅游推荐', 'iPhone 12 - 技术规格', '12 能被写成两个连续自然数相乘'),
        isFalse,
      );
    });

    test('still accepts results sharing the intent words', () {
      expect(
        SearchFilter.isRelevant('11月-3月国内海边旅游推荐目的地', '国内10大海边旅游景点',
            '海边旅游景点排行，适合 11月至3月 过冬'),
        isTrue,
      );
    });

    test('numeric-only queries keep the old behaviour', () {
      expect(SearchFilter.isRelevant('2026', '2026年新年', ''), isTrue);
    });
  });
}
