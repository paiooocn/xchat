/// Serialization of Markdown notes: the front-matter header and the body.
///
/// This is the **only** place where a note file is assembled or taken apart
/// (invariant: serialization lives in the data layer only).
///
/// Format:
///
/// ```markdown
/// ---
/// id: 9f2c1e0a-...
/// title: 会议纪要 · 2026-11-04
/// tags: [会议, 项目A]
/// created_at: 2026-11-04T09:12:33Z
/// updated_at: 2026-11-04T10:02:11Z
/// pinned: false
/// archived_at: null
/// ---
///
/// # 正文从这里开始
/// ```
///
/// Rules:
/// * the body is stored **verbatim** — no reformatting (except the single
///   blank line that separates it from the header);
/// * unknown front-matter keys are preserved as-is;
/// * a file without a front-matter header is a "bare" Markdown file: it is
///   imported as a note (the header is added on the next save).
library;

import '../../models/note.dart';

/// The front-matter keys this app understands. Everything else is preserved
/// verbatim in [Note.extra].
const Set<String> noteFrontMatterKeys = <String>{
  'id',
  'title',
  'tags',
  'created_at',
  'updated_at',
  'pinned',
  'archived_at',
};

/// How many characters of the body end up in the list preview.
const int notePreviewLength = 80;

/// How many bytes of a note file are read for the list scan (front-matter +
/// the beginning of the body).
const int noteHeadBytes = 4096;

/// Assembles a note file.
String encodeNote(Note note) {
  final buffer = StringBuffer()
    ..writeln('---')
    ..writeln('id: ${_scalar(note.id)}')
    ..writeln('title: ${_scalar(note.title)}')
    ..writeln('tags: [${note.tags.map(_scalar).join(', ')}]')
    ..writeln('created_at: ${_scalar(note.createdAt.toUtc().toIso8601String())}')
    ..writeln('updated_at: ${_scalar(note.updatedAt.toUtc().toIso8601String())}')
    ..writeln('pinned: ${note.pinned}')
    ..writeln(
      'archived_at: ${note.archivedAt == null ? 'null' : _scalar(note.archivedAt!.toUtc().toIso8601String())}',
    );
  for (final entry in note.extra.entries) {
    buffer.writeln('${entry.key}: ${entry.value}');
  }
  buffer
    ..writeln('---')
    ..writeln()
    ..write(note.body);
  return buffer.toString();
}

/// Parses a note file.
///
/// [fallbackId] is used when the header carries no `id` (bare Markdown file);
/// [fallbackCreatedAt]/[fallbackUpdatedAt] fill in missing timestamps.
Note decodeNote(
  String content, {
  required String fallbackId,
  DateTime? fallbackCreatedAt,
  DateTime? fallbackUpdatedAt,
}) {
  final lines = content.split('\n');
  final hasHeader = lines.isNotEmpty && lines.first.trim() == '---';
  var end = -1;
  if (hasHeader) {
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        end = i;
        break;
      }
    }
  }
  if (end < 0) {
    // No (or unterminated) header → the whole file is a bare Markdown note.
    return _bareNote(content, fallbackId, fallbackCreatedAt, fallbackUpdatedAt);
  }

  final fields = <String, String>{};
  final extra = <String, String>{};
  for (var i = 1; i < end; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    final separator = line.indexOf(':');
    if (separator < 0) continue;
    final key = line.substring(0, separator).trim();
    if (key.isEmpty) continue;
    final value = line.substring(separator + 1).trim();
    if (noteFrontMatterKeys.contains(key)) {
      fields[key] = value;
    } else {
      extra[key] = value;
    }
  }

  final body = _bodyFrom(lines, end);
  var title = _unquote(fields['title'] ?? '');
  if (title.isEmpty) title = titleFromBody(body);
  final id = _unquote(fields['id'] ?? '');

  return Note(
    id: id.isEmpty ? fallbackId : id,
    title: title,
    tags: parseTags(fields['tags'] ?? ''),
    createdAt: _parseTime(fields['created_at']) ??
        fallbackCreatedAt ??
        DateTime.now().toUtc(),
    updatedAt: _parseTime(fields['updated_at']) ??
        fallbackUpdatedAt ??
        fallbackCreatedAt ??
        DateTime.now().toUtc(),
    pinned: (fields['pinned'] ?? '').toLowerCase() == 'true',
    archivedAt: _parseTime(fields['archived_at']),
    body: body,
    extra: extra,
  );
}

