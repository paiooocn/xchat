import '../core/json_utils.dart';

/// A configurable web-search backend.
///
/// * built-ins (`kind` = `bing` / `duckduckgo`) use a fixed HTML parser;
/// * custom engines are described by a URL template plus CSS selectors.
class SearchEngineConfig {
  SearchEngineConfig({
    required this.id,
    required this.name,
    this.enabled = true,
    this.useProxy = true,
    this.kind = 'custom',
    this.urlTemplate = '',
    this.resultSelector = '',
    this.titleSelector = '',
    this.linkSelector = '',
    this.snippetSelector = '',
  });

  String id;
  String name;
  bool enabled;

  /// Whether the configured proxy is applied to this engine.
  bool useProxy;

  /// `bing` | `duckduckgo` | `custom`.
  String kind;

  /// Custom engine: search URL with `{query}` placeholder.
  String urlTemplate;
  String resultSelector;
  String titleSelector;
  String linkSelector;
  String snippetSelector;

  bool get isBuiltin => kind == 'bing' || kind == 'duckduckgo';

  SearchEngineConfig copyWith({String? id, String? name, bool? enabled, bool? useProxy}) =>
      SearchEngineConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        useProxy: useProxy ?? this.useProxy,
        kind: kind,
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
      urlTemplate: asString(json['url_template']) ?? '',
      resultSelector: asString(json['result_selector']) ?? '',
      titleSelector: asString(json['title_selector']) ?? '',
      linkSelector: asString(json['link_selector']) ?? '',
      snippetSelector: asString(json['snippet_selector']) ?? '',
    );
  }

  /// The built-in engines offered by default, in fallback order.
  static List<SearchEngineConfig> defaults() => <SearchEngineConfig>[
        SearchEngineConfig(id: 'bing', name: 'Bing', kind: 'bing'),
        SearchEngineConfig(id: 'duckduckgo', name: 'DuckDuckGo', kind: 'duckduckgo'),
      ];
}
