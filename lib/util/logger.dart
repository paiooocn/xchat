import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/config_manager.dart';

/// YOLO 模式下的工具执行日志（追加写，5MB 滚动）
class Logger {
  static Future<void> appendToolExec(
    String sessionId, {
    required String name,
    required String args,
    required String result,
  }) async {
    final dir = Directory(p.join(ConfigManager.instance.xchatDir.path, 'logs'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(p.join(dir.path, '$sessionId.log'));

    if (await file.exists()) {
      final sz = await file.length();
      if (sz > 5 * 1024 * 1024) {
        final roll = File(p.join(dir.path, '$sessionId.1.log'));
        if (await roll.exists()) await roll.delete();
        await file.rename(roll.path);
      }
    }

    final line = '[${DateTime.now().toUtc().toIso8601String()}] [$name] args=$args result=${result.replaceAll('\n', '\\n')}\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }
}
