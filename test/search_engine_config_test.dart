import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/models/app_config.dart';
import 'package:xchat/models/search_engine_config.dart';

/// Regression tests for search-engine config migration: the settings page must
/// keep offering the built-in Chinese engines (百度/搜狗), and persisted bing
/// templates must be pinned to the Chinese market.
void main() {
  group('AppConfig engine migration', () {
    test('missing built-in chinese engines are appended', () {
      final config = AppConfig.fromJson(<String, Object?>{
        'search_engines': <Object?>[
          <String, Object?>{
            'id': 'bing',
            'name': 'Bing',
            'url_template': 'https://cn.bing.com/search?q={query}',
          },
        ],
      });
      final ids = config.searchEngines.map((e) => e.id).toList();
      expect(ids, <String>['bing', 'baidu', 'sogou']);
    });

    test('existing engines keep their order and are not duplicated', () {
      final config = AppConfig.fromJson(<String, Object?>{
        'search_engines': <Object?>[
          <String, Object?>{
            'id': 'sogou',
            'name': '搜狗',
            'url_template': 'https://www.sogou.com/web?query={query}',
          },
          <String, Object?>{
            'id': 'baidu',
            'name': '百度',
            'url_template': 'https://www.baidu.com/s?wd={query}',
          },
        ],
      });
      expect(config.searchEngines.map((e) => e.id).toList(),
          <String>['sogou', 'baidu']);
    });

    test('empty config falls back to all built-in engines', () {
      final config = AppConfig.fromJson(<String, Object?>{});
      expect(
        config.searchEngines.map((e) => e.id),
        containsAll(<String>['bing', 'baidu', 'sogou']),
      );
    });
  });

  group('SearchEngineConfig bing locale', () {
    test('defaults pin bing to the chinese market', () {
      final bing = SearchEngineConfig.defaults().firstWhere((e) => e.id == 'bing');
      expect(bing.urlTemplate, contains('mkt=zh-CN'));
      expect(bing.urlTemplate, contains('setlang=zh-hans'));
      expect(bing.urlTemplate, contains('ensearch=0'));
    });

    test('persisted legacy bing template gains the locale parameters', () {
      final engine = SearchEngineConfig.fromJson(<String, Object?>{
        'id': 'bing',
        'name': 'Bing',
        'url_template': 'https://cn.bing.com/search?q={query}',
      });
      expect(engine.urlTemplate,
          'https://cn.bing.com/search?q={query}&mkt=zh-CN&setlang=zh-hans&ensearch=0');
    });

    test('non-bing templates are left untouched', () {
      const template = 'https://www.sogou.com/web?query={query}';
      final engine = SearchEngineConfig.fromJson(<String, Object?>{
        'id': 'sogou',
        'name': '搜狗',
        'url_template': template,
      });
      expect(engine.urlTemplate, template);
    });
  });
}
