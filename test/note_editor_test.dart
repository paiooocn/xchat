import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/notes_panel.dart';
import 'package:xchat/ui/widgets/note_editor.dart';

import 'helpers/test_theme.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final tmp = Directory.systemTemp.createTempSync('xchat_note_editor');
  final paths = await AppPaths.init(overrideRoot: tmp.path);
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

/// 让假时钟与真实事件循环交替推进（保存是真实 I/O，见 GOTCHAS §14）。
Future<void> pumpAsync(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 50),
  int rounds = 80,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(step);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
}

Future<void> pumpEditor(
  WidgetTester tester, {
  required String body,
  required ValueChanged<String> onChanged,
  VoidCallback? onSave,
  double ratio = 0.4,
  ValueChanged<double>? onRatio,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme(),
      home: Scaffold(
        body: NoteEditor(
          body: body,
          onChanged: onChanged,
          onSave: onSave ?? () {},
          splitRatio: ratio,
          onSplitRatioChanged: onRatio ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('NoteEditor', () {
    testWidgets('预览渲染 Markdown（标题可见）', (tester) async {
      await pumpEditor(
        tester,
        body: '# 会议纪要\n\n正文一段。\n',
        onChanged: (_) {},
      );

      expect(find.text('会议纪要'), findsOneWidget);
      expect(find.text('正文一段。'), findsOneWidget);
    });

    testWidgets('40% 档：编辑区可见；0% 档：编辑区收起', (tester) async {
      await pumpEditor(
        tester,
        body: '# 标题\n',
        onChanged: (_) {},
        ratio: 0.4,
      );
      expect(find.byType(TextField), findsOneWidget);

      await pumpEditor(
        tester,
        body: '# 标题\n',
        onChanged: (_) {},
        ratio: 0,
      );
      expect(find.byType(TextField), findsNothing);
      // 预览仍然在。
      expect(find.text('标题'), findsOneWidget);
    });

    testWidgets('分隔条拖动后吸附到最近档位', (tester) async {
      double? ratio;
      await pumpEditor(
        tester,
        body: 'x\n',
        onChanged: (_) {},
        ratio: 0.4,
        onRatio: (value) => ratio = value,
      );

      final splitter = find.byKey(const Key('note-splitter'));
      expect(splitter, findsOneWidget);

      // 往下拖 ~100px（总高约 600）→ 0.4 - 0.17 ≈ 0.23 → 吸附到 0.2。
      await tester.drag(splitter, const Offset(0, 100));
      await tester.pump();
      expect(ratio, isNotNull);
      expect(noteSplitRatios.contains(ratio), isTrue);
      expect(ratio, closeTo(0.2, 0.001));
    });

    testWidgets('工具栏「粗体」把选区包成 **…**', (tester) async {
      final changes = <String>[];
      await pumpEditor(
        tester,
        body: 'hello',
        onChanged: changes.add,
      );

      final editable = tester.widget<EditableText>(find.byType(EditableText));
      editable.controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();

      await tester.tap(find.byTooltip('粗体'));
      await tester.pump();

      expect(changes, isNotEmpty);
      expect(changes.last, '**hello**');
    });

    testWidgets('工具栏无选区时插入片段（表格骨架）', (tester) async {
      final changes = <String>[];
      await pumpEditor(tester, body: '', onChanged: changes.add);

      await tester.tap(find.byTooltip('表格'));
      await tester.pump();

      expect(changes.last, contains('| 列 1 |'));
    });
  });

  group('NotesPanel', () {
    testWidgets('改源码 → 停写 800ms 后自动落盘', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      final note = (await tester.runAsync(() => state.createNote(title: '测试')))!;
      final file = File(state.paths.noteFile(note.id));

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: testTheme(),
            home: NotesPanel(noteId: note.id),
          ),
        ),
      );
      await pumpAsync(tester, rounds: 10);

      // 编辑区里的输入框（AI 边栏里也有一个 TextField，别混了）。
      final editorField = find.descendant(
        of: find.byKey(const Key('note-editor')),
        matching: find.byType(TextField),
      );
      expect(editorField, findsOneWidget);

      await tester.enterText(editorField, '# 新内容\n');
      await tester.pump();

      // 假时钟推进 800ms 触发防抖保存，再让真实 I/O 跑完。
      await pumpAsync(tester, rounds: 80);

      final saved = await tester.runAsync(() => file.readAsString());
      expect(saved, contains('# 新内容'));
    });

    testWidgets('档位切换写入 SharedPreferences（40/20/0）', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      final note = (await tester.runAsync(() => state.createNote(title: '测试')))!;

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: testTheme(),
            home: NotesPanel(noteId: note.id),
          ),
        ),
      );
      await pumpAsync(tester, rounds: 10);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('notes_editor_split_ratio'), '40');

      await tester.tap(find.text('20%'));
      await pumpAsync(tester, rounds: 10);
      expect(prefs.getString('notes_editor_split_ratio'), '20');

      await tester.tap(find.text('收起'));
      await pumpAsync(tester, rounds: 10);
      expect(prefs.getString('notes_editor_split_ratio'), '0');
      // 0% 档：编辑区收起（AI 边栏的输入框仍在，所以要限定在编辑区里找）。
      expect(
        find.descendant(
          of: find.byKey(const Key('note-editor')),
          matching: find.byType(TextField),
        ),
        findsNothing,
      );
    });
  });
}
