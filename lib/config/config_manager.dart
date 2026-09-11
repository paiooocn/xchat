import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 用户级配置管理：~/.xchat/config.json
class ConfigManager {
  ConfigManager._();
  static final ConfigManager instance = ConfigManager._();

  late Directory _xchatDir;
  late File _configFile;
  Map<String, dynamic> _data = {};

  Future<void> init() async {
    _xchatDir = await _resolveXchatDir();
    if (!await _xchatDir.exists()) {
      await _xchatDir.create(recursive: true);
    }
    final sessionsDir = Directory(p.join(_xchatDir.path, 'sessions'));
    if (!await sessionsDir.exists()) await sessionsDir.create(recursive: true);
    final templatesDir = Directory(p.join(_xchatDir.path, 'templates'));
    if (!await templatesDir.exists()) await templatesDir.create(recursive: true);
    final logsDir = Directory(p.join(_xchatDir.path, 'logs'));
    if (!await logsDir.exists()) await logsDir.create(recursive: true);

    _configFile = File(p.join(_xchatDir.path, 'config.json'));
    if (await _configFile.exists()) {
      try {
        _data = jsonDecode(await _configFile.readAsString()) as Map<String, dynamic>;
      } catch (e) {
        _data = _defaultConfig();
      }
    } else {
      _data = _defaultConfig();
      await _save();
    }
  }

  Map<String, dynamic> get data => Map<String, dynamic>.from(_data);

  Directory get xchatDir => _xchatDir;
  File get configFile => _configFile;

  Future<Map<String, dynamic>> patch(Map<String, dynamic> updates) async {
    _data = _deepMerge(_data, updates);
    await _save();
    return data;
  }

  Future<void> _save() async {
    await _configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_data),
      flush: true,
    );
  }

  Future<Directory> _resolveXchatDir() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    return Directory(p.join(home, '.xchat'));
  }

  /// 测试专用:把 xchatDir 强制指定到临时目录,跳过 HOME 解析。
  /// 必须在 init() 之前调用。
  void initForTest(Directory dir) {
    _xchatDir = dir;
    _configFile = File(p.join(dir.path, 'config.json'));
    _data = _defaultConfig();
  }

  Map<String, dynamic> _deepMerge(Map<String, dynamic> a, Map<String, dynamic> b) {
    final out = Map<String, dynamic>.from(a);
    b.forEach((k, v) {
      final existing = out[k];
      if (existing is Map && v is Map) {
        out[k] = _deepMerge(Map<String, dynamic>.from(existing), Map<String, dynamic>.from(v));
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  Map<String, dynamic> _defaultConfig() {
    return {
      'providers': [],
      'defaults': {
        'provider_id': null,
        'model_id': null,
        'max_rounds': 20,
        'model_param': {
          'thinking': 'disabled',
          'reasoning_effort': 'medium',
          'temperature': 1.0,
        },
        'tool_output_limit': 8000,
        'context_compress_threshold': 0.8,
        'summarizer': {'provider_id': null, 'model_id': null},
      },
      'ui': {
        'currency': 'CNY',
        'fx_rates': {'USD': 1.0, 'CNY': 7.25, 'EUR': 0.92, 'JPY': 155.0},
        'fx_fetched_at': null,
        'theme': 'system',
        'confirm_mode': 'normal',
        'editor': null,
      },
    };
  }
}

/// 用于需要 platform-aware 路径时的工具；目前只用作占位以便后续扩展
Future<Directory> appSupportDir() async {
  // 仅用于未来扩展（例如多 profile），目前用 ~/.xchat 即可
  return Directory('.');
}
