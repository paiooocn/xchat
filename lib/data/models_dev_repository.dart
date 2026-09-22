import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../core/app_paths.dart';
import '../core/json_utils.dart';
import '../models/models_dev.dart';

/// Bundled fallback snapshot shipped with the app (trimmed models.dev data,
/// see DESIGN.md §17) — used when the network *and* the on-disk cache fail.
const String kModelsDevBundledAsset = 'assets/models_dev/models_dev.json';

/// Parses the bundled snapshot; `null` when it is missing/unreadable.
Future<ModelsDevCatalog?> loadBundledModelsDev() async {
  try {
    final raw = await rootBundle.loadString(kModelsDevBundledAsset);
    if (raw.trim().isEmpty) return null;
    final json = asMap(jsonDecode(raw));
    // Both the cache-file wrapper (`fetched_at` + `providers`) and a bare
    // `api.json` payload are accepted.
    final providers = json.containsKey('providers') ? json['providers'] : json;
    final catalog = ModelsDevCatalog.fromJson(providers);
    return catalog.providers.isEmpty ? null : catalog;
  } catch (_) {
    return null;
  }
}

/// Loads/saves the models.dev catalog snapshot (`XChat/models_dev.json`).
///
/// `refresh()` pulls `https://models.dev/api.json?type=all` and caches the raw
/// payload; `loadOrRefresh()` falls back to that cache when the network is
/// unavailable, so previously synced data stays usable offline.
class ModelsDevRepository {
  ModelsDevRepository(this.paths);

  final AppPaths paths;

  static const String sourceUrl = 'https://models.dev/api.json?type=all';

  /// When the current snapshot was fetched from models.dev.
  DateTime? lastFetched;

  Future<ModelsDevCatalog?> loadCached() async {
    final file = File(paths.modelsDevFile);
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final json = asMap(jsonDecode(raw));
      lastFetched = DateTime.tryParse(asString(json['fetched_at']) ?? '');
      return ModelsDevCatalog.fromJson(json['providers']);
    } catch (_) {
      return null;
    }
  }

  /// Fetches a fresh snapshot and persists it. Throws on network/HTTP errors.
  Future<ModelsDevCatalog> refresh() async {
    final response = await http
        .get(Uri.parse(sourceUrl))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('models.dev HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    final catalog = ModelsDevCatalog.fromJson(body);
    lastFetched = DateTime.now();
    final tmp = File('${paths.modelsDevFile}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'fetched_at': lastFetched!.toUtc().toIso8601String(),
        'providers': body,
      }),
      flush: true,
    );
    await tmp.rename(paths.modelsDevFile);
    return catalog;
  }

  /// Fresh snapshot, cached one, or the bundled fallback — the flag tells which
  /// source was used. Only when all three fail is the network error rethrown.
  Future<(ModelsDevCatalog, ModelsDevSource)> loadOrRefresh() async {
    try {
      return (await refresh(), ModelsDevSource.network);
    } catch (_) {
      final cached = await loadCached();
      if (cached != null) return (cached, ModelsDevSource.cache);
      final bundled = await loadBundledModelsDev();
      if (bundled != null) return (bundled, ModelsDevSource.bundled);
      rethrow;
    }
  }
}
