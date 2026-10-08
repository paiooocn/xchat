import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import '../../core/app_paths.dart';
import '../../models/extract_script.dart';

/// Merges page-extraction scripts from three sources and resolves the best one
/// for a given URL.
///
/// Sources, in load order (later overrides earlier for the same `id`):
/// 1. bundled `assets/scripts/*.json` — read-only built-ins;
/// 2. `<root>/scripts/*.json` — agent/user scripts, persisted across sessions.
///
/// A script mounted by the agent is written to (2), so it survives restarts and
/// is picked up by both `web_search`'s webview engine and `webview_extract`.
class ScriptRegistry {
  ScriptRegistry._();

  static const _builtinPrefix = 'assets/scripts/';

  /// Ids must be filename-safe: they become `<id>.json` on disk.
  static final _idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  static ScriptRegistry? _instance;

  /// Process-wide singleton; loads built-ins + user scripts on first use.
  static Future<ScriptRegistry> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final registry = ScriptRegistry._();
    await registry.reload();
    _instance = registry;
    return registry;
  }

  /// Drops the cache so the next [instance] reloads (tests / manual refresh).
  static void reset() => _instance = null;

  /// Whether [id] is safe to use as a filename.
  static bool isValidId(String id) => _idPattern.hasMatch(id.trim());

  final Map<String, ExtractScript> _scripts = <String, ExtractScript>{};

  List<ExtractScript> get all => _scripts.values.toList(growable: false);

  ExtractScript? byId(String id) => _scripts[id.trim()];

  /// Reloads built-ins then user scripts (user/agent wins on id conflicts).
  Future<void> reload() async {
    _scripts.clear();
    await _loadBuiltins();
    await _loadUserScripts();
  }

  /// Picks the best enabled script for [url]: highest match score wins, ties
  /// broken by [ExtractScript.priority].
  ExtractScript? resolve(Uri url) {
    ExtractScript? best;
    var bestScore = -1;
    for (final script in _scripts.values) {
      if (!script.enabled) continue;
      final score = script.matcher.score(url);
      if (score < 0) continue;
      if (score > bestScore ||
          (score == bestScore && script.priority > (best?.priority ?? -1))) {
        best = script;
        bestScore = score;
      }
    }
    return best;
  }

  /// Mounts (or replaces) [script] and persists it to disk.
  Future<void> mount(ExtractScript script) async {
    _scripts[script.id] = script;
    await _persist(script);
  }

  /// Unmounts a script. Built-ins are only disabled (they cannot be deleted);
  /// user/agent scripts are removed from disk.
  Future<void> unmount(String id) async {
    final script = _scripts[id.trim()];
    if (script == null) return;
    if (script.createdBy == 'builtin') {
      _scripts[script.id] = script.copyWith(enabled: false);
      return;
    }
    _scripts.remove(script.id);
    final file = _scriptFile(script.id);
    if (file != null) {
      final f = File(file);
      if (await f.exists()) await f.delete();
    }
  }

  Future<void> _loadBuiltins() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final key in manifest.listAssets()) {
        if (!key.startsWith(_builtinPrefix) || !key.endsWith('.json')) continue;
        try {
          _put(ExtractScript.fromJson(jsonDecode(await rootBundle.loadString(key))));
        } catch (_) {
          // One malformed built-in must not abort the rest.
        }
      }
    } catch (_) {
      // No asset bundle (unit tests) — built-ins are simply unavailable.
    }
  }

  Future<void> _loadUserScripts() async {
    if (!AppPaths.isReady) return;
    final dir = Directory(AppPaths.instance.scriptsDir);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        _put(ExtractScript.fromJson(jsonDecode(await entity.readAsString())));
      } catch (_) {
        // Skip unreadable/invalid files.
      }
    }
  }

  void _put(ExtractScript script) {
    if (!script.isValid || !isValidId(script.id)) return;
    _scripts[script.id] = script;
  }

  String? _scriptFile(String id) =>
      AppPaths.isReady ? AppPaths.instance.scriptFile(id) : null;

  Future<void> _persist(ExtractScript script) async {
    final path = _scriptFile(script.id);
    if (path == null) return;
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(script.toJson()),
      flush: true,
    );
  }
}
