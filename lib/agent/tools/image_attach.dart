import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/message_attachment.dart';
import 'path_guard.dart';

const _imageExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.gif',
  '.bmp',
};

/// Whether [path] looks like an image by extension — the cheap pre-check that
/// lets text tools hand pictures to the multimodal path instead of UTF-8
/// decoding them into mojibake.
bool looksLikeImagePath(String path) =>
    _imageExtensions.contains(p.extension(path).toLowerCase());

/// The image a tool call asked the model to look at, or `null` when the call
/// carries no image.
///
/// Both `attach_image` and `read_file` are image-capable: reading a picture
/// is a request to *see* it, not to get its bytes as text.
String? toolImagePath(String tool, String arguments) {
  if (tool != 'attach_image' && tool != 'read_file') return null;
  final path = _stringArg(arguments, 'path');
  if (path.isEmpty || !looksLikeImagePath(path)) return null;
  return path;
}

String _stringArg(String arguments, String key) {
  try {
    final decoded = jsonDecode(arguments);
    if (decoded is Map && decoded[key] is String) return decoded[key] as String;
  } catch (_) {
    // Malformed JSON: the tool reports it; nothing to attach.
  }
  return '';
}

/// The outcome of validating a candidate image for attachment.
///
/// Single source of truth for both sides of `attach_image`: the tool builds
/// the user-facing message from [error] / [summary], and the engine attaches
/// [attachment] to the tool message. Re-validating at attach time (rather than
/// trusting the tool) keeps a failed validation from silently turning into an
/// image-less "ok".
class ImageAttachResult {
  const ImageAttachResult.success(this.attachment)
      : error = null,
        sizeBytes = 0;

  const ImageAttachResult.failure(this.error)
      : attachment = null,
        sizeBytes = 0;

  const ImageAttachResult.tooLarge(this.error, this.sizeBytes)
      : attachment = null;

  /// The image to attach, or `null` when [error] explains why it was refused.
  final MessageAttachment? attachment;

  /// Model-facing reason the image was refused (sandbox escape, missing file,
  /// unsupported type, over the size cap).
  final String? error;

  /// File size in bytes; only meaningful for [tooLarge].
  final int sizeBytes;

  bool get ok => attachment != null;
}

/// Validates a sandbox-relative or absolute [rawPath] as an attachable image.
///
/// Checks, in order: inside the sandbox, exists, is a regular file, is a
/// supported image type, and is within [maxBytes] (0 = no limit). The file is
/// only stat-ed here — copying into the session happens in the engine.
Future<ImageAttachResult> resolveAttachableImage({
  required PathGuard guard,
  required int maxBytes,
  required String rawPath,
}) async {
  final String path;
  try {
    path = guard.resolveReal(rawPath);
  } on SandboxViolation catch (error) {
    return ImageAttachResult.failure('ERROR: ${error.message}（图片只能来自会话沙箱内）');
  }
  final file = File(path);
  if (!await file.exists()) {
    return ImageAttachResult.failure('ERROR: 图片文件不存在: $path');
  }
  final attachment = MessageAttachment.fromFile(path);
  if (attachment == null) {
    return ImageAttachResult.failure(
      'ERROR: 不支持的图片格式: $path（支持 png / jpg / webp / gif / bmp）',
    );
  }
  final size = await file.length();
  if (maxBytes > 0 && size > maxBytes) {
    return ImageAttachResult.tooLarge(
      'ERROR: 图片体积 ${_mb(size)}MB 超过上限 ${_mb(maxBytes)}MB。'
      '请改用更小的截图（如 chromium --screenshot 配合 --window-size=1280,800）'
      '或先压缩后再试。',
      size,
    );
  }
  return ImageAttachResult.success(attachment);
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

/// What the engine resolved for an `attach_image` tool call: the copies it
/// stored in the session sandbox, or the reason it refused.
class ToolImageAttachment {
  const ToolImageAttachment(this.stored, this.error);

  final List<MessageAttachment> stored;
  final String? error;
}
