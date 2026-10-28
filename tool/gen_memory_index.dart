/// Generates `.memory/MAP.yaml` — the machine-readable map of this repository.
///
/// The map is *facts only*: which files exist, what top-level symbols they
/// declare, which modules import which. Every judgement (what a module is
/// for, how risky it is to touch) lives in the hand-written
/// `.memory/ANNOTATIONS.yaml`, so regenerating never destroys human input.
///
/// Usage:
///
/// ```sh
/// dart run tool/gen_memory_index.dart          # write .memory/MAP.yaml
/// dart run tool/gen_memory_index.dart --check  # exit 1 if the map is stale
/// ```
library;

import 'dart:io';

/// A module is a directory below `lib/` (or the vendored `llm_api` package).
class Module {
  Module(this.id, this.path);

  /// Dotted id used as the dependency key, e.g. `data.xml`, `ui.pages`.
  final String id;

  /// Repository-relative directory, e.g. `lib/data/xml`.
  final String path;

  final List<SourceFile> files = [];
  final Set<String> deps = {};

  int get lines => files.fold(0, (int a, SourceFile f) => a + f.lines);
}

class SourceFile {
  SourceFile(this.path, this.lines, this.doc, this.symbols);

  /// Repository-relative path.
  final String path;
  final int lines;

  /// First line of the file's leading doc comment, if any.
  final String doc;

  /// Top-level type/function names, in declaration order.
  final List<String> symbols;
}

/// Module id → repository-relative directory. The longest matching prefix
/// owns a file, so `lib/data/xml/...` belongs to `data.xml`, not to `data`.
const Map<String, String> _modulePaths = {
  'app': 'lib',
  'core': 'lib/core',
  'models': 'lib/models',
  'util': 'lib/util',
  'data': 'lib/data',
  'data.xml': 'lib/data/xml',
  'llm': 'lib/llm',
  'agent': 'lib/agent',
  'agent.tools': 'lib/agent/tools',
  'session': 'lib/session',
  'state': 'lib/state',
  'ui': 'lib/ui',
  'ui.pages': 'lib/ui/pages',
  'ui.widgets': 'lib/ui/widgets',
  'ui.theme': 'lib/ui/theme',
  'pkg.llm_api': 'packages/llm_api/lib',
};

void main(List<String> args) {
  final bool check = args.contains('--check');
  final root = _repoRoot();
  final modules = _scan(root);

  final out = StringBuffer();
  out.writeln('# .memory/MAP.yaml — 由 tool/gen_memory_index.dart 生成，请勿手改。');
  out.writeln('#');
  out.writeln('# 这里只有机器可推导的事实：文件、顶层符号、模块依赖。');
  out.writeln('# 人的判断（职责、风险、注意事项、功能→文件映射）在 ANNOTATIONS.yaml。');
  out.writeln('#');
  out.writeln('# 生成方式: dart run tool/gen_memory_index.dart');
  out.write(_emit(modules, root));

  final target = File('$root/.memory/MAP.yaml');
  if (check) {
    if (!target.existsSync()) {
      stderr.writeln('MISSING .memory/MAP.yaml — 运行: dart run tool/gen_memory_index.dart');
      exit(1);
    }
    if (_stripVolatile(target.readAsStringSync()) != _stripVolatile(out.toString())) {
      stderr.writeln('STALE .memory/MAP.yaml — 代码已变，运行: dart run tool/gen_memory_index.dart');
      exit(1);
    }
    stdout.writeln('OK .memory/MAP.yaml 与代码一致');
    return;
  }
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(out.toString());
  stdout.writeln('wrote .memory/MAP.yaml  '
      '(${modules.length} modules, '
      '${modules.fold<int>(0, (int a, Module m) => a + m.files.length)} files, '
      '${modules.fold<int>(0, (int a, Module m) => a + m.lines)} lines)');
}

/// Drops the two volatile meta fields, so `--check` reports *code* drift only
/// (a new timestamp or a new commit is not a stale map).
String _stripVolatile(String text) => text
    .split('\n')
    .where((String l) => !l.startsWith('  generated_at:') && !l.startsWith('  git_sha:'))
    .join('\n');

