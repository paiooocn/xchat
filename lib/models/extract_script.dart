import 'dart:convert';

import '../core/json_utils.dart';

/// URL 匹配规则：`hosts` / `pathPrefix` / `urlPattern` 三者取并集。
///
/// 用于把一份解析脚本挂载到一组 URL 上——agent 分析过
/// `https://example.com/search?q=test` 后，同站点不同 query 的搜索页
/// 也能命中同一脚本（靠 host + 路径前缀），需要精确锁定时才用正则。
class UrlMatcher {
  UrlMatcher({
    List<String>? hosts,
    this.pathPrefix = '',
    this.urlPattern = '',
  }) : hosts = hosts ?? const <String>[];

  /// host 后缀匹配（`example.com` 命中 `www.example.com`）。
  final List<String> hosts;

  /// 路径前缀（如 `/search`）。
  final String pathPrefix;

  /// 完整 URL 正则，优先级最高，用于锁定精确 URL。
  final String urlPattern;

  bool get isEmpty =>
      hosts.isEmpty && pathPrefix.trim().isEmpty && urlPattern.trim().isEmpty;

  /// 匹配得分；`-1` 表示不匹配。得分越高越精确，用于多脚本竞争时择优。
  int score(Uri url) {
    final pattern = urlPattern.trim();
    if (pattern.isNotEmpty) {
      try {
        if (RegExp(pattern).hasMatch(url.toString())) return 3000;
      } catch (_) {
        // 非法正则：忽略该维度，继续按 host 判断。
      }
    }
    final host = url.host.toLowerCase();
    final prefix = pathPrefix.trim();
    var best = -1;
    for (final raw in hosts) {
      final h = raw.trim().toLowerCase();
      if (h.isEmpty) continue;
      final exact = host == h;
      if (!exact && !host.endsWith('.$h')) continue;
      if (prefix.isNotEmpty && !url.path.startsWith(prefix)) continue;
      final value = (exact ? 2000 : 1000) + (prefix.isNotEmpty ? 100 : 0);
      if (value > best) best = value;
    }
    return best;
  }

  bool matches(Uri url) => score(url) >= 0;

  Map<String, Object?> toJson() => <String, Object?>{
        if (hosts.isNotEmpty) 'hosts': hosts,
        if (pathPrefix.trim().isNotEmpty) 'path_prefix': pathPrefix.trim(),
        if (urlPattern.trim().isNotEmpty) 'url_pattern': urlPattern.trim(),
      };

  factory UrlMatcher.fromJson(Object? value) {
    final json = asMap(value);
    return UrlMatcher(
      hosts: asStringList(json['hosts']),
      pathPrefix: asString(json['path_prefix']) ?? '',
      urlPattern: asString(json['url_pattern']) ?? '',
    );
  }
}

/// 一份可挂载的页面解析脚本：把渲染后的页面转成
/// `[{title, url, snippet}]` 的 JSON 字符串。
///
/// 以 `<root>/scripts/<id>.json` 独立文件落盘，跨会话复用；启动时与内置
/// 脚本合并（同 id 时用户/agent 脚本覆盖内置）。
class ExtractScript {
  ExtractScript({
    required this.id,
    required this.name,
    required this.body,
    UrlMatcher? matcher,
    this.readySelector = '',
    this.nextSelector = '',
    this.priority = 0,
    this.enabled = true,
    this.createdBy = 'user',
    this.originUrl = '',
    this.createdAt,
    this.updatedAt,
  }) : matcher = matcher ?? UrlMatcher();

  /// 唯一标识（同时是文件名 `<id>.json`）。
  final String id;
  final String name;

  /// 脚本体：自执行函数，必须 `return JSON.stringify([...])`。
  final String body;

  final UrlMatcher matcher;

  /// 解析前等待该 CSS 选择器出现（可选，用于 JS 动态渲染的站点）。
  final String readySelector;

  /// 「下一页」按钮选择器（可选，点击它翻页抓取更多结果）。
  final String nextSelector;

  /// 匹配优先级（同分时比较，大者优先）。
  final int priority;

  final bool enabled;

  /// `builtin` | `user` | `agent`。
  final String createdBy;

  /// agent 分析来源 URL，便于追溯与精确复用。
  final String originUrl;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isValid => id.trim().isNotEmpty && body.trim().isNotEmpty;

