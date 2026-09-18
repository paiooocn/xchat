import 'dart:io';

import '../core/app_paths.dart';
import '../models/session.dart';
import 'index_repository.dart';
import 'xml/session_xml.dart';

/// Reads/writes session XML files under the sandbox directory.
///
/// Listing is served from the [IndexRepository] catalog (metadata only); the
/// full conversation is read from disk only when a session is opened.
class SessionRepository {
  SessionRepository(this.paths, this.indexRepository);

  final AppPaths paths;
  final IndexRepository indexRepository;

  Directory get _dir => Directory(paths.sessionsDir);

  /// Lists all active (non-archived) sessions, newest-updated first.
  Future<List<Session>> list() async {
    final index = await indexRepository.load();
    final sessions = index.sessions.map((e) => e.toSession()).toList();
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  /// Lists all archived sessions, newest-archived first.
  Future<List<Session>> listArchived() async {
    final index = await indexRepository.load();
    final sessions = index.archivedSessions.map((e) => e.toSession()).toList();
    sessions.sort((a, b) =>
        (b.archivedAt ?? b.updatedAt).compareTo(a.archivedAt ?? a.updatedAt));
    return sessions;
  }

  /// Reads a session by id from the default sandbox.
  Future<Session> read(String id) => readPath(paths.sessionFile(id));

  Future<Session> readPath(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Session file not found', path);
    }
    return SessionXml.decode(await file.readAsString(), filePath: path);
  }

  /// Atomically writes a session to `<sandbox>/<id>.xml` and refreshes the
  /// catalog index.
  Future<void> write(Session session) async {
    session.ensureSystem();
    final dir = _dir;
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File(paths.sessionFile(session.id));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(SessionXml.encode(session), flush: true);
    await tmp.rename(target.path);
    await indexRepository.upsertSession(session);
  }

  Future<void> writeTo(String path, Session session) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(SessionXml.encode(session), flush: true);
    await tmp.rename(path);
  }

  Future<void> delete(String id) async {
    final file = File(paths.sessionFile(id));
    if (await file.exists()) await file.delete();
    await indexRepository.removeSession(id);
  }

  Future<bool> exists(String id) => File(paths.sessionFile(id)).exists();
}
