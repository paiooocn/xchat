import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/agent/tools/file_ops.dart';
import 'package:xchat/agent/tools/path_guard.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('xchat-fileops');
  });

  tearDown(() async {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  File write(String name, String content) {
    final file = File('${sandbox.path}/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    return file;
  }

  group('mv_file', () {
    test('重命名文件', () async {
      write('a.txt', 'hello');
      final tool = buildMvFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'source': 'a.txt', 'destination': 'b.txt'})}';
      expect(result, contains('OK: moved'));
      expect(File('${sandbox.path}/b.txt').existsSync(), isTrue);
      expect(File('${sandbox.path}/a.txt').existsSync(), isFalse);
    });

    test('移动到已存在的目录', () async {
      write('a.txt', 'hello');
      Directory('${sandbox.path}/sub').createSync();
      final tool = buildMvFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'source': 'a.txt', 'destination': 'sub'})}';
      expect(result, contains('OK: moved'));
      expect(File('${sandbox.path}/sub/a.txt').existsSync(), isTrue);
    });

    test('目标已存在且未指定 overwrite 时报错', () async {
      write('a.txt', 'A');
      write('b.txt', 'B');
      final tool = buildMvFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'source': 'a.txt', 'destination': 'b.txt'})}';
      expect(result, contains('ERROR'));
      expect(File('${sandbox.path}/b.txt').readAsStringSync(), 'B');
    });

    test('overwrite=true 覆盖目标文件', () async {
      write('a.txt', 'A');
      write('b.txt', 'B');
      final tool = buildMvFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({
        'source': 'a.txt',
        'destination': 'b.txt',
        'overwrite': true,
      })}';
      expect(result, contains('OK: moved'));
      expect(File('${sandbox.path}/b.txt').readAsStringSync(), 'A');
    });

    test('源不存在时报错', () async {
      final tool = buildMvFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'source': 'nope.txt', 'destination': 'x.txt'})}';
      expect(result, contains('ERROR'));
    });

    test('拒绝移出沙箱', () async {
      write('a.txt', 'hello');
      final tool = buildMvFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'source': 'a.txt', 'destination': '../out.txt'})}';
      expect(result, contains('ERROR'));
    });

    test('移动目录', () async {
      write('dir/a.txt', 'x');
      final tool = buildMvFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'source': 'dir', 'destination': 'dir2'})}';
      expect(result, contains('OK: moved'));
      expect(File('${sandbox.path}/dir2/a.txt').existsSync(), isTrue);
    });
  });

  group('grep_file', () {
    test('匹配内容并给出行号', () async {
      write('a.txt', 'line1\nfoo target\nline3');
      write('b.py', 'nothing here');
      final tool = buildGrepFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'pattern': 'target'})}';
      expect(result, contains('a.txt:2:'));
      expect(result, contains('1 match(es)'));
      expect(result, isNot(contains('b.py')));
    });

    test('glob 过滤文件', () async {
      write('a.txt', 'target');
      write('b.py', 'target');
      final tool = buildGrepFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'pattern': 'target', 'glob': '**/*.py'})}';
      expect(result, contains('b.py:1:'));
      expect(result, isNot(contains('a.txt')));
    });

    test('regex=false 时按普通文本匹配', () async {
      write('a.txt', 'a.b\naxb');
      final tool = buildGrepFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'pattern': 'a.b', 'regex': false})}';
      expect(result, contains('1 match(es)'));
    });

    test('大小写不敏感', () async {
      write('a.txt', 'Target');
      final tool = buildGrepFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({
        'pattern': 'target',
        'case_sensitive': false,
      })}';
      expect(result, contains('1 match(es)'));
    });

    test('上下文行以 - 标记', () async {
      write('a.txt', 'l1\nl2\ntarget\nl4\nl5');
      final tool = buildGrepFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'pattern': 'target', 'context': 1})}';
      expect(result, contains('a.txt:2-'));
      expect(result, contains('a.txt:3:'));
      expect(result, contains('a.txt:4-'));
    });

    test('非法正则返回错误', () async {
      final tool = buildGrepFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'pattern': '('})}';
      expect(result, contains('ERROR'));
    });

    test('无匹配时返回提示', () async {
      write('a.txt', 'hello');
      final tool = buildGrepFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'pattern': 'zzz'})}';
      expect(result, contains('No matches'));
    });

    test('跳过二进制文件', () async {
      File('${sandbox.path}/bin.dat').writeAsBytesSync([1, 0, 2, 3]);
      write('a.txt', 'target');
      final tool = buildGrepFileTool(PathGuard(sandbox.path));
      final result = '${await tool.call({'pattern': 'target'})}';
      expect(result, contains('1 match(es)'));
      expect(result, isNot(contains('bin.dat')));
    });
  });
}
