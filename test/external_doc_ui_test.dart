import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/external_doc_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/models/external_doc.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/notes_panel.dart';
import 'package:xchat/ui/widgets/note_list.dart';

import 'helpers/test_theme.dart';

late Directory tmp;

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tmp = Directory.systemTemp.createTempSync('xchat_external_ui');
  final paths = await AppPaths.init(overrideRoot: tmp.path);
  final index = IndexRepository(paths);
  final state = AppState(
    paths: paths,
    configRepository: ConfigRepository(paths),
    sessionRepository: SessionRepository(paths, index),
    templateRepository: TemplateRepository(paths),
    projectRepository: ProjectRepository(paths, index),
    indexRepository: index,
    externalDocRepository: ExternalDocRepository(cacheDir: ''),
  );
  await state.load();
  return state;
}

File writeFile(String relative, String content) {
  final file = File('${tmp.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  return file;
}

/// 让假时钟与真实事件循环交替推进（读取/保存是真实 I/O，见 GOTCHAS §14）。
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

Future<void> pumpNoteList(
  WidgetTester tester, {
  String? externalRoot,
  List<ExternalMdEntry> externalFiles = const <ExternalMdEntry>[],
  String? externalFilePath,
  ValueChanged<String>? onOpenExternal,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme(),
      home: Scaffold(
        body: NoteList(
          notes: const [],
          archivedNotes: const [],
          selectedId: null,
          onSelect: (_) {},
          externalRoot: externalRoot,
          externalFiles: externalFiles,
          externalFilePath: externalFilePath,
          onOpenExternal: onOpenExternal,
          onPickExternalFile: () {},
          onPickExternalDirectory: () {},
          onRefreshExternal: () {},
          onCloseExternalRoot: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> pumpPanel(WidgetTester tester, AppState state, String path) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: NotesPanel(externalPath: path),
        ),
      ),
    ),
  );
  await pumpAsync(tester, rounds: 30);
}

Finder editorField() => find.descendant(
      of: find.byKey(const Key('note-editor')),
      matching: find.byType(TextField),
    );

void main() {
  group('侧栏外部文件区', () {
    testWidgets('未打开目录时给两行入口', (tester) async {
      await tester.runAsync(buildState);
      await pumpNoteList(tester);
      expect(find.text('外部文件'), findsOneWidget);
      expect(find.text('打开 md 文件…'), findsOneWidget);
      expect(find.text('打开文件夹…'), findsOneWidget);
    });

    testWidgets('打开目录后逐条列出 md，点击回调路径', (tester) async {
      await tester.runAsync(buildState);
      final entries = <ExternalMdEntry>[
        ExternalMdEntry(path: '/d/a.md', name: 'a.md'),
        ExternalMdEntry(
          path: '/d/sub/b.md',
          name: 'b.md',
          relativeDir: 'sub',
        ),
      ];
      String? opened;
      await pumpNoteList(
        tester,
        externalRoot: '/d',
        externalFiles: entries,
        onOpenExternal: (path) => opened = path,
      );
      expect(find.text('d'), findsOneWidget); // 目录名
      expect(find.text('2 个 md'), findsOneWidget);
      expect(find.text('a.md'), findsOneWidget);
      expect(find.text('sub'), findsOneWidget);
      await tester.tap(find.text('b.md'));
      expect(opened, '/d/sub/b.md');
    });

    testWidgets('单独打开的文件不在目录内时多显示一行', (tester) async {
      await tester.runAsync(buildState);
      await pumpNoteList(
        tester,
        externalRoot: '/d',
        externalFiles: <ExternalMdEntry>[
          ExternalMdEntry(path: '/d/a.md', name: 'a.md'),
        ],
        externalFilePath: '/other/draft.md',
        onOpenExternal: (_) {},
      );
      expect(find.text('draft.md'), findsOneWidget);
    });

    testWidgets('没有笔记时外部区仍可见（软空态不替换整列）', (tester) async {
      await tester.runAsync(buildState);
      await pumpNoteList(tester, externalRoot: '/d');
      expect(find.text('外部文件'), findsOneWidget);
      expect(find.text('该目录下没有 md 文件'), findsOneWidget);
      expect(find.text('还没有笔记'), findsOneWidget);
    });
  });

  group('外部文件主区（默认只读）', () {
    testWidgets('打开即只读：无输入框、有只读徽标与开启编辑', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      final file = writeFile('docs/a.md', '# 标题\n\n正文\n');
      await pumpPanel(tester, state, file.path);

      expect(find.text('a.md'), findsOneWidget);
      expect(find.text('只读'), findsWidgets); // 顶栏徽标 + 状态条
      expect(find.text('开启编辑'), findsOneWidget);
      expect(editorField(), findsNothing);
      // 预览渲染了 Markdown 标题。
      expect(find.textContaining('正文'), findsWidgets);
      expect(file.readAsStringSync(), '# 标题\n\n正文\n');
    });

    testWidgets('开启编辑需确认；确认后出现输入框，改动写回原文件', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      final file = writeFile('docs/b.md', '# 原标题\n');
      await pumpPanel(tester, state, file.path);

      await tester.tap(find.text('开启编辑'));
      await tester.pumpAndSettle();
      expect(find.text('改动会直接写入原文件，可能覆盖其他工具（如 VSCode / Typora）的修改。\n\n${file.path}'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '开启编辑'));
      await tester.pumpAndSettle();
      expect(editorField(), findsOneWidget);
      expect(find.text('编辑中'), findsOneWidget);

      await tester.enterText(editorField(), '# 已修改\n');
      await pumpAsync(tester);
      expect(file.readAsStringSync(), '# 已修改\n');
      expect(file.readAsStringSync().startsWith('---'), isFalse);
    });

    testWidgets('取消确认则保持只读、不写盘', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      final file = writeFile('docs/c.md', '# 原文\n');
      await pumpPanel(tester, state, file.path);

      await tester.tap(find.text('开启编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(editorField(), findsNothing);
      expect(find.text('只读'), findsWidgets);
      expect(file.readAsStringSync(), '# 原文\n');
    });

    testWidgets('文件过大时不预览，给出提示', (tester) async {
      final state = (await tester.runAsync(buildState))!;
      final file = File('${tmp.path}/big.md')
        ..writeAsStringSync('x' * (kExternalDocMaxBytes + 1));
      await pumpPanel(tester, state, file.path);
      expect(find.textContaining('文件过大'), findsOneWidget);
      expect(editorField(), findsNothing);
      expect(find.text('用外部编辑器打开'), findsOneWidget);
    });
  });
}
