import '../core/json_utils.dart';

/// A configurable web-search backend.
///
/// * `ddgs` aggregates many scraped engines via `package:ddgs` (no API key);
/// * `tavily` calls the Tavily Search API ([apiKey] required);
/// * built-ins (`kind` = `bing` / `duckduckgo`) use a fixed HTML parser;
/// * custom engines are described by a URL template plus CSS selectors.
class SearchEngineConfig {
  SearchEngineConfig({
    required this.id,
    required this.name,
    this.enabled = true,
    this.useProxy = true,
    this.kind = 'custom',
    this.apiKey = '',
    this.backend = defaultBackend,
    this.urlTemplate = '',
    this.resultSelector = '',
    this.titleSelector = '',
    this.linkSelector = '',
    this.snippetSelector = '',
  });

  static const defaultBackend = 'duckduckgo,brave,ecosia';

  String id;
  String name;
  bool enabled;

  /// Whether the configured proxy is applied to this engine.
  bool useProxy;

  /// `ddgs` | `tavily` | `bing` | `duckduckgo` | `custom`.
  String kind;

  /// API key for `tavily` engines.
  String apiKey;

  /// Comma separated `ddgs` backends, tried in order and merged.
  String backend;

  /// Custom engine: search URL with `{query}` placeholder.
  String urlTemplate;
  String resultSelector;
  String titleSelector;
  String linkSelector;
  String snippetSelector;

  bool get isBuiltin => kind == 'bing' || kind == 'duckduckgo';

  /// Whether the engine has everything it needs to serve searches.
  bool get isReady => kind != 'tavily' || apiKey.trim().isNotEmpty;

  /// Short label for the settings list.
  String get kindLabel {
    switch (kind) {
      case 'ddgs':
        return 'DDGS 多引擎';
      case 'tavily':
        return 'Tavily API';
      case 'bing':
        return '内置 · Bing HTML';
      case 'duckduckgo':
        return '内置 · DuckDuckGo HTML';
      default:
        return '自定义';
    }
  }

  SearchEngineConfig copyWith({String? id, String? name, bool? enabled, bool? useProxy}) =>
      SearchEngineConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        useProxy: useProxy ?? this.useProxy,
        kind: kind,
        apiKey: apiKey,
        backend: backend,
        urlTemplate: urlTemplate,
        resultSelector: resultSelector,
        titleSelector: titleSelector,
        linkSelector: linkSelector,
        snippetSelector: snippetSelector,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'enabled': enabled,
        'use_proxy': useProxy,
        'kind': kind,
        if (apiKey.isNotEmpty) 'api_key': apiKey,
        if (backend.isNotEmpty) 'backend': backend,
        if (urlTemplate.isNotEmpty) 'url_template': urlTemplate,
        if (resultSelector.isNotEmpty) 'result_selector': resultSelector,
        if (titleSelector.isNotEmpty) 'title_selector': titleSelector,
        if (linkSelector.isNotEmpty) 'link_selector': linkSelector,
        if (snippetSelector.isNotEmpty) 'snippet_selector': snippetSelector,
      };

  factory SearchEngineConfig.fromJson(Object? value) {
    final json = asMap(value);
    final id = asString(json['id']) ?? 'engine';
    return SearchEngineConfig(
      id: id,
      name: asString(json['name']) ?? id,
      enabled: asBool(json['enabled'], fallback: true),
      useProxy: asBool(json['use_proxy'], fallback: true),
      kind: (asString(json['kind']) ?? 'custom').trim().isEmpty
          ? 'custom'
          : asString(json['kind'])!.trim(),
      apiKey: asString(json['api_key']) ?? '',
      backend: (asString(json['backend']) ?? '').trim().isEmpty
          ? defaultBackend
          : asString(json['backend'])!.trim(),
      urlTemplate: asString(json['url_template']) ?? '',
      resultSelector: asString(json['result_selector']) ?? '',
      titleSelector: asString(json['title_selector']) ?? '',
      linkSelector: asString(json['link_selector']) ?? '',
      snippetSelector: asString(json['snippet_selector']) ?? '',
    );
  }

  /// The built-in engines offered by default, in fallback order.
  static List<SearchEngineConfig> defaults() => <SearchEngineConfig>[
        SearchEngineConfig(id: 'ddgs', name: 'DDGS 多引擎', kind: 'ddgs'),
        SearchEngineConfig(id: 'tavily', name: 'Tavily', kind: 'tavily'),
        SearchEngineConfig(id: 'bing', name: 'Bing', kind: 'bing'),
        SearchEngineConfig(id: 'duckduckgo', name: 'DuckDuckGo', kind: 'duckduckgo'),
      ];
}
