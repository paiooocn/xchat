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
import 'package:xchat/ui/pages/home_page.dart';
import 'package:xchat/ui/pages/notes_panel.dart';
import 'package:xchat/ui/widgets/note_diff_dialog.dart';
import 'helpers/test_theme.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final tmp = Directory.systemTemp.createTempSync('xchat_note_mobile');
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

void useViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 假时钟与真实事件循环交替推进，直到 [finder] 命中或超时。
Future<bool> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}

void main() {
  group('窄屏底部 Tab', () {
    testWidgets('底部只有「会话｜笔记」两个 Tab，侧栏不再有分段 Tab', (tester) async {
      useViewSize(tester, const Size(400, 800));
      final state = (await tester.runAsync(buildState))!;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: testTheme(), home: HomePage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // 底部 Tab 是唯一入口：'会话' / '笔记' 各只出现一次。
      expect(find.text('会话'), findsOneWidget);
      expect(find.text('笔记'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('切到「笔记」Tab 显示笔记列表空态', (tester) async {
      useViewSize(tester, const Size(400, 800));
      final state = (await tester.runAsync(buildState))!;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: testTheme(), home: HomePage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('笔记'));
      await tester.pumpAndSettle();
      expect(find.text('还没有笔记'), findsOneWidget);
    });

    testWidgets('新建笔记 → 压栈进编辑页（带返回按钮）', (tester) async {
      useViewSize(tester, const Size(400, 800));
      final state = (await tester.runAsync(buildState))!;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: testTheme(), home: HomePage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('笔记'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新建笔记'));

      final opened = await pumpUntilFound(
        tester,
        find.byKey(const Key('note-editor')),
      );
      expect(opened, isTrue);
      expect(find.byTooltip('返回笔记列表'), findsOneWidget);
      expect(state.notes.length, 1);
    });
  });

  group('移动端 AI 抽屉', () {
    testWidgets('编辑页的 AI 按钮唤起底部抽屉', (tester) async {
      useViewSize(tester, const Size(400, 800));
      final state = (await tester.runAsync(buildState))!;
      final note = await tester.runAsync(() => state.createNote());
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: testTheme(),
            home: Scaffold(body: NotesPanel(noteId: note!.id, mobile: true)),
          ),
        ),
      );
      // 等笔记正文真正读进编辑器（真实 I/O）。
      final loaded = await pumpUntilFound(
        tester,
        find.byKey(const Key('note-editor')),
      );
      expect(loaded, isTrue);

      await tester.tap(find.byTooltip('AI 助手'));
      await tester.pumpAndSettle();

      // 抽屉里的 AI 面板：三档 Tab + 关闭按钮 + 模型服务入口。
      expect(find.text('改写'), findsOneWidget);
      expect(find.text('生成'), findsOneWidget);
      expect(find.text('问答'), findsOneWidget);
      expect(find.byTooltip('关闭 AI 助手'), findsOneWidget);

      await tester.tap(find.byTooltip('关闭 AI 助手'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭 AI 助手'), findsNothing);
    });
  });

  group('窄窗口 AI 边栏', () {
    testWidgets('窗口 < 1080 时 AI 强制收起成竖轨', (tester) async {
      useViewSize(tester, const Size(900, 800));
      final state = (await tester.runAsync(buildState))!;
      final note = await tester.runAsync(() => state.createNote());
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: testTheme(),
            home: Scaffold(body: NotesPanel(noteId: note!.id)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byTooltip('窗口太窄，AI 边栏已收起'), findsOneWidget);
      expect(find.byTooltip('展开 AI 助手'), findsNothing);
      expect(find.text('改写'), findsNothing);
    });

    testWidgets('窗口 >= 1080 时 AI 边栏默认展开', (tester) async {
      useViewSize(tester, const Size(1400, 900));
      final state = (await tester.runAsync(buildState))!;
      final note = await tester.runAsync(() => state.createNote());
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: testTheme(),
            home: Scaffold(body: NotesPanel(noteId: note!.id)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('改写'), findsOneWidget);
      expect(find.byTooltip('窗口太窄，AI 边栏已收起'), findsNothing);
    });
  });

  group('窄屏 diff 预览', () {
    testWidgets('窄屏走全屏路由，可在其中接受', (tester) async {
      useViewSize(tester, const Size(400, 800));
      bool? answer;
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  answer = await showNoteDiffDialog(
                    context,
                    oldText: '旧内容',
                    newText: '新内容',
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // 全屏路由：没有 Dialog，走 AppBar（关闭 = 拒绝）+ 底部动作条。
      expect(find.byType(Dialog), findsNothing);
      expect(find.byTooltip('拒绝并返回'), findsOneWidget);
      expect(find.text('新内容'), findsOneWidget);

      await tester.tap(find.text('接受并应用'));
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });

    testWidgets('全屏路由的关闭按钮 = 拒绝', (tester) async {
      useViewSize(tester, const Size(400, 800));
      bool? answer;
      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  answer = await showNoteDiffDialog(
                    context,
                    oldText: '旧内容',
                    newText: '新内容',
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('拒绝并返回'));
      await tester.pumpAndSettle();
      expect(answer, isFalse);
    });
  });
}
