import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xchat/core/memory_protocol.dart';
import 'package:xchat/data/memory_repository.dart';

/// The `.memory/` index lives inside the project sandbox and is initialised
/// non-destructively (the agent's own notes are never overwritten).
void main() {
  const repository = MemoryRepository();

  late Directory sandbox;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('xchat_memory');
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('the index directory is .memory inside the sandbox', () {
    expect(repository.memoryDir(sandbox.path), p.join(sandbox.path, '.memory'));
  });

  test('ensureSkeleton writes the six index files', () async {
    final ok = await repository.ensureSkeleton(sandbox.path, projectName: 'P1');
    expect(ok, isTrue);

    final dir = Directory(repository.memoryDir(sandbox.path));
    expect(dir.existsSync(), isTrue);
    final names = dir
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toSet();
    expect(names, kMemoryFileNames.toSet());
  });

  test('ensureSkeleton is non-destructive', () async {
    await repository.ensureSkeleton(sandbox.path);
    final state = File(p.join(repository.memoryDir(sandbox.path), 'STATE.md'));
    await state.writeAsString('手写的内容');
    // A file the agent owns must survive a re-initialisation.
    await repository.ensureSkeleton(sandbox.path);
    expect(state.readAsStringSync(), '手写的内容');
  });

  test('ensureSkeleton fills in missing files only', () async {
    await repository.ensureSkeleton(sandbox.path);
    final map = File(p.join(repository.memoryDir(sandbox.path), 'MAP.yaml'));
    await map.delete();
    await repository.ensureSkeleton(sandbox.path);
    expect(map.existsSync(), isTrue);
  });

  test('an empty sandbox is rejected', () async {
    expect(await repository.ensureSkeleton(''), isFalse);
    expect(repository.exists(''), isFalse);
  });

  test('status reports a missing index', () async {
    final status = await repository.status(sandbox.path);
    expect(status.exists, isFalse);
    expect(status.files, isEmpty);
    expect(status.summary, '未初始化');
  });

  test('status lists the files and the last modification time', () async {
    await repository.ensureSkeleton(sandbox.path);
    final status = await repository.status(sandbox.path);
    expect(status.exists, isTrue);
    expect(status.files.toSet(), kMemoryFileNames.toSet());
    expect(status.isIncomplete, isFalse);
    expect(status.lastModified, isNotNull);
    expect(status.summary, contains('已初始化'));
  });

  test('status reports an incomplete index', () async {
    await repository.ensureSkeleton(sandbox.path);
    File(p.join(repository.memoryDir(sandbox.path), 'MAP.yaml')).deleteSync();
    final status = await repository.status(sandbox.path);
    expect(status.exists, isTrue);
    expect(status.isIncomplete, isTrue);
  });

  test('exists() follows the directory', () async {
    expect(repository.exists(sandbox.path), isFalse);
    await repository.ensureSkeleton(sandbox.path);
    expect(repository.exists(sandbox.path), isTrue);
  });
}
