import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/tools/file_tools.dart';
import 'package:xchat/tools/path_guard.dart';

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('ft_');
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  group('FileTools.writeFile', () {
    test('顶层文件写入', () {
      FileTools.writeFile(sandbox.path, 'a.txt', 'hello');
      expect(File('${sandbox.path}/a.txt').existsSync(), true);
      expect(File('${sandbox.path}/a.txt').readAsStringSync(), 'hello');
    });

    test('修复 #1:深层嵌套路径自动创建父目录', () {
      FileTools.writeFile(sandbox.path, 'src/lib/utils/x.dart', 'code');
      expect(File('${sandbox.path}/src/lib/utils/x.dart').existsSync(), true);
      expect(File('${sandbox.path}/src/lib/utils/x.dart').readAsStringSync(), 'code');
    });

    test('修复 #2:中间已存在的目录也能写入', () {
      Directory('${sandbox.path}/a').createSync();
      FileTools.writeFile(sandbox.path, 'a/b/c.txt', 'data');
      expect(File('${sandbox.path}/a/b/c.txt').existsSync(), true);
    });

    test('覆盖已存在文件', () {
      FileTools.writeFile(sandbox.path, 'a.txt', 'v1');
      FileTools.writeFile(sandbox.path, 'a.txt', 'v2');
      expect(File('${sandbox.path}/a.txt').readAsStringSync(), 'v2');
    });

    test('越界路径抛 PathEscapeError', () {
      expect(
        () => FileTools.writeFile(sandbox.path, '../escape.txt', 'x'),
        throwsA(isA<PathEscapeError>()),
      );
    });
  });

  group('FileTools.readFile', () {
    test('读取已存在文件', () {
      FileTools.writeFile(sandbox.path, 'a.txt', 'content');
      expect(FileTools.readFile(sandbox.path, 'a.txt'), 'content');
    });

    test('修复 #3:文件不存在返回明确 ERROR 而不是抛异常', () {
      final r = FileTools.readFile(sandbox.path, 'no.txt');
      expect(r, startsWith('ERROR: file_not_found:'));
    });
  });

  group('FileTools.editFile', () {
    test('编辑已存在文件', () {
      FileTools.writeFile(sandbox.path, 'a.txt', 'hello world');
      FileTools.editFile(sandbox.path, 'a.txt', 'world', 'dart');
      expect(File('${sandbox.path}/a.txt').readAsStringSync(), 'hello dart');
    });

    test('allOccurrences 全部替换', () {
      FileTools.writeFile(sandbox.path, 'a.txt', 'a-a-a');
      FileTools.editFile(sandbox.path, 'a.txt', 'a', 'b', allOccurrences: true);
      expect(File('${sandbox.path}/a.txt').readAsStringSync(), 'b-b-b');
    });

    test('修复 #4:目标文件不存在时降级为 write_file(创建新文件)', () {
      FileTools.editFile(sandbox.path, 'new/nested/file.txt', 'placeholder', 'actual content');
      expect(File('${sandbox.path}/new/nested/file.txt').existsSync(), true);
      expect(File('${sandbox.path}/new/nested/file.txt').readAsStringSync(), 'actual content');
    });
  });

  group('FileTools.listDir', () {
    test('列目录', () {
      FileTools.writeFile(sandbox.path, 'a.txt', 'x');
      Directory('${sandbox.path}/sub').createSync();
      final r = FileTools.listDir(sandbox.path, '.');
      expect(r, contains('a.txt'));
      expect(r, contains('sub'));
    });

    test('修复 #5:目录不存在返回明确 ERROR', () {
      final r = FileTools.listDir(sandbox.path, 'no_such_dir');
      expect(r, startsWith('ERROR: directory_not_found:'));
    });
  });

  group('FileTools.glob', () {
    test('顶层 *.txt 匹配', () {
      FileTools.writeFile(sandbox.path, 'a.txt', 'x');
      FileTools.writeFile(sandbox.path, 'b.md', 'y');
      expect(FileTools.glob(sandbox.path, '*.txt'), contains('a.txt'));
    });

    test('** 递归匹配', () {
      FileTools.writeFile(sandbox.path, 'a/b/c.txt', 'z');
      final r = FileTools.glob(sandbox.path, 'a/**/*.txt');
      expect(r, contains('c.txt'));
    });

    test('修复 #6:glob 在嵌套不存在目录时不抛异常', () {
      final r = FileTools.glob(sandbox.path, 'no/dir/*.txt');
      expect(r, '');
    });
  });

  group('FileTools.grep', () {
    test('递归搜索', () {
      FileTools.writeFile(sandbox.path, 'a.txt', 'hello\nworld\nhello again');
      final r = FileTools.grep(sandbox.path, 'hello');
      expect(r, contains('a.txt:1:hello'));
      expect(r, contains('a.txt:3:hello again'));
    });

    test('ignoreCase', () {
      FileTools.writeFile(sandbox.path, 'a.txt', 'Hello');
      expect(FileTools.grep(sandbox.path, 'hello', ignoreCase: true), contains('Hello'));
      expect(FileTools.grep(sandbox.path, 'hello', ignoreCase: false), '(no matches)');
    });

    test('修复 #7:目录不存在返回 ERROR', () {
      final r = FileTools.grep(sandbox.path, 'x', path: 'no_dir');
      expect(r, startsWith('ERROR: directory_not_found:'));
    });

    test('无匹配返回 (no matches) 而非空字符串', () {
      FileTools.writeFile(sandbox.path, 'a.txt', 'hello');
      expect(FileTools.grep(sandbox.path, 'zzzzzz'), '(no matches)');
    });
  });
}
