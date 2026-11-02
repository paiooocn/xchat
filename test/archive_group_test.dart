import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/models/archive_group.dart';
import 'package:xchat/models/project.dart';
import 'package:xchat/models/session.dart';

Project _project(String id, {String name = '', bool archived = false}) => Project(
      id: id,
      name: name,
      sandbox: '/tmp/xchat/projects/$id',
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
      archivedAt: archived ? DateTime.utc(2025, 6, 1) : null,
    );

Session _session(
  String id, {
  String projectId = '',
  bool archived = false,
}) =>
    Session(
      id: id,
      sandbox: '/tmp/xchat/sandboxs/$id',
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
      projectId: projectId,
      archivedAt: archived ? DateTime.utc(2025, 6, 1) : null,
    );

void main() {
  group('buildArchivedGlobalSessions', () {
    test('only the sessions without a project are global', () {
      final sessions = <Session>[
        _session('g1'),
        _session('p1', projectId: 'p1', archived: true),
        _session('g2'),
      ];
      final global = buildArchivedGlobalSessions(sessions);
      expect(global.map((s) => s.id).toList(), <String>['g1', 'g2']);
    });

    test('keeps the incoming order', () {
      final sessions = <Session>[_session('a'), _session('b')];
      expect(
        buildArchivedGlobalSessions(sessions).map((s) => s.id).toList(),
        <String>['a', 'b'],
      );
    });
  });

  group('buildArchiveProjectGroups', () {
    test('lists archived projects and projects with archived sessions', () {
      final groups = buildArchiveProjectGroups(
        projects: <Project>[
          _project('p1', name: 'Alpha'),
          _project('p2', name: 'Nothing'),
        ],
        archivedProjects: <Project>[_project('p3', name: 'Beta', archived: true)],
        sessions: <Session>[_session('s1', projectId: 'p1')],
        archivedSessions: <Session>[
          _session('s2', projectId: 'p1', archived: true),
        ],
      );
      expect(
        groups.map((g) => g.project.id).toList(),
        <String>['p1', 'p3'],
      );
    });

    test('badge「全部」: the project and all its sessions are archived', () {
      final groups = buildArchiveProjectGroups(
        projects: <Project>[],
        archivedProjects: <Project>[_project('p1', archived: true)],
        sessions: <Session>[],
        archivedSessions: <Session>[
          _session('s1', projectId: 'p1', archived: true),
          _session('s2', projectId: 'p1', archived: true),
        ],
      );
      expect(groups.single.badge, ArchiveBadge.all);
      expect(groups.single.badge.label, '全部');
      expect(groups.single.archivedCount, 2);
      expect(groups.single.totalSessions, 2);
    });

    test('badge「部分」: the project is archived but one session is active', () {
      final groups = buildArchiveProjectGroups(
        projects: <Project>[],
        archivedProjects: <Project>[_project('p1', archived: true)],
        sessions: <Session>[_session('s1', projectId: 'p1')],
        archivedSessions: <Session>[
          _session('s2', projectId: 'p1', archived: true),
        ],
      );
      expect(groups.single.badge, ArchiveBadge.partial);
      expect(groups.single.badge.label, '部分');
      expect(groups.single.archivedCount, 1);
      expect(groups.single.totalSessions, 2);
    });

    test('badge「部分」: an active project with some archived sessions', () {
      final groups = buildArchiveProjectGroups(
        projects: <Project>[_project('p1')],
        archivedProjects: <Project>[],
        sessions: <Session>[_session('s1', projectId: 'p1')],
        archivedSessions: <Session>[
          _session('s2', projectId: 'p1', archived: true),
        ],
      );
      expect(groups.single.badge, ArchiveBadge.partial);
    });

    test('no badge without archived sessions', () {
      final groups = buildArchiveProjectGroups(
        projects: <Project>[],
        archivedProjects: <Project>[_project('p1', archived: true)],
        sessions: <Session>[],
        archivedSessions: <Session>[],
      );
      expect(groups.single.badge, ArchiveBadge.none);
      expect(groups.single.badge.label, '');
    });

    test('a project without sessions gets no badge', () {
      final groups = buildArchiveProjectGroups(
        projects: <Project>[],
        archivedProjects: <Project>[_project('p1', archived: true)],
        sessions: <Session>[],
        archivedSessions: <Session>[],
      );
      expect(groups.single.badge, ArchiveBadge.none);
      expect(groups.single.totalSessions, 0);
    });

    test('the archived sessions of a project are its children', () {
      final groups = buildArchiveProjectGroups(
        projects: <Project>[_project('p1')],
        archivedProjects: <Project>[],
        sessions: <Session>[],
        archivedSessions: <Session>[
          _session('s2', projectId: 'p1', archived: true),
          _session('s1', projectId: 'p1', archived: true),
        ],
      );
      expect(
        groups.single.archivedSessions.map((s) => s.id).toList(),
        <String>['s2', 's1'],
      );
    });

    test('the groups are sorted by project name (unnamed last)', () {
      final groups = buildArchiveProjectGroups(
        projects: <Project>[
          _project('p1', name: 'B项目'),
          _project('p2', name: ''),
          _project('p3', name: 'A项目'),
        ],
        archivedProjects: <Project>[],
        sessions: <Session>[],
        archivedSessions: <Session>[
          _session('s1', projectId: 'p1', archived: true),
          _session('s2', projectId: 'p2', archived: true),
          _session('s3', projectId: 'p3', archived: true),
        ],
      );
      expect(
        groups.map((g) => g.project.name).toList(),
        <String>['A项目', 'B项目', ''],
      );
    });
  });
}
