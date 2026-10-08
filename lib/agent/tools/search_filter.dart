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

  /// Cheap relevance gate: a usable result must share some vocabulary with the
  /// query — cloaked SEO-spam (e.g. 磨粉机站群) shares none of it.
  ///
  /// Short queries (≤3 terms) accept a single hit; longer ones need two, so a
  /// single coincidental bigram does not admit an off-topic page.
  static bool isRelevant(String query, String title, String snippet) {
    final wanted = terms(query);
    if (wanted.isEmpty) return true;
    final got = terms('$title $snippet');
    if (got.isEmpty) return false;
    var hits = 0;
    for (final term in wanted) {
      if (got.contains(term)) hits++;
    }
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

  /// Strips digits/punctuation → keyword-only fallback query.
  static String compactQuery(String query) {
    final compact = query
        .replaceAll(RegExp(r'[^a-zA-Z\u4e00-\u9fff]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return compact.length > 40 ? compact.substring(0, 40).trim() : compact;
  }
}
