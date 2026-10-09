import '../core/json_utils.dart';

/// A configurable web-search backend.
///
/// Every engine is searched the same way: its SERP URL is loaded in the hidden
/// WebView (a real browser context, so anti-bot walls see a browser) and parsed
/// by an extraction script — the engine's own `extractScript`, a matching
/// [ScriptRegistry] script (built-ins ship for baidu/bing/duckduckgo/google/
/// sogou), or a script generated from the CSS selectors below.
class SearchEngineConfig {
  SearchEngineConfig({
    required this.id,
    required this.name,
    this.enabled = true,
    this.urlTemplate = '',
    this.resultSelector = '',
    this.titleSelector = '',
    this.linkSelector = '',
    this.snippetSelector = '',
    this.readySelector = '',
    this.nextSelector = '',
    this.pages = 1,
    this.extractScript = '',
  });

  String id;
  String name;
  bool enabled;

  /// Search URL with a `{query}` placeholder — the only required field.
  String urlTemplate;

  /// CSS selectors used to build an extraction script when no script matches
  /// the SERP URL. Ignored when [extractScript] is set.
  String resultSelector;
  String titleSelector;
  String linkSelector;
  String snippetSelector;

  /// Wait for this CSS selector before parsing (optional).
  String readySelector;

  /// "Next page" CSS selector — its link is loaded to fetch the following SERP
  /// page (optional; without it only page 1 is read).
  String nextSelector;

  /// How many SERP pages to aggregate into one result list (1 = single page).
  /// Higher values trade seconds for more results.
  int pages;

  /// Inline extraction script (optional; takes precedence over the
  /// [ScriptRegistry] and the CSS selectors).
  String extractScript;

  /// SERP pages to aggregate, clamped (each extra page costs a navigation plus
  /// a render, so a handful is the practical ceiling).
  int get pageCount => pages.clamp(1, 10);

  /// Whether the engine has a browsable SERP to load.
  bool get isReady => urlTemplate.trim().contains('{query}');

  /// Short label for the engine list.
  String get label => '隐藏 WebView${pageCount > 1 ? ' · 聚合 $pageCount 页' : ''}';

  SearchEngineConfig copyWith({
    String? id,
    String? name,
    bool? enabled,
    String? nextSelector,
    int? pages,
  }) =>
      SearchEngineConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        urlTemplate: urlTemplate,
        resultSelector: resultSelector,
        titleSelector: titleSelector,
        linkSelector: linkSelector,
        snippetSelector: snippetSelector,
        readySelector: readySelector,
        nextSelector: nextSelector ?? this.nextSelector,
        pages: pages ?? this.pages,
        extractScript: extractScript,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'enabled': enabled,
        if (urlTemplate.isNotEmpty) 'url_template': urlTemplate,
        if (resultSelector.isNotEmpty) 'result_selector': resultSelector,
        if (titleSelector.isNotEmpty) 'title_selector': titleSelector,
        if (linkSelector.isNotEmpty) 'link_selector': linkSelector,
        if (snippetSelector.isNotEmpty) 'snippet_selector': snippetSelector,
        if (readySelector.isNotEmpty) 'ready_selector': readySelector,
        if (nextSelector.isNotEmpty) 'next_selector': nextSelector,
        if (pages > 1) 'pages': pages,
        if (extractScript.isNotEmpty) 'extract_script': extractScript,
      };

  factory SearchEngineConfig.fromJson(Object? value) {
    final json = asMap(value);
    final id = asString(json['id']) ?? 'engine';
    // Legacy configs described the engine with a `kind` and no URL template
    // (the removed "request the engine directly" mode). Map those kinds onto
    // their SERP so the engine keeps working through the WebView.
    final urlTemplate = (asString(json['url_template']) ?? '').trim();
    final kind = (asString(json['kind']) ?? '').trim();
    return SearchEngineConfig(
      id: id,
      name: asString(json['name']) ?? id,
      enabled: asBool(json['enabled'], fallback: true),
      urlTemplate: _withBingLocale(urlTemplate.isNotEmpty
          ? urlTemplate
          : _legacyTemplates[kind] ?? _legacyTemplates[id] ?? ''),
      resultSelector: asString(json['result_selector']) ?? '',
      titleSelector: asString(json['title_selector']) ?? '',
      linkSelector: asString(json['link_selector']) ?? '',
      snippetSelector: asString(json['snippet_selector']) ?? '',
      readySelector: asString(json['ready_selector']) ?? '',
      nextSelector: asString(json['next_selector']) ?? '',
      pages: (asInt(json['pages']) ?? 1).clamp(1, 10),
      extractScript: asString(json['extract_script']) ?? '',
    );
  }

  /// SERP templates for the engines of the removed direct-request mode; all of
  /// them have a built-in extraction script, so the URL alone is enough.
  static const _legacyTemplates = <String, String>{
    'bing': _bingTemplate,
    'duckduckgo': 'https://duckduckgo.com/?q={query}',
    'webview': 'https://www.google.com/search?q={query}&num=20',
  };

  /// Bing SERP pinned to the Chinese market: without `mkt/setlang/ensearch`
  /// the session may land on the international SERP, whose query
  /// understanding anchors on a leading number/date token
  /// (`11月-3月…` → `Windows 11`).
  static const _bingTemplate =
      'https://cn.bing.com/search?q={query}&mkt=zh-CN&setlang=zh-hans&ensearch=0';

  /// Upgrades a persisted bing template that predates the locale parameters.
  static String _withBingLocale(String template) {
    if (!template.contains('{query}') ||
        !template.contains('bing.com') ||
        template.contains('mkt=')) {
      return template;
    }
    final joiner = template.contains('?') ? '&' : '?';
    return '$template${joiner}mkt=zh-CN&setlang=zh-hans&ensearch=0';
  }

  /// The built-in engines offered by default, in fallback order.
  static List<SearchEngineConfig> defaults() => <SearchEngineConfig>[
        SearchEngineConfig(
          id: 'bing',
          name: 'Bing',
          urlTemplate: _bingTemplate,
          pages: 2,
        ),
        SearchEngineConfig(
          id: 'baidu',
          name: '百度',
          urlTemplate: 'https://www.baidu.com/s?wd={query}',
          pages: 2,
        ),
        SearchEngineConfig(
          id: 'sogou',
          name: '搜狗',
          urlTemplate: 'https://www.sogou.com/web?query={query}',
          pages: 2,
        ),
        SearchEngineConfig(
          id: 'google',
          name: 'Google',
          urlTemplate: 'https://www.google.com/search?q={query}&num=20',
          pages: 2,
        ),
        SearchEngineConfig(
          id: 'duckduckgo',
          name: 'DuckDuckGo',
          urlTemplate: 'https://duckduckgo.com/?q={query}',
          pages: 2,
        ),
      ];
}
