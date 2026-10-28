import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/data/xml/project_xml.dart';
import 'package:xchat/models/catalog_index.dart';
import 'package:xchat/models/project.dart';

/// The `memory_enabled` flag must round-trip through the project XML and the
/// catalog index, and legacy files (without the field) must decode as
/// **disabled** — their behaviour may not change silently.
void main() {
  Project project({bool memoryEnabled = false}) => Project(
        id: 'p1',
        name: '项目一',
        description: '说明',
        sandbox: '/tmp/xchat/projects/p1',
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
        memoryEnabled: memoryEnabled,
      );

  group('ProjectXml', () {
    test('round-trips the memory flag', () {
      final xml = ProjectXml.encode(project(memoryEnabled: true));
      expect(xml.contains('<memory_enabled>true</memory_enabled>'), isTrue);

      final decoded = ProjectXml.decode(xml, filePath: '/tmp/xchat/projects/p1.xml');
      expect(decoded.memoryEnabled, isTrue);
    });

    test('a disabled project is written as false', () {
      final decoded = ProjectXml.decode(
        ProjectXml.encode(project()),
        filePath: '/tmp/xchat/projects/p1.xml',
      );
      expect(decoded.memoryEnabled, isFalse);
    });

    test('a project written before the flag existed decodes as "never set"', () {
      const legacy = '''<?xml version="1.0" encoding="UTF-8"?>
<project sandbox="/tmp/xchat/projects/p1">
  <id>p1</id>
  <name>项目一</name>
</project>
''';
      final decoded = ProjectXml.decode(legacy, filePath: '/tmp/xchat/projects/p1.xml');
      // null = never set: such a project counts as enabled only when its
      // `.memory/` directory already exists (see AppState.isMemoryEnabled).
      expect(decoded.memoryEnabled, isNull);
    });
  });

  group('ProjectIndexEntry', () {
    test('carries the memory flag through the catalog index', () {
      final entry = ProjectIndexEntry.fromProject(project(memoryEnabled: true));
      expect(entry.toJson()['memory_enabled'], isTrue);
      expect(entry.toProject().memoryEnabled, isTrue);

      final restored = ProjectIndexEntry.fromJson(entry.toJson());
      expect(restored.memoryEnabled, isTrue);
      expect(restored.toProject().memoryEnabled, isTrue);
    });

    test('an index written before the flag existed loads as "never set"', () {
      final restored = ProjectIndexEntry.fromJson(<String, Object?>{
        'id': 'p1',
        'sandbox': '/tmp/xchat/projects/p1',
      });
      expect(restored.memoryEnabled, isNull);
    });

    test('an explicit "off" survives the index round-trip', () {
      final entry = ProjectIndexEntry.fromProject(project(memoryEnabled: false));
      expect(entry.toJson()['memory_enabled'], isFalse);
      final restored = ProjectIndexEntry.fromJson(entry.toJson());
      expect(restored.memoryEnabled, isFalse);
    });
  });

  group('CatalogIndex', () {
    test('the version was bumped so old indexes are rebuilt', () {
      // Version 3 added `memory_enabled`; older index files lack the field.
      expect(CatalogIndex.version, greaterThanOrEqualTo(3));
    });
  });
}
