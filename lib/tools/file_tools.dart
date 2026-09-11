import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_guard.dart';

class FileTools {
  static String readFile(String sandbox, String path) {
    final abs = PathGuard.resolve(sandbox, path);
    final f = File(abs);
    if (!f.existsSync()) {
      // 明确错误信息,便于 LLM 感知(普通 FileSystemException 容易被忽略)
      return 'ERROR: file_not_found: $abs';
    }
    try {
      return f.readAsStringSync();
    } on FileSystemException catch (e) {
      return 'ERROR: read_failed: ${e.message} (path=$abs)';
    }
  }

  static void writeFile(String sandbox, String path, String content) {
    final abs = PathGuard.resolve(sandbox, path);
    final f = File(abs);
    // 修复:write_file 必须自动创建父目录;否则 LLM 写到深层路径会因父目录不存在而失败,
    // 表现为"工具返回 ERROR 但 sandbox 中找不到文件"。
    final parent = f.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    f.writeAsStringSync(content, flush: true);
  }

  static void editFile(String sandbox, String path, String find, String replace, {bool allOccurrences = false}) {
    final abs = PathGuard.resolve(sandbox, path);
    final f = File(abs);
    if (!f.existsSync()) {
      // 修复:edit_file 目标不存在时,自动降级为 write_file 语义(常见用法是创建新文件)。
      // 父目录也一并创建。
      final parent = f.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      f.writeAsStringSync(replace, flush: true);
      return;
    }
    final src = f.readAsStringSync();
    String next;
    if (allOccurrences) {
      next = src.replaceAll(find, replace);
    } else {
      next = src.replaceFirst(find, replace);
    }
    f.writeAsStringSync(next, flush: true);
  }

  static String listDir(String sandbox, String path, {bool hidden = false}) {
    final abs = PathGuard.resolve(sandbox, path);
    final dir = Directory(abs);
    if (!dir.existsSync()) {
      return 'ERROR: directory_not_found: $abs';
    }
    final entries = dir.listSync().where((e) {
      if (!hidden && p.basename(e.path).startsWith('.')) return false;
      return true;
    }).map((e) {
      final stat = e.statSync();
      final type = stat.type == FileSystemEntityType.directory ? 'd' : 'f';
      return '$type ${p.basename(e.path)}';
    }).toList();
    return entries.join('\n');
  }

  static String glob(String sandbox, String pattern) {
    // 极简 glob：只支持 path/*.ext 与 path/**/*.ext
    final parts = pattern.split('/');
    final base = PathGuard.resolve(sandbox, '.');
    final baseDir = Directory(base);
    if (!baseDir.existsSync()) {
      return 'ERROR: directory_not_found: $base';
    }
    // 把 ** 当成递归
    final out = <String>[];
    void walk(Directory d, List<String> remain) {
      if (remain.isEmpty) {
        out.add(d.path);
        return;
      }
      final head = remain.first;
      if (head == '**') {
        for (final e in d.listSync()) {
          if (e is Directory) {
            walk(e, remain.sublist(1));
            walk(e, remain); // **
          }
        }
        return;
      }
      if (head.contains('*')) {
        final re = RegExp('^${head.replaceAll('*', '.*')}\$');
        for (final e in d.listSync()) {
          if (re.hasMatch(p.basename(e.path))) {
            if (remain.length == 1) {
              out.add(e.path);
            } else if (e is Directory) {
              walk(e, remain.sublist(1));
            }
          }
        }
      } else {
        final next = Directory(p.join(d.path, head));
        if (next.existsSync()) walk(next, remain.sublist(1));
      }
    }
    walk(baseDir, parts);
    return out.join('\n');
  }

  static String grep(String sandbox, String pattern, {String? path, bool ignoreCase = false}) {
    final base = path == null ? sandbox : PathGuard.resolve(sandbox, path);
    final root = Directory(base);
    if (!root.existsSync()) return 'ERROR: directory_not_found: $base';
    final re = RegExp(pattern, caseSensitive: !ignoreCase);
    final out = <String>[];
    void walk(Directory d) {
      for (final e in d.listSync(recursive: false)) {
        if (e is Directory) {
          walk(e);
        } else if (e is File) {
          try {
            final lines = e.readAsLinesSync();
            for (var i = 0; i < lines.length; i++) {
              if (re.hasMatch(lines[i])) {
                out.add('${e.path}:${i + 1}:${lines[i]}');
              }
            }
          } catch (_) {}
        }
      }
    }
    walk(root);
    return out.isEmpty ? '(no matches)' : out.join('\n');
  }
}
