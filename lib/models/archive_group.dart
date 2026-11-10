import 'project.dart';
import 'session.dart';

/// The badge shown on a project entry in the archive page.
///
/// * [all]   — the project itself is archived **and** every one of its
///   sessions is archived.
/// * [partial] — the project has archived sessions but does not satisfy the
///   "all" condition.
/// * [none] — nothing archived (or the project has no sessions at all).
enum ArchiveBadge {
  none,
  all,
  partial;

  /// The label shown in the UI (empty for [ArchiveBadge.none]).
  String get label => switch (this) {
        ArchiveBadge.all => '全部',
        ArchiveBadge.partial => '部分',
        ArchiveBadge.none => '',
      };
}

/// One project entry in the archive page: the project (parent) plus its
/// archived sessions (children).
class ArchiveProjectGroup {
  ArchiveProjectGroup({
    required this.project,
    required this.archivedSessions,
    required this.totalSessions,
    required this.badge,
  });

  /// The project the archived sessions belong to.
  final Project project;

  /// The project's archived sessions (children of the project entry).
  final List<Session> archivedSessions;

  /// Total number of sessions of the project (archived + still active).
  final int totalSessions;

  /// Number of archived sessions of the project.
  int get archivedCount => archivedSessions.length;

  /// How much of the project is archived (see [ArchiveBadge]).
  final ArchiveBadge badge;
}

/// The archived sessions that are not bound to any project ("global"
/// sessions) — they are listed on their own tab.
///
/// [missingProjectIds] covers the second case of «no project»: the session
/// still carries a `project` id, but that project no longer exists (its XML was
/// deleted / never synced). Such a session belongs to no project *group*, so
/// without this it would be invisible on both tabs.
List<Session> buildArchivedGlobalSessions(
  List<Session> archivedSessions, {
  Set<String> missingProjectIds = const <String>{},
}) =>
    archivedSessions
        .where((s) =>
            s.projectId.isEmpty || missingProjectIds.contains(s.projectId))
        .toList(growable: false);

/// Sessions whose owning project is **not** among [projectIds].
///
/// Callers pass the project ids they actually render (the sidebar passes the
/// active ones only — an archived project's sessions have no group there
/// either), so a session whose project was deleted or archived still shows up
/// somewhere instead of vanishing from every list.
List<Session> buildOrphanProjectSessions(
  List<Session> sessions, {
  required Set<String> projectIds,
}) =>
    sessions
        .where((s) => s.projectId.isNotEmpty && !projectIds.contains(s.projectId))
        .toList(growable: false);

/// Builds the project entries of the archive page.
///
/// A project shows up when it is archived itself or when at least one of its
/// sessions is archived. The badge tells how much of it is archived:
///
/// * [ArchiveBadge.all] — the project is archived **and** all of its sessions
///   are archived (a project without any session gets no badge at all);
/// * [ArchiveBadge.partial] — some sessions are archived, but the "all"
///   condition does not hold;
/// * [ArchiveBadge.none] — nothing archived.
List<ArchiveProjectGroup> buildArchiveProjectGroups({
  required List<Project> projects,
  required List<Project> archivedProjects,
  required List<Session> sessions,
  required List<Session> archivedSessions,
}) {
  final groups = <ArchiveProjectGroup>[];
  final seen = <String>{};

  for (final project in <Project>[...archivedProjects, ...projects]) {
    if (!seen.add(project.id)) continue;
    final archived = archivedSessions
        .where((s) => s.projectId == project.id)
        .toList(growable: false);
    final total = sessions.where((s) => s.projectId == project.id).length +
        archived.length;
    groups.add(
      ArchiveProjectGroup(
        project: project,
        archivedSessions: archived,
        totalSessions: total,
        badge: _badgeFor(project, archivedCount: archived.length, total: total),
      ),
    );
  }

  // Projects without anything archived are not shown at all.
  final visible = groups
      .where((g) => g.project.isArchived || g.archivedCount > 0)
      .toList(growable: false);

  visible.sort((a, b) {
    final left = a.project.name;
    final right = b.project.name;
    if (left.isEmpty && right.isEmpty) return 0;
    if (left.isEmpty) return 1;
    if (right.isEmpty) return -1;
    return left.compareTo(right);
  });
  return visible;
}

ArchiveBadge _badgeFor(
  Project project, {
  required int archivedCount,
  required int total,
}) {
  if (total == 0) return ArchiveBadge.none;
  if (project.isArchived && archivedCount == total) return ArchiveBadge.all;
  if (archivedCount > 0) return ArchiveBadge.partial;
  return ArchiveBadge.none;
}
