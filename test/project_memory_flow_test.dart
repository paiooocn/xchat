import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/core/memory_protocol.dart';
import 'package:xchat/data/config_repository.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/project_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/template_repository.dart';
import 'package:xchat/state/app_state.dart';

/// End-to-end behaviour of the project memory index:
/// creating a project initialises `.memory/`, and a session inside that
/// project gets the memory protocol injected into its system prompt.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState state;
  late Directory tmp;

  Future<AppState> buildState() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('xchat_project_memory');
    final paths = await AppPaths.init(overrideRoot: tmp.path);
    final index = IndexRepository(paths);
    final appState = AppState(
      paths: paths,
      configRepository: ConfigRepository(paths),
      sessionRepository: SessionRepository(paths, index),
      templateRepository: TemplateRepository(paths),
      projectRepository: ProjectRepository(paths, index),
      indexRepository: index,
    );
    await appState.load();
    return appState;
  }

  String systemPromptOf(String sessionId) =>
      state.sessionById(sessionId)!.messages.first.content ?? '';

  setUp(() async {
    state = await buildState();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('creating a project initialises the .memory skeleton', () async {
    final project = await state.createProject(name: 'P1');
    final dir = Directory(p.join(project.sandbox, kMemoryDirName));
    expect(dir.existsSync(), isTrue);
    final names = dir.listSync().whereType<File>().map((f) => p.basename(f.path)).toSet();
    expect(names, kMemoryFileNames.toSet());
  });

  test('a project can opt out of the memory index', () async {
    final project = await state.createProject(name: 'P2', memoryEnabled: false);
    expect(
      Directory(p.join(project.sandbox, kMemoryDirName)).existsSync(),
      isFalse,
    );
    expect(project.memoryEnabled, isFalse);
  });

  test('a session in a project with memory gets the protocol injected', () async {
    final project = await state.createProject(name: 'P3');
    final session = await state.createSession(projectId: project.id);
    final prompt = systemPromptOf(session.id);
    expect(prompt, startsWith('工作空间根目录: '));
    expect(prompt, contains('.memory/'));
    expect(prompt, contains('STATE.md'));
  });

  test('the protocol can be switched off per session', () async {
    final project = await state.createProject(name: 'P4');
    final session =
        await state.createSession(projectId: project.id, useMemoryProtocol: false);
    expect(systemPromptOf(session.id), isNot(contains('.memory/')));
  });

  test('a project without memory gets no protocol', () async {
    final project = await state.createProject(name: 'P5', memoryEnabled: false);
    final session = await state.createSession(projectId: project.id);
    expect(systemPromptOf(session.id), isNot(contains('.memory/')));
  });

  test('an existing .memory directory enables the protocol (self-heal)', () async {
    final project = await state.createProject(name: 'P6', memoryEnabled: false);
    // 老项目：开关从未设置过（null），但目录已经在了 → 按「已启用」自愈。
    project.memoryEnabled = null;
    await state.projectRepository.write(project);
    await state.refreshProjects();
    Directory(p.join(project.sandbox, kMemoryDirName)).createSync(recursive: true);
    final session = await state.createSession(projectId: project.id);
    expect(systemPromptOf(session.id), contains('.memory/'));
  });

  test('an explicitly disabled project stays disabled', () async {
    final project = await state.createProject(name: 'P9');
    project.memoryEnabled = false;
    await state.projectRepository.write(project);
    await state.refreshProjects();
    // 目录还在，但用户明确关了开关 → 不注入协议。
    final session = await state.createSession(projectId: project.id);
    expect(systemPromptOf(session.id), isNot(contains('.memory/')));
    expect(state.isMemoryEnabled(state.projectById(project.id)!), isFalse);
  });

  test('projectsWithoutMemory lists the projects without an index', () async {
    final withMemory = await state.createProject(name: '有记忆');
    final without = await state.createProject(name: '没记忆', memoryEnabled: false);
    final missing =
        state.projectsWithoutMemory().map((p) => p.id).toSet();
    expect(missing, contains(without.id));
    expect(missing, isNot(contains(withMemory.id)));
  });

  test('backfillProjectMemory creates the missing indexes and enables them',
      () async {
    final legacy = await state.createProject(name: '老项目', memoryEnabled: false);
    legacy.memoryEnabled = null;
    await state.projectRepository.write(legacy);
    await state.refreshProjects();

    final touched = await state.backfillProjectMemory();
    expect(touched, greaterThanOrEqualTo(1));
    expect(
      Directory(p.join(legacy.sandbox, kMemoryDirName)).existsSync(),
      isTrue,
    );
    final reloaded = state.projectById(legacy.id)!;
    expect(reloaded.memoryEnabled, isTrue);
    expect(state.isMemoryEnabled(reloaded), isTrue);
  });

  test('healProjectMemory restores a deleted index on start', () async {
    final project = await state.createProject(name: '被误删');
    final dir = Directory(p.join(project.sandbox, kMemoryDirName));
    dir.deleteSync(recursive: true);

    final healed = await state.healProjectMemory();
    expect(healed, 1);
    expect(dir.existsSync(), isTrue);
  });

  test('a session created from an already-injected prompt keeps one block',
      () async {
    final project = await state.createProject(name: 'P11');
    final source = await state.createSession(projectId: project.id);
    final stored = source.systemPrompt;
    expect(stored.contains(kMemoryProtocolMarker), isTrue);

    // 模拟「压缩会话」：把已经含协议块的提示词再交给 createSession。
    final clone = await state.createSession(
      projectId: project.id,
      systemPrompt: stored,
    );
    expect(
      kMemoryProtocolMarker.allMatches(clone.systemPrompt).length,
      1,
      reason: '协议块只能出现一次，否则压缩出来的会话会白烧 token',
    );
  });

  test('the flag survives a save/load round-trip', () async {
    final project = await state.createProject(name: 'P7');
    await state.saveProject(project);
    await state.refreshProjects();
    final reloaded = state.projectById(project.id)!;
    expect(reloaded.memoryEnabled, isTrue);
  });

  test('ensureProjectMemory fills in the missing files only', () async {
    final project = await state.createProject(name: 'P8');
    final stateFile = File(p.join(project.sandbox, kMemoryDirName, 'STATE.md'));
    await stateFile.writeAsString('手写的内容');
    final mapFile = File(p.join(project.sandbox, kMemoryDirName, 'MAP.yaml'));
    await mapFile.delete();

    expect(await state.ensureProjectMemory(project), isTrue);
    expect(stateFile.readAsStringSync(), '手写的内容');
    expect(mapFile.existsSync(), isTrue);
  });
}
