import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
