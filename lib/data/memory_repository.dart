import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/memory_protocol.dart';
import '../models/memory_status.dart';

/// Reads and initialises the `.memory/` index of a project sandbox.
///
/// The index lives **inside** the project folder (`<sandbox>/.memory/`), so it
/// travels with the project, can be committed to version control and is
/// reachable by the agent's ordinary file tools.
///
/// Writes are non-destructive: initialising an existing index only fills in
/// the files that are missing, it never overwrites what the agent wrote.
class MemoryRepository {
  const MemoryRepository();

  /// Absolute path of the memory directory for [sandbox].
  String memoryDir(String sandbox) => p.join(sandbox, kMemoryDirName);

  /// Creates the index (and the missing skeleton files) for [sandbox].
  ///
  /// Returns false when the sandbox is empty or not writable — the caller
  /// treats that as "this project has no memory" instead of failing.
  Future<bool> ensureSkeleton(String sandbox, {String projectName = ''}) async {
    if (sandbox.trim().isEmpty) return false;
    final dir = Directory(memoryDir(sandbox));
    try {
      await dir.create(recursive: true);
      final templates = memorySkeletonTemplates(projectName: projectName);
      for (final entry in templates.entries) {
        final file = File(p.join(dir.path, entry.key));
        if (await file.exists()) continue; // Never clobber the agent's notes.
        await file.writeAsString(entry.value, flush: true);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether the index directory already exists.
  bool exists(String sandbox) {
    if (sandbox.trim().isEmpty) return false;
    return Directory(memoryDir(sandbox)).existsSync();
  }

  /// Reads the current state of the index (files + last modification time).
  Future<MemoryStatus> status(String sandbox) async {
    if (sandbox.trim().isEmpty) {
      return const MemoryStatus(exists: false);
    }
    final dir = Directory(memoryDir(sandbox));
    if (!await dir.exists()) {
      return const MemoryStatus(exists: false);
    }
    final files = <String>[];
    DateTime? newest;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        files.add(p.basename(entity.path));
        final stat = await entity.stat();
        final modified = stat.modified;
        if (newest == null || modified.isAfter(newest)) newest = modified;
      }
    } catch (_) {
      // A partially readable directory is still reported as existing.
    }
    files.sort();
    return MemoryStatus(exists: true, files: files, lastModified: newest);
  }
}