// ---------------------------------------------------------------- scanning

String _repoRoot() {
  final dir = Directory.current;
  if (dir.path.endsWith('/tool')) return dir.parent.path;
  return dir.path;
}

/// The module that owns [rel] — the one with the longest matching prefix.
String? _ownerOf(String rel) {
  String? best;
  int bestLen = -1;
  for (final entry in _modulePaths.entries) {
    final p = entry.value;
    final owns = rel == '$p.dart' || rel.startsWith('$p/');
    if (owns && p.length > bestLen) {
      best = entry.key;
      bestLen = p.length;
    }
  }
  return best;
}

List<Module> _scan(String root) {
  final modules = <String, Module>{
    for (final e in _modulePaths.entries) e.key: Module(e.key, e.value),
  };

  // 1) Collect every Dart file and assign it to its owning module.
  final sources = <String, String>{}; // rel path -> absolute path
  for (final base in ['lib', 'packages/llm_api/lib']) {
    final dir = Directory('$root/$base');
    if (!dir.existsSync()) continue;
    for (final f in dir.listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.dart')) {
        final rel = f.path.substring(root.length + 1);
        sources[rel] = f.path;
      }
    }
  }

  for (final rel in sources.keys.toList()..sort()) {
    final owner = _ownerOf(rel);
    if (owner == null) continue;
    modules[owner]!.files.add(_readFile(rel, sources[rel]!));
  }

  // Drop modules that ended up empty (e.g. `lib/ui` only holds sub-directories).
  modules.removeWhere((String _, Module m) => m.files.isEmpty);

  // 2) Dependency edges from the project's own imports.
  for (final m in modules.values) {
    for (final f in m.files) {
      final text = File('$root/${f.path}').readAsStringSync();
      final dir = f.path.substring(0, f.path.lastIndexOf('/'));
      for (final imp in _imports(text, dir)) {
        final target = imp.startsWith('package:llm_api/')
            ? 'pkg.llm_api'
            : _ownerOf(imp);
        if (target == null || target == m.id) continue;
        m.deps.add(target);
      }
    }
  }

  final out = modules.values.toList()
    ..sort((Module a, Module b) => a.id.compareTo(b.id));
  return out;
}

/// Resolves the project's own imports to repository-relative paths.
List<String> _imports(String text, String dirOfFile) {
  final out = <String>[];
  final re = RegExp(r"""import\s+'([^']+)'""");
  for (final m in re.allMatches(text)) {
    final spec = m.group(1)!;
    if (spec.startsWith('package:xchat/')) {
      out.add('lib/${spec.substring('package:xchat/'.length)}');
    } else if (spec.startsWith('package:llm_api/')) {
      out.add(spec);
    } else if (spec.startsWith('.')) {
      // Relative import: resolved against the importing file's directory.
      out.add(_normalize('$dirOfFile/$spec'));
    }
  }
  return out;
}

/// POSIX-style path normalisation, without pulling in `package:path`.
String _normalize(String p) {
  final out = <String>[];
  for (final part in p.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(part);
    }
  }
  return out.join('/');
}

SourceFile _readFile(String rel, String abs) {
  final text = File(abs).readAsStringSync();
  final lines = '\n'.allMatches(text).length + (text.endsWith('\n') ? 0 : 1);
  return SourceFile(rel, lines, _fileDoc(text), _symbols(text));
}

/// The first `///` line of the leading doc comment, before any import.
String _fileDoc(String text) {
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('import ') || line.startsWith('export ')) break;
    if (line.startsWith('//')) {
      final body = line.replaceFirst(RegExp(r'^///?\s*'), '').trim();
      if (body.isNotEmpty) return body;
    }
  }
  return '';
}

