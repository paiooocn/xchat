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
import 'package:xchat/models/session_params.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/home_page.dart';
import 'package:xchat/ui/widgets/model_picker.dart';
import 'helpers/test_theme.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_quick');
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
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(theme: testTheme(), home: HomePage()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// 等待落盘/列表刷新完成。
Future<void> flush(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pumpAndSettle();
}

Future<void> sendWelcome(WidgetTester tester, String text) async {
  final input = find.descendant(
    of: find.byKey(const Key('welcome-input')),
    matching: find.byType(TextField),
  );
  await tester.enterText(input, text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
}

void main() {
  testWidgets('无模板也能发送：默认快捷配置直接建会话', (tester) async {
    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
    });
    await pumpHome(tester, state);

    expect(find.text('请先选择会话模板'), findsNothing);
    expect(state.sessions, isEmpty);

    // 默认思考开关 on、思考强度 low。
    await tester.tap(find.byKey(const Key('expertise-badge-programming')));
    await tester.pump();
    await sendWelcome(tester, '你好');
    await flush(tester, () => state.sessions.isNotEmpty);

    expect(state.sessions, hasLength(1));
    final session = state.sessions.single;
    expect(session.systemPrompt, contains('你擅长编程开发'));
    expect(session.params.thinking, ThinkingSwitch.on);
    expect(session.params.reasoningEffort, 'low');
    expect(session.model, state.config.currentModel);
  });

  testWidgets('输入栏下方点专长 + 控件选厂家/模型/思考强度后建会话', (tester) async {
    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
    });
    await pumpHome(tester, state);

    // 专长 badge 在输入栏下方，直接点选。
    await tester.tap(find.byKey(const Key('expertise-badge-programming')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('expertise-badge-education')));
    await tester.pump();

    // 厂家：同款胶囊下拉，切到 Moonshot。
    await tester.tap(find.text('DeepSeek').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'Moonshot / Kimi').last,
    );
    await tester.pumpAndSettle();
    // 切厂家后模型重置为该厂家第一个模型。
    expect(state.config.providerById('moonshot')!.models.first,
        'kimi-k2-0905-preview');

    // 模型：会话同款胶囊，限同一厂家。
    final modelPill =
        find.text('Moonshot / Kimi · kimi-k2-0905-preview');
    await tester.tap(modelPill);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'kimi-k2-thinking').last,
    );
    await tester.pumpAndSettle();

    // 思考强度：tune 图标 + 勾选菜单。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, 'high').last,
    );
    await tester.pumpAndSettle();

    await sendWelcome(tester, '帮我写个方案');
    await flush(tester, () => state.sessions.isNotEmpty);

    final session = state.sessions.single;
    expect(session.provider, 'moonshot');
    expect(session.model, 'kimi-k2-thinking');
    expect(session.params.reasoningEffort, 'high');
    expect(
      session.systemPrompt,
      contains(
        composeExpertisePrompt(
          <String>{'programming', 'education'},
          state.expertises,
        ),
      ),
    );
    expect(session.systemPrompt.indexOf('你擅长编程开发'),
        lessThan(session.systemPrompt.indexOf('你擅长教育与学习')));
  });

  testWidgets('未配置厂家时快捷配置不崩溃', (tester) async {
    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
      state.config.providers = [];
      state.config.currentProviderId = '';
      state.config.currentModel = '';
      await state.saveConfig();
    });
    await pumpHome(tester, state);

    expect(find.textContaining('未配置厂家'), findsNothing);
    expect(find.byType(ModelPicker), findsNothing);
    expect(find.byType(ProviderPicker), findsNothing);
  });

  testWidgets('未选专长时弹窗提示：可选专长或从新建会话发起', (tester) async {
    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
    });
    await pumpHome(tester, state);

    await sendWelcome(tester, '你好');
    await tester.pumpAndSettle();

    expect(find.text('请选择 AI 专长'), findsOneWidget);
    expect(state.sessions, isEmpty);

    // 「选择专长」关闭弹窗，用户回到输入栏下方点选。
    await tester.tap(find.text('选择专长'));
    await tester.pumpAndSettle();
    expect(find.text('请选择 AI 专长'), findsNothing);

    await tester.tap(find.byKey(const Key('expertise-badge-programming')));
    await tester.pump();
    await sendWelcome(tester, '你好');
    await flush(tester, () => state.sessions.isNotEmpty);
    expect(state.sessions, hasLength(1));
  });

  testWidgets('未选专长时「新建会话」进入创建向导', (tester) async {
    late AppState state;
    await tester.runAsync(() async {
      state = await buildState();
    });
    await pumpHome(tester, state);

    await sendWelcome(tester, '你好');
    await tester.pumpAndSettle();
    expect(find.text('请选择 AI 专长'), findsOneWidget);

    await tester.tap(find.text('新建会话'));
    await tester.pumpAndSettle();
    expect(find.text('起点：空白会话，或从模板创建'), findsOneWidget);
  });
}
