import 'package:xml/xml.dart';

import '../../models/project.dart';
import 'cdata.dart';
import 'xml_writer.dart';

/// Project ⇄ XML codec.
///
/// ```xml
/// <project sandbox="...">
///   <id>...</id>
///   <name>...</name>
///   <description>...</description>
///   <created_at>...</created_at>
///   <updated_at>...</updated_at>
///   <provider>...</provider>
///   <model>...</model>
/// </project>
/// ```
class ProjectXml {
  const ProjectXml._();

  static String encode(Project project) {
    final out = XmlOut();
    out.declaration();
    out.open('project', {'sandbox': project.sandbox});
    out.leafText('id', project.id);
    out.leafText('name', project.name);
    out.leafText('description', project.description);
    out.leafText('created_at', project.createdAt.toUtc().toIso8601String());
    out.leafText('updated_at', project.updatedAt.toUtc().toIso8601String());
    out.leafText('provider', project.provider);
    out.leafText('model', project.model);
    if (project.archivedAt != null) {
      out.leafText('archived_at', project.archivedAt!.toUtc().toIso8601String());
    }
    out.close('project');
    return out.build();
  }

  static Project decode(String xml, {required String filePath}) {
    final document = XmlDocument.parse(xml);
    final root = document.rootElement;
    if (root.name.local != 'project') {
      throw FormatException('Root element must be <project>, got <${root.name.local}>');
    }
    final id = readTextOrEmpty(root, 'id');
    final createdAt =
        DateTime.tryParse(readTextOrEmpty(root, 'created_at')) ?? DateTime.now();
    return Project(
      id: id.isEmpty ? _basename(filePath) : id,
      name: readTextOrEmpty(root, 'name'),
      description: readTextOrEmpty(root, 'description'),
      sandbox: root.getAttribute('sandbox') ?? _dirname(filePath),
      createdAt: createdAt,
      updatedAt: DateTime.tryParse(readTextOrEmpty(root, 'updated_at')) ?? createdAt,
      provider: readTextOrEmpty(root, 'provider'),
      model: readTextOrEmpty(root, 'model'),
      archivedAt: DateTime.tryParse(readTextOrEmpty(root, 'archived_at')),
    );
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final name = normalized.split('/').last;
    return name.endsWith('.xml') ? name.substring(0, name.length - 4) : name;
  }

  static String _dirname(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index <= 0 ? '' : normalized.substring(0, index);
  }
}
