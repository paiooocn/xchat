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

/// 新建会话页的提示词三段式：会话提示词 / 项目提示词 / 新增提示词，
/// 段间用 `\n---\n` 分隔；项目提示词由开关控制。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> buildState() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final tmp = Directory.systemTemp.createTempSync('xchat_wizard');
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

  Future<void> pumpWizard(
    WidgetTester tester,
    AppState state, {
    String? projectId,
  }) async {
    // The wizard is one long list: give it a tall viewport so every section
    // is laid out (and therefore hittable) without scrolling.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: SessionWizardPage(initialProjectId: projectId)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Taps「创建」. The session is created in memory synchronously (the disk
  /// write continues in the background), so the prompt can be inspected right
  /// after the tap.
  Future<void> tapCreate(WidgetTester tester) async {
    await tester.ensureVisible(find.widgetWithText(FilledButton, '创建'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('会话提示词与新增提示词按 --- 分隔写入系统提示词',
      (tester) async {
    late AppState state;
    await tester.runAsync(() async => state = await buildState());
    await pumpWizard(tester, state);

    await tester.enterText(
      find.widgetWithText(TextField, '会话提示词'),
      '会话段',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '新增提示词（可选）'),
      '新增段',
    );
    await tester.pump();

    await tapCreate(tester);

    expect(state.sessions.length, 1);
    final prompt = state.sessions.first.systemPrompt;
    expect(prompt.contains('会话段'), isTrue);
    expect(prompt.contains('新增段'), isTrue);
    expect(prompt.contains('\n---\n'), isTrue);
    // 工作空间根目录行仍写在最上面。
    expect(prompt.startsWith('工作空间根目录:'), isTrue);
  });

  testWidgets('未选项目时项目提示词开关不可用', (tester) async {
    late AppState state;
    await tester.runAsync(() async => state = await buildState());
    await pumpWizard(tester, state);

    expect(find.text('启用项目提示词'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isFalse);
    expect(tile.onChanged, isNull);
  });

  testWidgets('选了带提示词的项目后默认启用项目提示词', (tester) async {
    late AppState state;
    String? projectId;
    await tester.runAsync(() async {
      state = await buildState();
      final project =
          await state.createProject(name: 'P1', systemPrompt: '项目段');
      projectId = project.id;
    });
    await pumpWizard(tester, state, projectId: projectId);

    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isTrue);
    expect(tile.onChanged, isNotNull);
    // 项目提示词原文可见，便于确认要并入的内容。
    expect(find.text('项目段'), findsWidgets);
  });

  testWidgets('关掉开关后项目提示词不并入会话', (tester) async {
    late AppState state;
    String? projectId;
    await tester.runAsync(() async {
      state = await buildState();
      final project =
          await state.createProject(name: 'P1', systemPrompt: '项目段');
      projectId = project.id;
    });
    await pumpWizard(tester, state, projectId: projectId);

    await tester.enterText(
      find.widgetWithText(TextField, '会话提示词'),
      '会话段',
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();

    await tapCreate(tester);

    expect(state.sessions.length, 1);
    final prompt = state.sessions.first.systemPrompt;
    expect(prompt.contains('会话段'), isTrue);
    expect(prompt.contains('项目段'), isFalse);
  });
}
