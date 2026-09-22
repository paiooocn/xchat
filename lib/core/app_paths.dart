import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Resolves and creates the on-disk layout under the data root.
///
/// Android target: the shared, externally readable
/// `{shared storage}/com.yimo.xchat/data`, e.g.
/// `/sdcard/com.yimo.xchat/data` (`/sdcard` ≡ `/storage/emulated/0`).
/// Writing there needs "all files access" (Android 11+) or legacy external
/// storage (Android 10); without it the app degrades to its private external
/// dir (`Android/data/<pkg>/app_flutter`, private on Android 11+).
/// Desktop: `~/Documents/XChat`.
///
/// ```
/// <root>/
///   config.json
///   sessions/                 default sandbox for session files (<uuid>.xml)
///   templates/                session templates
///   logs/
///   sandboxs/                 per-session working dirs
///   projects/                 project files + working dirs
/// ```
class AppPaths {
  AppPaths._(this._root);

  String _root;
  String get root => _root;

  static const _rootKey = 'xchat_root';
  static const _askedKey = 'xchat_storage_permission_asked';

  /// Package-qualified subdir under every shared base.
  static const _sharedSubdir = <String>['com.yimo.xchat', 'data'];

  /// Candidate bases of shared (externally readable) storage.
  /// `/storage/emulated/0` is the canonical path, `/sdcard` its well-known alias.
  static const _sharedBases = <String>['/storage/emulated/0', '/sdcard'];

  static AppPaths? _instance;

