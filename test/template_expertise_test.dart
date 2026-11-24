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
import 'package:xchat/models/expertise.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/templates_page.dart';
import 'package:xchat/ui/widgets/system_prompt_config.dart';
import 'helpers/test_theme.dart';

Future<AppState> _buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_expertise');
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

Future<void> _pumpEditor(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(theme: testTheme(), home: TemplatesPage()),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.text('新建模板'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('直接编辑'));
  await tester.pumpAndSettle();
}

Future<void> _switchMode(WidgetTester tester, String label) async {
  final segment = find.descendant(
    of: find.byType(SegmentedButton<SystemPromptMode>),
    matching: find.text(label),
  );
  expect(segment, findsOneWidget);
  await tester.tap(segment);
  await tester.pumpAndSettle();
}

const _textLabel = '系统提示词（{sandbox} 自动替换为会话 sandbox 路径）';
const _selectedBadgeColor = Color(0xFF43A047);

/// 读取某个专长 badge 的填充色，用于断言选中态。
Color? _badgeColor(WidgetTester tester, String id) {
  final container = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byKey(Key('expertise-badge-$id')),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (container.decoration as BoxDecoration?)?.color;
}

void main() {
  testWidgets('文本输入与 AI专长互斥，切换后两侧数据都保留', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await _buildState();
    });
    await _pumpEditor(tester, state);

    // 默认「文本输入」，展示多行输入框。
    expect(find.widgetWithText(TextField, _textLabel), findsOneWidget);
    expect(find.text(SystemPromptConfig.expertiseHint), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, _textLabel), '我的手动提示词');
    await tester.pump();

    await _switchMode(tester, 'AI专长');

    // 手动输入框隐藏，改为专长说明 + badge；未选时给出提示。
    expect(find.widgetWithText(TextField, _textLabel), findsNothing);
    expect(find.text(SystemPromptConfig.expertiseHint), findsOneWidget);
    expect(find.text(SystemPromptConfig.emptySelectionText), findsOneWidget);
    expect(find.byKey(const Key('expertise-badge-programming')), findsOneWidget);
    expect(find.byKey(const Key('expertise-badge-data_analysis')), findsOneWidget);

    // 选中两个，再切回文本输入：文本仍在。
    await tester.tap(find.byKey(const Key('expertise-badge-programming')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('expertise-badge-data_analysis')));
    await tester.pumpAndSettle();
    expect(find.text(SystemPromptConfig.emptySelectionText), findsNothing);

    await _switchMode(tester, '文本输入');
    expect(find.widgetWithText(TextField, _textLabel), findsOneWidget);
    expect(find.text('我的手动提示词'), findsOneWidget);

    // 再切回 AI专长：已选仍然保留（选中项为绿色背景，无对勾）。
    await _switchMode(tester, 'AI专长');
    expect(_badgeColor(tester, 'programming'), _selectedBadgeColor);
    expect(_badgeColor(tester, 'data_analysis'), _selectedBadgeColor);
    expect(_badgeColor(tester, 'devops'), isNot(_selectedBadgeColor));
    expect(
      find.descendant(
        of: find.byKey(const Key('expertise-badge-programming')),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );
  });

  testWidgets('保存按专长库顺序组合，并保留另一侧内容', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await _buildState();
    });
    await _pumpEditor(tester, state);

    await tester.enterText(find.widgetWithText(TextField, _textLabel), '手写内容');
    await tester.pump();

    await _switchMode(tester, 'AI专长');
    // 故意逆着库顺序点击。
    await tester.tap(find.byKey(const Key('expertise-badge-data_analysis')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('expertise-badge-programming')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    for (var i = 0; i < 80; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (state.templates.isNotEmpty) break;
    }
    await tester.pumpAndSettle();

    expect(state.templates, hasLength(1));
    final saved = state.templates.single;
    expect(saved.promptMode, SystemPromptMode.expertise);
    expect(saved.manualPrompt, '手写内容');
    expect(saved.expertiseIds.toSet(), <String>{'programming', 'data_analysis'});
    // 最终提示词按专长库 sort（programming=10 在 data_analysis=20 之前），
    // 而不是点击顺序。
    expect(
      saved.systemPrompt,
      composeExpertisePrompt(
        <String>{'programming', 'data_analysis'},
        state.expertises,
      ),
    );
    expect(
      saved.systemPrompt.indexOf('你擅长编程开发'),
      lessThan(saved.systemPrompt.indexOf('你擅长数据与数据库')),
    );
  });

  testWidgets('AI专长模式下未选择专长时保存被拦下并提示', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await _buildState();
    });
    await _pumpEditor(tester, state);

    await _switchMode(tester, 'AI专长');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(state.templates, isEmpty);
    expect(find.text(SystemPromptConfig.emptySelectionText), findsWidgets);
  });

  testWidgets('专长库为空时展示空状态', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await _buildState();
      state.expertises = <Expertise>[];
    });
    await _pumpEditor(tester, state);

    await _switchMode(tester, 'AI专长');
    expect(find.text(SystemPromptConfig.emptyLibraryText), findsOneWidget);
    expect(find.text(SystemPromptConfig.emptySelectionText), findsOneWidget);
  });

  testWidgets('停用的专长不出现在待选项', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppState state;
    await tester.runAsync(() async {
      state = await _buildState();
      state.expertises = <Expertise>[
        for (final item in state.expertises)
          if (item.id != 'programming') item,
      ];
    });
    await _pumpEditor(tester, state);

    await _switchMode(tester, 'AI专长');
    expect(find.byKey(const Key('expertise-badge-programming')), findsNothing);
    expect(find.byKey(const Key('expertise-badge-devops')), findsOneWidget);
    expect(find.text(SystemPromptConfig.emptySelectionText), findsOneWidget);
  });
}
