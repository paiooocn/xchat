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
  String? maxOutputTokensByEffort,
}) =>
    ProviderConfig(
      id: 'test',
      name: 'test',
      baseUrl: 'https://api.test/v1',
      useMaxCompletionTokens: useMaxCompletionTokens,
      maxOutputTokens: maxOutputTokens,
      maxOutputTokensByEffort: maxOutputTokensByEffort,
    );

/// Sends one request through the real provider stack and returns its body.
Future<Map<String, Object?>> _requestBody(
  ProviderConfig config, {
  int? maxTokens,
  String? reasoningEffort,
}) async {
  final transport = MockHttpTransport.sse(<Object?>[
    <String, Object?>{'choices': <Object?>[]},
  ]);
  final provider = OpenAiCompatibleProvider(
    config: buildOpenAiConfig(config, reasoningEffort: reasoningEffort),
    transport: transport,
    maxRetries: 0,
    retryBaseDelay: Duration.zero,
  );
  await provider.complete(
    ChatRequest(
      model: 'm',
      maxTokens: maxTokens,
      reasoning: reasoningEffort == null
          ? null
          : ReasoningConfig(
              effort: ReasoningEffort.parse(reasoningEffort),
              effortName: reasoningEffort,
            ),
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

  group('output cap per thinking level', () {
    const spec = 'low:1280/medium:2560/high:3840/xhigh:5120';

    test('picks the cap of the current thinking level', () async {
      final body = await _requestBody(
        _provider(maxOutputTokensByEffort: spec),
        reasoningEffort: 'high',
      );
      expect(body['max_tokens'], 3840);
    });

    test('is case-insensitive on the level name', () async {
      final body = await _requestBody(
        _provider(maxOutputTokensByEffort: spec),
        reasoningEffort: 'LOW',
      );
      expect(body['max_tokens'], 1280);
    });

    test('a level that is not listed means no cap', () async {
      final body = await _requestBody(
        _provider(maxOutputTokensByEffort: spec),
        reasoningEffort: 'minimal',
      );
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('max_completion_tokens'), isFalse);
    });

    test('no thinking level means no cap', () async {
      final body = await _requestBody(
        _provider(maxOutputTokensByEffort: spec),
      );
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('the level table replaces the flat cap', () async {
      final body = await _requestBody(
        _provider(maxOutputTokens: 4096, maxOutputTokensByEffort: spec),
        reasoningEffort: 'medium',
      );
      expect(body['max_tokens'], 2560);
    });

    test('the parameter name still follows the provider setting', () async {
      final body = await _requestBody(
        _provider(useMaxCompletionTokens: true, maxOutputTokensByEffort: spec),
        reasoningEffort: 'xhigh',
      );
      expect(body['max_completion_tokens'], 5120);
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('a request-level max_tokens still wins', () async {
      final body = await _requestBody(
        _provider(maxOutputTokensByEffort: spec),
        maxTokens: 64,
        reasoningEffort: 'high',
      );
      expect(body['max_tokens'], 64);
    });
  });

  group('per-level cap parsing', () {
    test('reads the {level}:{length} pairs', () {
      final table = parseMaxTokensByEffort('low:1280/medium:2560/high:3840');
      expect(table, <String, int>{
        'low': 1280,
        'medium': 2560,
        'high': 3840,
      });
    });

    test('drops malformed entries', () {
      final table = parseMaxTokensByEffort('low:1280/bad/medium:abc/high:0');
      expect(table, <String, int>{'low': 1280});
    });

    test('an empty spec means "not configured"', () {
      expect(parseMaxTokensByEffort(null), isEmpty);
      expect(parseMaxTokensByEffort(''), isEmpty);
      expect(parseMaxTokensByEffort('nonsense'), isEmpty);
    });

    test('resolves the cap of a level', () {
      final config = _provider(maxOutputTokensByEffort: 'low:1280/high:3840');
      expect(config.maxOutputTokensFor('high'), 3840);
      expect(config.maxOutputTokensFor('low'), 1280);
      expect(config.maxOutputTokensFor('medium'), isNull);
      expect(config.maxOutputTokensFor(null), isNull);
    });

    test('falls back to the flat cap when no table is configured', () {
      final config = _provider(maxOutputTokens: 4096);
      expect(config.maxOutputTokensFor('high'), 4096);
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

    test('round-trips max_output_tokens_by_effort', () {
      final config = _provider(maxOutputTokensByEffort: 'low:1280/high:3840');
      final restored = ProviderConfig.fromJson(config.toJson());
      expect(restored.maxOutputTokensByEffort, 'low:1280/high:3840');
    });

    test('keeps the per-level key absent when unset', () {
      final json = _provider().toJson();
      expect(json.containsKey('max_output_tokens_by_effort'), isFalse);
      expect(ProviderConfig.fromJson(json).maxOutputTokensByEffort, isNull);
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

    testWidgets('takes a per-level cap and saves it', (tester) async {
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

      const label = '最大输出 tokens（max_tokens / max_completion_tokens）';
      final field = find.widgetWithText(TextField, label);
      expect(field, findsOneWidget);

      await tester.enterText(field, 'low:1280/medium:2560/high:3840');
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(
        state.config.providers.any((p) =>
            p.maxOutputTokensByEffort == 'low:1280/medium:2560/high:3840'),
        isTrue,
      );
    });
  });
}
