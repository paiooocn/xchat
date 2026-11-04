import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../models/catalog_index.dart';
import '../models/note.dart';
import '../models/project.dart';
import '../models/session.dart';
import 'xml/note_md.dart';
import 'xml/project_xml.dart';
import 'xml/session_xml.dart';

/// Maintains `XChat/index.json`: a five-bucket catalog of active/archived
/// sessions and projects plus the Markdown notes.
///
/// The index lets the UI list and filter sessions/projects/notes (and find
/// archived ones) without parsing every file; a session's messages and a
/// note's body are only read when the item is actually opened. The index is
/// validated against the directory contents on load and transparently rebuilt
/// when files changed on disk.
class IndexRepository {
  IndexRepository(this.paths);

  final AppPaths paths;

  CatalogIndex? _cached;

  Future<CatalogIndex> load() async {
    // Validate even the cached index against disk: sessions/projects can be
    // created, deleted or archived by another app instance (or an older app
    // version sharing the same data dir) while this one is running, and the
    // list must reflect that. The check is cheap (two directory listings
    // compared by id), so it runs on every load.
    final cached = _cached;
    if (cached != null && await _matchesDisk(cached)) return cached;
    final stored = await _readFile();
    if (stored != null && await _matchesDisk(stored)) {
      _cached = stored;
      return stored;
    }
    return rebuild();
  }

  /// Loads the index for a write, skipping the disk validation of [load].
  ///
  /// On the write path the caller has just written the session/project file,
  /// so the disk always looks out of sync with the index and [load] would
  /// rebuild the whole catalog — re-parsing every session file — on every
  /// single save (tens of milliseconds, growing with the session count).
  ///
  /// The catalog is only a cache: entries it misses (files added by another
  /// app instance) are merged back in by the next [load], which still
  /// validates against the disk.
  Future<CatalogIndex> _loadForWrite() async {
    final cached = _cached;
    if (cached != null) return cached;
    final stored = await _readFile();
    if (stored != null) {
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
      notes: await _scanNotes(),
    );
    await _persist(index);
    return index;
  }

  /// Scans `notes/` and builds the note summaries.
  ///
  /// Only the first [noteHeadBytes] of a note are read (the front-matter plus
  /// the beginning of the body) — a long note must not slow the list down.
  Future<List<NoteIndexEntry>> _scanNotes() async {
    final entries = <NoteIndexEntry>[];
    for (final file in await _noteFiles(paths.notesDir)) {
      try {
        final stat = await file.stat();
        final head = await _readNoteHead(file);
        final id = p.basenameWithoutExtension(file.path);
        final summary = decodeNoteSummary(
          head,
          fallbackId: id,
          fallbackCreatedAt: stat.modified.toUtc(),
          fallbackUpdatedAt: stat.modified.toUtc(),
        );
        entries.add(NoteIndexEntry.fromSummary(summary));
      } catch (_) {
        // Skip unreadable files rather than failing the whole catalog.
      }
    }
    return entries;
  }

  Future<void> upsertSession(Session session) async {
    final index = await _loadForWrite();
    _removeSession(index, session.id);
    final entry = SessionIndexEntry.fromSession(session);
    (session.isArchived ? index.archivedSessions : index.sessions).add(entry);
    await _persist(index);
  }

  Future<void> removeSession(String id) async {
    final index = await _loadForWrite();
    if (_removeSession(index, id)) await _persist(index);
  }

  Future<void> upsertProject(Project project) async {
    final index = await _loadForWrite();
    _removeProject(index, project.id);
    final entry = ProjectIndexEntry.fromProject(project);
    (project.isArchived ? index.archivedProjects : index.projects).add(entry);
    await _persist(index);
  }

  Future<void> removeProject(String id) async {
    final index = await _loadForWrite();
    if (_removeProject(index, id)) await _persist(index);
  }

  /// Adds/updates a note in the catalog.
  Future<void> upsertNote(Note note) async {
    final index = await _loadForWrite();
    _removeNote(index, note.id);
    index.notes.add(NoteIndexEntry(
      id: note.id,
      title: note.title,
      tags: List<String>.of(note.tags),
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      pinned: note.pinned,
      archivedAt: note.archivedAt,
      preview: previewFromBody(note.body),
    ));
    await _persist(index);
  }

  Future<void> removeNote(String id) async {
    final index = await _loadForWrite();
    if (_removeNote(index, id)) await _persist(index);
  }

  bool _removeNote(CatalogIndex index, String id) {
    final before = index.notes.length;
    index.notes.removeWhere((e) => e.id == id);
    return before != index.notes.length;
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
    final diskNotes = await _noteIds(paths.notesDir);
    return _sameSet(diskSessions, index.allSessionIds) &&
        _sameSet(diskProjects, index.allProjectIds) &&
        _sameSet(diskNotes, index.allNoteIds);
  }

  Future<Set<String>> _noteIds(String dir) async {
    final out = <String>{};
    for (final file in await _noteFiles(dir)) {
      out.add(p.basenameWithoutExtension(file.path));
    }
    return out;
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

  Future<List<File>> _noteFiles(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return <File>[];
    final out = <File>[];
    await for (final entity in d.list()) {
      if (entity is File && entity.path.endsWith('.md')) out.add(entity);
    }
    return out;
  }

  /// Reads the head of a note file (front-matter + the beginning of the body).
  ///
  /// Falls back to the whole file when the header does not fit into the head
  /// (a huge front-matter is unusual, but it must not corrupt the summary).
  Future<String> _readNoteHead(File file) async {
    final handle = await file.open();
    String head;
    try {
      final length = await handle.length();
      final count = length > noteHeadBytes ? noteHeadBytes : length;
      head = utf8.decode(await handle.read(count), allowMalformed: true);
    } finally {
      await handle.close();
    }
    if (head.startsWith('---') && !head.trimRight().endsWith('---')) {
      return file.readAsString();
    }
    return head;
  }

  Future<void> _persist(CatalogIndex index) async {
    _cached = index;
    final file = File(paths.indexFile);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    // No `flush`: the catalog is a cache — it is validated against the disk
    // on every load and transparently rebuilt when it is stale or truncated,
    // so an fsync here would only slow every save down.
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(index.toJson()),
    );
    await tmp.rename(file.path);
  }
}
