/// Markdown notes: a note is one `<root>/notes/<id>.md` file with a
/// front-matter header and a Markdown body.
///
/// The model is pure data — parsing/serializing lives in
/// `lib/data/xml/note_md.dart` (serialization only in the data layer).
library;

/// A complete note: metadata + Markdown body.
class Note {
  Note({
    required this.id,
    this.title = '',
    List<String>? tags,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.archivedAt,
    this.body = '',
    Map<String, String>? extra,
  })  : tags = tags ?? <String>[],
        extra = extra ?? <String, String>{};

  /// Stable id (UUID); also the file name (`<id>.md`).
  String id;

  /// Display title. Empty means "derive it from the body's first heading".
  String title;

  List<String> tags;
  DateTime createdAt;
  DateTime updatedAt;

  /// Whether the note is pinned to the top of the list.
  bool pinned;

  /// Non-null when the note is archived (it then leaves the active list).
  DateTime? archivedAt;

  /// The Markdown body, stored verbatim (no reformatting on save).
  String body;

  /// Front-matter keys outside the known set, kept verbatim so a round trip
  /// never drops data the user (or another tool) added.
  Map<String, String> extra;

  bool get archived => archivedAt != null;

  Note copyWith({
    String? title,
    List<String>? tags,
    DateTime? updatedAt,
    bool? pinned,
    DateTime? archivedAt,
    bool clearArchived = false,
    String? body,
    Map<String, String>? extra,
  }) =>
      Note(
        id: id,
        title: title ?? this.title,
        tags: tags ?? List<String>.of(this.tags),
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        pinned: pinned ?? this.pinned,
        archivedAt: clearArchived ? null : (archivedAt ?? this.archivedAt),
        body: body ?? this.body,
        extra: extra ?? Map<String, String>.of(this.extra),
      );
}

/// The list projection of a note: metadata + a short preview, no body.
///
/// The list is served from the catalog index, so opening the list never
/// parses whole note files; the body is read only when a note is opened.
class NoteSummary {
  NoteSummary({
    required this.id,
    this.title = '',
    List<String>? tags,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.archivedAt,
    this.preview = '',
  }) : tags = tags ?? <String>[];

  String id;
  String title;
  List<String> tags;
  DateTime createdAt;
  DateTime updatedAt;
  bool pinned;
  DateTime? archivedAt;

  /// First ~80 characters of the body.
  String preview;

  bool get archived => archivedAt != null;
}

/// The `notes` bucket entry of the catalog index (`index.json`).
class NoteIndexEntry {
  NoteIndexEntry({
    required this.id,
    this.title = '',
    List<String>? tags,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.archivedAt,
    this.preview = '',
  }) : tags = tags ?? <String>[];

  String id;
  String title;
  List<String> tags;
  DateTime createdAt;
  DateTime updatedAt;
  bool pinned;
  DateTime? archivedAt;
  String preview;

  bool get archived => archivedAt != null;

  factory NoteIndexEntry.fromSummary(NoteSummary summary) => NoteIndexEntry(
        id: summary.id,
        title: summary.title,
        tags: List<String>.of(summary.tags),
        createdAt: summary.createdAt,
        updatedAt: summary.updatedAt,
        pinned: summary.pinned,
        archivedAt: summary.archivedAt,
        preview: summary.preview,
      );

  NoteSummary toSummary() => NoteSummary(
        id: id,
        title: title,
        tags: List<String>.of(tags),
        createdAt: createdAt,
        updatedAt: updatedAt,
        pinned: pinned,
        archivedAt: archivedAt,
        preview: preview,
      );

  factory NoteIndexEntry.fromJson(Object? value) {
    final json = value is Map
        ? value.map((key, v) => MapEntry(key.toString(), v))
        : const <String, Object?>{};
    return NoteIndexEntry(
      id: _str(json['id']) ?? '',
      title: _str(json['title']) ?? '',
      tags: (json['tags'] is List)
          ? (json['tags'] as List).map((e) => e.toString()).toList()
          : const <String>[],
      createdAt: DateTime.tryParse(_str(json['created_at']) ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(_str(json['updated_at']) ?? '') ?? DateTime.now(),
      pinned: json['pinned'] == true,
      archivedAt: DateTime.tryParse(_str(json['archived_at']) ?? ''),
      preview: _str(json['preview']) ?? '',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        if (tags.isNotEmpty) 'tags': tags,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'pinned': pinned,
        if (archivedAt != null) 'archived_at': archivedAt!.toUtc().toIso8601String(),
        'preview': preview,
      };
}

String? _str(Object? value) => value is String ? value : null;
