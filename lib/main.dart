import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/app_paths.dart';
import 'data/config_repository.dart';
import 'data/index_repository.dart';
import 'data/project_repository.dart';
import 'data/session_repository.dart';
import 'data/template_repository.dart';
import 'models/app_config.dart';
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

  // Desktop only: restore the user-selected window size on launch.
  if (!kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
    await _applyWindowSize(state.config.windowSize);
  }

  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const XChatApp(),
    ),
  );
}

Future<void> _applyWindowSize(String value) async {
  await windowManager.ensureInitialized();
  final size = parseWindowSize(value) ?? (width: 1280, height: 720);
  final options = WindowOptions(
    size: Size(size.width.toDouble(), size.height.toDouble()),
    minimumSize: const Size(960, 600),
    center: true,
    title: 'XChat',
    titleBarStyle: TitleBarStyle.normal,
  );
  // Never await this before `runApp`: the callback fires only once the engine
  // is ready to show, which requires the widget tree to have been built.
  unawaited(windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  }));
}
