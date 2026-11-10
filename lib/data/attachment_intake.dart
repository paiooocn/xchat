import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/message_attachment.dart';
import 'office_text.dart';

/// Stages files for the next send, from either the system picker or a drop.
///
/// **No type is refused.** One entry point for both paths keeps the rules in a
/// single place; the only thing that decides whether a file is accepted is its
/// size against the matching cap:
///
/// - images → [AttachmentKind.image], cap `maxImageBytes`
///   (`AppConfig.maxAttachmentBytes`, they ride base64-inline in the request);
/// - anything else → cap `maxFileBytes` (`AppConfig.maxFileAttachmentBytes`,
///   they stay on disk), then classified by content:
///   - `.docx` / `.xlsx` / `.pptx` → extracted text ([AttachmentKind.text]);
///   - looks like text → [AttachmentKind.text] (inlined, truncated to
///     [kMaxTextAttachmentChars]);
///   - anything else → [AttachmentKind.file] (copied to the sandbox, the model
///     only gets its path and can open it with the tools).
///
/// Directories and unreadable paths are still refused — there is nothing to
/// stage for them.
class AttachmentIntake {
  AttachmentIntake({
    required this.staged,
    required this.unsupported,
    required this.oversized,
    required this.maxImageBytes,
    required this.maxFileBytes,
  });

  final List<MessageAttachment> staged;
  final List<String> unsupported;
  final List<String> oversized;
  final int maxImageBytes;
  final int maxFileBytes;

  /// A one-line summary of what was refused, or `null` when everything made it.
  String? get note {
    final notes = <String>[
      if (unsupported.isNotEmpty) '已忽略无法读取的条目：${unsupported.join('、')}',
      if (oversized.isNotEmpty)
        '已忽略超过体积上限的文件：${oversized.join('、')}'
            '（图片 ${_size(maxImageBytes)}，其他文件 ${_size(maxFileBytes)}，'
            '可在设置中调整）',
    ];
    return notes.isEmpty ? null : notes.join('\n');
  }

  static String _size(int bytes) =>
      bytes <= 0 ? '不限' : '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}

/// Classifies [paths] into attachments. Never throws: an unreadable path lands
/// in [AttachmentIntake.unsupported].
Future<AttachmentIntake> collectAttachments(
  Iterable<String> paths, {
  required int maxImageBytes,
  required int maxFileBytes,
}) async {
  final staged = <MessageAttachment>[];
  final unsupported = <String>[];
  final oversized = <String>[];
  for (final path in paths) {
    final name = p.basename(path);
    try {
      final stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.directory) {
        // A dropped folder could be a whole project; silently importing its
        // tree would be worse than asking the user to point at files.
        unsupported.add('$name/（文件夹）');
        continue;
      }
      if (stat.type != FileSystemEntityType.file) {
        unsupported.add(name);
        continue;
      }
      final image = MessageAttachment.fromFile(path, name: name);
      if (image != null) {
        if (maxImageBytes > 0 && stat.size > maxImageBytes) {
          oversized.add(name);
        } else {
          staged.add(image);
        }
        continue;
      }
      if (maxFileBytes > 0 && stat.size > maxFileBytes) {
        oversized.add(name);
        continue;
      }
      if (isOfficeExtension(extensionOf(path))) {
        final text = await extractOfficeText(path);
        staged.add(text == null
            ? MessageAttachment.file(path, name: name)
            : await _stageExtractedText(text, name));
        continue;
      }
      if (await _looksLikeText(path)) {
        staged.add(MessageAttachment.text(path, name: name));
      } else {
        staged.add(MessageAttachment.file(path, name: name));
      }
    } catch (_) {
      unsupported.add(name);
    }
  }
  return AttachmentIntake(
    staged: staged,
    unsupported: unsupported,
    oversized: oversized,
    maxImageBytes: maxImageBytes,
    maxFileBytes: maxFileBytes,
  );
}

/// Writes extracted document text to a scratch file and stages it under the
/// original file name.
///
/// The text has to live *somewhere* the attachment can point at — the message
/// only stores a path — and the scratch file is exactly what the send path then
/// copies into `<sandbox>/attachments/` under a `.txt` name, so the session
/// keeps the readable form rather than the original binary.
Future<MessageAttachment> _stageExtractedText(String text, String name) async {
  final dir = await Directory.systemTemp.createTemp('xchat_doc_');
  final base = p.basenameWithoutExtension(name);
  final file = File(p.join(dir.path, '$base.txt'));
  await file.writeAsString(text, flush: true);
  return MessageAttachment.text(file.path, name: name);
}

/// Heuristic "is this a text file": no NUL byte in the first block and mostly
/// valid UTF-8. Extension lists go stale (a new language appears every week) and
/// miss extension-less files (Makefile, .env), so the content decides.
Future<bool> _looksLikeText(String path) async {
  final handle = await File(path).open();
  try {
    final head = await handle.read(8192);
    if (head.isEmpty) return true;
    if (head.contains(0)) return false;
    final decoded = utf8.decode(head, allowMalformed: true);
    // A truncated multi-byte char at the block boundary yields one replacement
    // character; anything more means it is not UTF-8 text.
    final broken = '\uFFFD'.allMatches(decoded).length;
    if (broken > 1) return false;
    // Reject the classic "binary that happens to decode" case.
    final control = decoded.runes
        .where((r) => r < 0x20 && r != 0x09 && r != 0x0A && r != 0x0D)
        .length;
    return control * 100 <= decoded.length;
  } finally {
    await handle.close();
  }
}
