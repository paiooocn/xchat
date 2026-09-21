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

/// Classifies [command] against the configured lists.
///
/// Deny (F) wins over level2, which wins over level1; otherwise [baseLevel]
/// (the tool's configured level) applies.
ShellClassification classifyShellCommand(
  String command, {
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
        if (RegExp(raw, caseSensitive: false).hasMatch(command)) return true;
      } catch (_) {
        // Invalid regex → fall back to a literal, case-insensitive substring.
        if (command.toLowerCase().contains(raw.toLowerCase())) return true;
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
