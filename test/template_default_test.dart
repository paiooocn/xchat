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
import 'package:xchat/models/app_config.dart';
import 'package:xchat/models/session_template.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/home_page.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_tpl');
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
  test('default_template_id survives a config round-trip', () {
    final config = AppConfig.fromJson({
      'default_template_id': 'tpl-1',
    });
    expect(config.defaultTemplateId, 'tpl-1');
    expect(AppConfig.fromJson(config.toJson()).defaultTemplateId, 'tpl-1');
  });

  test('defaultTemplate resolves the configured template, null when unset', () async {
    final state = await buildState();
    expect(state.defaultTemplate, isNull);

    final template = SessionTemplate(id: 'tpl-1', name: '编码模板');
    await state.saveTemplate(template);

    state.config.defaultTemplateId = 'tpl-1';
    await state.saveConfig();
    expect(state.defaultTemplate?.name, '编码模板');

    // A template that no longer exists must not resolve.
    state.config.defaultTemplateId = 'gone';
    await state.saveConfig();
    expect(state.defaultTemplate, isNull);
  });

  testWidgets('picking a template shows its name and creates no session', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
      await state.saveTemplate(SessionTemplate(id: 'tpl-1', name: '编码模板'));
    });
    await pumpHome(tester, state);

    expect(state.sessions, isEmpty);

    // Open the template picker and select the template.
    await tester.tap(find.text('会话模板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编码模板').last);
    await tester.pumpAndSettle();

    // The pill now shows the template name…
    expect(find.text('编码模板'), findsOneWidget);
    // …but no session was created yet.
    expect(state.sessions, isEmpty);
  });

  testWidgets('sending without a template prompts to pick one', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
      await state.saveTemplate(SessionTemplate(id: 'tpl-1', name: '编码模板'));
    });
    await pumpHome(tester, state);

    await tester.enterText(find.byType(TextField).first, '你好');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    // The prompt asks for a template; nothing was sent yet.
    expect(find.text('请先选择会话模板'), findsOneWidget);
    expect(state.sessions, isEmpty);
  });

  testWidgets('the default template is used when none is picked', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
      await state.saveTemplate(SessionTemplate(id: 'tpl-1', name: '编码模板'));
      state.config.defaultTemplateId = 'tpl-1';
      await state.saveConfig();
    });
    await pumpHome(tester, state);

    // The default template's name is shown on the picker pill.
    expect(find.text('编码模板'), findsOneWidget);
    expect(state.sessions, isEmpty);
  });
}
