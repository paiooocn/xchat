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
import 'package:intl/intl.dart';
import 'package:xchat/models/session_message.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/home_page.dart';
import 'helpers/test_theme.dart';

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
  session.messages.add(SessionMessage(
    role: MessageRole.user,
    id: 'u1',
    content: 'hello-user',
    sentAt: DateTime.utc(2025, 1, 2, 3, 4),
  ));
  session.messages.add(SessionMessage(
    role: MessageRole.assistant,
    id: 'a1',
    content: 'hello-assistant',
    receivedAt: DateTime.utc(2025, 1, 2, 3, 5, 30),
  ));
  await state.sessionRepository.write(session);
  await state.refreshSessions();
  return state;
}

Future<void> pumpHome(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(value: state, child: MaterialApp(theme: testTheme(), home: HomePage())),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// Pumps until [finder] matches, letting the real (non-fake) async work of the
/// page finish in between.
///
/// Opening a session reads it from disk (`_openSession` → `reloadSession`).
/// Widget tests only let that I/O progress inside [WidgetTester.runAsync], so
/// a fixed number of pumps made these tests fail on a loaded machine (the
/// panel was simply not there yet).
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
    await tester.tap(find.text('(未命名会话)').first);
    await pumpUntilFound(tester, find.byType(SessionChatPanel));
    await pumpUntilFound(tester, find.text('hello-user'));
    expect(find.byType(SessionChatPanel), findsOneWidget);
    expect(find.text('hello-user'), findsOneWidget);
    expect(find.text('hello-assistant'), findsOneWidget);

    // 对话卡底部：user 发送时间、assistant 接收时间 + 本轮耗时。
    final minute = DateFormat('yyyy-MM-dd HH:mm');
    expect(
      find.textContaining('发送 ${minute.format(DateTime.utc(2025, 1, 2, 3, 4).toLocal())}'),
      findsOneWidget,
    );
    expect(
      find.textContaining('接收 ${minute.format(DateTime.utc(2025, 1, 2, 3, 5, 30).toLocal())}'),
      findsOneWidget,
    );
    expect(find.textContaining('本轮耗时'), findsOneWidget);
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
    await tester.tap(find.text('(未命名会话)').first);
    await pumpUntilFound(tester, find.byType(SessionChatPanel));
    await pumpUntilFound(tester, find.text('hello-user'));
    expect(find.byType(SessionChatPanel), findsOneWidget);
    expect(find.text('hello-user'), findsOneWidget);
  });
}
