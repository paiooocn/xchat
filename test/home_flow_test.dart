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
import 'package:xchat/models/session_message.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/home_page.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_home');
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
  final project = await state.createProject(name: 'P1');
  final session = await state.createSession(projectId: project.id);
  session.messages.add(SessionMessage(role: MessageRole.user, id: 'u1', content: 'hello-user'));
  session.messages.add(SessionMessage(role: MessageRole.assistant, id: 'a1', content: 'hello-assistant'));
  await state.sessionRepository.write(session);
  await state.refreshSessions();
  return state;
}

Future<void> pumpHome(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(value: state, child: const MaterialApp(home: HomePage())),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('desktop: opening a project session shows its history', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async => state = await buildState());
    await pumpHome(tester, state);

    // Project sessions are nested under their project (no filter step needed).
    expect(find.text('P1'), findsWidgets);
    // Projects start collapsed — expand first.
    await tester.tap(find.text('P1').first);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('(未命名会话)').first);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SessionChatPanel), findsOneWidget);
    expect(find.text('hello-user'), findsOneWidget);
    expect(find.text('hello-assistant'), findsOneWidget);
  });

  testWidgets('mobile: opening a project session shows its history', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async => state = await buildState());
    await pumpHome(tester, state);

    // Projects start collapsed — expand first.
    await tester.tap(find.text('P1').first);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('(未命名会话)').first);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SessionChatPanel), findsOneWidget);
    expect(find.text('hello-user'), findsOneWidget);
  });
}
