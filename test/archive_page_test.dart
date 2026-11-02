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
import 'package:xchat/ui/pages/archive_page.dart';

/// Builds an app state on a temporary data root.
///
/// Everything that touches the disk must run inside [WidgetTester.runAsync] —
/// the widget-test clock is fake, so real file I/O never completes outside it.
Future<AppState> buildState(WidgetTester tester) async {
  final state = await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    final tmp = Directory.systemTemp.createTempSync('xchat_archive_page');
    final paths = await AppPaths.init(overrideRoot: tmp.path);
    final index = IndexRepository(paths);
    final appState = AppState(
      paths: paths,
      configRepository: ConfigRepository(paths),
      sessionRepository: SessionRepository(paths, index),
      templateRepository: TemplateRepository(paths),
      projectRepository: ProjectRepository(paths, index),
      indexRepository: index,
    );
    await appState.load();
    return appState;
  });
  return state!;
}

/// Pumps until [condition] holds, letting the real event loop run in between
/// (the disk writes triggered by a button tap need it).
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  fail('等待超时');
}

Future<void> pumpArchive(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: ArchivePage()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('the two tabs are named 归档·全局 / 归档·项目', (tester) async {
    final state = await buildState(tester);
    await pumpArchive(tester, state);

    expect(find.text('归档·全局'), findsOneWidget);
    expect(find.text('归档·项目'), findsOneWidget);
  });

  testWidgets('the global tab only lists global archived sessions',
      (tester) async {
    final state = await buildState(tester);
    await tester.runAsync(() async {
      final global = await state.createSession(title: '全局会话');
      final project = await state.createProject(name: 'P1');
      final inProject =
          await state.createSession(projectId: project.id, title: '项目会话');
      await state.setSessionArchived(global.id, true);
      await state.setSessionArchived(inProject.id, true);
    });
    await pumpArchive(tester, state);

    expect(find.text('全局会话'), findsOneWidget);
    expect(find.text('项目会话'), findsNothing);
  });

  testWidgets('the project tab shows the project, its badge and its sessions',
      (tester) async {
    final state = await buildState(tester);
    await tester.runAsync(() async {
      final project = await state.createProject(name: 'P1');
      await state.createSession(projectId: project.id, title: '项目会话');
      await state.setProjectArchived(project.id, true);
    });
    await pumpArchive(tester, state);

    await tester.tap(find.text('归档·项目'));
    await tester.pumpAndSettle();

    expect(find.text('P1'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    // The project entry starts collapsed → the session is not visible yet.
    expect(find.text('项目会话'), findsNothing);

    await tester.tap(find.text('P1'));
    await tester.pumpAndSettle();
    expect(find.text('项目会话'), findsOneWidget);
  });

  testWidgets('a partly archived project shows the 部分 badge', (tester) async {
    final state = await buildState(tester);
    await tester.runAsync(() async {
      final project = await state.createProject(name: 'P1');
      final archived =
          await state.createSession(projectId: project.id, title: '已归档');
      await state.createSession(projectId: project.id, title: '还活跃');
      await state.setSessionArchived(archived.id, true);
    });
    await pumpArchive(tester, state);

    await tester.tap(find.text('归档·项目'));
    await tester.pumpAndSettle();

    expect(find.text('部分'), findsOneWidget);
    expect(find.text('全部'), findsNothing);
  });

  testWidgets('deleting a project asks twice and then removes it',
      (tester) async {
    final state = await buildState(tester);
    late String projectId;
    await tester.runAsync(() async {
      final project = await state.createProject(name: 'P1');
      projectId = project.id;
      await state.createSession(projectId: project.id, title: '项目会话');
      await state.setProjectArchived(project.id, true);
    });
    await pumpArchive(tester, state);

    await tester.tap(find.text('归档·项目'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('删除项目'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除项目'), findsOneWidget);
    expect(find.textContaining('个会话会一并删除'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.projectById(projectId), isNotNull);

    await tester.tap(find.byTooltip('删除项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('再次确认'), findsOneWidget);

    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    await pumpUntil(tester, () => state.projectById(projectId) == null);
    expect(state.sessions.where((s) => s.projectId == projectId), isEmpty);
  });

  testWidgets('a session can be restored from the project tab',
      (tester) async {
    final state = await buildState(tester);
    late String sessionId;
    late String projectId;
    await tester.runAsync(() async {
      final project = await state.createProject(name: 'P1');
      projectId = project.id;
      final session =
          await state.createSession(projectId: project.id, title: '项目会话');
      sessionId = session.id;
      await state.setProjectArchived(project.id, true);
    });
    await pumpArchive(tester, state);

    await tester.tap(find.text('归档·项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('P1'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('恢复').last);
    await tester.pumpAndSettle();
    await pumpUntil(
      tester,
      () => state.archivedCountOfProject(projectId) == 0 &&
          state.sessions.any((s) => s.id == sessionId),
    );

    expect(state.sessions.where((s) => s.id == sessionId).length, 1);
  });
}
