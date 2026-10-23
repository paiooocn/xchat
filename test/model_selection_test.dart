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
import 'package:xchat/ui/pages/session_wizard_page.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_model');
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

void main() {
  test('a stale configured model is repaired when the config is loaded', () async {
    final state = await buildState();
    // 模拟：服务商下架了当前选中的模型（配置里仍指向旧模型）。
    state.config.currentModel = 'MiniMax-M3.1-Flash-Preview';
    await state.saveConfig();

    // 重新加载（应用启动路径）。
    await state.load();

    final provider = state.providerById(state.config.currentProviderId);
    expect(provider.models, contains(state.config.currentModel));
    expect(state.config.currentModel, isNot('MiniMax-M3.1-Flash-Preview'));
  });

  testWidgets('new-session wizard opens with a stale configured model',
      (tester) async {
    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
      state.config.currentModel = 'MiniMax-M3.1-Flash-Preview';
      await state.saveConfig();
      await state.load();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: SessionWizardPage()),
      ),
    );
    await tester.pump();

    // 下拉框的值必须与条目一一对应，否则 Flutter 会抛断言。
    expect(tester.takeException(), isNull);
    expect(find.text('新建会话'), findsOneWidget);
  });
}
