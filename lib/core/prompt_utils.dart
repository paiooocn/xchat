/// Prompt assembly helpers shared by the session-creation flow.
library;

import 'memory_protocol.dart';

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

/// Appends the project memory protocol to [systemPrompt].
///
/// The block is a separate section (separated by [kPromptSectionSeparator])
/// so it can never be confused with the hand-written prompt text. An empty
/// prompt yields the block alone.
///
/// **Idempotent**: a prompt that already carries the protocol is returned
/// unchanged. This matters for sessions created by compressing another one:
/// the stored prompt of the source session already contains the block, and
/// injecting it again would duplicate it (and waste tokens).
///
/// When the prompt starts with the workspace-root line, a one-line pointer is
/// inserted right after it — the agent should notice the index *before* it
/// reads a long hand-written prompt. The full duties stay at the end of the
/// prompt, next to the conversation.
String injectMemoryProtocol(String systemPrompt, {String projectName = ''}) {
  if (systemPrompt.contains(kMemoryProtocolMarker)) return systemPrompt;
  final body = systemPrompt.trim();
  final block = memoryProtocolBlock(projectName: projectName);
  if (body.isEmpty) return block;
  final lines = body.split('\n');
  final String composed;
  if (lines.first.trim().startsWith(kWorkspaceRootPrefix)) {
    composed = <String>[
      lines.first,
      memoryPointerLine(projectName: projectName),
      ...lines.skip(1),
    ].join('\n');
  } else {
    composed = body;
  }
  return '$composed$kPromptSectionSeparator$block';
}
