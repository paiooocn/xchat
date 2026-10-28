import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/core/memory_protocol.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/models/project.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/widgets/project_dialog.dart';

/// Regression: the project dialog must not dispose its text controllers
/// while the dialog is still mounted.
///
/// The old implementation disposed them right after `showDialog` returned,
/// which made the still-animating dialog throw
/// "A TextEditingController was used after being disposed" (plus the
/// follow-up framework assertions) as soon as the user pressed 确定.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> buildState() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final tmp = Directory.systemTemp.createTempSync('xchat_project_dialog');
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

  Future<void> pumpDialog(
    WidgetTester tester,
    AppState state, {
    Project? existing,
  }) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(body: ProjectDialog(existing: existing)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('初始化 .memory 后关闭对话框不报错', (tester) async {
    // 对话框内容比默认视口高：给一个大视口，保证按钮可点。
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    late Project project;
    await tester.runAsync(() async {
      state = await buildState();
      project = await state.createProject(name: 'P1', memoryEnabled: false);
    });
    await pumpDialog(tester, state, existing: project);

    expect(find.text('初始化 / 补齐'), findsOneWidget);

    // 初始化按钮会真的写文件：真实 IO 要在真实事件循环里跑，
    // 每轮 runAsync + pump 让一次 IO 往返完成。
    await tester.tap(find.text('初始化 / 补齐'));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    // 关闭对话框：这里正是旧实现抛「used after being disposed」的地方。
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    expect(tester.takeException(), isNull);
    expect(
      Directory('${project.sandbox}/$kMemoryDirName').existsSync(),
      isTrue,
    );
  });

  testWidgets('新建项目对话框关闭时不报错', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async => state = await buildState());
    await pumpDialog(tester, state);

    await tester.enterText(
      find.widgetWithText(TextField, '项目名称'),
      '新项目',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
