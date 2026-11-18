import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
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
import 'package:xchat/ui/widgets/note_list.dart';

import 'helpers/test_theme.dart';

Future<AppPaths> makePaths() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final tmp = Directory.systemTemp.createTempSync('xchat_note_folder');
  return AppPaths.init(overrideRoot: tmp.path);
}

Future<AppState> buildState() async {
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
  return state;
}

Note sampleNote({
  String id = 'n1',
  String title = '会议纪要',
  String folder = '',
  List<String> tags = const <String>[],
  String body = '# 正文\n\n第一段。\n',
}) =>
    Note(
      id: id,
      title: title,
      tags: tags,
      createdAt: DateTime.utc(2026, 11, 4, 9, 12, 33),
      updatedAt: DateTime.utc(2026, 11, 4, 10, 2, 11),
      folder: folder,
      body: body,
    );

/// 让假时钟与真实事件循环交替推进（保存是真实 I/O，见 GOTCHAS §14）。
Future<void> pumpAsync(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 50),
  int rounds = 60,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

/// 轮询到 [condition] 成立（保存走真实磁盘 I/O，见 GOTCHAS §14）。
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int rounds = 200,
}) async {
  for (var i = 0; i < rounds && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

/// 弹层里的输入框（列表顶部还有一个搜索框，不能用 `.last`）。
Finder dialogField() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );

Future<void> pumpList(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      // 与 HomePage 一样由 AppState 驱动重建（列表是构造参数，不会自己刷新）。
      child: MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: state,
            builder: (context, _) => NoteList(
              notes: state.notes,
              archivedNotes: state.archivedNotes,
              selectedId: null,
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await pumpAsync(tester, rounds: 20);
}

void main() {
  group('front-matter', () {
    test('folder 往返；空值不写这一行（旧文件字节不变）', () {
      final encoded = encodeNote(sampleNote(folder: '会议'));
      expect(encoded.contains('folder: 会议'), isTrue);

      final decoded = decodeNote(encoded, fallbackId: 'n1');
      expect(decoded.folder, '会议');

      final bare = encodeNote(sampleNote());
      expect(bare.contains('folder:'), isFalse);
      expect(decodeNote(bare, fallbackId: 'n1').folder, '');
    });

    test('旧文件（没有 folder）读出空串；与未知 key 共存', () {
      const raw = '---\nid: abc\ntitle: 旧笔记\n---\n\n正文\n';
      final decoded = decodeNote(raw, fallbackId: 'abc');
      expect(decoded.folder, '');

      final note = sampleNote(folder: '读书')
        ..extra['author'] = '张三';
      final round = decodeNote(encodeNote(note), fallbackId: 'n1');
      expect(round.folder, '读书');
      expect(round.extra['author'], '张三');
    });
  });

  group('索引', () {
    test('写入/扫描都带 folder；旧索引（无 folder）能读且为空', () async {
      final paths = await makePaths();
      final index = IndexRepository(paths);
      final repo = NoteRepository(paths, index);
      await repo.write(sampleNote(id: 'f1', folder: '会议'));

      final entry =
          (jsonDecode(await File(paths.indexFile).readAsString())
              as Map<String, Object?>)['notes'] as List;
      expect((entry.first as Map<String, Object?>)['folder'], '会议');

      // 磁盘扫描（模拟索引重建）也带 folder。
      final rebuilt = await IndexRepository(paths).rebuild();
      expect(rebuilt.notes.first.folder, '会议');

      // 把索引里的 folder 抹掉，模拟升级前的旧索引：仍能加载，值为空。
      final file = File(paths.indexFile);
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      (json['notes'] as List).first['folder'] = null;
      await file.writeAsString(jsonEncode(json));
      final oldIndex = await IndexRepository(paths).load();
      expect(oldIndex.notes.first.toSummary().folder, '');
    });
  });

  group('AppState', () {
    test('noteFolders / setNoteFolder / rename / clear', () async {
      final state = await buildState();
      final a = await state.createNote(title: 'A');
      final b = await state.createNote(title: 'B');
      expect(state.noteFolders, isEmpty);

      await state.setNoteFolder(a.id, '会议');
      expect(state.noteFolders, ['会议']);
      expect(state.notes.firstWhere((n) => n.id == a.id).folder, '会议');

      await state.setNoteFolder(b.id, '会议');
      expect(state.noteFolders, ['会议']);

      // 改名：笔记跟着走，旧名消失。
      await state.renameNoteFolder('会议', '项目A');
      expect(state.noteFolders, ['项目A']);
      expect(state.notes.firstWhere((n) => n.id == b.id).folder, '项目A');

      // 清空：笔记保留、全部移出。
      await state.clearNoteFolder('项目A');
      expect(state.noteFolders, isEmpty);
      expect(state.notes.length, 2);
      expect(state.notes.every((n) => n.folder.isEmpty), isTrue);
    });

    test('移出收纳箱 = 传空名', () async {
      final state = await buildState();
      final a = await state.createNote(title: 'A');
      await state.setNoteFolder(a.id, '临时');
      await state.setNoteFolder(a.id, '');
      expect(state.noteFolders, isEmpty);
      expect(state.notes.single.folder, '');
    });
  });

  group('NoteList UI', () {
    testWidgets('未归箱进「笔记」段；归箱后进收纳箱段（一篇只出现一次）', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      await tester.runAsync(() => state.createNote(title: '普通笔记'));
      final boxed =
          (await tester.runAsync(() => state.createNote(title: '箱内笔记')))!;
      await tester.runAsync(() => state.setNoteFolder(boxed.id, '会议'));

      await pumpList(tester, state);

      expect(find.text('笔记'), findsOneWidget);
      expect(find.text('会议'), findsOneWidget);
      expect(find.text('普通笔记'), findsOneWidget);
      expect(find.text('箱内笔记'), findsOneWidget);
      // 顶部不再有「最近」段。
      expect(find.text('最近'), findsNothing);
    });

    testWidgets('点收纳箱标题折叠/展开，状态持久化', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      final note =
          (await tester.runAsync(() => state.createNote(title: '箱内笔记')))!;
      await tester.runAsync(() => state.setNoteFolder(note.id, '会议'));
      await pumpList(tester, state);

      await tester.tap(find.text('会议'));
      await pumpAsync(tester, rounds: 20);
      expect(find.text('箱内笔记'), findsNothing);

      final prefs = (await tester.runAsync(
        () => SharedPreferences.getInstance(),
      ))!;
      expect(prefs.getStringList('notes_folders_collapsed'), ['会议']);

      await tester.tap(find.text('会议'));
      await pumpAsync(tester, rounds: 20);
      expect(find.text('箱内笔记'), findsOneWidget);
    });

    testWidgets('行菜单「收纳箱…」→ 输入新名字 → 笔记进箱', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      final pending =
          (await tester.runAsync(() => state.createNote(title: '待归箱')))!;
      await pumpList(tester, state);

      await tester.tap(find.byTooltip('笔记操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收纳箱…'));
      await tester.pumpAndSettle();

      await tester.enterText(dialogField(), '读书');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await pumpUntil(tester, () => state.noteFolders.contains('读书'));

      expect(state.noteFolders, ['读书']);
      expect(
        state.notes.firstWhere((n) => n.id == pending.id).folder,
        '读书',
      );
      expect(find.text('待归箱'), findsOneWidget);
    });

    testWidgets('收纳箱菜单：重命名后笔记跟着走', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      final boxed =
          (await tester.runAsync(() => state.createNote(title: '箱内笔记')))!;
      await tester.runAsync(() => state.setNoteFolder(boxed.id, '会议'));
      await pumpList(tester, state);

      await tester.tap(find.byTooltip('收纳箱操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名收纳箱'));
      await tester.pumpAndSettle();

      await tester.enterText(dialogField(), '项目A');
      // 按钮的可用状态由 ValueListenableBuilder 驱动，先重建一帧再点。
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await pumpUntil(tester, () => state.noteFolders.contains('项目A'));

      expect(state.noteFolders, ['项目A']);
      expect(find.text('项目A'), findsOneWidget);
      expect(find.text('会议'), findsNothing);
    });
  });
}
