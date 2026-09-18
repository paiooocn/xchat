import 'dart:convert';
import 'dart:io';

import '../core/app_paths.dart';
import '../models/catalog_index.dart';
import '../models/project.dart';
import '../models/session.dart';
import 'xml/project_xml.dart';
import 'xml/session_xml.dart';

/// Maintains `XChat/index.json`: a four-bucket catalog of active/archived
/// sessions and projects.
///
/// The index lets the UI list and filter sessions/projects (and find archived
/// ones) without parsing every XML file; a session's messages are only read
/// when it is actually opened. The index is validated against the directory
/// contents on load and transparently rebuilt when files changed on disk.
class IndexRepository {
  IndexRepository(this.paths);

  final AppPaths paths;

  CatalogIndex? _cached;

  Future<CatalogIndex> load() async {
    final cached = _cached;
    if (cached != null) return cached;
    final stored = await _readFile();
    if (stored != null && await _matchesDisk(stored)) {
      _cached = stored;
      return stored;
    }
    return rebuild();
  }

  /// Forces a rebuild by re-parsing every session/project file.
  Future<CatalogIndex> rebuild() async {
    final sessions = <SessionIndexEntry>[];
    final archivedSessions = <SessionIndexEntry>[];
    final projects = <ProjectIndexEntry>[];
    final archivedProjects = <ProjectIndexEntry>[];

    for (final file in await _xmlFiles(paths.sessionsDir)) {
      try {
        final session = SessionXml.decode(await file.readAsString(), filePath: file.path);
        final entry = SessionIndexEntry.fromSession(session);
        (session.isArchived ? archivedSessions : sessions).add(entry);
      } catch (_) {
        // Skip corrupt files rather than failing the whole catalog.
      }
    }
    for (final file in await _xmlFiles(paths.projectsDir)) {
      try {
        final project = ProjectXml.decode(await file.readAsString(), filePath: file.path);
        final entry = ProjectIndexEntry.fromProject(project);
        (project.isArchived ? archivedProjects : projects).add(entry);
      } catch (_) {
        // Skip corrupt files.
      }
    }

    final index = CatalogIndex(
      sessions: sessions,
      projects: projects,
      archivedSessions: archivedSessions,
      archivedProjects: archivedProjects,
    );
    await _persist(index);
    return index;
  }

  Future<void> upsertSession(Session session) async {
    final index = await load();
    _removeSession(index, session.id);
    final entry = SessionIndexEntry.fromSession(session);
    (session.isArchived ? index.archivedSessions : index.sessions).add(entry);
    await _persist(index);
  }

  Future<void> removeSession(String id) async {
    final index = await load();
    if (_removeSession(index, id)) await _persist(index);
  }

  Future<void> upsertProject(Project project) async {
    final index = await load();
    _removeProject(index, project.id);
    final entry = ProjectIndexEntry.fromProject(project);
    (project.isArchived ? index.archivedProjects : index.projects).add(entry);
    await _persist(index);
  }

  Future<void> removeProject(String id) async {
    final index = await load();
    if (_removeProject(index, id)) await _persist(index);
  }

  bool _removeSession(CatalogIndex index, String id) {
    final before = index.sessions.length + index.archivedSessions.length;
    index.sessions.removeWhere((e) => e.id == id);
    index.archivedSessions.removeWhere((e) => e.id == id);
    return before != index.sessions.length + index.archivedSessions.length;
  }

  bool _removeProject(CatalogIndex index, String id) {
    final before = index.projects.length + index.archivedProjects.length;
    index.projects.removeWhere((e) => e.id == id);
    index.archivedProjects.removeWhere((e) => e.id == id);
    return before != index.projects.length + index.archivedProjects.length;
  }

  Future<CatalogIndex?> _readFile() async {
    final file = File(paths.indexFile);
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map || json['version'] != CatalogIndex.version) return null;
      return CatalogIndex.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _matchesDisk(CatalogIndex index) async {
    final diskSessions = await _dirIds(paths.sessionsDir);
    final diskProjects = await _dirIds(paths.projectsDir);
    return _sameSet(diskSessions, index.allSessionIds) &&
        _sameSet(diskProjects, index.allProjectIds);
  }

  Future<Set<String>> _dirIds(String dir) async {
    final out = <String>{};
    for (final file in await _xmlFiles(dir)) {
      final name = file.uri.pathSegments.last;
      out.add(name.endsWith('.xml') ? name.substring(0, name.length - 4) : name);
    }
    return out;
  }

  bool _sameSet(Set<String> a, Iterable<String> b) {
    final set = b.toSet();
    return a.length == set.length && a.every(set.contains);
  }

  Future<List<File>> _xmlFiles(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return <File>[];
    final out = <File>[];
    await for (final entity in d.list()) {
      if (entity is File && entity.path.endsWith('.xml')) out.add(entity);
    }
    return out;
  }

  Future<void> _persist(CatalogIndex index) async {
    _cached = index;
    final file = File(paths.indexFile);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(index.toJson()),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