  ExtractScript copyWith({
    String? name,
    String? body,
    UrlMatcher? matcher,
    String? readySelector,
    String? nextSelector,
    int? priority,
    bool? enabled,
    String? createdBy,
    String? originUrl,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      ExtractScript(
        id: id,
        name: name ?? this.name,
        body: body ?? this.body,
        matcher: matcher ?? this.matcher,
        readySelector: readySelector ?? this.readySelector,
        nextSelector: nextSelector ?? this.nextSelector,
        priority: priority ?? this.priority,
        enabled: enabled ?? this.enabled,
        createdBy: createdBy ?? this.createdBy,
        originUrl: originUrl ?? this.originUrl,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'created_by': createdBy,
        if (originUrl.isNotEmpty) 'origin_url': originUrl,
        'match': matcher.toJson(),
        if (readySelector.trim().isNotEmpty) 'ready_selector': readySelector.trim(),
        if (nextSelector.trim().isNotEmpty) 'next_selector': nextSelector.trim(),
        'priority': priority,
        'enabled': enabled,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
        if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
        'body': body,
      };

  factory ExtractScript.fromJson(Object? value) {
    final json = asMap(value);
    final id = (asString(json['id']) ?? '').trim();
    return ExtractScript(
      id: id,
      name: (asString(json['name']) ?? id).trim(),
      body: asString(json['body']) ?? '',
      matcher: UrlMatcher.fromJson(json['match']),
      readySelector: asString(json['ready_selector']) ?? '',
      nextSelector: asString(json['next_selector']) ?? '',
      priority: asInt(json['priority']) ?? 0,
      enabled: asBool(json['enabled'], fallback: true),
      createdBy: (asString(json['created_by']) ?? 'user').trim(),
      originUrl: asString(json['origin_url']) ?? '',
      createdAt: DateTime.tryParse(asString(json['created_at']) ?? ''),
      updatedAt: DateTime.tryParse(asString(json['updated_at']) ?? ''),
    );
  }

  /// 引擎只配了 CSS 选择器时，动态生成脚本。
  factory ExtractScript.fromSelectors({
    required String id,
    required String name,
    required String resultSelector,
    String titleSelector = '',
    String linkSelector = '',
    String snippetSelector = '',
    String readySelector = '',
    String nextSelector = '',
    UrlMatcher? matcher,
    String originUrl = '',
  }) =>
      ExtractScript(
        id: id,
        name: name,
        body: buildSelectorScript(
          resultSelector: resultSelector,
          titleSelector: titleSelector,
          linkSelector: linkSelector,
          snippetSelector: snippetSelector,
        ),
        matcher: matcher,
        readySelector: readySelector,
        nextSelector: nextSelector,
        createdBy: 'builtin',
        originUrl: originUrl,
      );

  /// 内联脚本（引擎自带 `extractScript`）。
  factory ExtractScript.inline({
    required String id,
    required String body,
    String readySelector = '',
    String nextSelector = '',
  }) =>
      ExtractScript(
        id: id,
        name: id,
        body: body,
        readySelector: readySelector,
        nextSelector: nextSelector,
        createdBy: 'builtin',
      );
}

/// 生成「按 CSS 选择器提取」的脚本，返回 JSON 字符串。
///
/// 空选择器退化为常用默认：链接取块内首个 `<a>`，标题取该链接，
/// 摘要留空。
String buildSelectorScript({
  required String resultSelector,
  String titleSelector = '',
  String linkSelector = '',
  String snippetSelector = '',
}) {
  String q(String selector, String fallback) =>
      selector.trim().isEmpty ? fallback : 'node.querySelector(${jsonEncode(selector.trim())})';
  final link = q(linkSelector, 'node.querySelector("a")');
  final title = q(titleSelector, 'a');
  final snippet = q(snippetSelector, 'null');
  return '''
(function () {
  var out = [];
  var nodes = document.querySelectorAll(${jsonEncode(resultSelector.trim())});
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i];
    var a = $link;
    if (!a && node.tagName === "A") a = node;
    var t = $title || a;
    var s = $snippet;
    if (!a || !a.href) continue;
    out.push({
      title: ((t && (t.innerText || t.textContent)) || "").trim(),
      url: a.href,
      snippet: ((s && (s.innerText || s.textContent)) || "").trim()
    });
  }
  return JSON.stringify(out);
})()''';
}
