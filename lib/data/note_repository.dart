import 'dart:io';

import '../core/app_paths.dart';
import '../models/note.dart';
import 'atomic_file.dart';
import 'index_repository.dart';
import 'xml/note_md.dart';

/// Reads/writes Markdown notes under `XChat/notes/`.
///
/// A note is one `<id>.md` file (front-matter header + Markdown body).
/// Listing is served from the [IndexRepository] catalog (metadata + preview
/// only); the body is read from disk only when a note is opened.
class NoteRepository {
  NoteRepository(this.paths, this.indexRepository);

  final AppPaths paths;
  final IndexRepository indexRepository;

  Directory get _dir => Directory(paths.notesDir);

  /// Lists all notes (active **and** archived), pinned first, newest first.
  ///
  /// The caller splits the list by [NoteSummary.archived].
  Future<List<NoteSummary>> list() async {
    final index = await indexRepository.load();
    final notes = index.notes.map((e) => e.toSummary()).toList();
    notes.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return notes;
  }

  /// Reads a note (including its body) by id.
  Future<Note> read(String id) async {
    final file = File(paths.noteFile(id));
    if (!await file.exists()) {
      throw FileSystemException('Note file not found', file.path);
    }
    final stat = await file.stat();
    return decodeNote(
      await file.readAsString(),
      fallbackId: id,
      fallbackCreatedAt: stat.modified.toUtc(),
      fallbackUpdatedAt: stat.modified.toUtc(),
    );
  }

  /// Atomically writes a note and refreshes the catalog index.
  Future<void> write(Note note) async {
    final dir = _dir;
    if (!await dir.exists()) await dir.create(recursive: true);
    await writeAtomic(paths.noteFile(note.id), encodeNote(note));
    await indexRepository.upsertNote(note);
  }

  Future<void> delete(String id) async {
    final file = File(paths.noteFile(id));
    if (await file.exists()) await file.delete();
    await indexRepository.removeNote(id);
  }

  Future<bool> exists(String id) => File(paths.noteFile(id)).exists();

  /// Last modification time of a note file (null when it does not exist).
  ///
  /// Used to detect changes made outside the app (another editor).
  Future<DateTime?> modifiedAt(String id) async {
    final file = File(paths.noteFile(id));
    if (!await file.exists()) return null;
    return (await file.stat()).modified;
  }
}
