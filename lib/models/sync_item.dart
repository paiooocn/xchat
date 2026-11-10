import '../core/json_utils.dart';

/// What a sync item is. Only these two kinds travel over the LAN link.
enum SyncItemKind {
  project,
  session;

  static SyncItemKind parse(Object? value) =>
      asString(value) == project.name ? project : session;
}

/// Metadata-only description of one syncable item, sent in a manifest.
///
/// The same item (same id) may exist on both sides: the [key] is then equal and
/// the two lists tick it together.
class SyncItemSummary {
  SyncItemSummary({
    required this.kind,
    required this.id,
    this.title = '',
    this.subtitle = '',
    required this.updatedAt,
    this.sessionCount = 0,
    this.projectId = '',
  });

  final SyncItemKind kind;
  final String id;
  final String title;

  /// Project name for a session, a short hint for a project.
  final String subtitle;
  final DateTime updatedAt;

  /// Sessions owned by a project (0 for sessions).
  final int sessionCount;

  /// Owning project id of a **session** (empty for projects and standalone
  /// sessions). Drives the「勾项目 → 连带它的会话」联动 on both sides.
  final String projectId;

  /// Identity used by the two check lists: `session:<uuid>` / `project:<uuid>`.
  String get key => '${kind.name}:$id';

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'session_count': sessionCount,
        'project_id': projectId,
      };

  factory SyncItemSummary.fromJson(Object? value) {
    final json = asMap(value);
    return SyncItemSummary(
      kind: SyncItemKind.parse(json['kind']),
      id: asString(json['id']) ?? '',
      title: asString(json['title']) ?? '',
      subtitle: asString(json['subtitle']) ?? '',
      updatedAt: DateTime.tryParse(asString(json['updated_at']) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      sessionCount: asInt(json['session_count']) ?? 0,
      projectId: asString(json['project_id']) ?? '',
    );
  }
}

/// A complete item on the wire: metadata plus the raw XML document.
///
/// The XML is the on-disk format (see `data/xml/session_xml.dart` /
/// `project_xml.dart`); the receiver re-targets the working directory before
/// writing (工作目录不同步) — see `data/sync_repository.dart`.
class SyncItemPayload {
  SyncItemPayload({
    required this.kind,
    required this.id,
    this.title = '',
    required this.updatedAt,
    required this.xml,
  });

  final SyncItemKind kind;
  final String id;
  final String title;
  final DateTime updatedAt;
  final String xml;

  String get key => '${kind.name}:$id';

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'id': id,
        'title': title,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'xml': xml,
      };

  factory SyncItemPayload.fromJson(Object? value) {
    final json = asMap(value);
    return SyncItemPayload(
      kind: SyncItemKind.parse(json['kind']),
      id: asString(json['id']) ?? '',
      title: asString(json['title']) ?? '',
      updatedAt: DateTime.tryParse(asString(json['updated_at']) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      xml: asString(json['xml']) ?? '',
    );
  }
}

/// What an import actually did (both locally and on the peer).
class SyncImportOutcome {
  SyncImportOutcome();

  int imported = 0;
  final Set<String> touchedSessionIds = <String>{};
  final Set<String> touchedProjectIds = <String>{};

  /// Human readable reasons for the items that were not written.
  final List<String> skipped = <String>[];

  void merge(SyncImportOutcome other) {
    imported += other.imported;
    touchedSessionIds.addAll(other.touchedSessionIds);
    touchedProjectIds.addAll(other.touchedProjectIds);
    skipped.addAll(other.skipped);
  }
}

/// Result of one 同步 run (pull + push).
class SyncReport {
  SyncReport({
    this.pulled = 0,
    this.pushed = 0,
    List<String>? notes,
  }) : notes = notes ?? <String>[];

  final int pulled;
  final int pushed;
  final List<String> notes;

  bool get ok => notes.isEmpty;

  String get summary {
    final parts = <String>[
      if (pulled > 0) '接收 $pulled 项',
      if (pushed > 0) '发送 $pushed 项',
      if (pulled == 0 && pushed == 0) '没有需要同步的改动',
    ];
    return parts.join('，');
  }
}
