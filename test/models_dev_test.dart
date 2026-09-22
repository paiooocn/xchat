import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/data/models_dev_repository.dart';
import 'package:xchat/models/models_dev.dart';
import 'package:xchat/models/provider_config.dart';

const _catalogJson = <String, Object?>{
  'deepseek': <String, Object?>{
    'id': 'deepseek',
    'name': 'DeepSeek',
    'api': 'https://api.deepseek.com',
    'npm': '@ai-sdk/openai-compatible',
    'models': <String, Object?>{
      'deepseek-v4-flash': <String, Object?>{
        'id': 'deepseek-v4-flash',
        'name': 'DeepSeek V4 Flash',
        'reasoning': true,
        'tool_call': true,
        'interleaved': <String, Object?>{'field': 'reasoning_content'},
        'reasoning_options': <Object?>[
          <String, Object?>{'type': 'toggle'},
          <String, Object?>{
            'type': 'effort',
            'values': <String>['low', 'high'],
          },
        ],
        'limit': <String, Object?>{'context': 1000000, 'output': 384000},
        'release_date': '2026-09-10',
      },
      'deepseek-v4-pro': <String, Object?>{
        'id': 'deepseek-v4-pro',
        'reasoning': true,
        'tool_call': true,
        'interleaved': <String, Object?>{'field': 'reasoning_content'},
        'limit': <String, Object?>{'context': 200000, 'output': 64000},
        'release_date': '2026-08-12',
      },
      'deepseek-chat': <String, Object?>{
        'id': 'deepseek-chat',
        'reasoning': false,
        'tool_call': true,
        'status': 'deprecated',
        'limit': <String, Object?>{'context': 65536, 'output': 8192},
      },
      'deepseek-embed': <String, Object?>{
        'id': 'deepseek-embed',
        'tool_call': false,
        'type': 'decision',
      },
    },
  },
  'anthropic': <String, Object?>{
    'id': 'anthropic',
    'name': 'Anthropic',
    'npm': '@ai-sdk/anthropic',
    'models': <String, Object?>{
      'claude-x': <String, Object?>{
        'id': 'claude-x',
        'reasoning': true,
        'tool_call': true,
        'limit': <String, Object?>{'context': 200000},
      },
    },
  },
};

ProviderConfig _provider({
  String id = 'deepseek',
  String preset = 'deepseek',
  String name = 'DeepSeek',
  String baseUrl = 'https://api.deepseek.com/v1',
  List<String> models = const ['deepseek-chat', 'my-private-model'],
}) =>
    ProviderConfig(
      id: id,
      name: name,
      baseUrl: baseUrl,
      preset: preset,
      models: models,
    );

