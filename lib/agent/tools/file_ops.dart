import 'dart:io';

import 'package:llm_api/llm_api.dart';
import 'package:path/path.dart' as p;

import '../../models/shell_exec.dart';
import 'path_guard.dart';

/// Glob 模式 → 正则（`**` 跨目录、`*` 不跨目录、`?` 单字符）。
///
/// Moved out of `builtin_tools.dart` so the file-operation tools can share it.
RegExp globToRegExp(String glob) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final char = glob[i];
    if (char == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        if (i + 2 < glob.length && glob[i + 2] == '/') {
          // `**/` 跨任意层目录（含零层：`*.py` 也要能匹配 `a.py`）。
          buffer.write('(?:.*/)?');
          i += 2;
        } else {
          buffer.write('.*');
          i++;
        }
      } else {
        buffer.write('[^/]*');
      }
    } else if (char == '?') {
      buffer.write('[^/]');
    } else if (r'\^$.|+()[]{}'.contains(char)) {
      buffer.write('\\$char');
    } else {
      buffer.write(char);
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

/// `mv_file` — 改名 / 移动文件或目录（限定在沙箱内）。
LlmTool buildMvFileTool(PathGuard guard) => FunctionTool(
      name: 'mv_file',
      description: '在沙箱内改名或移动文件/目录（不能移出沙箱）。'
          'source 是原路径，destination 是新路径；destination 是已存在的目录时移动到该目录内；'
          'overwrite=true 可覆盖已存在的同名目标文件。',
      parameters: objectSchema(
        properties: {
          'source': stringSchema(description: '原文件/目录路径（相对沙箱或绝对路径）'),
          'destination': stringSchema(description: '新路径（相对沙箱或绝对路径）'),
          'overwrite': booleanSchema(description: '目标已存在时是否覆盖（默认 false）'),
        },
        required: ['source', 'destination'],
      ),
      handler: (args) async {
        final source = '${args['source'] ?? ''}'.trim();
        final destination = '${args['destination'] ?? ''}'.trim();
        if (source.isEmpty || destination.isEmpty) {
          return 'ERROR: source and destination are required';
        }
        final String src;
        final String dst;
        try {
          src = guard.resolve(source);
          dst = guard.resolve(destination);
        } on SandboxViolation catch (error) {
          return 'ERROR: ${error.message}';
        }

        final srcType = FileSystemEntity.typeSync(src, followLinks: false);
        if (srcType == FileSystemEntityType.notFound) {
          return 'ERROR: source not found: $src';
        }

        // `mv a.txt dir/` → 移入该目录。
        var target = dst;
        if (FileSystemEntity.typeSync(dst, followLinks: false) ==
            FileSystemEntityType.directory) {
          target = p.join(dst, p.basename(src));
        }

        // 不能把目录移进它自己（或其子目录）。
        if (srcType == FileSystemEntityType.directory && p.isWithin(src, target)) {
          return 'ERROR: cannot move a directory into itself: $src';
        }

        final targetType = FileSystemEntity.typeSync(target, followLinks: false);
        if (targetType != FileSystemEntityType.notFound) {
          if (args['overwrite'] != true) {
            return 'ERROR: destination already exists: $target'
                '（加 overwrite=true 可覆盖同名文件）';
          }
          if (targetType == FileSystemEntityType.directory) {
            return 'ERROR: destination is a directory, refusing to overwrite: $target';
          }
          try {
            await File(target).delete();
          } catch (error) {
            return 'ERROR: cannot overwrite $target: $error';
          }
        }

        try {
          await Directory(p.dirname(target)).create(recursive: true);
        } catch (error) {
          return 'ERROR: cannot create target directory: $error';
        }

        try {
          await _move(src, target);
        } catch (error) {
          return 'ERROR: move failed: $error';
        }

        final base = p.normalize(p.absolute(guard.sandbox));
        return 'OK: moved ${p.relative(src, from: base)} -> ${p.relative(target, from: base)}';
      },
    );

/// Moves [src] to [target]; falls back to copy+delete across file systems.
Future<void> _move(String src, String target) async {
  try {
    if (Directory(src).existsSync()) {
      await Directory(src).rename(target);
    } else if (File(src).existsSync()) {
      await File(src).rename(target);
    } else {
      await Link(src).rename(target);
    }
  } on FileSystemException {
    // 跨文件系统时 rename 不可用（EXDEV）：文件走复制 + 删除。
    final file = File(src);
    if (!file.existsSync()) rethrow;
    await file.copy(target);
    await file.delete();
  }
}

/// `grep_file` — 在沙箱内按正则检索文件内容（Dart 实现，不依赖外部 grep）。
LlmTool buildGrepFileTool(PathGuard guard) => FunctionTool(
      name: 'grep_file',
      description: '在沙箱内按正则检索文件内容（纯 Dart 实现，不依赖外部 grep 命令）。'
          '默认递归搜索 path 目录下的所有文本文件，可用 glob 过滤文件名（如 **/*.py）；'
          '输出格式为 路径:行号: 匹配行，二进制文件自动跳过。',
      parameters: objectSchema(
        properties: {
          'pattern': stringSchema(description: '检索内容（默认按正则解析，regex=false 时按普通文本）'),
          'path': stringSchema(description: '搜索根目录，默认 .'),
          'glob': stringSchema(description: '文件名过滤（glob，如 **/*.dart），默认全部文件'),
          'regex': booleanSchema(description: 'pattern 是否按正则解析（默认 true）'),
          'case_sensitive': booleanSchema(description: '是否区分大小写（默认 true）'),
          'context': integerSchema(description: '匹配行前后的上下文行数（默认 0）', minimum: 0),
          'max_results': integerSchema(description: '最多返回的匹配行数（默认 100）', minimum: 1),
        },
        required: ['pattern'],
      ),
      handler: (args) async {
        final pattern = '${args['pattern'] ?? ''}';
        if (pattern.isEmpty) return 'ERROR: pattern required';
        final useRegex = args['regex'] != false;
        final RegExp matcher;
        try {
          matcher = RegExp(
            useRegex ? pattern : RegExp.escape(pattern),
            caseSensitive: args['case_sensitive'] != false,
          );
        } on FormatException catch (error) {
          return 'ERROR: invalid pattern: ${error.message}';
        }

        final rawPath = '${args['path'] ?? '.'}'.trim();
        final String root;
        try {
          root = guard.resolve(rawPath.isEmpty ? '.' : rawPath);
        } on SandboxViolation catch (error) {
          return 'ERROR: ${error.message}';
        }

        final base = p.normalize(p.absolute(guard.sandbox));
        final globFilter = '${args['glob'] ?? ''}'.trim();
        final filePattern = globFilter.isEmpty ? null : globToRegExp(globFilter);
        final maxResults = (args['max_results'] as num?)?.toInt() ?? 100;
        final context = ((args['context'] as num?)?.toInt() ?? 0).clamp(0, 10);
        const maxFileBytes = 5 * 1024 * 1024;

        final files = <File>[];
        if (File(root).existsSync()) {
          files.add(File(root));
        } else {
          final dir = Directory(root);
          if (!await dir.exists()) return 'ERROR: not a directory: $root';
          await for (final entity in dir.list(recursive: true, followLinks: false)) {
            if (entity is! File) continue;
            final rel = p.relative(entity.path, from: base);
            if (rel.split(p.separator).contains('.git')) continue;
            if (filePattern != null && !filePattern.hasMatch(rel)) continue;
            files.add(entity);
            if (files.length >= 5000) break;
          }
        }

        final results = <String>[];
        final emitted = <String>{};
        var matchCount = 0;
        var matchedFiles = 0;

        for (final file in files) {
          if (results.length >= maxResults) break;
          final int size;
          try {
            size = await file.length();
          } catch (_) {
            continue;
          }
          if (size > maxFileBytes) continue;
          final List<int> bytes;
          try {
            bytes = await file.readAsBytes();
          } catch (_) {
            continue;
          }
          if (_looksBinary(bytes)) continue;
          final lines = decodeShellOutput(bytes).split('\n');
          final rel = p.relative(file.path, from: base);
          var fileMatches = 0;
          for (var i = 0; i < lines.length; i++) {
            if (!matcher.hasMatch(lines[i])) continue;
            fileMatches++;
            matchCount++;
            final start = i - context < 0 ? 0 : i - context;
            final end = i + context >= lines.length ? lines.length - 1 : i + context;
            for (var j = start; j <= end; j++) {
              final key = '$rel#${j + 1}';
              if (!emitted.add(key)) continue;
              final marker = j == i ? ':' : '-';
              results.add('$rel:${j + 1}$marker${_truncate(lines[j])}');
            }
            if (results.length >= maxResults) break;
          }
          if (fileMatches > 0) matchedFiles++;
        }

        if (results.isEmpty) {
          return 'No matches for "$pattern" (searched ${files.length} file(s)).';
        }
        final header = '$matchCount match(es) in $matchedFiles file(s), '
            'scanned ${files.length} file(s):';
        return '$header\n${results.join('\n')}';
      },
    );

/// Heuristic binary check: a NUL byte in the first chunk.
bool _looksBinary(List<int> bytes) {
  final limit = bytes.length < 8000 ? bytes.length : 8000;
  for (var i = 0; i < limit; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

/// Truncates a matched line so one huge line cannot flood the context.
String _truncate(String line) {
  const limit = 300;
  if (line.length <= limit) return line;
  return '${line.substring(0, limit)}…';
}
