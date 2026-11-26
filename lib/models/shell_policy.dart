/// Shell command policy: maps a command string to an approval level, or marks
/// it as globally denied (F级).
///
/// Every list entry is a **regular expression** (case-insensitive) matched
/// against the whole command string via `hasMatch`. Entries that fail to
/// compile are treated as literal substrings. Use `\b` to anchor a command
/// word, e.g. `\brm\b`.
library;

/// Source list that decided a shell command's classification.
enum ShellMatch { deny, level2, level1, base }

/// Outcome of classifying a shell command.
class ShellClassification {
  const ShellClassification({
    required this.denied,
    required this.level,
    required this.match,
  });

  /// `true` when the command matches the F级 (deny) list.
  final bool denied;

  /// Effective approval level (0..3) when not denied.
  final int level;

  /// Which list (or the tool's base level) produced [level].
  final ShellMatch match;
}

/// 判断一条用户消息是否是「清理 / 删除」类任务（文件 / 文件夹 / 目录 / 邮件 / 邮箱）。
///
/// 命中时本轮把**未登记**的 shell 命令临时提到 3 级（见 `AgentEngine.run`）：
/// 清理类任务最容易由模型自行组织 `del` / `Remove-Item` / `find -delete` 等
/// 未登记命令，宁可多弹一次审批。动作词与对象词**同时**出现才算命中，避免
/// 「删掉这个字段」这类纯代码改动被误判。
bool isCleanupDeleteTask(String? text) {
  final value = (text ?? '').trim();
  if (value.isEmpty) return false;
  return _cleanupActionPattern.hasMatch(value) &&
      _cleanupTargetPattern.hasMatch(value);
}

/// 动作词：清理 / 清除 / 清空 / 删除 / 移除 …（英文按词边界，避免误伤）。
final RegExp _cleanupActionPattern = RegExp(
  r'清理|清除|清空|删除|删掉|移除|丢掉|\b(?:clean(?:up)?|delete|remove|purge|wipe|erase|unlink|rmdir|del)\b',
  caseSensitive: false,
);

/// 对象词：文件 / 文件夹 / 目录 / 邮件 / 邮箱 …（英文按词边界，`profile` 不命中 `file`）。
final RegExp _cleanupTargetPattern = RegExp(
  r'文件|文件夹|目录|邮件|邮箱|收件箱|\b(?:files?|folders?|dirs?|director(?:y|ies)|mails?|mailbox|emails?|inbox)\b',
  caseSensitive: false,
);

/// 把复合命令切成子命令段：`&&`、`||`、`;`、`|`、`&`、换行。
///
/// 重定向里的 `>&` / `<&`（如 `2>&1`）不是分隔符：切分前先把它们临时打码，
/// 切完再还原。空段会被丢掉。
List<String> splitShellSegments(String command) {
  const marker = '\u0000';
  final guarded = command.replaceAllMapped(
    RegExp(r'([<>])&'),
    (match) => '${match[1]}$marker',
  );
  return guarded
      .split(RegExp(r'&&|\|\||;|\||&|\r?\n'))
      .map((segment) => segment.replaceAll(marker, '&').trim())
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
}

/// Classifies [command] against the configured lists.
///
/// 复合命令（`a && b; c | d`）**逐段**判定后取**最高**等级：任一段被 F 级拒绝
/// 则整条拒绝，否则取各段 level 的最大值。这样「`rm x && ls`」里被 1 级名单
/// 登记过的 `ls` 不会把整条命令压低到 1 级 —— 未登记的那一段仍按基础等级
/// （默认 2 级；清理/删除任务当轮 3 级）算。
///
/// Deny (F) wins over everything; otherwise the strictest segment level applies.
ShellClassification classifyShellCommand(
  String command, {
  required List<String> level1,
  required List<String> level2,
  required List<String> denied,
  required int baseLevel,
}) {
  final segments = splitShellSegments(command);
  if (segments.isEmpty) {
    return ShellClassification(denied: false, level: baseLevel, match: ShellMatch.base);
  }
  ShellClassification? worst;
  for (final segment in segments) {
    final one = _classifySegment(
      segment,
      level1: level1,
      level2: level2,
      denied: denied,
      baseLevel: baseLevel,
    );
    if (one.denied) return one;
    if (worst == null || one.level > worst.level) worst = one;
  }
  return worst!;
}

ShellClassification _classifySegment(
  String segment, {
  required List<String> level1,
  required List<String> level2,
  required List<String> denied,
  required int baseLevel,
}) {
  bool matches(List<String> patterns) {
    for (final entry in patterns) {
      final raw = entry.trim();
      if (raw.isEmpty) continue;
      try {
        if (RegExp(raw, caseSensitive: false).hasMatch(segment)) return true;
      } catch (_) {
        // Invalid regex → fall back to a literal, case-insensitive substring.
        if (segment.toLowerCase().contains(raw.toLowerCase())) return true;
      }
    }
    return false;
  }

  if (matches(denied)) {
    return const ShellClassification(denied: true, level: 3, match: ShellMatch.deny);
  }
  if (matches(level2)) {
    return const ShellClassification(denied: false, level: 2, match: ShellMatch.level2);
  }
  if (matches(level1)) {
    return const ShellClassification(denied: false, level: 1, match: ShellMatch.level1);
  }
  return ShellClassification(denied: false, level: baseLevel, match: ShellMatch.base);
}
