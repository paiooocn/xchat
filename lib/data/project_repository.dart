import 'dart:io';

import '../core/app_paths.dart';
import '../models/project.dart';
import 'index_repository.dart';
import 'xml/project_xml.dart';

/// Reads/writes project XML files under `XChat/projects/`, served through the
/// catalog index for cheap listing/archiving.
class ProjectRepository {
  ProjectRepository(this.paths, this.indexRepository);

  final AppPaths paths;
  final IndexRepository indexRepository;

  Directory get _dir => Directory(paths.projectsDir);

  /// Lists active (non-archived) projects, by name.
  Future<List<Project>> list() async {
    final index = await indexRepository.load();
    final projects = index.projects.map((e) => e.toProject()).toList();
    projects.sort((a, b) => a.name.compareTo(b.name));
    return projects;
  }

  /// Lists archived projects.
  Future<List<Project>> listArchived() async {
    final index = await indexRepository.load();
    final projects = index.archivedProjects.map((e) => e.toProject()).toList();
    projects.sort((a, b) => a.name.compareTo(b.name));
    return projects;
  }

  Future<Project> read(String id) async {
    final file = File(paths.projectFile(id));
    if (!await file.exists()) {
      throw FileSystemException('Project file not found', file.path);
    }
    return ProjectXml.decode(await file.readAsString(), filePath: file.path);
  }

  Future<void> write(Project project) async {
    final dir = _dir;
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File(paths.projectFile(project.id));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(ProjectXml.encode(project), flush: true);
    await tmp.rename(target.path);
    await indexRepository.upsertProject(project);
  }

  Future<void> delete(String id) async {
    final file = File(paths.projectFile(id));
    if (await file.exists()) await file.delete();
    await indexRepository.removeProject(id);
  }
}
