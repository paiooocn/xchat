/// Result filtering shared by the web-search engines.
///
/// Standalone and dependency-free so it can be unit-tested without a Flutter
/// binding or network access. The relevance gate is the part most likely to
/// silently drop good results, so it is covered by direct tests.
library;

class SearchFilter {
  const SearchFilter._();

  /// Latin words, digit runs and CJK bigrams — a language-agnostic relevance
  /// vocabulary.
  ///
  /// Digits are included on purpose: a query like `2026昆明商业论坛` must keep
  /// `2026` as a term, otherwise a numeric-only part of the query can never
  /// contribute to (or be required by) the relevance check.
  static Set<String> terms(String text) {
    final out = <String>{};
    for (final m in RegExp(r'[a-zA-Z]{2,}').allMatches(text)) {
      out.add(m.group(0)!.toLowerCase());
    }
    for (final m in RegExp(r'\d{2,}').allMatches(text)) {
      out.add(m.group(0)!);
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

  /// Whether [term] carries meaning on its own: a Latin word or a CJK bigram.
  ///
  /// Pure digit runs (`11`, `2025`) and single CJK characters (`月`, `年`) are
  /// weak: they appear in every date stamp, so a "Windows 11" page matches a
  /// `11月…` query on them alone.
  static bool _isStrong(String term) =>
      term.length >= 2 && !RegExp(r'^\d+$').hasMatch(term);

  /// Cheap relevance gate: a usable result must share some vocabulary with the
  /// query — cloaked SEO-spam (e.g. 磨粉机站群) shares none of it.
  ///
  /// At least one *strong* term must hit when the query has any, so a result
  /// that only echoes numbers/units (the number-pivot SERP Bing returns for
  /// date-leading queries) is rejected and the caller can fall through to the
  /// next engine or a rewritten query.
  ///
  /// Short queries (≤3 terms) accept a single hit; longer ones need two, so a
  /// single coincidental bigram does not admit an off-topic page.
  static bool isRelevant(String query, String title, String snippet) {
    final wanted = terms(query);
    if (wanted.isEmpty) return true;
    final got = terms('$title $snippet');
    if (got.isEmpty) return false;
    var hits = 0;
    var strong = 0;
    final needsStrong = wanted.any(_isStrong);
    for (final term in wanted) {
      if (!got.contains(term)) continue;
      hits++;
      if (_isStrong(term)) strong++;
    }
    if (needsStrong && strong == 0) return false;
    return hits >= 2 || (wanted.length <= 3 && hits >= 1);
  }

  /// Drops unusable entries: empty, in-page anchors, engine-internal links.
  static bool isJunk(String title, String url) {
    if (title.isEmpty || url.isEmpty) return true;
    if (url.startsWith('javascript:') || url.startsWith('#')) return true;
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host.endsWith('bing.com') || host.endsWith('duckduckgo.com');
  }

  /// Junk / duplicate / irrelevant filter + snippet capping. [seen] may span
  /// engines for cross-engine de-duplication.
  ///
  /// Does **not** truncate to a count — the caller applies the result limit, so
  /// "dropped" can mean "rejected by the filter" rather than "cut off by max".
  static List<Map<String, Object?>> usable(
    String query,
    List<Map<String, Object?>> raw, {
    Set<String>? seen,
  }) {
    final urls = seen ?? <String>{};
    final kept = <Map<String, Object?>>[];
    for (final item in raw) {
      final title = '${item['title'] ?? ''}'.trim();
      final url = '${item['url'] ?? ''}'.trim();
      final snippet = '${item['snippet'] ?? ''}'.trim();
      if (isJunk(title, url) || !urls.add(url) || !isRelevant(query, title, snippet)) continue;
      kept.add({
        'title': title,
        'url': url,
        'snippet': snippet.length > 300 ? '${snippet.substring(0, 300)}…' : snippet,
      });
    }
    return kept;
  }

  /// Minimal cleanup for `filter: false`: drops empty entries and duplicates,
  /// but keeps every result the engine actually returned (no truncation).
  static List<Map<String, Object?>> dedupe(
    List<Map<String, Object?>> raw, {
    Set<String>? seen,
  }) {
    final urls = seen ?? <String>{};
    final kept = <Map<String, Object?>>[];
    for (final item in raw) {
      final title = '${item['title'] ?? ''}'.trim();
      final url = '${item['url'] ?? ''}'.trim();
      if (title.isEmpty || url.isEmpty || !urls.add(url)) continue;
      kept.add({
        'title': title,
        'url': url,
        'snippet': '${item['snippet'] ?? ''}'.trim(),
      });
    }
    return kept;
  }

  /// Keyword-only fallback query: drops punctuation and bare digit runs, but
  /// keeps date units (`11月`, `2025年`) and ranges (`11月至3月`) intact —
  /// stripping their digits turned `11月-3月…` into the nonsense `月至 月…`.
  static String compactQuery(String query) {
    final buffer = StringBuffer();
    final token = RegExp(
        r'\d+(?:月|年|日|天|号|岁|季度|周)(?:\s*[至到]\s*\d+(?:月|年|日|天|号|岁|季度|周))?'
        r'|[a-zA-Z\u4e00-\u9fff]+');
    for (final m in token.allMatches(query)) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(m.group(0));
    }
    final compact = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return compact.length > 40 ? compact.substring(0, 40).trim() : compact;
  }

  /// Normalizes numeric ranges to `至`: `11月-3月` → `11月至3月`.
  ///
  /// A bare `-` is Bing's NOT operator and also splits the token, both of which
  /// derail a date-range query.
  static String normalizeRanges(String query) => query.replaceAllMapped(
      RegExp(r'(\d+\s*(?:月|年|日))\s*[-–—~～]\s*(\d+\s*(?:月|年|日))'),
      (m) =>
          '${m[1]!.replaceAll(RegExp(r'\s+'), '')}至${m[2]!.replaceAll(RegExp(r'\s+'), '')}');

  /// Leading date/scope qualifiers a query may open with, e.g. `11月至3月`,
  /// `2025年`, `十一月`, `冬季`, `国内`.
  static final RegExp _leadingTime = RegExp(
      r'^(?:\d{4}\s*年(?:\s*\d{1,2}\s*月)?'
      r'|\d{1,2}\s*月\s*(?:[至到\-–—~～]\s*\d{1,2}\s*月)?'
      r'|(?:[一二三四五六七八九十冬腊]{1,3}|[0-9]{1,2})\s*月'
      r'|[春夏秋冬]季|今[春夏秋冬])');
  static final RegExp _leadingScope = RegExp(
      r'^(?:国内|国外|中国|全国|海外|本地|境内|境外)\s*');

  /// Moves the leading time/scope qualifiers behind the intent words:
  /// `11月-3月国内海边旅游推荐目的地` → `海边旅游推荐目的地 11月至3月 国内`.
  ///
  /// SERPs anchor on the *first* segment of a query (a leading `11月`/`国内`
  /// attracts `Windows 11`/`人民网` regardless of the rest), so the intent
  /// words must come first; the qualifiers still constrain results from the
  /// tail.
  static String moveQualifiersBack(String query) {
    var rest = query.trim();
    final quals = <String>[];
    final time = _leadingTime.firstMatch(rest);
    if (time != null) {
      quals.add(time.group(0)!.replaceAll(RegExp(r'\s+'), ''));
      rest = rest.substring(time.end);
    }
    final scope = _leadingScope.firstMatch(rest);
    if (scope != null) {
      quals.add(scope.group(0)!.trim());
      rest = rest.substring(scope.end);
    }
    if (quals.isEmpty || rest.trim().isEmpty) return query;
    return '${rest.trim()} ${quals.join(' ')}';
  }

  /// Rewritten queries to try when the original yields nothing usable, best
  /// first: qualifiers moved behind the intent words, then the keyword-only
  /// compact form.
  static List<String> retryQueries(String query) {
    final variants = <String>[];
    void add(String candidate) {
      if (candidate.isNotEmpty && candidate != query && !variants.contains(candidate)) {
        variants.add(candidate);
      }
    }

    add(moveQualifiersBack(normalizeRanges(query)));
    add(compactQuery(query));
    return variants;
  }
}
