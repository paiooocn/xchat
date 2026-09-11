import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/config_manager.dart';

/// Provider 配置:实际存于 ~/.xchat/config.json 的 `providers` 数组。
/// 结构:
/// {
///   "id": "openai-main",
///   "type": "openai_compatible" | "anthropic",
///   "base_url": "https://api.openai.com/v1",
///   "api_key": "sk-...",
///   "models": [
///     {
///       "id": "gpt-4o",
///       "context": 128000,
///       "pricing": { "in": 2.5, "out": 10.0, "cache": 1.25 }   // USD / 1M tokens
///     }
///   ]
/// }
class ProviderSpec {
  final String id;
  String type;          // openai_compatible | anthropic
  String baseUrl;
  String apiKey;
  List<ModelSpec> models;
  ProviderSpec({
    required this.id,
    required this.type,
    required this.baseUrl,
    required this.apiKey,
    List<ModelSpec>? models,
  }) : models = models ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'base_url': baseUrl,
        'api_key': apiKey,
        'models': models.map((m) => m.toJson()).toList(),
      };
  static ProviderSpec fromJson(Map<String, dynamic> j) => ProviderSpec(
        id: (j['id'] ?? '') as String,
        type: (j['type'] ?? 'openai_compatible') as String,
        baseUrl: (j['base_url'] ?? '') as String,
        apiKey: (j['api_key'] ?? '') as String,
        models: ((j['models'] as List?) ?? [])
            .map((e) => ModelSpec.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

class ModelSpec {
  final String id;
  int context;              // 上下文窗口(tokens)
  Map<String, double> pricing; // in / out / cache,USD/1M
  // 可选请求参数(均为可空:null = 不传入该参数,沿用 ChatMeta 默认或 LLM 服务端默认)
  String? thinking;        // '' | enabled | disabled | adaptive  (openai 兼容: 映射为 reasoning_effort)
  String? reasoningEffort; // '' | max | xhigh | high | medium | low | minimal | none
  double? temperature;     // 0.0 ~ 2.0

  ModelSpec({
    required this.id,
    this.context = 0,
    Map<String, double>? pricing,
    this.thinking,
    this.reasoningEffort,
    this.temperature,
  }) : pricing = pricing ?? {'in': 0, 'out': 0, 'cache': 0};

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'context': context,
      'pricing': {
        'in': pricing['in'] ?? 0,
        'out': pricing['out'] ?? 0,
        'cache': pricing['cache'] ?? 0,
      },
    };
    if (thinking != null && thinking!.isNotEmpty) m['thinking'] = thinking;
    if (reasoningEffort != null && reasoningEffort!.isNotEmpty) m['reasoning_effort'] = reasoningEffort;
    if (temperature != null) m['temperature'] = temperature;
    return m;
  }
  static ModelSpec fromJson(Map<String, dynamic> j) {
    final p = (j['pricing'] as Map?) ?? {};
    return ModelSpec(
      id: (j['id'] ?? '') as String,
      context: (j['context'] as int?) ?? 0,
      pricing: {
        'in': ((p['in'] as num?) ?? 0).toDouble(),
        'out': ((p['out'] as num?) ?? 0).toDouble(),
        'cache': ((p['cache'] as num?) ?? 0).toDouble(),
      },
      thinking: (j['thinking'] as String?)?.trim(),
      reasoningEffort: (j['reasoning_effort'] as String?)?.trim(),
      temperature: (j['temperature'] as num?)?.toDouble(),
    );
  }
}

class ProviderRepo {
  static const _kKey = 'providers';

  static Future<List<ProviderSpec>> list() async {
    final data = ConfigManager.instance.data;
    final raw = (data[_kKey] as List?) ?? [];
    return raw
        .map((e) => ProviderSpec.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  static Future<ProviderSpec?> get(String id) async {
    final all = await list();
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 新增或更新。id 已存在则覆盖(整体替换 models)。
  static Future<ProviderSpec> upsert(ProviderSpec spec) async {
    final all = await list();
    final i = all.indexWhere((p) => p.id == spec.id);
    if (i >= 0) {
      all[i] = spec;
    } else {
      all.add(spec);
    }
    await ConfigManager.instance.patch({_kKey: all.map((x) => x.toJson()).toList()});
    return spec;
  }

  static Future<void> delete(String id) async {
    final all = await list();
    all.removeWhere((p) => p.id == id);
    await ConfigManager.instance.patch({_kKey: all.map((x) => x.toJson()).toList()});
  }

  /// 测试连接:发最小请求,带 8s 超时。
  /// openai_compatible → POST {base_url}/chat/completions (stream=false, max_tokens=1)
  /// anthropic          → POST {base_url}/v1/messages (max_tokens=1)
  static Future<Map<String, dynamic>> test(String id, {String? modelId}) async {
    final p = await get(id);
    if (p == null) return {'ok': false, 'error': 'provider not found'};
    final m = (modelId != null && modelId.isNotEmpty)
        ? p.models.firstWhere((x) => x.id == modelId, orElse: () => ModelSpec(id: modelId))
        : (p.models.isNotEmpty ? p.models.first : null);
    final start = DateTime.now();
    try {
      if (p.type == 'anthropic') {
        final req = http.Request('POST', Uri.parse('${p.baseUrl}/v1/messages'));
        req.headers['Content-Type'] = 'application/json';
        if (p.apiKey.isNotEmpty) req.headers['x-api-key'] = p.apiKey;
        req.headers['anthropic-version'] = '2023-06-01';
        req.body = jsonEncode({
          'model': m?.id ?? 'claude-3-haiku-20240307',
          'max_tokens': 1,
          'messages': [{'role': 'user', 'content': 'hi'}],
        });
        final resp = await req.send().timeout(const Duration(seconds: 8));
        await resp.stream.drain();
        final ms = DateTime.now().difference(start).inMilliseconds;
        if (resp.statusCode >= 200 && resp.statusCode < 400) {
          return {'ok': true, 'latency_ms': ms, 'status': resp.statusCode};
        }
        return {'ok': false, 'latency_ms': ms, 'status': resp.statusCode, 'error': 'http ${resp.statusCode}'};
      } else {
        // openai_compatible
        final req = http.Request('POST', Uri.parse('${p.baseUrl}/chat/completions'));
        req.headers['Content-Type'] = 'application/json';
        if (p.apiKey.isNotEmpty) req.headers['Authorization'] = 'Bearer ${p.apiKey}';
        req.body = jsonEncode({
          'model': m?.id ?? 'test',
          'messages': [{'role': 'user', 'content': 'hi'}],
          'max_tokens': 1,
          'stream': false,
        });
        final resp = await req.send().timeout(const Duration(seconds: 8));
        await resp.stream.drain();
        final ms = DateTime.now().difference(start).inMilliseconds;
        if (resp.statusCode >= 200 && resp.statusCode < 400) {
          return {'ok': true, 'latency_ms': ms, 'status': resp.statusCode};
        }
        return {'ok': false, 'latency_ms': ms, 'status': resp.statusCode, 'error': 'http ${resp.statusCode}'};
      }
    } catch (e) {
      final ms = DateTime.now().difference(start).inMilliseconds;
      return {'ok': false, 'latency_ms': ms, 'error': e.toString()};
    }
  }
}
