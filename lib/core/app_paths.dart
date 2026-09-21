import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Resolves and creates the on-disk layout under `Documents/XChat/`.
///
/// ```
/// <root>/                     e.g. ~/Documents/XChat
///   config.json
///   sessions/                 default sandbox for session files (<uuid>.xml)
///   templates/                session templates
///   logs/
/// ```
class AppPaths {
  AppPaths._(this.root);

  final String root;

  static const _rootKey = 'xchat_root';
  static AppPaths? _instance;

  static AppPaths get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('AppPaths.init() must be called before use');
    }
    return value;
  }

  static bool get isReady => _instance != null;

  static Future<AppPaths> init({String? overrideRoot}) async {
    final prefs = await SharedPreferences.getInstance();
    var root = overrideRoot ?? prefs.getString(_rootKey);
    if (root == null || root.trim().isEmpty) {
      final docs = await getApplicationDocumentsDirectory();
      root = p.join(docs.path, 'XChat');
    }
    final paths = AppPaths._(root);
    _instance = paths;
    await paths.ensureDirs();
    return paths;
  }

  static Future<void> setRoot(String root) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_rootKey, root);
    _instance = AppPaths._(root);
    await _instance!.ensureDirs();
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
}
