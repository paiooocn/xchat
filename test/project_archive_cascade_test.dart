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
import 'package:xchat/state/app_state.dart';

Future<AppState> buildState() async {
  SharedPreferences.setMockInitialValues({});
  final tmp = Directory.systemTemp.createTempSync('xchat_archive');
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
  test('archiving a project archives all of its sessions', () async {
    final state = await buildState();
    final project = await state.createProject(name: 'P1');
    final s1 = await state.createSession(projectId: project.id, title: 's1');
    final s2 = await state.createSession(projectId: project.id, title: 's2');

    await state.setProjectArchived(project.id, true);

    expect(state.archivedCountOfProject(project.id), 2);
    expect(
      state.archivedSessions.where((s) => s.projectId == project.id).length,
      2,
    );
    expect(state.sessions.where((s) => s.projectId == project.id), isEmpty);
    // The session files carry the archived marker.
    final reread = await state.sessionRepository.read(s1.id);
    expect(reread.archivedAt, isNotNull);
    expect((await state.sessionRepository.read(s2.id)).archivedAt, isNotNull);
  });

  test('restoring a project restores every session of it', () async {
    final state = await buildState();
    final project = await state.createProject(name: 'P1');
    await state.createSession(projectId: project.id, title: 's1');
    final s2 = await state.createSession(projectId: project.id, title: 's2');
    // One session was archived on its own before the project was archived.
    await state.setSessionArchived(s2.id, true);

    await state.setProjectArchived(project.id, true);
    expect(state.archivedCountOfProject(project.id), 2);

    await state.setProjectArchived(project.id, false);
    expect(state.archivedCountOfProject(project.id), 0);
    expect(state.sessions.where((s) => s.projectId == project.id).length, 2);
  });

  test('deleting a project deletes its sessions as well', () async {
    final state = await buildState();
    final project = await state.createProject(name: 'P1');
    final other = await state.createProject(name: 'P2');
    final s1 = await state.createSession(projectId: project.id, title: 's1');
    final keep = await state.createSession(projectId: other.id, title: 'keep');

    await state.deleteProject(project.id);

    expect(state.projectById(project.id), isNull);
    expect(
      state.sessions.where((s) => s.id == s1.id),
      isEmpty,
    );
    expect(state.archivedSessions.where((s) => s.id == s1.id), isEmpty);
    expect(
      await state.sessionRepository.exists(s1.id),
      isFalse,
    );
    // Other projects and their sessions survive.
    expect(state.projectById(other.id), isNotNull);
    expect(state.sessions.where((s) => s.id == keep.id).length, 1);
  });

  test('deleting a project recycles its working directory', () async {
    final state = await buildState();
    final project = await state.createProject(name: 'P1');
    final sandbox = project.sandbox;
    final marker = File('$sandbox/keep.txt');
    await marker.parent.create(recursive: true);
    await marker.writeAsString('data');

    await state.deleteProject(project.id);

    expect(Directory(sandbox).existsSync(), isFalse);
    final recycled = Directory(
      p.join(p.dirname(sandbox), '_rec_${p.basename(sandbox)}'),
    );
    expect(recycled.existsSync(), isTrue);
    expect(File(p.join(recycled.path, 'keep.txt')).readAsStringSync(), 'data');
  });
}
