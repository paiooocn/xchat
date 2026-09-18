import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Generates a v4 UUID string.
String newId() => _uuid.v4();

/// Generates a short, url/file-safe random id (for message/tool-call ids).
String newShortId([int length = 8]) {
  final raw = _uuid.v4().replaceAll('-', '');
  return raw.substring(0, length.clamp(1, raw.length));
}

/// Milliseconds-since-epoch, locally unique enough for message ids.
String nextSeqId() => DateTime.now().microsecondsSinceEpoch.toString();
