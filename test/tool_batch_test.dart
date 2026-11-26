import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llm_api/llm_api.dart' as llm;
import 'package:xchat/agent/tools/builtin_tools.dart';
import 'package:xchat/agent/tools/file_ops.dart';
import 'package:xchat/agent/tools/image_attach.dart';

void main() {
  late Directory sandbox;
  late List<llm.LlmTool> tools;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('xchat-batch');
    tools = BuiltinTools.build(
      sandbox: sandbox.path,
      enabled: ['read_file', 'write_file', 'edit_file', 'mv_file'],
    );
  });

  tearDown(() async {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  File write(String name, String content) => File('${sandbox.path}/$name')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  Future<String> call(String name, Map<String, Object?> args) async =>
      '${await tools.firstWhere((t) => t.name == name).call(args)}';

  group('read_file 批量', () {
    test('paths 多文件分节返回并带 summary', () async {
      write('a.txt', 'AAA');
      write('b.txt', 'BBB');
      final result = await call('read_file', {
        'paths': ['a.txt', 'b.txt'],
      });
      expect(result, contains('=== a.txt ==='));
      expect(result, contains('AAA'));
      expect(result, contains('=== b.txt ==='));
      expect(result, contains('BBB'));
      expect(result, contains('summary: 2 ok, 0 failed, 0 skipped'));
    });

    test('单项 path 保持旧行为（不加分节）', () async {
      write('a.txt', 'AAA');
      final result = await call('read_file', {'path': 'a.txt'});
      expect(result, 'AAA');
    });

    test('超过批量上限直接报错', () async {
      final paths = <String>[for (var i = 0; i < kToolMaxBatchItems + 1; i++) 'f$i.txt'];
      final result = await call('read_file', {'paths': paths});
      expect(result, contains('ERROR'));
      expect(result, contains('$kToolMaxBatchItems'));
    });

    test('单文件缺失时该项失败、其余照读', () async {
      write('a.txt', 'AAA');
      final result = await call('read_file', {
        'paths': ['a.txt', 'missing.txt'],
      });
      expect(result, contains('ERROR: file not found'));
      expect(result, contains('1 ok, 1 failed'));
    });

    test('start_line / end_line 分页并给出续读参数', () async {
      write('a.txt', List<String>.generate(10, (i) => 'line${i + 1}').join('\n'));
      final result = await call('read_file', {
        'path': 'a.txt',
        'start_line': 3,
        'end_line': 4,
      });
      expect(result, startsWith('line3\nline4'));
      expect(result, contains('共 10 行'));
      expect(result, contains('start_line=5'));
    });

    test('批量时不接受分页参数', () async {
      write('a.txt', 'AAA');
      write('b.txt', 'BBB');
      final result = await call('read_file', {
        'paths': ['a.txt', 'b.txt'],
        'start_line': 1,
      });
      expect(result, contains('ERROR'));
      expect(result, contains('只支持单文件'));
    });

    test('max_chars 是每文件上限', () async {
      write('a.txt', 'x' * 50);
      write('b.txt', 'y' * 50);
      final result = await call('read_file', {
        'paths': ['a.txt', 'b.txt'],
        'max_chars': 10,
      });
      expect(result, contains('已截断 40 字符'));
    });

    test('超出总预算的文件标记 SKIPPED', () async {
      write('a.txt', 'x' * 100);
      write('b.txt', 'y' * 100);
      final result = await call('read_file', {
        'paths': ['a.txt', 'b.txt'],
        'max_total_chars': 120,
      });
      expect(result, contains('SKIPPED'));
      expect(result, contains('1 skipped'));
    });
  });

  group('write_file 批量', () {
    test('files 多文件逐项写入', () async {
      final result = await call('write_file', {
        'files': [
          {'path': 'a.txt', 'content': 'AAA'},
          {'path': 'sub/b.txt', 'content': 'BBB'},
        ],
      });
      expect(result, contains('=== a.txt ==='));
      expect(result, contains('OK: wrote a.txt (3 chars)'));
      expect(File('${sandbox.path}/sub/b.txt').readAsStringSync(), 'BBB');
      expect(result, contains('summary: 2 ok'));
    });

    test('单项 path + content 保持旧行为', () async {
      final result = await call('write_file', {'path': 'a.txt', 'content': 'AAA'});
      expect(result, startsWith('OK: wrote'));
      expect(File('${sandbox.path}/a.txt').readAsStringSync(), 'AAA');
    });
  });

  group('edit_file 批量', () {
    test('同一文件的多项编辑按顺序生效', () async {
      write('a.txt', 'apple pie\nbanana');
      final result = await call('edit_file', {
        'edits': [
          {'path': 'a.txt', 'old_string': 'apple', 'new_string': 'cherry'},
          {'path': 'a.txt', 'old_string': 'banana', 'new_string': 'date'},
        ],
      });
      expect(File('${sandbox.path}/a.txt').readAsStringSync(), 'cherry pie\ndate');
      expect(result, contains('2 ok'));
    });

    test('单项失败不影响其余项', () async {
      write('a.txt', 'AAA');
      write('b.txt', 'BBB');
      final result = await call('edit_file', {
        'edits': [
          {'path': 'a.txt', 'old_string': 'AAA', 'new_string': 'ZZZ'},
          {'path': 'b.txt', 'old_string': 'nope', 'new_string': 'ZZZ'},
        ],
      });
      expect(File('${sandbox.path}/a.txt').readAsStringSync(), 'ZZZ');
      expect(result, contains('old_string not found'));
      expect(result, contains('1 ok, 1 failed'));
    });

    test('单项 path + old_string + new_string 保持旧行为', () async {
      write('a.txt', 'hello world');
      final result = await call('edit_file', {
        'path': 'a.txt',
        'old_string': 'world',
        'new_string': 'there',
      });
      expect(result, 'OK: replaced 1 occurrence(s)');
    });
  });

  group('mv_file 批量', () {
    test('moves 多文件逐项移动', () async {
      write('a.txt', 'A');
      write('b.txt', 'B');
      final result = await call('mv_file', {
        'moves': [
          {'source': 'a.txt', 'destination': 'a2.txt'},
          {'source': 'b.txt', 'destination': 'b2.txt'},
        ],
      });
      expect(File('${sandbox.path}/a2.txt').existsSync(), isTrue);
      expect(File('${sandbox.path}/b2.txt').existsSync(), isTrue);
      expect(result, contains('2 ok'));
    });

    test('单项失败不影响其余项', () async {
      write('a.txt', 'A');
      final result = await call('mv_file', {
        'moves': [
          {'source': 'nope.txt', 'destination': 'x.txt'},
          {'source': 'a.txt', 'destination': 'a2.txt'},
        ],
      });
      expect(File('${sandbox.path}/a2.txt').existsSync(), isTrue);
      expect(result, contains('source not found'));
      expect(result, contains('1 ok, 1 failed'));
    });
  });

  group('toolImagePaths', () {
    test('批量 paths 里的图片被逐张收集', () {
      final paths = toolImagePaths(
        'read_file',
        '{"paths":["shot.png","notes.txt","other.jpg"]}',
      );
      expect(paths, ['shot.png', 'other.jpg']);
    });

    test('单项 path 仍然识别', () {
      expect(toolImagePaths('read_file', '{"path":"a.webp"}'), ['a.webp']);
      expect(toolImagePaths('read_file', '{"path":"a.txt"}'), isEmpty);
    });

    test('非图片工具不收集', () {
      expect(toolImagePaths('write_file', '{"path":"a.png"}'), isEmpty);
    });
  });

  group('ToolRegistry 结果上限', () {
    test('per-tool 覆盖生效，其余沿用默认', () async {
      final registry = llm.ToolRegistry([
        llm.FunctionTool(
          name: 'read_file',
          description: '',
          handler: (_) => 'x' * 30000,
        ),
        llm.FunctionTool(
          name: 'shell',
          description: '',
          handler: (_) => 'y' * 30000,
        ),
      ])
        ..resultCharacterLimits['read_file'] = kReadFileMaxResultChars;

      final big = await registry.invoke(
        const llm.ToolCall(id: '1', name: 'read_file', arguments: '{}'),
      );
      expect(big.content.length, 30000);

      final small = await registry.invoke(
        const llm.ToolCall(id: '2', name: 'shell', arguments: '{}'),
      );
      expect(small.content, contains('[truncated'));
    });
  });
}
