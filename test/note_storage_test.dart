import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/note_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/data/xml/note_md.dart';
import 'package:xchat/models/note.dart';
import 'package:xchat/state/app_state.dart';

Future<AppPaths> makePaths() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final tmp = Directory.systemTemp.createTempSync('xchat_notes');
  return AppPaths.init(overrideRoot: tmp.path);
}

Note sampleNote({
  String id = 'n1',
  String title = '会议纪要 · 2026-11-04',
  List<String> tags = const <String>['会议', '项目A'],
  String body = '# 正文从这里开始\n\n第一段。\n\n```dart\nvoid main() {}\n```\n',
}) {
  final created = DateTime.utc(2026, 11, 4, 9, 12, 33);
  return Note(
    id: id,
    title: title,
    tags: tags,
    createdAt: created,
    updatedAt: DateTime.utc(2026, 11, 4, 10, 2, 11),
    pinned: true,
    body: body,
  );
}

void main() {
  group('front-matter 往返', () {
    test('字段全等、正文逐字相等', () {
      final note = sampleNote();
      final decoded = decodeNote(encodeNote(note), fallbackId: 'fallback');
      expect(decoded.id, note.id);
      expect(decoded.title, note.title);
      expect(decoded.tags, note.tags);
      expect(decoded.createdAt.toUtc(), note.createdAt);
      expect(decoded.updatedAt.toUtc(), note.updatedAt);
      expect(decoded.pinned, isTrue);
      expect(decoded.archivedAt, isNull);
      expect(decoded.body, note.body);
    });

    test('正文里的空行与缩进原样保留', () {
      const body = '第一行\n\n    缩进代码\n\n\n末尾空行\n\n';
      final note = sampleNote(body: body);
      final decoded = decodeNote(encodeNote(note), fallbackId: 'n');
      expect(decoded.body, body);
    });

    test('未知 key 原样保留', () {
      final note = sampleNote()..extra['author'] = '张三';
      note.extra['custom'] = 'value';
      final decoded = decodeNote(encodeNote(note), fallbackId: 'n');
      expect(decoded.extra['author'], '张三');
      expect(decoded.extra['custom'], 'value');
      // 未知 key 不影响已知字段。
      expect(decoded.title, note.title);
      expect(decoded.body, note.body);
    });

    test('缺 key 走默认（归档为空 / 未置顶 / 标题取正文首个标题）', () {
      const raw = '---\nid: abc\n---\n\n# 正文标题\n\n内容\n';
      final decoded = decodeNote(raw, fallbackId: 'abc');
      expect(decoded.pinned, isFalse);
      expect(decoded.archivedAt, isNull);
      expect(decoded.tags, isEmpty);
      expect(decoded.title, '正文标题');
      expect(decoded.body, '# 正文标题\n\n内容\n');
    });

    test('裸 Markdown 可导入（补齐头部）', () {
      const raw = '# 我的笔记\n\n随便写点什么\n';
      final decoded = decodeNote(raw, fallbackId: 'file-id');
      expect(decoded.id, 'file-id');
      expect(decoded.title, '我的笔记');
      expect(decoded.body, raw);
      // 再写回去就有头部了。
      final written = encodeNote(decoded);
      expect(written.startsWith('---\n'), isTrue);
      expect(written.contains('id: file-id'), isTrue);
    });

    test('归档时间可读写', () {
      final archived = DateTime.utc(2026, 11, 5, 8, 0, 0);
      final note = sampleNote()..archivedAt = archived;
      final decoded = decodeNote(encodeNote(note), fallbackId: 'n');
      expect(decoded.archivedAt, isNotNull);
      expect(decoded.archivedAt!.toUtc(), archived);
      expect(decoded.archived, isTrue);
    });
  });

  group('仓库读写', () {
    test('新建 / 读取 / 保存 / 归档 / 删除', () async {
      final paths = await makePaths();
      final repo = NoteRepository(paths, IndexRepository(paths));

      final note = sampleNote(id: 'note-1');
      await repo.write(note);

      final read = await repo.read('note-1');
      expect(read.title, note.title);
      expect(read.body, note.body);

      final summaries = await repo.list();
      expect(summaries.map((s) => s.id), contains('note-1'));
      expect(summaries.first.preview, isNotEmpty);

      final archived = read..archivedAt = DateTime.utc(2026, 11, 6);
      await repo.write(archived);
      final after = await repo.list();
      expect(after.firstWhere((s) => s.id == 'note-1').archived, isTrue);

      await repo.delete('note-1');
      expect(await repo.exists('note-1'), isFalse);
      expect((await repo.list()).map((s) => s.id), isNot(contains('note-1')));
    });

    test('原子写：目录里不残留 .tmp', () async {
      final paths = await makePaths();
      final repo = NoteRepository(paths, IndexRepository(paths));
      await repo.write(sampleNote(id: 'note-2'));
      final files = await Directory(paths.notesDir).list().toList();
      expect(files.whereType<File>().map((f) => f.path), isNot(contains(endsWith('.tmp'))));
      expect(files.whereType<File>().length, 1);
    });

    test('摘要扫描只读前 4KB（超长文件不影响列表）', () async {
      final paths = await makePaths();
      final index = IndexRepository(paths);
      final repo = NoteRepository(paths, index);
      final long = '# 长笔记\n\n${'内容行\n' * 20000}';
      final note = Note(
        id: 'note-3',
        title: '长笔记',
        createdAt: DateTime.utc(2026, 11, 4),
        updatedAt: DateTime.utc(2026, 11, 4),
        body: long,
      );
      // 直接落盘（绕过写入路径），强制走索引重建时的头部扫描。
      await File(paths.noteFile('note-3')).writeAsString(encodeNote(note));

      final summaries = await repo.list();
      final summary = summaries.firstWhere((s) => s.id == 'note-3');
      expect(summary.title, '长笔记');
      expect(summary.preview.length, lessThanOrEqualTo(notePreviewLength));
      expect(summary.preview, contains('内容行'));
    });
  });

  group('索引第五桶', () {
    test('index.json 出现 notes 桶，版本为 5', () async {
      final paths = await makePaths();
      final index = IndexRepository(paths);
      final repo = NoteRepository(paths, index);
      await repo.write(sampleNote(id: 'note-4'));

      final raw = jsonDecode(await File(paths.indexFile).readAsString());
      expect(raw['version'], 5);
      expect(raw['notes'], isA<List>());
      expect((raw['notes'] as List).length, 1);
      final entry = (raw['notes'] as List).first as Map<String, Object?>;
      expect(entry['id'], 'note-4');
      expect(entry['title'], '会议纪要 · 2026-11-04');
      expect(entry['tags'], <String>['会议', '项目A']);
      expect(entry['pinned'], isTrue);
      expect(entry['preview'], isA<String>());
      expect(entry.containsKey('body'), isFalse);
    });

    test('旧版本索引（version 4）被丢弃重建', () async {
      final paths = await makePaths();
      final index = IndexRepository(paths);
      final repo = NoteRepository(paths, index);
      await repo.write(sampleNote(id: 'note-5'));

      // 手工把索引退回 version 4（没有 notes 桶）。
      final file = File(paths.indexFile);
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      json['version'] = 4;
      json.remove('notes');
      await file.writeAsString(jsonEncode(json));

      // 用一个没有内存缓存的实例加载（模拟新启动）。
      final fresh = IndexRepository(paths);
      final rebuilt = await fresh.load();
      expect(rebuilt.notes.map((e) => e.id), contains('note-5'));
      final persisted = jsonDecode(await file.readAsString());
      expect(persisted['version'], 5);
    });

    test('索引损坏能重建', () async {
      final paths = await makePaths();
      final index = IndexRepository(paths);
      final repo = NoteRepository(paths, index);
      await repo.write(sampleNote(id: 'note-6'));
      await File(paths.indexFile).writeAsString('{ this is not json');

      final rebuilt = await index.load();
      expect(rebuilt.notes.map((e) => e.id), contains('note-6'));
    });

    test('磁盘上新增的笔记会被校验发现并重建', () async {
      final paths = await makePaths();
      final index = IndexRepository(paths);
      final repo = NoteRepository(paths, index);
      await repo.write(sampleNote(id: 'note-7'));

      // 模拟另一个实例新增了一篇笔记（绕过索引）。
      final extra = Note(
        id: 'note-8',
        title: '外部新增',
        createdAt: DateTime.utc(2026, 11, 7),
        updatedAt: DateTime.utc(2026, 11, 7),
        body: '# 外部新增\n',
      );
      await File(paths.noteFile('note-8')).writeAsString(encodeNote(extra));

      final loaded = await index.load();
      expect(loaded.notes.map((e) => e.id), contains('note-8'));
    });

    test('索引条目 JSON 往返', () {
      final entry = NoteIndexEntry(
        id: 'x',
        title: '标题',
        tags: const <String>['a'],
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        pinned: true,
        archivedAt: DateTime.utc(2026, 1, 3),
        preview: '预览',
      );
      final back = NoteIndexEntry.fromJson(entry.toJson());
      expect(back.id, entry.id);
      expect(back.title, entry.title);
      expect(back.tags, entry.tags);
      expect(back.createdAt.toUtc(), entry.createdAt);
      expect(back.updatedAt.toUtc(), entry.updatedAt);
      expect(back.pinned, isTrue);
      expect(back.archivedAt!.toUtc(), entry.archivedAt!.toUtc());
      expect(back.preview, entry.preview);
    });
  });

  group('AppState 集成', () {
    test('刷新 / 新建 / 保存 / 归档 / 删除', () async {
      final paths = await makePaths();
      final index = IndexRepository(paths);
      final state = AppState(
        paths: paths,
        configRepository: ConfigRepository(paths),
        sessionRepository: SessionRepository(paths, index),
        templateRepository: TemplateRepository(paths),
        projectRepository: ProjectRepository(paths, index),
        indexRepository: index,
      );
      await state.load();
      expect(state.notes, isEmpty);

      final note = await state.createNote(title: '第一篇');
      expect(state.notes.length, 1);
      expect(state.notes.first.title, '第一篇');
      expect(state.archivedNotes, isEmpty);

      note.body = '# 第一篇\n\n正文\n';
      await state.saveNote(note);
      final read = await state.readNote(note.id);
      expect(read?.body, '# 第一篇\n\n正文\n');

      await state.setNoteArchived(note.id, true);
      expect(state.notes, isEmpty);
      expect(state.archivedNotes.length, 1);

      await state.setNoteArchived(note.id, false);
      expect(state.notes.length, 1);
      expect(state.archivedNotes, isEmpty);

      await state.deleteNote(note.id);
      expect(state.notes, isEmpty);
      expect(await File(paths.noteFile(note.id)).exists(), isFalse);
    });
  });
}
