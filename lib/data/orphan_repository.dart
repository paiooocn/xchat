import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import '../models/orphan_file.dart';
import 'index_repository.dart';
import 'project_repository.dart';
import 'session_repository.dart';
import 'xml/project_xml.dart';
import 'xml/session_xml.dart';

/// Finds and cleans up XML files that exist on disk but not in the catalog
/// index (`sessions/*.xml` / `projects/*.xml`).
///
/// Such leftovers come from interrupted deletes, hand-copied files, or a file
/// the index rebuild could not decode. They are deliberately **not** part of
/// the LAN sync list (`SyncRepository.manifest` reads the index only) — the
/// user decides here whether to bring one back into the catalog or drop it.
class OrphanRepository {
  OrphanRepository({
    required this.paths,
    required this.indexRepository,
    required this.sessionRepository,
    required this.projectRepository,
  });

  final AppPaths paths;
  final IndexRepository indexRepository;
  final SessionRepository sessionRepository;
  final ProjectRepository projectRepository;

  /// Lists every XML file under `sessions/` and `projects/` whose id is not in
  /// the index (archived entries count as indexed — they *are* in the catalog).
  Future<List<OrphanFile>> scan() async {
    final index = await indexRepository.load();
    final projectNames = <String, String>{
      for (final project in index.projects) project.id: project.name,
      for (final project in index.archivedProjects) project.id: project.name,
    };
    final out = <OrphanFile>[
      ...await _scanDir(
        dir: paths.sessionsDir,
        known: index.allSessionIds.toSet(),
        kind: 'session',
      ),
      ...await _scanDir(
        dir: paths.projectsDir,
        known: index.allProjectIds.toSet(),
        kind: 'project',
      ),
    ];
    for (var i = 0; i < out.length; i++) {
      final file = out[i];
      if (file.owner.isEmpty) continue;
      out[i] = OrphanFile(
        kind: file.kind,
        id: file.id,
        path: file.path,
        title: file.title,
        updatedAt: file.updatedAt,
        parsed: file.parsed,
        owner: projectNames[file.owner] ?? file.owner,
        error: file.error,
      );
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  Future<List<OrphanFile>> _scanDir({
    required String dir,
    required Set<String> known,
    required String kind,
  }) async {
    final directory = Directory(dir);
    if (!await directory.exists()) return <OrphanFile>[];
    final out = <OrphanFile>[];
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith('.xml')) continue;
      final id = name.substring(0, name.length - 4);
      if (id.isEmpty || known.contains(id)) continue;
      DateTime modified;
      try {
        modified = (await entity.stat()).modified;
      } catch (_) {
        modified = DateTime.fromMillisecondsSinceEpoch(0);
      }
      try {
        final text = await entity.readAsString();
        if (kind == 'project') {
          final project = ProjectXml.decode(text, filePath: entity.path);
          out.add(OrphanFile(
            kind: kind,
            id: id,
            path: p.normalize(entity.path),
            title: project.name.isEmpty ? '未命名项目' : project.name,
            updatedAt: project.updatedAt,
            parsed: true,
          ));
        } else {
          final session = SessionXml.decode(text, filePath: entity.path);
          out.add(OrphanFile(
            kind: kind,
            id: id,
            path: p.normalize(entity.path),
            title: session.title.isEmpty ? '未命名会话' : session.title,
            updatedAt: session.updatedAt,
            parsed: true,
            owner: session.projectId,
          ));
        }
      } catch (error) {
        out.add(OrphanFile(
          kind: kind,
          id: id,
          path: p.normalize(entity.path),
          title: id,
          updatedAt: modified,
          error: '$error',
        ));
      }
    }
    return out;
  }

  /// Puts [file] back into the catalog.
  ///
  /// The id is re-anchored at the file name (a file whose inner `<id>` differs
  /// from its name is exactly how such a leftover is produced), the file is
  /// rewritten at its canonical path, and the stale index entry of the old id
  /// (if any) is dropped. Archived state inside the file is kept as is.
  ///
  /// Returns null on success, or a human readable reason on failure.
  Future<String?> restore(OrphanFile file) async {
    final source = File(file.path);
    if (!await source.exists()) return '文件已不存在';
    final String text;
    try {
      text = await source.readAsString();
    } catch (error) {
      return '读不了文件：$error';
    }
    try {
      if (file.isProject) {
        final project = ProjectXml.decode(text, filePath: file.path);
        final previousId = project.id;
        project.id = file.id;
        await projectRepository.write(project);
        if (previousId.isNotEmpty && previousId != file.id) {
          await indexRepository.removeProject(previousId);
        }
        await _dropIfMoved(file.path, paths.projectFile(file.id));
        return null;
      }
      final session = SessionXml.decode(text, filePath: file.path);
      final previousId = session.id;
      session.id = file.id;
      await sessionRepository.write(session);
      if (previousId.isNotEmpty && previousId != file.id) {
        await indexRepository.removeSession(previousId);
      }
      await _dropIfMoved(file.path, paths.sessionFile(file.id));
      return null;
    } catch (error) {
      return '解析失败：$error';
    }
  }

  /// Deletes the file for good (it is not in the index, so nothing else to do).
  Future<String?> delete(OrphanFile file) async {
    try {
      final entity = File(file.path);
      if (await entity.exists()) await entity.delete();
      return null;
    } on FileSystemException catch (error) {
      return '删除失败：${error.message}';
    }
  }

  /// Removes the original file when [restore] wrote it at another path
  /// (only the file name differs, so this is the same content).
  Future<void> _dropIfMoved(String from, String to) async {
    if (p.equals(p.normalize(from), p.normalize(to))) return;
    try {
      final old = File(from);
      if (await old.exists()) await old.delete();
    } on FileSystemException {
      // Leaving a duplicate file behind is harmless.
    }
  }
}
