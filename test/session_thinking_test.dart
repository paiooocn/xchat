import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/models/app_config.dart';
import 'package:xchat/models/provider_config.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_params.dart';
import 'package:xchat/session/session_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SessionController thinking settings', () {
    late Directory tmp;
    late AppPaths paths;
    late SessionRepository repository;
    late SessionController controller;
    late Session session;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('xchat_thinking');
      paths = await AppPaths.init(overrideRoot: tmp.path);
      final index = IndexRepository(paths);
      repository = SessionRepository(paths, index);
      final provider = ProviderConfig(id: 'p1', name: 'P1');
      controller = SessionController(
        repository: repository,
        config: AppConfig(providers: [provider]),
        providerResolver: (_) => provider,
      );
      session = Session(
        id: 's1',
        sandbox: paths.sessionsDir,
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
        provider: 'p1',
        model: 'm1',
      );
      await repository.write(session);
      controller.open(session);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('setThinking writes the switch into the session file', () async {
      await controller.setThinking(ThinkingSwitch.on);
      expect(session.params.thinking, ThinkingSwitch.on);

      final reloaded = await repository.read('s1');
      expect(reloaded.params.thinking, ThinkingSwitch.on);
    });

    test('setReasoningEffort writes the effort into the session file', () async {
      await controller.setReasoningEffort('high');
      expect(session.params.reasoningEffort, 'high');

      final reloaded = await repository.read('s1');
      expect(reloaded.params.reasoningEffort, 'high');
    });

    test('clearing the effort removes it from the session file', () async {
      await controller.setReasoningEffort('low');
      await controller.setReasoningEffort('');
      expect(session.params.reasoningEffort, isNull);

      final reloaded = await repository.read('s1');
      expect(reloaded.params.reasoningEffort, isNull);
    });
  });
}
