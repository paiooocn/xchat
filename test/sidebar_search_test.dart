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
  final tmp = Directory.systemTemp.createTempSync('xchat_sidebar_search');
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

  final alpha = await state.createProject(name: 'Alpha');
  final beta = await state.createProject(name: 'Beta');
  await state.setProjectTags(alpha.id, <String>['t-alpha']);
  await state.setProjectTags(beta.id, <String>['t-beta']);

  await state.createSession(
    title: 'GlobalOne',
    tags: <String>['t-global'],
  );
  await state.createSession(
    title: 'Inner',
    projectId: alpha.id,
    tags: <String>['t-inner'],
  );
  await state.createSession(
    title: 'Member',
    projectId: beta.id,
    tags: <String>['t-beta'],
  );
  return state;
}

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

Future<void> search(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('sidebar-search')), text);
  await tester.pumpAndSettle();
}

/// 交替推进假时钟与真实事件循环（落盘是真实 I/O，见 GOTCHAS §14）。
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  fail('等待超时：$finder');
}

void main() {
  testWidgets('会话 Tab 有搜索框，标签 badge 展示在会话/项目行上', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    expect(find.byKey(const Key('sidebar-search')), findsOneWidget);
    // 项目名与全局会话标题默认可见。
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('GlobalOne'), findsOneWidget);
    // 标签既在筛选 chips 里，也在项目行 badge 里。
    expect(find.text('t-alpha'), findsWidgets);
    expect(find.text('t-beta'), findsWidgets);
  });

  testWidgets('纯文本搜索项目：只显示命中的项目', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    await search(tester, 'Alpha');
    expect(find.widgetWithText(ExpansionTile, 'Alpha'), findsOneWidget);
    expect(find.widgetWithText(ExpansionTile, 'Beta'), findsNothing);
    expect(find.widgetWithText(ListTile, 'GlobalOne'), findsNothing);
  });

  testWidgets(r'$文本搜索全局会话：只显示命中的全局会话', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    await search(tester, r'$Global');
    expect(find.widgetWithText(ListTile, 'GlobalOne'), findsOneWidget);
    expect(find.widgetWithText(ExpansionTile, 'Alpha'), findsNothing);
    expect(find.widgetWithText(ExpansionTile, 'Beta'), findsNothing);
  });

  testWidgets('#文本搜索标签：项目与会话都按标签过滤', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    await search(tester, '#t-beta');
    expect(find.widgetWithText(ExpansionTile, 'Beta'), findsOneWidget);
    expect(find.widgetWithText(ExpansionTile, 'Alpha'), findsNothing);
    expect(find.widgetWithText(ListTile, 'GlobalOne'), findsNothing);
  });

  testWidgets('点标签 chip 筛选：项目与全局会话都收敛', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    await tester.tap(find.widgetWithText(FilterChip, 't-beta'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ExpansionTile, 'Beta'), findsOneWidget);
    expect(find.widgetWithText(ExpansionTile, 'Alpha'), findsNothing);
    expect(find.widgetWithText(ListTile, 'GlobalOne'), findsNothing);
  });

  testWidgets('项目行「编辑标签」：保存后 badge / chip 更新', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    final tile = find.widgetWithText(ExpansionTile, 'Alpha');
    await tester.tap(
      find.descendant(of: tile, matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑标签'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      't-new',
    );
    await tester.tap(find.text('确定'));
    await pumpUntilFound(tester, find.widgetWithText(FilterChip, 't-new'));

    // 新标签同时出现在筛选 chip 与项目行 badge 上。
    expect(find.widgetWithText(FilterChip, 't-new'), findsOneWidget);
    expect(find.text('t-new'), findsWidgets);
  });
}
