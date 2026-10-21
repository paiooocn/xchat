import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/proxy_config.dart';

/// PATH 列表的分隔符（POSIX 为 `:`，Windows 为 `;`）。
String get kPathListSeparator => Platform.isWindows ? ';' : ':';

/// 默认 pip 镜像链：清华 → 阿里 → 官方（原始站）。
const List<String> kDefaultPipIndexUrls = <String>[
  'https://pypi.tuna.tsinghua.edu.cn/simple',
  'https://mirrors.aliyun.com/pypi/simple/',
  'https://pypi.org/simple',
];

/// 解释器来源标识。
class PythonOrigin {
  /// 应用包内自带（Tier 1/2）。
  static const String builtin = 'builtin';

  /// 系统 PATH 上的解释器（Tier 3）。
  static const String system = 'system';

  /// 用户在设置里指定的路径。
  static const String custom = 'custom';
}

/// 镜像链中某个源点的展示名（按 URL 识别）。
String pipIndexName(String url) {
  final u = url.toLowerCase();
  if (u.contains('tuna.tsinghua.edu.cn')) return '清华';
  if (u.contains('mirrors.aliyun.com')) return '阿里';
  if (u.contains('pypi.org')) return '官方';
  return '自定义';
}

/// 一个可用的 Python 3 解释器。
class PythonRuntime {
  const PythonRuntime({
    required this.executable,
    required this.home,
    required this.binDir,
    required this.packagesDir,
    required this.origin,
    this.version = '',
  });

  /// 解释器可执行文件的绝对路径。
  final String executable;

  /// 解释器根目录（含 `bin/` 或 `python.exe` + `Lib/`）。
  final String home;

  /// 解释器所在目录（POSIX 为 `<home>/bin`，Windows 为 `<home>`）。
  final String binDir;

  /// pip 包目录（写入 PYTHONPATH）。
  final String packagesDir;

  /// builtin | system | custom
  final String origin;

  /// 版本号（探测后回填）。
  final String version;

  bool get isBuiltin => origin == PythonOrigin.builtin;

  /// 展示用来源名。
  String get originLabel => switch (origin) {
        PythonOrigin.builtin => '内置',
        PythonOrigin.system => '系统',
        PythonOrigin.custom => '自定义',
        _ => origin,
      };

  /// 子进程环境：
  /// * PATH 前置内置解释器目录 → `python3` 直接可用；
  /// * PYTHONPATH 指向包目录 → 内置 pip 装的库可被 import；
  /// * PYTHONNOUSERSITE=1 → 屏蔽用户 site-packages，行为可复现；
  /// * HTTP(S)_PROXY / NO_PROXY → python 与 pip 走应用代理；
  /// * PIP_INDEX_URL / PIP_EXTRA_INDEX_URL → pip 走镜像链。
  Map<String, String> childEnvironment({
    ProxyConfig? proxy,
    List<String> extraPaths = const <String>[],
    List<String> pipIndexes = const <String>[],
    String? pipCacheDir,
  }) {
    final env = <String, String>{};

    // Windows 的环境变量名大小写不敏感，父环境里通常写作 `Path`；Dart 合并父
    // 环境时按 key 精确匹配，若这里另写一个 `PATH`，子进程会同时拿到 `PATH`
    // 与 `Path` 两条记录，生效顺序不确定。因此对父环境中所有 PATH 的大小写
    // 变体统统写入同一个新值，保证子进程看到的 PATH 唯一且确定。
    final pathKeys = Platform.environment.keys
        .where((key) => key.toUpperCase() == 'PATH')
        .toList(growable: false);
    final path = Platform.environment[pathKeys.isEmpty ? 'PATH' : pathKeys.first] ?? '';
    final newPath = path.isEmpty ? binDir : '$binDir$kPathListSeparator$path';
    if (pathKeys.isEmpty) {
      env['PATH'] = newPath;
    } else {
      for (final key in pathKeys) {
        env[key] = newPath;
      }
    }

    final paths = <String>[
      packagesDir,
      ...extraPaths.map((e) => e.trim()).where((e) => e.isNotEmpty),
    ];
    if (paths.isNotEmpty) env['PYTHONPATH'] = paths.join(kPathListSeparator);
    env['PYTHONNOUSERSITE'] = '1';

    final cfg = proxy ?? ProxyConfig();
    final http = cfg.httpProxy.trim();
    final https = cfg.httpsProxy.trim();
    final no = cfg.noProxy.trim();
    if (http.isNotEmpty) env['HTTP_PROXY'] = http;
    if (https.isNotEmpty) env['HTTPS_PROXY'] = https;
    if (no.isNotEmpty) env['NO_PROXY'] = no;

    final indexes = pipIndexes.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (indexes.isNotEmpty) {
      env['PIP_INDEX_URL'] = indexes.first;
      if (indexes.length > 1) env['PIP_EXTRA_INDEX_URL'] = indexes.sublist(1).join(' ');
      env['PIP_DISABLE_PIP_VERSION_CHECK'] = '1';
    }
    if (pipCacheDir != null && pipCacheDir.isNotEmpty) {
      env['PIP_CACHE_DIR'] = pipCacheDir;
    }
    return env;
  }

