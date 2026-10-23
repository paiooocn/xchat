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
import 'package:xchat/models/session_template.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/home_page.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_ui');
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

Future<void> pumpHome(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: HomePage()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('the template dialog scrolls instead of overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
      // Many templates: the dialog content must not overflow.
      for (var i = 0; i < 30; i++) {
        await state.saveTemplate(SessionTemplate(id: 't$i', name: '模板 $i'));
      }
    });
    await pumpHome(tester, state);

    await tester.enterText(find.byType(TextField).first, '你好');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(find.text('请先选择会话模板'), findsOneWidget);
    // An overflow would have been reported as a test failure.
  });

  testWidgets('sending switches to the new session without waiting for disk',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
      await state.saveTemplate(SessionTemplate(id: 't0', name: '默认模板'));
      state.config.defaultTemplateId = 't0';
      await state.saveConfig();
    });
    await pumpHome(tester, state);

    expect(find.byType(SessionChatPanel), findsNothing);

    await tester.enterText(find.byType(TextField).first, '你好');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    // A single frame — the panel must already be showing.
    await tester.pump();

    expect(find.byType(SessionChatPanel), findsOneWidget);
    expect(state.sessions.length, 1);
  });
}
