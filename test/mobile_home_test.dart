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
  final tmp = Directory.systemTemp.createTempSync('xchat_mobile_home');
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

Future<void> pumpHome(WidgetTester tester, AppState state) async {
  useViewSize(tester, const Size(400, 800));
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(theme: testTheme(), home: HomePage()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('窄屏默认落在首页（桌面同款欢迎页内容）', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    // 底部选中「首页」。
    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, 0);

    // 桌面欢迎页的核心内容都在：问候语 + 输入框 + 专长 badge。
    expect(find.byKey(const Key('welcome-input')), findsOneWidget);
    expect(find.textContaining('接下来交给我吧'), findsOneWidget);
    expect(find.byKey(const Key('expertise-badge-programming')), findsOneWidget);
    // 顶行保留常用入口。
    expect(find.byTooltip('新建会话'), findsOneWidget);
    expect(find.byTooltip('模板'), findsOneWidget);
    expect(find.byTooltip('更多'), findsOneWidget);
  });

  testWidgets('会话列表里点「回到首页」切回首页', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    await tester.tap(find.text('会话'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome-input')), findsNothing);

    await tester.tap(find.byTooltip('回到首页'));
    await tester.pumpAndSettle();

    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(nav.selectedIndex, 0);
    expect(find.byKey(const Key('welcome-input')), findsOneWidget);
  });

  testWidgets('首页发送后压栈进移动端聊天页', (tester) async {
    final state = (await tester.runAsync(buildState))!;
    await pumpHome(tester, state);

    await tester.tap(find.byKey(const Key('expertise-badge-programming')));
    await tester.pump();
    final input = find.descendant(
      of: find.byKey(const Key('welcome-input')),
      matching: find.byType(TextField),
    );
    await tester.enterText(input, '你好');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));

    final opened = await pumpUntilFound(
      tester,
      find.byType(SessionChatPanel),
    );
    expect(opened, isTrue);
    expect(state.sessions, hasLength(1));
  });
}
