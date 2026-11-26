import 'dart:io';

import 'package:llm_api/llm_api.dart';
import 'package:path/path.dart' as p;

import '../../models/shell_exec.dart';
import 'path_guard.dart';

/// 单次工具调用的最大批量项数（`read_file` / `write_file` / `edit_file` /
/// `mv_file` 共用）。超出直接返回 ERROR 让模型自己分批 —— 静默截断会让模型
/// 误以为剩余项也执行了。
const int kToolMaxBatchItems = 20;

/// `read_file` 一次调用里所有文件合计的字符预算；超出预算的文件标记 SKIPPED，
/// 提示模型单独再读，而不是把内容截一半。
const int kReadFileMaxTotalChars = 200000;

/// `write_file` 一次调用里所有文件合计的字符预算。
const int kWriteFileMaxTotalChars = 4 * 1024 * 1024;

/// 文件读取类工具的结果上限。`ToolRegistry` 默认把所有工具结果截到 24000
/// 字符（见 `packages/llm_api` 的 `maxResultCharacters`），那是「20K 以上的
/// 文件读不全」的真因；`read_file` 在这里单独放开，与上面的批量预算对齐。
const int kReadFileMaxResultChars = 240000;

/// 批量项数校验：`null` = 通过，否则是要回给模型的错误文案。
String? checkBatchSize(int count) =>
    count > kToolMaxBatchItems
        ? 'ERROR: 单次最多处理 $kToolMaxBatchItems 项（本次 $count 项），请分批调用'
        : null;

/// 批量工具的统一输出：单项时原样返回正文（保持旧的单次行为），多项时按
/// `=== label ===` 分节，并在末尾附 `summary: N ok, N failed, N skipped`。
String batchReport(List<MapEntry<String, String>> items) {
  if (items.isEmpty) return 'ERROR: nothing to do';
  if (items.length == 1) return items.first.value;
  final buffer = StringBuffer();
  var ok = 0;
  var failed = 0;
  var skipped = 0;
  for (final item in items) {
    buffer
      ..writeln('=== ${item.key} ===')
      ..writeln(item.value);
    if (item.value.startsWith('SKIPPED')) {
      skipped++;
    } else if (item.value.startsWith('ERROR')) {
      failed++;
    } else {
      ok++;
    }
  }
  buffer.write('---\nsummary: $ok ok, $failed failed, $skipped skipped '
      '(batch ${items.length}/$kToolMaxBatchItems)');
  return buffer.toString();
}

/// 沙箱内路径的显示形式（相对沙箱，越界时原样回显）——批量结果的分节标题。
String sandboxLabel(PathGuard guard, String raw) {
  final base = p.normalize(p.absolute(guard.sandbox));
  final absolute = p.isAbsolute(raw) ? raw : p.join(base, raw);
  final normalized = p.normalize(absolute);
  final inside = normalized == base || p.isWithin(base, normalized);
  return inside ? p.relative(normalized, from: base) : raw;
}

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
          '支持批量：moves 为 [{source, destination, overwrite}] 列表，按数组顺序逐项执行，'
          '单次最多 $kToolMaxBatchItems 项；也可用单项参数 source + destination。'
          'destination 是已存在的目录时移动到该目录内；overwrite=true 可覆盖已存在的同名目标文件。'
          '单项失败不影响其余项，结果逐项返回（不整体回滚）。',
      parameters: objectSchema(
        properties: {
          'moves': arraySchema(
            description: '批量移动列表（最多 $kToolMaxBatchItems 项，按序执行）',
            items: objectSchema(
              properties: {
                'source': stringSchema(description: '原文件/目录路径'),
                'destination': stringSchema(description: '新路径'),
                'overwrite': booleanSchema(description: '目标已存在时是否覆盖（默认 false）'),
              },
              required: ['source', 'destination'],
            ),
          ),
          'source': stringSchema(description: '单项模式：原路径（相对沙箱或绝对路径）'),
          'destination': stringSchema(description: '单项模式：新路径（相对沙箱或绝对路径）'),
          'overwrite': booleanSchema(description: '单项模式：目标已存在时是否覆盖（默认 false）'),
        },
      ),
      handler: (args) async {
        final jobs = _collectMoves(args);
        if (jobs.isEmpty) {
          return 'ERROR: 需要 moves 列表，或 source + destination';
        }
        final tooMany = checkBatchSize(jobs.length);
        if (tooMany != null) return tooMany;
        final items = <MapEntry<String, String>>[];
        for (final job in jobs) {
          items.add(MapEntry(
            '${job.source} -> ${job.destination}',
            await _moveOne(guard, job.source, job.destination, job.overwrite),
          ));
        }
        return batchReport(items);
      },
    );

/// 收集 `moves` 列表（或单项参数），丢弃缺字段的项。
List<({String source, String destination, bool overwrite})> _collectMoves(
  Map<String, Object?> args,
) {
  final jobs = <({String source, String destination, bool overwrite})>[];
  final list = args['moves'];
  if (list is List) {
    for (final raw in list) {
      if (raw is! Map) continue;
      final source = '${raw['source'] ?? ''}'.trim();
      final destination = '${raw['destination'] ?? ''}'.trim();
      if (source.isEmpty || destination.isEmpty) continue;
      jobs.add((
        source: source,
        destination: destination,
        overwrite: raw['overwrite'] == true,
      ));
    }
    if (jobs.isNotEmpty) return jobs;
  }
  final source = '${args['source'] ?? ''}'.trim();
  final destination = '${args['destination'] ?? ''}'.trim();
  if (source.isNotEmpty && destination.isNotEmpty) {
    jobs.add((
      source: source,
      destination: destination,
      overwrite: args['overwrite'] == true,
    ));
  }
  return jobs;
}

/// 移动一项；返回 `OK: moved …` 或 `ERROR: …` 文本（批量结果的一项）。
Future<String> _moveOne(
  PathGuard guard,
  String source,
  String destination,
  bool overwrite,
) async {
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
    if (!overwrite) {
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
}

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