  PythonRuntime copyWith({String? version}) => PythonRuntime(
        executable: executable,
        home: home,
        binDir: binDir,
        packagesDir: packagesDir,
        origin: origin,
        version: version ?? this.version,
      );

  /// 探测版本号（失败返回空串，不抛异常）。
  Future<String> probeVersion() async {
    try {
      final result = await Process.run(
        executable,
        <String>['-c', 'import sys;print(sys.version.split()[0])'],
        environment: childEnvironment(),
      ).timeout(const Duration(seconds: 20));
      final out = '${result.stdout}'.trim();
      return result.exitCode == 0 && out.isNotEmpty ? out : '';
    } catch (_) {
      return '';
    }
  }
}

/// 解释器定位：内置（应用包/开发态）→ 系统 PATH → 用户自定义。
class PythonRuntimeLocator {
  const PythonRuntimeLocator._();

  /// 按 [source]（`auto` / `builtin` / `system` / `custom`）定位解释器。
  ///
  /// [packagesDir] 是 pip 包目录，会写进结果的 [PythonRuntime.packagesDir]。
  static Future<PythonRuntime?> locate({
    required String source,
    String customPath = '',
    required String packagesDir,
  }) async {
    switch (source) {
      case 'custom':
        final trimmed = customPath.trim();
        if (trimmed.isEmpty) return null;
        return _probe(trimmed, packagesDir, PythonOrigin.custom);
      case 'system':
        return _system(packagesDir);
      case 'builtin':
        for (final root in builtinRoots()) {
          final found = await _probe(root, packagesDir, PythonOrigin.builtin);
          if (found != null) return found;
        }
        return null;
      default: // auto
        for (final root in builtinRoots()) {
          final found = await _probe(root, packagesDir, PythonOrigin.builtin);
          if (found != null) return found;
        }
        return _system(packagesDir);
    }
  }

  /// 内置解释器的候选根目录（按优先级）。
  ///
  /// 1. `XCHAT_PYTHON_HOME`（调试覆盖）；
  /// 2. `<AppDir>/runtime/python`（打包后随应用分发）；
  /// 3. `<cwd>/third_party/python` 及其子目录（`flutter run` 开发态，
  ///    uv 装出的目录形如 `cpython-3.12.x-linux-x86_64-gnu/`）。
  static List<String> builtinRoots() {
    final roots = <String>[];
    final override = Platform.environment['XCHAT_PYTHON_HOME'];
    if (override != null && override.trim().isNotEmpty) roots.add(override.trim());
    try {
      roots.add(p.join(p.dirname(Platform.resolvedExecutable), 'runtime', 'python'));
    } catch (_) {
      // 忽略：无法解析可执行文件路径时继续下一候选。
    }
    try {
      final dev = p.join(Directory.current.path, 'third_party', 'python');
      roots.add(dev);
      final dir = Directory(dev);
      if (dir.existsSync()) {
        for (final child in dir.listSync(followLinks: false)) {
          if (child is Directory) roots.add(child.path);
        }
      }
    } catch (_) {
      // 忽略。
    }
    return roots;
  }

  /// 探测一个路径（文件或目录）是否是可用的解释器。
  static Future<PythonRuntime?> _probe(
    String path,
    String packagesDir,
    String origin,
  ) async {
    final file = File(path);
    if (file.existsSync()) {
      return PythonRuntime(
        executable: file.path,
        home: p.dirname(file.path),
        binDir: p.dirname(file.path),
        packagesDir: packagesDir,
        origin: origin,
      );
    }
    final dir = Directory(path);
    if (!dir.existsSync()) return null;
    final layout = layoutIn(dir.path);
    if (layout == null) return null;
    return PythonRuntime(
      executable: layout.executable,
      home: dir.path,
      binDir: layout.binDir,
      packagesDir: packagesDir,
      origin: origin,
    );
  }

  /// 在 [root] 下找出解释器；返回 `null` 表示不是解释器目录。
  static ({String executable, String binDir})? layoutIn(String root) {
    const posix = <String>['bin/python3', 'bin/python3.12', 'bin/python'];
    for (final rel in posix) {
      final f = File(p.join(root, rel));
      if (f.existsSync()) {
        return (executable: f.path, binDir: p.join(root, 'bin'));
      }
    }
    const windows = <String>['python.exe', 'bin/python.exe', 'Scripts/python.exe'];
    for (final rel in windows) {
      final f = File(p.join(root, rel));
      if (f.existsSync()) {
        return (executable: f.path, binDir: root);
      }
    }
    return null;
  }

  /// 系统 PATH 上的 `python3` / `python`。
  static PythonRuntime? _system(String packagesDir) {
    final names = Platform.isWindows
        ? <String>['python.exe', 'python3.exe']
        : <String>['python3', 'python'];
    final dirs = (Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':')
        .where((d) => d.trim().isNotEmpty);
    for (final name in names) {
      for (final dir in dirs) {
        final file = File(p.join(dir.trim(), name));
        if (file.existsSync()) {
          return PythonRuntime(
            executable: file.path,
            home: p.dirname(file.path),
            binDir: dir.trim(),
            packagesDir: packagesDir,
            origin: PythonOrigin.system,
          );
        }
      }
    }
    return null;
  }
}
