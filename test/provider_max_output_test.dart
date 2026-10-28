import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_api/llm_api.dart';
import 'package:llm_api/llm_api_testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/llm/llm_factory.dart';
import 'package:xchat/models/provider_config.dart';
import 'package:xchat/state/app_state.dart';
import 'package:xchat/ui/pages/providers_page.dart';

ProviderConfig _provider({
  bool useMaxCompletionTokens = false,
  int? maxOutputTokens,
}) =>
    ProviderConfig(
      id: 'test',
      name: 'test',
      baseUrl: 'https://api.test/v1',
      useMaxCompletionTokens: useMaxCompletionTokens,
      maxOutputTokens: maxOutputTokens,
    );

/// Sends one request through the real provider stack and returns its body.
Future<Map<String, Object?>> _requestBody(
  ProviderConfig config, {
  int? maxTokens,
}) async {
  final transport = MockHttpTransport.sse(<Object?>[
    <String, Object?>{'choices': <Object?>[]},
  ]);
  final provider = OpenAiCompatibleProvider(
    config: buildOpenAiConfig(config),
    transport: transport,
    maxRetries: 0,
    retryBaseDelay: Duration.zero,
  );
  await provider.complete(
    ChatRequest(
      model: 'm',
      maxTokens: maxTokens,
      messages: <ChatMessage>[ChatMessage.user('hi')],
    ),
  );
  return transport.lastBody;
}

/// A state backed by a throw-away data directory.
Future<AppState> _buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_provider');
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
  group('provider output cap', () {
    test('is sent as max_completion_tokens when that parameter name is picked',
        () async {
      final body = await _requestBody(
        _provider(useMaxCompletionTokens: true, maxOutputTokens: 4096),
      );
      expect(body['max_completion_tokens'], 4096);
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('is sent as max_tokens by default', () async {
      final body = await _requestBody(_provider(maxOutputTokens: 4096));
      expect(body['max_tokens'], 4096);
      expect(body.containsKey('max_completion_tokens'), isFalse);
    });

    test('is omitted when the provider has no cap', () async {
      final body = await _requestBody(_provider());
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('max_completion_tokens'), isFalse);
    });

    test('a request-level max_tokens wins over the provider cap', () async {
      final body = await _requestBody(
        _provider(useMaxCompletionTokens: true, maxOutputTokens: 4096),
        maxTokens: 128,
      );
      expect(body['max_completion_tokens'], 128);
    });
  });

  group('provider config persistence', () {
    test('round-trips max_output_tokens', () {
      final config = _provider(maxOutputTokens: 8192);
      final restored = ProviderConfig.fromJson(config.toJson());
      expect(restored.maxOutputTokens, 8192);
    });

    test('keeps the key absent when unset (old config.json stays valid)', () {
      final json = _provider().toJson();
      expect(json.containsKey('max_output_tokens'), isFalse);
      expect(ProviderConfig.fromJson(json).maxOutputTokens, isNull);
    });
  });

  group('provider editor page', () {
    testWidgets('takes a numeric output cap and saves it', (tester) async {
      // 编辑页很长，撑高视口让所有字段都被构建（ListView 是懒加载的）。
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
          child: const MaterialApp(home: ProvidersPage()),
        ),
      );
      await tester.pumpAndSettle();

      final edit = find.byIcon(Icons.edit_outlined).first;
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();

      // 旧的开/关开关没了，取而代之的是数值输入框 + 参数名下拉。
      expect(find.text('使用 max_completion_tokens'), findsNothing);

      const label = '最大输出 tokens（max_tokens / max_completion_tokens）';
      final field = find.widgetWithText(TextField, label);
      expect(field, findsOneWidget);

      final dropdown =
          find.widgetWithText(DropdownButtonFormField<String>, '输出上限参数名');
      expect(dropdown, findsOneWidget);
      expect(find.text('max_tokens'), findsOneWidget);

      await tester.enterText(field, '4096');
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(
        state.config.providers.any((p) => p.maxOutputTokens == 4096),
        isTrue,
      );
    });
  });
}
