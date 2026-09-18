import 'dart:convert';
import 'dart:io';

import '../core/app_paths.dart';
import '../models/app_config.dart';

/// Loads/saves `XChat/config.json`.
class ConfigRepository {
  ConfigRepository(this.paths);

  final AppPaths paths;

  Future<AppConfig> load() async {
    final file = File(paths.configFile);
    if (!await file.exists()) {
      final config = AppConfig();
      await save(config);
      return config;
    }
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return AppConfig();
      return AppConfig.fromJson(jsonDecode(raw));
    } catch (_) {
      return AppConfig();
    }
  }

  Future<void> save(AppConfig config) async {
    final file = File(paths.configFile);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
