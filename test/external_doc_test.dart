import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/external_doc_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/state/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ExternalDocRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xchat_external');
    // cacheDir 给空串：不依赖 path_provider 插件，且视为「非临时副本」。
    repo = ExternalDocRepository(cacheDir: '');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File writeFile(String relative, String content) {
    final file = File('${tmp.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  group('目录扫描', () {
    setUp(() {
      writeFile('docs/a.md', '# a\n');
      writeFile('docs/b.markdown', '# b\n');
      writeFile('docs/notes.txt', 'x');
      writeFile('docs/.hidden.md', 'x');
      writeFile('docs/.git/c.md', 'x');
      writeFile('docs/sub/d.md', '# d\n');
      writeFile('docs/sub/deep/e.md', '# e\n');
      writeFile('docs/sub/deep/deeper/f.md', '# f\n');
    });

    test('递归列出 md，跳过隐藏项与非 md', () async {
      final scan = await repo.scanDirectory('${tmp.path}/docs');
      expect(scan.error, isNull);
      expect(
        scan.files.map((e) => e.name).toList(),
        <String>['a.md', 'b.markdown', 'd.md', 'e.md', 'f.md'],
      );
      final d = scan.files.firstWhere((e) => e.name == 'd.md');
      expect(d.relativeDir, 'sub');
      expect(scan.files.firstWhere((e) => e.name == 'a.md').relativeDir, '');
      expect(scan.truncated, isFalse);
    });

    test('maxDepth 限制下潜层数', () async {
      final scan = await repo.scanDirectory('${tmp.path}/docs', maxDepth: 0);
      expect(scan.files.map((e) => e.name), <String>['a.md', 'b.markdown']);
    });

    test('maxFiles 命中上限时标记 truncated', () async {
      final scan = await repo.scanDirectory('${tmp.path}/docs', maxFiles: 2);
      expect(scan.files.length, 2);
      expect(scan.truncated, isTrue);
    });

    test('目录不存在时给出 error 而不是抛异常', () async {
      final scan = await repo.scanDirectory('${tmp.path}/nope');
      expect(scan.error, '目录不存在');
      expect(scan.files, isEmpty);
    });

    test('notesDir 内的文件标记为本机笔记', () async {
      final scan = await repo.scanDirectory(
        '${tmp.path}/docs',
        notesDir: '${tmp.path}/docs/sub',
      );
      expect(
        scan.files.firstWhere((e) => e.name == 'd.md').isInternalNote,
        isTrue,
      );
      expect(
        scan.files.firstWhere((e) => e.name == 'a.md').isInternalNote,
        isFalse,
      );
    });
  });

  group('读取', () {
    test('普通文件：正文逐字读入、可写', () async {
      final file = writeFile('x.md', '# 标题\n\n正文\n');
      final doc = await repo.read(file.path);
      expect(doc.ok, isTrue);
      expect(doc.body, '# 标题\n\n正文\n');
      expect(doc.crlf, isFalse);
      expect(doc.bom, isFalse);
      expect(doc.writable, isTrue);
      expect(doc.loadedMtime, isNotNull);
    });

    test('CRLF 文件：行尾规范成 LF，并记下 crlf', () async {
      final file = writeFile('crlf.md', 'a\r\nb\r\n');
      final doc = await repo.read(file.path);
      expect(doc.crlf, isTrue);
      expect(doc.body, 'a\nb\n');
    });

    test('带 BOM 的文件：剥离 BOM 并记下 bom', () async {
      final file = File('${tmp.path}/bom.md')
        ..writeAsBytesSync(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode('# bom\n')]);
      final doc = await repo.read(file.path);
      expect(doc.bom, isTrue);
      expect(doc.body, '# bom\n');
    });

    test('疑似二进制（含 NUL）：拒绝预览且不可写', () async {
      final file = File('${tmp.path}/bin.md')
        ..writeAsBytesSync(<int>[0x61, 0x00, 0x62]);
      final doc = await repo.read(file.path);
      expect(doc.ok, isFalse);
      expect(doc.loadError, '看起来不是文本文件');
      expect(doc.writable, isFalse);
    });

    test('文件不存在：loadError 而不是抛异常', () async {
      final doc = await repo.read('${tmp.path}/missing.md');
      expect(doc.ok, isFalse);
      expect(doc.loadError, '文件不存在');
    });

    test('缓存目录内的路径（系统选择器的副本）标记为不可写', () async {
      final cache = Directory('${tmp.path}/cache')..createSync();
      final file = File('${cache.path}/copy.md')..writeAsStringSync('# c\n');
      final copyRepo = ExternalDocRepository(cacheDir: cache.path);
      final doc = await copyRepo.read(file.path);
      expect(doc.writable, isFalse);
    });
  });

  group('写回', () {
    test('逐字写回、不加 front-matter、不留 .tmp', () async {
      final file = writeFile('w.md', 'old\n');
      final doc = await repo.read(file.path);
      await repo.write(doc, '# 新内容\n\n第二段\n');
      expect(file.readAsStringSync(), '# 新内容\n\n第二段\n');
      expect(file.readAsStringSync().startsWith('---'), isFalse);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      expect(doc.body, '# 新内容\n\n第二段\n');
    });

    test('CRLF 文件写回仍是 CRLF', () async {
      final file = writeFile('w2.md', 'a\r\nb\r\n');
      final doc = await repo.read(file.path);
      await repo.write(doc, 'c\nd\n');
      expect(file.readAsStringSync(), 'c\r\nd\r\n');
    });

    test('BOM 文件写回仍带 BOM', () async {
      final file = File('${tmp.path}/w3.md')
        ..writeAsBytesSync(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode('a\n')]);
      final doc = await repo.read(file.path);
      await repo.write(doc, 'b\n');
      final bytes = file.readAsBytesSync();
      expect(bytes.sublist(0, 3), <int>[0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(bytes.sublist(3)), 'b\n');
    });

    test('写回后刷新 mtime（外部改动检测的基线）', () async {
      final file = writeFile('w4.md', 'a\n');
      final doc = await repo.read(file.path);
      final before = doc.loadedMtime;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await repo.write(doc, 'b\n');
      expect(doc.loadedMtime, isNotNull);
      expect(doc.loadedMtime!.isBefore(before!), isFalse);
      expect(doc.sizeBytes, file.lengthSync());
    });
  });

  group('AppState 集成', () {
    late AppState state;

    Future<AppState> buildState() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final paths = await AppPaths.init(overrideRoot: tmp.path);
      final index = IndexRepository(paths);
      final app = AppState(
        paths: paths,
        configRepository: ConfigRepository(paths),
        sessionRepository: SessionRepository(paths, index),
        templateRepository: TemplateRepository(paths),
        projectRepository: ProjectRepository(paths, index),
        indexRepository: index,
        externalDocRepository: ExternalDocRepository(cacheDir: ''),
      );
      await app.load();
      return app;
    }

    setUp(() async {
      state = await buildState();
    });

    test('打开 / 刷新 / 关闭目录，目录写进 prefs', () async {
      writeFile('docs/a.md', '# a\n');
      await state.openExternalRoot('${tmp.path}/docs');
      expect(state.externalRoot, isNotNull);
      expect(state.externalFiles.map((e) => e.name), <String>['a.md']);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('notes_external_root'), state.externalRoot);

      writeFile('docs/b.md', '# b\n');
      await state.refreshExternalRoot();
      expect(state.externalFiles.length, 2);

      await state.closeExternalRoot();
      expect(state.externalRoot, isNull);
      expect(state.externalFiles, isEmpty);
      expect(prefs.getString('notes_external_root'), isNull);
    });

    test('启动时恢复上次的目录（loadExternalState）', () async {
      writeFile('docs/a.md', '# a\n');
      final prefsDir = '${tmp.path}/docs';
      final restored = await buildState();
      // 模拟「上次退出时开着这个目录」。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'notes_external_root': prefsDir,
      });
      await restored.loadExternalState();
      expect(restored.externalRoot, prefsDir);
      expect(restored.externalFiles.single.name, 'a.md');
    });

    test('内部笔记目录里的文件按笔记打开（同一文件两个真相）', () async {
      final note = await state.createNote(title: '我的笔记');
      final path = state.paths.noteFile(note.id);
      expect(state.internalNoteIdForPath(path), note.id);
      expect(state.internalNoteIdForPath('${tmp.path}/docs/a.md'), isNull);
    });

    test('读写外部文件：保存成功 / 文件被删后 exists=false', () async {
      final file = writeFile('docs/a.md', '# a\n');
      final doc = await state.readExternalDoc(file.path);
      final ok = await state.saveExternalDoc(doc, '# 改过\n');
      expect(ok, isTrue);
      expect(file.readAsStringSync(), '# 改过\n');
      expect(await state.externalDocExists(file.path), isTrue);

      file.deleteSync();
      expect(await state.externalDocExists(file.path), isFalse);
      expect(await state.externalDocModifiedAt(file.path), isNull);
    });
  });
}
