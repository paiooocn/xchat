import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/xml/session_xml.dart';
import 'package:xchat/models/session.dart';

/// Regression tests for the session-list refresh path: the catalog index is
/// cached in memory, but sessions can appear/disappear on disk while the app
/// runs (another app instance, or an older app version sharing the same data
/// dir). `SessionRepository.list()` must re-validate against disk every time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppPaths paths;
  late SessionRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final root = Directory.systemTemp.createTempSync('xchat_index').path;
    paths = await AppPaths.init(overrideRoot: root);
    repository = SessionRepository(paths, IndexRepository(paths));
  });

  Session sessionWithId(String id) => Session(
        id: id,
        sandbox: p.join(paths.sandboxesDir, id),
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
        title: 'session $id',
      );

  test('list picks up a session file created externally after caching', () async {
    // Prime the in-memory index cache (what app startup does).
    await repository.list();

    // Another app instance writes a new session file straight to the
    // sessions dir, without touching this instance's cache.
    final external = sessionWithId('external-1');
    await File(p.join(paths.sessionsDir, '${external.id}.xml'))
        .writeAsString(SessionXml.encode(external), flush: true);

    // The refresh-button path: list() must re-validate against disk.
    final sessions = await repository.list();
    expect(sessions.map((s) => s.id), contains('external-1'));
    expect(sessions.firstWhere((s) => s.id == 'external-1').title, 'session external-1');
  });

  test('list drops a session whose file was deleted externally', () async {
    await repository.write(sessionWithId('doomed'));
    expect((await repository.list()).map((s) => s.id), contains('doomed'));

    await File(paths.sessionFile('doomed')).delete();
    expect((await repository.list()).map((s) => s.id), isNot(contains('doomed')));
  });

  test('list stays stable when disk is unchanged (no needless rebuild)', () async {
    await repository.write(sessionWithId('stable-1'));
    final first = await repository.list();
    final second = await repository.list();
    expect(second.map((s) => s.id), first.map((s) => s.id));
  });
}
