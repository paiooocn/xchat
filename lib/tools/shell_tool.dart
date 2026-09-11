import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/blocklist_loader.dart';

enum ShellResultKind { ok, blockedLayerA, blockedExceptionYolo, userDenied, error }

class ShellResult {
  final ShellResultKind kind;
  final String message;
  final int? exitCode;
  ShellResult(this.kind, this.message, {this.exitCode});
  static ShellResult ok(String out, int code) => ShellResult(ShellResultKind.ok, out, exitCode: code);
}

class ShellTool {
  /// 执行 shell 命令；含 Layer A/B 检查 + cwd=sandbox
  static ShellResult execute(String sandbox, String cmd, {required String confirmMode}) {
    final blocklist = BlocklistLoader.instance.current;

    // Layer A: 全模式拒绝
    for (final r in blocklist.layerA) {
      if (r.regex.hasMatch(cmd)) {
        return ShellResult(ShellResultKind.blockedLayerA,
            'blocked_command_layer_a: ${r.note} (pattern=${r.pattern})');
      }
    }

    // Layer B 命中
    BlockRule? hitB;
    for (final r in blocklist.layerB) {
      if (r.regex.hasMatch(cmd)) {
        hitB = r;
        break;
      }
    }

    if (hitB != null) {
      // 检查例外
      BlockRule? exceptionHit;
      for (final r in blocklist.layerBExceptions) {
        if (r.regex.hasMatch(cmd)) {
          exceptionHit = r;
          break;
        }
      }
      if (exceptionHit != null && confirmMode == 'yolo') {
        return ShellResult(ShellResultKind.blockedExceptionYolo,
            'blocked_exception_yolo: ${exceptionHit.note} (pattern=${exceptionHit.pattern})');
      }
      // normal / shell 模式：调用方应已弹 confirm；这里假定已 confirm 后才执行
      // 简化：若未 confirm 返回 userDenied（实际由 bridge 层拦截）
    }

    // 执行
    try {
      final result = Process.runSync('/bin/sh', ['-c', cmd], workingDirectory: p.canonicalize(p.absolute(sandbox)));
      final out = (result.stdout as String) + (result.stderr as String);
      final truncated = out.length > 8000;
      final finalOut = truncated ? out.substring(0, 8000) + '\n[truncated]' : out;
      return ShellResult(ShellResultKind.ok, finalOut, exitCode: result.exitCode);
    } catch (e) {
      return ShellResult(ShellResultKind.error, 'shell_error: $e');
    }
  }
}
