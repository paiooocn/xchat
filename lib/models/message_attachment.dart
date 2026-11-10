import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/json_utils.dart';

/// What the payload of an attachment is, which decides how it goes out:
///
/// - [image] → an `image_url` part (base64, the only thing every vision model
///   accepts);
/// - [text] → a `text` part inlined into the user turn, so even a session with
///   tools disabled can still "read the file";
/// - [file] → nothing is inlined: the file is copied into the session sandbox
///   and the turn only carries its path, so `read_file` / `shell` can open
///   whatever it is (PDF, archive, video …).
enum AttachmentKind { image, text, file }

/// Upper bound for the inlined text itself (characters, not bytes) — the token
/// guard on the `text` path. Longer payloads are truncated with a marker.
const int kMaxTextAttachmentChars = 200 * 1000;

/// A file (or an inline image blob) sent along with a user message.
///
/// Binary payloads live on disk next to the session — inside the session
/// sandbox under `attachments/` — so the session XML stays small and
/// hand-editable; only the relative path is serialized. A session that has
/// been copied elsewhere without its attachment folder degrades to a
/// missing-file marker rather than a corrupt document.
class MessageAttachment {
  MessageAttachment({
    required this.mimeType,
    this.kind = AttachmentKind.image,
    this.name = '',
    this.path,
    this.data,
  }) : assert(
          path != null || data != null,
          'attachment needs a path or inline data',
        );

  /// Builds an attachment from a picked file, or `null` when the extension is
  /// not a supported image type.
  static MessageAttachment? fromFile(String filePath, {String? name}) {
    final extension = p.extension(filePath).toLowerCase();
    final mimeType = mimeForExtension(extension);
    if (mimeType == null) return null;
    return MessageAttachment(
      mimeType: mimeType,
      name: name ?? p.basename(filePath),
      path: filePath,
    );
  }

  /// Builds a text attachment (source file on disk, read at send time).
  static MessageAttachment text(String filePath, {String? name}) {
    return MessageAttachment(
      kind: AttachmentKind.text,
      mimeType: 'text/plain',
      name: name ?? p.basename(filePath),
      path: filePath,
    );
  }

  /// Builds an opaque file attachment: copied to the sandbox, referenced (not
  /// inlined) in the request.
  static MessageAttachment file(String filePath, {String? name}) {
    return MessageAttachment(
      kind: AttachmentKind.file,
      mimeType: 'application/octet-stream',
      name: name ?? p.basename(filePath),
      path: filePath,
    );
  }

  /// `image/png`, `text/plain`, …
  final String mimeType;

  /// Whether the payload is an image or inlined text.
  final AttachmentKind kind;

  /// Original file name, shown in the UI.
  final String name;

  /// Location of the binary payload. Absolute while the message is being
  /// composed; rewritten to a sandbox-relative path once persisted.
  final String? path;

  /// Inline base64 payload (no data-URI prefix). Used for small images that
  /// never need to touch the disk.
  final String? data;

  bool get isText => kind == AttachmentKind.text;

  /// Not inlined at all — the model only learns where the file lives.
  bool get isOpaqueFile => kind == AttachmentKind.file;

  /// Whether [resolve] can actually produce a payload for this attachment.
  bool get isAvailable => data != null || (path != null && File(path!).existsSync());

  /// Reads the payload, or `null` when the file is gone.
  Future<List<int>?> readBytes() async {
    if (data != null) return _decodeBase64(data!);
    final file = path == null ? null : File(path!);
    if (file == null || !await file.exists()) return null;
    return file.readAsBytes();
  }

  /// Reads a text payload, or `null` when the file is gone.
  ///
  /// Decoding never throws: a file that turned out not to be valid UTF-8 (or
  /// was replaced by a binary) degrades to replacement characters instead of
  /// sinking the whole turn.
  Future<String?> readText({int maxChars = kMaxTextAttachmentChars}) async {
    final bytes = await readBytes();
    if (bytes == null) return null;
    var text = utf8.decode(bytes, allowMalformed: true);
    if (maxChars > 0 && text.length > maxChars) {
      text = '${text.substring(0, maxChars)}\n…（文件过长，已截断）';
    }
    return text;
  }

  MessageAttachment copyWith({String? path, String? data, AttachmentKind? kind}) =>
      MessageAttachment(
        mimeType: mimeType,
        kind: kind ?? this.kind,
        name: name,
        path: path ?? this.path,
        data: data ?? this.data,
      );

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'kind': kind.name,
        'mime_type': mimeType,
        if (name.isNotEmpty) 'name': name,
        if (path != null) 'path': path,
        if (data != null) 'data': data,
      });

  factory MessageAttachment.fromJson(Object? value) {
    final json = asMap(value);
    return MessageAttachment(
      kind: switch (asString(json['kind'])) {
        'text' => AttachmentKind.text,
        'file' => AttachmentKind.file,
        _ => AttachmentKind.image,
      },
      mimeType: asString(json['mime_type']) ?? 'image/png',
      name: asString(json['name']) ?? '',
      path: asString(json['path']),
      data: asString(json['data']),
    );
  }

  static List<int> _decodeBase64(String value) {
    final normalized = value.contains(',') ? value.split(',').last : value;
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final table = <int, int>{};
    for (var i = 0; i < alphabet.length; i++) {
      table[alphabet.codeUnitAt(i)] = i;
    }
    final out = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final unit in normalized.codeUnits) {
      final value6 = table[unit];
      if (value6 == null) continue; // '=' padding and whitespace
      buffer = (buffer << 6) | value6;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xFF);
      }
    }
    return out;
  }
}

/// Mime type for a file extension, restricted to what the multimodal path
/// accepts. Returns `null` for anything unsupported.
String? mimeForExtension(String extension) => switch (extension) {
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.webp' => 'image/webp',
      '.gif' => 'image/gif',
      '.bmp' => 'image/bmp',
      _ => null,
    };
