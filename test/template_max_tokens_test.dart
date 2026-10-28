import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/models/provider_config.dart';
import 'package:xchat/models/session_params.dart';
import 'package:xchat/models/session_template.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/templates_page.dart';

/// A state backed by a throw-away data directory.
Future<AppState> _buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_template');
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
  group('template output cap', () {
    test('is inherited by a session created from the template', () async {
      final state = await _buildState();
      final template = SessionTemplate(
        id: 't1',
        name: '模板',
        params: SessionParams(maxTokens: 4096, reasoningEffort: 'high'),
      );
      final session = state.createFromTemplateDraft(template);
      expect(session.params.maxTokens, 4096);
      expect(session.params.reasoningEffort, 'high');
    });

    test('an empty value means "use the provider config"', () async {
      final state = await _buildState();
      final template = SessionTemplate(id: 't2', name: '模板2');
      final session = state.createFromTemplateDraft(template);
      expect(session.params.maxTokens, isNull);
    });

    test('the session value wins over the provider cap', () {
      final provider = ProviderConfig(
        id: 'p',
        name: 'p',
        baseUrl: 'https://api.test/v1',
        maxOutputTokensByEffort: 'low:1280/high:3840',
      );
      // 会话显式值优先；没填时才用服务按档位算出的值。
      int? effective(int? sessionValue, String effort) =>
          sessionValue ?? provider.maxOutputTokensFor(effort);
      expect(effective(4096, 'high'), 4096);
      expect(effective(null, 'high'), 3840);
      expect(provider.maxOutputTokensFor('high'), 3840);
    });
  });

  group('template editor page', () {
    testWidgets('takes an explicit output cap and saves it', (tester) async {
      // 编辑页较长，撑高视口让所有字段都被构建（ListView 是懒加载的）。
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.reset());

      late AppState state;
      await tester.runAsync(() async {
        state = await _buildState();
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: TemplatesPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('新建模板'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('直接编辑'));
      await tester.pumpAndSettle();

      const label = '最大输出 tokens（留空 = 用模型服务配置）';
      final field = find.widgetWithText(TextField, label);
      expect(field, findsOneWidget);

      await tester.enterText(field, '4096');
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pump();
      // 保存走真实文件 I/O（写盘 → 重新读盘）：真实事件循环（runAsync）与假
      // 时钟（pump）必须交替让行，异步链才会真正走完。
      for (var i = 0; i < 30; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (state.templates.any((t) => t.params.maxTokens == 4096)) break;
      }
      await tester.pumpAndSettle();

      expect(state.templates.any((t) => t.params.maxTokens == 4096), isTrue);
    });
  });
}
