import 'dart:io';

import 'file_tools.dart';
import 'path_guard.dart';
import 'shell_tool.dart';

class ToolRegistry {
  static const safeTools = {'read_file', 'list_dir', 'glob', 'grep', 'get_time'};
  static const dangerousTools = {'shell', 'write_file', 'edit_file'};

  /// 是否该 confirm
  static bool shouldConfirm(String toolName, String confirmMode) {
    if (confirmMode == 'yolo') return false;
    if (confirmMode == 'shell') return toolName == 'shell';
    // normal
    return dangerousTools.contains(toolName);
  }

  static bool isDangerous(String toolName) => dangerousTools.contains(toolName);

  /// 执行；返回文本结果（含错误）
  static String execute(String toolName, String sandbox, Map<String, dynamic> args,
      {String confirmMode = 'normal', bool alreadyConfirmed = false}) {
    // 入口日志:统一打出 sandbox + args + 解析后的绝对路径(若有),
    // 便于排查"工具说写成功了但找不到文件"。
    _logToolCall(toolName, sandbox, args);
    try {
      switch (toolName) {
        case 'read_file':
          final path = args['path'] as String;
          return FileTools.readFile(sandbox, path);
        case 'write_file':
          if (shouldConfirm('write_file', confirmMode) && !alreadyConfirmed) {
            return 'ERROR: confirmation required (write_file)';
          }
          final path = args['path'] as String;
          final content = args['content'] as String;
          try {
            FileTools.writeFile(sandbox, path, content);
            _logToolResult('write_file', sandbox, path, ok: true, bytes: content.length);
            return 'OK: wrote ${content.length} chars to $path';
          } on PathEscapeError catch (e) {
            _logToolResult('write_file', sandbox, path, ok: false, err: 'path_escape: $e');
            return 'ERROR: path_escape: $e';
          } on FileSystemException catch (e) {
            // 修复:把异常转成明确错误信息,避免 LLM 看到空 stderr
            _logToolResult('write_file', sandbox, path, ok: false, err: 'write_failed: ${e.message}');
            return 'ERROR: write_failed: ${e.message} (path=$path)';
          }
        case 'edit_file':
          if (shouldConfirm('edit_file', confirmMode) && !alreadyConfirmed) {
            return 'ERROR: confirmation required (edit_file)';
          }
          final path = args['path'] as String;
          final find = args['find'] as String;
          final replace = args['replace'] as String;
          final all = args['all_occurrences'] == true;
          try {
            FileTools.editFile(sandbox, path, find, replace, allOccurrences: all);
            _logToolResult('edit_file', sandbox, path, ok: true);
            return 'OK: edited $path';
          } on PathEscapeError catch (e) {
            _logToolResult('edit_file', sandbox, path, ok: false, err: 'path_escape: $e');
            return 'ERROR: path_escape: $e';
          } on FileSystemException catch (e) {
            _logToolResult('edit_file', sandbox, path, ok: false, err: 'edit_failed: ${e.message}');
            return 'ERROR: edit_failed: ${e.message} (path=$path)';
          }
        case 'list_dir':
          final path = (args['path'] as String?) ?? '.';
          return FileTools.listDir(sandbox, path);
        case 'glob':
          final pattern = args['pattern'] as String;
          return FileTools.glob(sandbox, pattern);
        case 'grep':
          final pattern = args['pattern'] as String;
          final path = args['path'] as String?;
          final ignoreCase = args['ignore_case'] == true;
          return FileTools.grep(sandbox, pattern, path: path, ignoreCase: ignoreCase);
        case 'shell':
          if (shouldConfirm('shell', confirmMode) && !alreadyConfirmed) {
            return 'ERROR: confirmation required (shell)';
          }
          final cmd = args['cmd'] as String;
          final r = ShellTool.execute(sandbox, cmd, confirmMode: confirmMode);
          if (r.kind == ShellResultKind.blockedLayerA) {
            throw BlockedLayerA(r.message);
          }
          if (r.kind == ShellResultKind.blockedExceptionYolo) {
            throw BlockedExceptionYolo(r.message);
          }
          return r.message;
        case 'get_time':
          return DateTime.now().toUtc().toIso8601String();
        default:
          return 'ERROR: unknown tool $toolName';
      }
    } on PathEscapeError catch (e) {
      return 'ERROR: path_escape: $e';
    } on BlockedLayerA {
      rethrow;
    } on BlockedExceptionYolo {
      rethrow;
    } catch (e) {
      return 'ERROR: $e';
    }
  }

