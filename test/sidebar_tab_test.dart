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
import 'helpers/test_theme.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final tmp = Directory.systemTemp.createTempSync('xchat_sidebar_tab');
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

/// 宽屏（>= 820）才能同时看到侧栏与主区。
Future<void> pumpHome(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(theme: testTheme(), home: HomePage()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// 让假时钟与真实事件循环交替推进，直到 [finder] 命中或超时。
///
/// 笔记的落盘是真实 I/O：只在 `runAsync` 里才会推进（GOTCHAS §14）。
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
  testWidgets('侧栏有「会话」「笔记」两个 Tab', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    expect(find.text('会话'), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);
  });

  testWidgets('点「笔记」Tab：主区切到笔记视图，左栏出现笔记列表', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();

    // 主区：笔记面板占位。
    expect(find.text('选择或新建一篇笔记'), findsOneWidget);
    // 左栏：笔记列表占位（空态）。
    expect(find.text('还没有笔记'), findsOneWidget);
    // 会话树不再显示。
    expect(find.text('全局会话'), findsNothing);
  });

  testWidgets('侧栏不再有「新建会话」文字行', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    expect(find.text('新建会话'), findsNothing);
  });

  testWidgets('顶行：刷新与新建按钮都在，新建在刷新右侧', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    final refresh = find.byTooltip('刷新会话列表');
    final create = find.byTooltip('新建会话');
    expect(refresh, findsOneWidget);
    expect(create, findsOneWidget);

    final refreshX = tester.getCenter(refresh).dx;
    final createX = tester.getCenter(create).dx;
    expect(createX, greaterThan(refreshX));
  });

  testWidgets('笔记 Tab：刷新/新建按钮换成笔记语义', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('刷新笔记列表'), findsOneWidget);
    expect(find.byTooltip('新建笔记'), findsOneWidget);
    expect(find.byTooltip('刷新会话列表'), findsNothing);
  });

  testWidgets('笔记 Tab 的「＋新建」建一篇笔记并打开', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('新建笔记'));
    final opened =
        await pumpUntilFound(tester, find.byKey(const Key('note-editor')));
    expect(opened, isTrue);
    expect(state.notes.length, 1);
  });
}