  static AppPaths get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('AppPaths.init() must be called before use');
    }
    return value;
  }

  static bool get isReady => _instance != null;

  /// Resolves the data root and creates its layout.
  ///
  /// Candidates are tried in order — explicit override, persisted root, shared
  /// default, private fallbacks — and the first one that can be created and
  /// written wins. This must never throw: a broken/unavailable root (missing
  /// dir, unmounted storage, missing permission, ...) has to degrade to a
  /// usable fallback instead of aborting `main()` before `runApp`, which would
  /// leave the app permanently unstartable as long as the bad root is stored.
  static Future<AppPaths> init({String? overrideRoot}) async {
    final prefs = await SharedPreferences.getInstance();
    final override = overrideRoot?.trim();
    final stored = prefs.getString(_rootKey)?.trim();
    final hasStored = stored != null && stored.isNotEmpty;

    AppPaths? paths = await _firstUsable(<String>[
      if (override != null && override.isNotEmpty) p.normalize(override),
      if (stored != null && stored.isNotEmpty) p.normalize(stored),
    ]);
    paths ??= await _defaultPaths();
    _instance = paths;
    if (override == null || override.isEmpty) {
      await paths._migrateLegacy(hasStored);
    }
    return paths;
  }

  /// Switches the data root. An empty input restores the platform default.
  ///
  /// The directory is created and write-probed *before* the choice is persisted,
  /// so a failed switch can never be stored and poison the next startup.
  static Future<void> setRoot(String root) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = root.trim();
    final AppPaths paths;
    if (trimmed.isEmpty) {
      paths = await _defaultPaths();
    } else {
      paths = AppPaths._(p.normalize(trimmed));
      await paths._prepare();
    }
    if (trimmed.isEmpty) {
      await prefs.remove(_rootKey);
    } else {
      await prefs.setString(_rootKey, paths.root);
    }
    // Mutate the shared instance in place: repositories keep their reference.
    final current = _instance;
    if (current == null) {
      _instance = paths;
    } else {
      current._root = paths.root;
    }
  }

  /// Asks for the permission that makes the shared data dir writable on Android
  /// ("all files access" on 11+, storage on 10-). No-op elsewhere, when the
  /// shared dir is already writable, or when the user was already asked once
  /// (unless [force], e.g. from the settings page).
  static Future<void> requestSharedAccess({bool force = false}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      if (await _sharedRootWritable()) return;
      final prefs = await SharedPreferences.getInstance();
      if (!force && (prefs.getBool(_askedKey) ?? false)) return;
      await prefs.setBool(_askedKey, true);
      if (await Permission.storage.isGranted) return;
      if (!await Permission.manageExternalStorage.isGranted) {
        // Opens the system "all files access" page for this app.
        await Permission.manageExternalStorage.request();
      }
      await Permission.storage.request();
    } catch (error) {
      debugPrint('AppPaths: 存储权限申请失败: $error');
    }
  }

  String get sessionsDir => p.join(root, 'sessions');
  String get templatesDir => p.join(root, 'templates');
  String get logsDir => p.join(root, 'logs');

  /// Base directory for per-session working dirs (`sandboxs/{session_id}`).
  String get sandboxesDir => p.join(root, 'sandboxs');

  /// Base directory for projects (`projects/{project_id}.xml` + dirs).
  String get projectsDir => p.join(root, 'projects');
  String get configFile => p.join(root, 'config.json');

  /// Catalog index of sessions/projects (active + archived).
  String get indexFile => p.join(root, 'index.json');

  /// Cached models.dev provider/model catalog snapshot.
  String get modelsDevFile => p.join(root, 'models_dev.json');

  String sessionFile(String id) => p.join(sessionsDir, '$id.xml');
  String templateFile(String id) => p.join(templatesDir, '$id.xml');
  String projectFile(String id) => p.join(projectsDir, '$id.xml');

  /// Default working dir for a standalone session.
  String sessionSandboxDir(String id) => p.join(sandboxesDir, id);

  /// Default (and inherited) working dir for a project.
  String projectSandboxDir(String id) => p.join(projectsDir, id);

  /// Resolves a user-supplied sandbox path to an absolute one.
  ///
  /// A relative path is anchored at `projects/`, so `foo/bar` always means
  /// `<root>/projects/foo/bar`. An empty input is returned unchanged.
  String resolveSandbox(String sandbox) {
    final raw = sandbox.trim();
    if (raw.isEmpty) return raw;
    if (p.isAbsolute(raw)) return p.normalize(raw);
    return p.normalize(p.join(projectsDir, raw));
  }

  Future<void> ensureDirs() async {
    for (final dir in <String>[
      root,
      sessionsDir,
      templatesDir,
      logsDir,
      sandboxesDir,
      projectsDir,
    ]) {
      final d = Directory(dir);
      if (!await d.exists()) {
        await d.create(recursive: true);
      }
    }
  }

  /// First candidate that can be created and written, or `null` when none is
  /// usable. Never throws.
  static Future<AppPaths?> _firstUsable(List<String> candidates) async {
    Object? lastError;
    String? previous;
    for (final root in candidates) {
      if (root.isEmpty || root == previous) continue;
      previous = root;
      final candidate = AppPaths._(root);
      try {
        await candidate._prepare();
        return candidate;
      } catch (error) {
        lastError = error;
      }
    }
    debugPrint('AppPaths: 数据目录均不可用 ($lastError)');
    return null;
  }

  /// Best default root — shared → private → emergency. Never throws; as a very
  /// last resort an unprobed system-temp root keeps startup alive.
  static Future<AppPaths> _defaultPaths() async {
    final paths = await _firstUsable(await _defaultRoots()) ??
        await _firstUsable(<String>[await _emergencyRoot()]);
    return paths ?? AppPaths._(p.join(Directory.systemTemp.path, 'XChat'));
  }

  /// Default roots in order of preference:
  /// 1. shared `{shared}/com.yimo.xchat/data` (externally readable),
  /// 2. app-specific external `Android/data/<pkg>/app_flutter` (permission-free
  ///    but private on Android 11+),
  /// 3. internal `Documents/XChat`.
  static Future<List<String>> _defaultRoots() async {
    final roots = <String>[];
    if (!kIsWeb && Platform.isAndroid) {
      for (final base in _sharedBases) {
        roots.add(p.joinAll(<String>[base, ..._sharedSubdir]));
      }
      try {
        // `getExternalFilesDir` also materializes `Android/data/<pkg>`, which
        // plain mkdirs() is not allowed to create under scoped storage.
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          roots.add(p.normalize(p.join(p.dirname(ext.path), 'app_flutter')));
        }
      } catch (_) {
        // Ignore — later candidates still apply.
      }
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      roots.add(p.join(docs.path, 'XChat'));
    } catch (_) {
      // Ignore — the emergency root still applies.
    }
    return roots;
  }

  static Future<String> _emergencyRoot() async {
    try {
      final tmp = await getTemporaryDirectory();
      return p.join(tmp.path, 'XChat');
    } catch (_) {
      // Plugin unavailable (e.g. unit tests) — try the next option.
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, 'XChat');
    } catch (_) {
      return p.join(Directory.systemTemp.path, 'XChat');
    }
  }

  static Future<bool> _sharedRootWritable() async {
    for (final base in _sharedBases) {
      try {
        final dir = Directory(p.joinAll(<String>[base, ..._sharedSubdir]));
        await dir.create(recursive: true);
        final probe = File(p.join(dir.path, '.write_probe'));
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        return true;
      } catch (_) {
        // Try the next base.
      }
    }
    return false;
  }

  /// Creates the layout and proves the root is actually writable.
  Future<void> _prepare() async {
    await ensureDirs();
    final probe = File(p.join(root, '.write_probe'));
    await probe.writeAsString(DateTime.now().toIso8601String(), flush: true);
    await probe.delete();
  }

  /// One-time move of data from previous default roots when the root is the
  /// default, so changing the default never orphans existing data. Best-effort.
  Future<void> _migrateLegacy(bool hasStoredRoot) async {
    if (hasStoredRoot || kIsWeb || !Platform.isAndroid) return;
    try {
      if (await File(configFile).exists() ||
          await File(indexFile).exists() ||
          !await Directory(sessionsDir).list().isEmpty) {
        return; // Root already holds data — never merge over it.
      }
      for (final source in await _oldDefaultRoots(root)) {
        final legacy = Directory(source);
        if (!await legacy.exists()) continue;
        await for (final entry in legacy.list(followLinks: false)) {
          final target = p.join(root, p.basename(entry.path));
          try {
            await entry.rename(target);
          } catch (_) {
            // Internal → shared crosses mount points: copy instead.
            await _copyTree(entry, target);
            await entry.delete(recursive: true);
          }
        }
        await legacy.delete(recursive: true);
      }
    } catch (error) {
      debugPrint('AppPaths: 旧数据迁移失败: $error');
    }
  }

  /// Earlier Android defaults: internal `Documents/XChat` and the app-specific
  /// external `app_flutter`.
  static Future<List<String>> _oldDefaultRoots(String current) async {
    final sources = <String>[];
    try {
      final docs = await getApplicationDocumentsDirectory();
      sources.add(p.join(docs.path, 'XChat'));
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        sources.add(p.normalize(p.join(p.dirname(ext.path), 'app_flutter')));
      }
    } catch (_) {
      // Whatever resolves is migrated; the rest is left untouched.
    }
    return [for (final source in sources) if (!p.equals(source, current)) source];
  }

  static Future<void> _copyTree(FileSystemEntity from, String to) async {
    if (from is Directory) {
      await Directory(to).create(recursive: true);
      await for (final entry in from.list(followLinks: false)) {
        await _copyTree(entry, p.join(to, p.basename(entry.path)));
      }
    } else if (from is File) {
      await from.copy(to);
    }
  }
}
