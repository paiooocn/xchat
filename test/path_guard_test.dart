import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xchat/tools/path_guard.dart';

void main() {
  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('xchat_sb_');
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  group('PathGuard.resolve', () {
    test('合法相对路径解析为 sandbox 内绝对路径', () {
      final abs = PathGuard.resolve(sandbox.path, 'foo.txt');
      expect(abs.startsWith(sandbox.path), true);
    });

    test('合法子目录路径 OK', () {
      Directory(p.join(sandbox.path, 'sub')).createSync();
      final abs = PathGuard.resolve(sandbox.path, 'sub/bar.txt');
      expect(abs.startsWith(sandbox.path), true);
      expect(abs.endsWith('sub/bar.txt'), true);
    });

    test('.. 逃逸被拒', () {
      expect(
        () => PathGuard.resolve(sandbox.path, '../etc/passwd'),
        throwsA(isA<PathEscapeError>()),
      );
    });

    test('多层 .. 逃逸被拒', () {
      expect(
        () => PathGuard.resolve(sandbox.path, '../../etc/passwd'),
        throwsA(isA<PathEscapeError>()),
      );
    });

    test('绝对路径在 sandbox 外被拒', () {
      expect(
        () => PathGuard.resolve(sandbox.path, '/etc/passwd'),
        throwsA(isA<PathEscapeError>()),
      );
    });

    test('同名前缀(目录名撞前缀)不被误判', () {
      final sbEvil = Directory('${sandbox.path}_evil')..createSync();
      try {
        expect(
          () => PathGuard.resolve(sandbox.path, '../${p.basename(sbEvil.path)}/foo'),
          throwsA(isA<PathEscapeError>()),
        );
      } finally {
        if (sbEvil.existsSync()) sbEvil.deleteSync(recursive: true);
      }
    });
  });
}