void main() {
  final catalog = ModelsDevCatalog.fromJson(_catalogJson);

  test('parses providers and models', () {
    expect(catalog.providers.length, 2);
    final deepseek = catalog.byId('deepseek')!;
    expect(deepseek.name, 'DeepSeek');
    expect(deepseek.openAiCompatible, isTrue);
    expect(catalog.byId('anthropic')!.openAiCompatible, isFalse);
    expect(deepseek.models['deepseek-v4-flash']!.context, 1000000);
    expect(deepseek.models['deepseek-v4-flash']!.maxOutput, 384000);
    expect(deepseek.derivedReasoningSource, 'field');
    expect(deepseek.derivedReasoningStyle, 'reasoning_effort');
  });

  test('matches by id, endpoint host and preset alias', () {
    expect(catalog.matchFor(_provider())!.id, 'deepseek');
    expect(
      catalog.matchFor(_provider(id: 'custom_1', preset: 'custom',
              baseUrl: 'https://api.deepseek.com/v1'))!
          .id,
      'deepseek',
    );
    expect(
      catalog.matchFor(_provider(id: 'ds-copy', preset: 'custom',
              baseUrl: 'https://my-gateway.example/v1')),
      isNull,
    );
    // Preset alias only matches untouched default endpoints.
    final aliased = ProviderConfig(
      id: 'my-deepseek', preset: 'deepseek', baseUrl: kPresetDefaultBaseUrls['deepseek']!,
    );
    expect(catalog.matchFor(aliased)!.id, 'deepseek');
  });

  test('sync keeps user models/endpoints and appends fresh catalog models', () {
    final target = _provider();
    final result = applyModelsDev(target, catalog.byId('deepseek')!);

    // Stale catalog-dead entry dropped, unknown user model preserved…
    expect(target.models.contains('deepseek-chat'), isFalse);
    expect(result.removed, 1);
    expect(target.models.contains('my-private-model'), isTrue);
    // …and fresh tool-capable models appended (never the specialized one).
    expect(target.models.contains('deepseek-v4-flash'), isTrue);
    expect(target.models.contains('deepseek-v4-pro'), isTrue);
    expect(target.models.contains('deepseek-embed'), isFalse);
    // Newest first among appended models.
    expect(target.models.indexOf('deepseek-v4-flash') < target.models.indexOf('deepseek-v4-pro'), isTrue);

    // Untouched default endpoint is normalized, curated fields preserved.
    expect(target.baseUrl, 'https://api.deepseek.com/v1');
    expect(target.reasoningStyle, 'none');
    expect(target.contextWindow, 1000000);
    expect(target.contextWindowFor('deepseek-v4-pro'), 200000);
    expect(target.contextWindowFor('my-private-model'), 1000000); // fallback
    expect(target.specFor('deepseek-v4-flash')!.maxOutputTokens, 384000);
  });

  test('sync never clobbers a custom mirror endpoint or name', () {
    final target = _provider(
      name: '公司网关',
      baseUrl: 'https://llm.corp.example/v1',
    );
    applyModelsDev(target, catalog.byId('deepseek')!);
    expect(target.baseUrl, 'https://llm.corp.example/v1');
    expect(target.name, '公司网关');
  });

  test('full fill overwrites name, endpoint and reasoning parameters', () {
    final target = _provider(preset: 'custom');
    applyModelsDev(target, catalog.byId('deepseek')!, full: true);
    expect(target.name, 'DeepSeek');
    expect(target.baseUrl, 'https://api.deepseek.com/v1');
    expect(target.reasoningSource, 'field');
    expect(target.reasoningStyle, 'reasoning_effort');
  });

  test('custom providers get a derived style on sync when unset', () {
    final target = _provider(preset: 'custom');
    applyModelsDev(target, catalog.byId('deepseek')!);
    expect(target.reasoningStyle, 'reasoning_effort');
  });

  test('anthropic-protocol providers keep their endpoint', () {
    final target = ProviderConfig(id: 'anthropic', name: 'A', preset: 'custom');
    applyModelsDev(target, catalog.byId('anthropic')!, full: true);
    expect(target.baseUrl, isEmpty);
    expect(target.models, ['claude-x']);
  });

  test('preset mapping for wizard-created providers', () {
    expect(modelsDevPresetFor('deepseek'), 'deepseek');
    expect(modelsDevPresetFor('moonshotai-cn'), 'moonshot');
    expect(modelsDevPresetFor('alibaba-cn'), 'qwen');
    expect(modelsDevPresetFor('random-host'), 'custom');
  });

  test('wizard selection is kept verbatim (no models appended)', () {
    final source = catalog.byId('deepseek')!;
    final target = ProviderConfig(
      id: 'deepseek-2',
      name: 'DeepSeek',
      models: ['deepseek-v4-pro'],
    );
    applyModelsDev(target, source, full: true, appendNew: false);
    expect(target.models, ['deepseek-v4-pro']);
    expect(target.contextWindowFor('deepseek-v4-pro'), 200000);
    expect(target.reasoningStyle, 'reasoning_effort');
  });

  test('bundled fallback snapshot parses and matches presets', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final bundled = await loadBundledModelsDev();
    expect(bundled, isNotNull);
    final deepseek = bundled!.byId('deepseek');
    expect(deepseek, isNotNull);
    expect(deepseek!.models, isNotEmpty);
    // Built-in preset endpoints resolve against the bundled snapshot too.
    expect(bundled.matchFor(ProviderConfig(id: 'deepseek', preset: 'deepseek'))!.id,
        'deepseek');
    expect(
      bundled.matchFor(ProviderConfig(
        id: 'ds', preset: 'deepseek', baseUrl: kPresetDefaultBaseUrls['deepseek']!,
      )),
      isNotNull,
    );
  });
}
