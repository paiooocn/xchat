import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/data/xml/project_xml.dart';
import 'package:xchat/data/xml/session_xml.dart';
import 'package:xchat/models/project.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/state/app_state.dart';

/// Builds an [AppState] rooted at a fresh temp dir, mirroring app wiring.
Future<({AppState state, AppPaths paths, String root})> buildState() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final root = Directory.systemTemp.createTempSync('xchat_sandbox').path;
  final paths = await AppPaths.init(overrideRoot: root);
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
  return (state: state, paths: paths, root: root);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppPaths.resolveSandbox', () {
    late AppPaths paths;
    late String root;

    setUp(() async {
      final built = await buildState();
      paths = built.paths;
      root = built.root;
    });

    test('relative path is anchored at <root>/projects', () {
      expect(paths.resolveSandbox('foo/bar'), p.join(root, 'projects', 'foo', 'bar'));
    });

    test('bare name resolves to a direct child of projects', () {
      expect(paths.resolveSandbox('proj'), p.join(root, 'projects', 'proj'));
    });

    test('absolute path is kept (normalized) as-is', () {
      final abs = p.join(root, 'elsewhere', 'dir');
      expect(paths.resolveSandbox(abs), abs);
    });

    test('empty / whitespace input stays empty', () {
      expect(paths.resolveSandbox(''), '');
      expect(paths.resolveSandbox('   '), '');
    });

    test('parent traversal is normalized but still under projects', () {
      expect(paths.resolveSandbox('a/../b'), p.join(root, 'projects', 'b'));
    });
  });

  group('XML decode resolves relative sandbox against projects/', () {
    late String root;

    setUp(() async {
      final built = await buildState();
      root = built.root;
    });

    test('SessionXml.decode', () {
      final session = Session(
        id: 'sess-1',
        sandbox: 'team/alpha',
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
      );
      final xml = SessionXml.encode(session);
      final decoded = SessionXml.decode(xml, filePath: '/anywhere/x.xml');
      expect(decoded.sandbox, p.join(root, 'projects', 'team', 'alpha'));
    });

    test('ProjectXml.decode', () {
      final project = Project(
        id: 'proj-1',
        name: 'P',
        description: '',
        sandbox: 'team/alpha',
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
      );
      final xml = ProjectXml.encode(project);
      final decoded = ProjectXml.decode(xml, filePath: '/anywhere/y.xml');
      expect(decoded.sandbox, p.join(root, 'projects', 'team', 'alpha'));
    });

    test('absolute sandbox survives a round-trip unchanged', () {
      final abs = p.join(root, 'abs', 'dir');
      final xml = SessionXml.encode(Session(
        id: 'sess-abs',
        sandbox: abs,
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
      ));
      expect(
        SessionXml.decode(xml, filePath: '/anywhere/x.xml').sandbox,
        abs,
      );
    });
  });

  group('AppState normalizes sandbox on write', () {
    test('createProject stores an absolute projects/-anchored path', () async {
      final built = await buildState();
      final expected = p.join(built.root, 'projects', 'my', 'proj');

      final project = await built.state.createProject(sandbox: 'my/proj');
      expect(project.sandbox, expected);

      // Persisted XML must reload to the same absolute path.
      final reloaded = await built.state.projectRepository.read(project.id);
      expect(reloaded.sandbox, expected);
    });

    test('createSession stores an absolute projects/-anchored path', () async {
      final built = await buildState();
      final expected = p.join(built.root, 'projects', 'work');

      final session = await built.state.createSession(sandbox: 'work');
      expect(session.sandbox, expected);

      final reloaded = await built.state.sessionRepository.read(session.id);
      expect(reloaded.sandbox, expected);
    });

    test('createSession inherits a resolved project sandbox', () async {
      final built = await buildState();
      final project = await built.state.createProject(sandbox: 'shared');
      final session = await built.state.createSession(projectId: project.id);
      expect(session.sandbox, project.sandbox);
      expect(session.sandbox, p.join(built.root, 'projects', 'shared'));
    });

    test('empty sandbox falls back to the default session dir', () async {
      final built = await buildState();
      final session = await built.state.createSession();
      expect(session.sandbox, built.paths.sessionSandboxDir(session.id));
    });

    test('saveProject normalizes an edited relative sandbox', () async {
      final built = await buildState();
      final project = await built.state.createProject(sandbox: 'first');
      project.sandbox = 'second/nested';
      await built.state.saveProject(project);
      expect(project.sandbox, p.join(built.root, 'projects', 'second', 'nested'));

      final reloaded = await built.state.projectRepository.read(project.id);
      expect(reloaded.sandbox, p.join(built.root, 'projects', 'second', 'nested'));
    });
  });
}
