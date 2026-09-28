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
    await _writeAtomic(paths.sessionFile(session.id), SessionXml.encode(session));
    await indexRepository.upsertSession(session);
  }

  Future<void> writeTo(String path, Session session) async {
    await _writeAtomic(path, SessionXml.encode(session));
  }

  /// Writes via a `.tmp` file + rename so a crash can't truncate a session.
  ///
  /// `rename` over an existing file fails on some targets (Windows, and some
  /// Android storage backends), which used to abort the save entirely — fall
  /// back to dropping the old file first, then to a direct write.
  static Future<void> _writeAtomic(String path, String content) async {
    final target = File(path);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(content, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      if (await target.exists()) await target.delete();
      try {
        await tmp.rename(target.path);
      } on FileSystemException {
        await tmp.copy(target.path);
        await tmp.delete();
      }
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<void> delete(String id) async {
    final file = File(paths.sessionFile(id));
    if (await file.exists()) await file.delete();
    await indexRepository.removeSession(id);
  }

  Future<bool> exists(String id) => File(paths.sessionFile(id)).exists();
}
