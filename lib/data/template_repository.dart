import 'dart:io';

import '../core/app_paths.dart';
import '../data/xml/template_xml.dart';
import '../models/session_template.dart';

/// Reads/writes session template XML files under `XChat/templates/`.
class TemplateRepository {
  TemplateRepository(this.paths);

  final AppPaths paths;

  Directory get _dir => Directory(paths.templatesDir);

  Future<List<SessionTemplate>> list() async {
    final dir = _dir;
    if (!await dir.exists()) return <SessionTemplate>[];
    final templates = <SessionTemplate>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.xml')) continue;
      try {
        templates.add(TemplateXml.decode(await entity.readAsString()));
      } catch (_) {
        // ignore malformed templates
      }
    }
    templates.sort((a, b) => a.name.compareTo(b.name));
    return templates;
  }

  Future<SessionTemplate> read(String id) async {
    final file = File(paths.templateFile(id));
    if (!await file.exists()) {
      throw FileSystemException('Template file not found', file.path);
    }
    return TemplateXml.decode(await file.readAsString());
  }

  Future<void> write(SessionTemplate template) async {
    final dir = _dir;
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File(paths.templateFile(template.id));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(TemplateXml.encode(template), flush: true);
    await tmp.rename(target.path);
  }

  Future<void> delete(String id) async {
    final file = File(paths.templateFile(id));
    if (await file.exists()) await file.delete();
  }
}