/// Parses only the header (and the beginning of the body) of a note file.
///
/// Used for the list scan, which only reads the first few KB of a file.
NoteSummary decodeNoteSummary(
  String content, {
  required String fallbackId,
  DateTime? fallbackCreatedAt,
  DateTime? fallbackUpdatedAt,
}) {
  final note = decodeNote(
    content,
    fallbackId: fallbackId,
    fallbackCreatedAt: fallbackCreatedAt,
    fallbackUpdatedAt: fallbackUpdatedAt,
  );
  return NoteSummary(
    id: note.id,
    title: note.title,
    tags: List<String>.of(note.tags),
    createdAt: note.createdAt,
    updatedAt: note.updatedAt,
    pinned: note.pinned,
    archivedAt: note.archivedAt,
    preview: previewFromBody(note.body),
  );
}

/// The first heading of the body (`# Title`), or an empty string.
String titleFromBody(String body) {
  for (final line in body.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('# ')) {
      return trimmed.substring(2).trim();
    }
  }
  return '';
}

/// A one-line preview of the body (first [notePreviewLength] characters).
String previewFromBody(String body) {
  final flat = body.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (flat.length <= notePreviewLength) return flat;
  return flat.substring(0, notePreviewLength);
}

/// Parses an inline list (`[a, b]`) or a comma separated list (`a, b`).
List<String> parseTags(String raw) {
  var value = raw.trim();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  if (value.trim().isEmpty) return <String>[];
  final out = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (quote.isNotEmpty) {
      if (ch == quote) {
        quote = '';
      } else {
        buffer.write(ch);
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      continue;
    }
    if (ch == ',') {
      out.add(buffer.toString().trim());
      buffer.clear();
      continue;
    }
    buffer.write(ch);
  }
  out.add(buffer.toString().trim());
  return out.where((t) => t.isNotEmpty).toList();
}

Note _bareNote(
  String content,
  String fallbackId,
  DateTime? fallbackCreatedAt,
  DateTime? fallbackUpdatedAt,
) {
  return Note(
    id: fallbackId,
    title: titleFromBody(content),
    createdAt: fallbackCreatedAt ?? DateTime.now().toUtc(),
    updatedAt: fallbackUpdatedAt ?? fallbackCreatedAt ?? DateTime.now().toUtc(),
    body: content,
  );
}

/// The body is everything after the closing `---`, minus the single blank
/// line that separates it from the header.
String _bodyFrom(List<String> lines, int end) {
  final rest = lines.sublist(end + 1).join('\n');
  if (rest.startsWith('\n')) return rest.substring(1);
  return rest;
}

/// Renders a scalar front-matter value (quoted only when needed).
String _scalar(String value) {
  if (value.isEmpty) return '""';
  final needsQuotes = value.contains('\n') ||
      value.contains('\r') ||
      value.contains('"') ||
      value.contains("'") ||
      value.contains(': ') ||
      value.contains('#') ||
      value.endsWith(' ') ||
      value.startsWith(' ') ||
      const <String>[
        '-',
        '?',
        ':',
        ',',
        '[',
        ']',
        '{',
        '}',
        '&',
        '*',
        '!',
        '|',
        '>',
        '%',
        '@',
        '`',
        '~',
      ].any(value.startsWith);
  if (!needsQuotes) return value;
  final escaped = value.replaceAll('\\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

/// Removes the surrounding quotes of a front-matter value.
String _unquote(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed
        .substring(1, trimmed.length - 1)
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\');
  }
  if (trimmed.length >= 2 && trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

DateTime? _parseTime(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed == 'null') return null;
  return DateTime.tryParse(trimmed);
}
