import 'dart:convert';

import 'browser_session.dart';

/// Billing-cycle quota from `GET https://api.tavily.com/usage`.
class TavilyUsage {
  TavilyUsage({
    required this.plan,
    required this.used,
    required this.limit,
    required this.searchUsed,
  });

  /// Subscription plan name, e.g. `Free` / `Bootstrap`.
  final String plan;

  /// Credits used for this API key in the current billing cycle.
  final int used;

  /// Cycle limit for this key; `null` = unlimited.
  final int? limit;

  /// Search-endpoint credits used in the current cycle.
  final int searchUsed;

  /// Remaining credits this month (`null` when unlimited).
  int? get remaining => limit == null ? null : limit! - used;

  String describe() {
    final cap = limit == null ? '不限' : '$limit';
    final left = remaining == null ? '不限' : '$remaining';
    return '套餐：$plan\n'
        '本月已用：$used / $cap 次（其中搜索 $searchUsed）\n'
        '本月剩余：$left 次';
  }
}

/// Thin REST client for the Tavily API (search + usage).
class TavilyApi {
  static final Uri _searchUri = Uri.parse('https://api.tavily.com/search');
  static final Uri _usageUri = Uri.parse('https://api.tavily.com/usage');

  /// `POST /search` — returns `title/url/snippet` maps (1 credit per call).
  static Future<List<Map<String, Object?>>> search(
    BrowserSession session,
    String apiKey,
    String query,
    int max,
  ) async {
    final page = await session.postJson(
      _searchUri,
      <String, Object?>{
        'api_key': apiKey, // legacy auth; the Bearer header covers the current one
        'query': query,
        'search_depth': 'basic',
        'max_results': max.clamp(1, 20).toInt(),
      },
      bearer: apiKey,
    );
    final json = _asJson(page, 'Tavily');
    final results = <Map<String, Object?>>[];
    for (final item in (json['results'] as List?) ?? const []) {
      if (item is! Map) continue;
      results.add({
        'title': '${item['title'] ?? ''}',
        'url': '${item['url'] ?? ''}',
        'snippet': '${item['content'] ?? ''}',
      });
    }
    return results;
  }

  /// `GET /usage` — key/account quota for the current billing cycle.
  static Future<TavilyUsage> usage(BrowserSession session, String apiKey) async {
    final page = await session.get(_usageUri, bearer: apiKey);
    final json = _asJson(page, 'Tavily usage');
    final key = (json['key'] as Map?) ?? const {};
    final account = (json['account'] as Map?) ?? const {};
    return TavilyUsage(
      plan: '${account['current_plan'] ?? '未知'}',
      used: (key['usage'] as num?)?.toInt() ?? 0,
      limit: (key['limit'] as num?)?.toInt(),
      searchUsed: (key['search_usage'] as num?)?.toInt() ?? 0,
    );
  }

  static Map<String, Object?> _asJson(BrowserPage page, String what) {
    if (page.statusCode == 401 || page.statusCode == 403) {
      throw StateError('$what: API key 无效或无权限 (${page.statusCode})');
    }
    if (page.statusCode >= 400) {
      throw StateError('$what: HTTP ${page.statusCode} ${_short(page.body)}');
    }
    final decoded = jsonDecode(page.body);
    return decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{};
  }

  static String _short(String text) => text.length > 200 ? '${text.substring(0, 200)}…' : text;
}