/// Top-level declarations. Dart style puts class members at an indent, so a
/// column-0 match is a top-level declaration.
List<String> _symbols(String text) {
  final out = <String>[];
  final typeRe = RegExp(
      r'^(?:abstract\s+|sealed\s+|base\s+|final\s+|interface\s+|mixin\s+)*'
      r'(class|enum|mixin|extension|typedef)\s+([A-Za-z_]\w*)');
  final funcRe = RegExp(r'^([A-Za-z_][\w<>,\s\?\.\[\]]{0,40}?)\s'
      r'([a-z_]\w*)\s*(?:<[^>]*>)?\([^)]*\)\s*(?:async\s*)?\{');

  for (final raw in text.split('\n')) {
    if (raw.isEmpty || raw.startsWith(' ')) continue;
    final t = typeRe.firstMatch(raw);
    if (t != null) {
      final name = t.group(2)!;
      if (name.startsWith('_')) continue; // private API is not part of the map
      if (!out.contains(name)) out.add(name);
      continue;
    }
    final f = funcRe.firstMatch(raw);
    if (f != null) {
      final name = f.group(2)!;
      if (name == 'main' || name.startsWith('_')) continue;
      if (!out.contains(name)) out.add(name);
    }
  }
  return out;
}

// ---------------------------------------------------------------- emitting

String _emit(List<Module> modules, String root) {
  final b = StringBuffer();
  final totalFiles = modules.fold<int>(0, (int a, Module m) => a + m.files.length);
  final totalLines = modules.fold<int>(0, (int a, Module m) => a + m.lines);

  b.writeln('meta:');
  b.writeln('  generated_at: ${_q(_now())}');
  b.writeln('  git_sha: ${_q(_gitSha(root))}');
  b.writeln('  generator: ${_q('tool/gen_memory_index.dart')}');
  b.writeln('  module_count: ${modules.length}');
  b.writeln('  file_count: $totalFiles');
  b.writeln('  line_count: $totalLines');
  b.writeln();
  b.writeln('modules:');
  for (final m in modules) {
    b.writeln('  - id: ${_q(m.id)}');
    b.writeln('    path: ${_q(m.path)}');
    b.writeln('    lines: ${m.lines}');
    b.writeln('    deps: ${_flow(m.deps.toList()..sort())}');
    b.writeln('    files:');
    for (final f in m.files) {
      b.writeln('      - path: ${_q(f.path)}');
      b.writeln('        lines: ${f.lines}');
      if (f.doc.isNotEmpty) b.writeln('        doc: ${_q(f.doc)}');
      if (f.symbols.isNotEmpty) {
        b.writeln('        symbols: ${_flow(f.symbols)}');
      }
    }
  }

  b.writeln();
  b.writeln('tests:');
  for (final t in _tests(root)) {
    b.writeln('  - path: ${_q(t.path)}');
    b.writeln('    lines: ${t.lines}');
    b.writeln('    cases: ${t.cases}');
  }
  return b.toString();
}

class _TestInfo {
  _TestInfo(this.path, this.lines, this.cases);
  final String path;
  final int lines;
  final int cases;
}

List<_TestInfo> _tests(String root) {
  final dir = Directory('$root/test');
  if (!dir.existsSync()) return const [];
  final out = <_TestInfo>[];
  final files = dir.listSync(recursive: true).whereType<File>().toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final f in files) {
    if (!f.path.endsWith('.dart')) continue;
    final text = f.readAsStringSync();
    final rel = f.path.substring(root.length + 1);
    final cases = RegExp(r'\b(?:test|testWidgets)\s*\(').allMatches(text).length;
    out.add(_TestInfo(rel, '\n'.allMatches(text).length + 1, cases));
  }
  return out;
}

String _flow(List<String> items) =>
    items.isEmpty ? '[]' : '[${items.map(_q).join(', ')}]';

/// YAML double-quoted scalar (always quoted: paths may contain `:` or `#`).
String _q(String s) {
  final escaped = s
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\n', ' ')
      .replaceAll('\t', ' ');
  return '"$escaped"';
}

String _now() {
  final d = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String _gitSha(String root) {
  try {
    final r = Process.runSync('git', ['rev-parse', '--short', 'HEAD'],
        workingDirectory: root);
    final out = (r.stdout as String).trim();
    return out.isEmpty ? 'unknown' : out;
  } catch (_) {
    return 'unknown';
  }
}
