/// Prompt assembly helpers shared by the session-creation flow.
library;

/// Prefix of the auto-injected workspace-root line (matched against the
/// trimmed start of each prompt line).
const String kWorkspaceRootPrefix = '工作空间根目录';

/// Separator placed between the prompt sections of a composed system prompt
/// (会话提示词 / 项目提示词 / 新增提示词).
const String kPromptSectionSeparator = '\n---\n';

/// Prepends a `工作空间根目录: <sandbox>` line holding the session's absolute
/// sandbox path to [systemPrompt].
///
/// Any existing workspace-root line (a hand-written one or the old
/// `工作空间根目录: {sandbox}` placeholder form) is dropped so the prompt keeps
/// exactly one such line, always on top. The workspace-root line is separated
/// from the prompt body by a blank line. The rest of the prompt is preserved
/// verbatim.
String injectWorkspaceRoot(String systemPrompt, String sandbox) {
  final line = '$kWorkspaceRootPrefix: $sandbox';
  final body = systemPrompt
      .split('\n')
      .where((l) => !l.trim().startsWith(kWorkspaceRootPrefix))
      .join('\n')
      .trim();
  return body.isEmpty ? line : '$line\n\n$body';
}

/// Joins the prompt sections of a session's system prompt in the canonical
/// order — 会话提示词 / 项目提示词 / 新增提示词 — with [kPromptSectionSeparator]
/// between them.
///
/// Empty sections are dropped, so a session without a project prompt does not
/// get a stray separator.
String composePromptSections(List<String> sections) {
  final parts = sections
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  return parts.join(kPromptSectionSeparator);
}
