import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config_manager.dart';

/// 汇率管理：启动时拉取 exchangerate-api，失败用静态值
class FxRates {
  static const _endpoint = 'https://api.exchangerate-api.com/v4/latest/USD';
  static const _staleDays = 30;

  static Map<String, double> _rates = {
    'USD': 1.0,
    'CNY': 7.25,
    'EUR': 0.92,
    'JPY': 155.0,
  };
  static String? _fetchedAt;

  static Map<String, double> get rates => Map.unmodifiable(_rates);
  static String? get fetchedAt => _fetchedAt;
  static String get currency => (ConfigManager.instance.data['ui']?['currency']) ?? 'CNY';

  /// 启动时调用；失败不阻塞
  static Future<void> refresh({bool silent = false}) async {
    try {
      final resp = await http.get(Uri.parse(_endpoint)).timeout(
            const Duration(seconds: 5),
          );
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final raw = (j['rates'] as Map?) ?? {};
        for (final k in ['USD', 'CNY', 'EUR', 'JPY']) {
          final v = raw[k];
          if (v is num) _rates[k] = v.toDouble();
        }
        _fetchedAt = DateTime.now().toUtc().toIso8601String();
        await ConfigManager.instance.patch({
          'ui': {
            'fx_rates': _rates,
            'fx_fetched_at': _fetchedAt,
          }
        });
        return;
      }
    } catch (_) {
      // swallow
    }
    if (!silent) {
      // 即便失败也保留旧 fetchedAt；不抛
    }
  }

  static bool get isStale {
    final ts = _fetchedAt;
    if (ts == null) return true;
    try {
      final dt = DateTime.parse(ts);
      return DateTime.now().toUtc().difference(dt).inDays > _staleDays;
    } catch (_) {
      return true;
    }
  }

  static double convertUsd(double usd, {String? to}) {
    final code = to ?? currency;
    final rate = _rates[code] ?? 1.0;
    return usd * rate;
  }
}
