/// Session execution mode controlling when tool calls require approval.
///
/// Approval levels (per tool, 0..3) against mode values (普通=1, 自动=2, 托管=3).
/// A call needs approval iff `m <= t` (equivalently NOT `m > t`):
/// * 0 — never approve (普通/自动/托管).
/// * 1 — 普通 approve.
/// * 2 — 普通/自动 approve.
/// * 3 — always approve (普通/自动/托管).
enum AgentMode {
  normal,
  auto,
  managed;

  /// Parses a stored mode value. Missing/unknown values fall back to the
  /// default [AgentMode.auto]; `normal` is matched explicitly so sessions
  /// explicitly saved as 普通 are preserved.
  static AgentMode parse(String? value) => switch (value) {
        'normal' => AgentMode.normal,
        'managed' => AgentMode.managed,
        _ => AgentMode.auto,
      };

  String get wire => name;

  String get label => switch (this) {
        AgentMode.normal => '普通',
        AgentMode.auto => '自动',
        AgentMode.managed => '托管',
      };
}

/// Whether a tool whose approval [level] is 0..3 needs the user's consent when
/// the session runs in [mode].
bool requiresApproval(int level, AgentMode mode) {
  final modeValue = switch (mode) {
    AgentMode.normal => 1,
    AgentMode.auto => 2,
    AgentMode.managed => 3,
  };
  return modeValue <= level.clamp(0, 3);
}

/// Human readable description of an approval level.
String approvalLevelLabel(int level) => switch (level.clamp(0, 3)) {
      0 => '0 · 从不审批',
      1 => '1 · 普通审批',
      2 => '2 · 普通/自动审批',
      _ => '3 · 总是审批',
    };
