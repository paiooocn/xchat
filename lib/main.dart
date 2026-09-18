import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/app_paths.dart';
import 'data/config_repository.dart';
import 'data/index_repository.dart';
import 'data/project_repository.dart';
import 'data/session_repository.dart';
import 'data/template_repository.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final paths = await AppPaths.init();
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
  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const XChatApp(),
    ),
  );
}