  /// 入口日志:打印工具名 + sandbox + 关键 args + 解析后的绝对路径。
  /// 解析失败(例如 path 越界)时打 attempted=... 而不抛。
  static void _logToolCall(String toolName, String sandbox, Map<String, dynamic> args) {
    final buf = StringBuffer()
      ..write('[XChat][tool] call name=$toolName sandbox=$sandbox');
    switch (toolName) {
      case 'read_file':
      case 'write_file':
      case 'edit_file':
      case 'list_dir':
        final raw = (args['path'] ?? '').toString();
        _appendPathInfo(buf, sandbox, raw);
        if (toolName == 'write_file') {
          final c = args['content'];
          buf.write(' bytes=${c is String ? c.length : '?'}');
        } else if (toolName == 'edit_file') {
          buf.write(' all_occurrences=${args['all_occurrences'] == true}');
        }
        break;
      case 'grep':
        buf.write(' pattern=${args['pattern']}');
        final raw = args['path'];
        if (raw is String && raw.isNotEmpty) {
          _appendPathInfo(buf, sandbox, raw);
        } else {
          buf.write(' path=<sandbox>');
        }
        buf.write(' ignore_case=${args['ignore_case'] == true}');
        break;
      case 'glob':
        buf.write(' pattern=${args['pattern']}');
        break;
      case 'shell':
        buf.write(' cmd=${args['cmd']}');
        break;
      case 'get_time':
        break;
    }
    // ignore: avoid_print
    print(buf.toString());
  }

  /// 结果日志:对写入类工具额外打 exists_after / size,
    // 直接告诉用户文件到底有没有落到磁盘上。
  static void _logToolResult(String toolName, String sandbox, String relPath,
      {required bool ok, int? bytes, String? err}) {
    String abs = relPath;
    bool existsAfter = false;
    int sizeAfter = -1;
    try {
      abs = PathGuard.resolve(sandbox, relPath);
      final f = File(abs);
      existsAfter = f.existsSync();
      if (existsAfter) sizeAfter = f.lengthSync();
    } catch (_) {
      // 解析失败时仍打印 attempted 值,exists_after=false
    }
    final buf = StringBuffer()
      ..write('[XChat][tool] result name=$toolName ok=$ok')
      ..write(' attempted=$relPath')
      ..write(' abs=$abs')
      ..write(' exists_after=$existsAfter')
      ..write(' size_after=$sizeAfter');
    if (bytes != null) buf.write(' bytes=$bytes');
    if (err != null) buf.write(' err=$err');
    // ignore: avoid_print
    print(buf.toString());
  }

  static void _appendPathInfo(StringBuffer buf, String sandbox, String raw) {
    String abs = '<unresolved>';
    String err = '';
    try {
      abs = PathGuard.resolve(sandbox, raw);
    } on PathEscapeError catch (e) {
      err = ' path_escape=$e';
    } catch (e) {
      err = ' resolve_err=$e';
    }
    buf.write(' path=$raw abs=$abs$err');
  }
}

class BlockedLayerA implements Exception {
  final String message;
  BlockedLayerA(this.message);
  @override
  String toString() => message;
}

class BlockedExceptionYolo implements Exception {
  final String message;
  BlockedExceptionYolo(this.message);
  @override
  String toString() => message;
}
