import '../core/memory_protocol.dart';

/// Snapshot of a project's `.memory/` index on disk.
///
/// Pure data (no Flutter, no IO) so it can be handed to the UI as-is.
class MemoryStatus {
  const MemoryStatus({
    required this.exists,
    this.files = const <String>[],
    this.lastModified,
  });

  /// Whether the `.memory/` directory exists at all.
  final bool exists;

  /// File names inside `.memory/` (relative to it), sorted.
  final List<String> files;

  /// Last modification time of the newest file in the index.
  final DateTime? lastModified;

  /// Whether the index is missing one of the expected files.
  bool get isIncomplete => files.length < kMemoryFileNames.length;

  /// A short human-readable summary for the project panel.
  String get summary {
    if (!exists) return '未初始化';
    final when = lastModified == null ? '' : '，最近更新 ${_stamp(lastModified!)}';
    return '已初始化（${files.length} 个文件$when）';
  }

  static String _stamp(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
