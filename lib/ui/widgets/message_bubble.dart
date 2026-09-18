import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/session_message.dart';
import 'markdown_view.dart';
import 'thinking_block.dart';
import 'tool_call_block.dart';
import 'usage_badge.dart';

/// A single message row in the chat view.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.isLastUser = false,
    this.onEdit,
    this.onDelete,
    this.onRegenerate,
  });

  final SessionMessage message;
  final bool isLastUser;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    switch (message.role) {
      case MessageRole.system:
        return const SizedBox.shrink();
      case MessageRole.user:
        return _userBubble(context);
      case MessageRole.assistant:
        return _assistantBubble(context);
      case MessageRole.tool:
        return Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ToolResultBlock(
              content: message.content ?? '',
              isError: message.isError,
            ),
          ),
        );
    }
  }

  Widget _userBubble(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: markdownView(message.content ?? ''),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '复制',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: message.content ?? ''),
                  ),
                  icon: const Icon(Icons.copy_all_outlined),
                ),
                if (isLastUser)
                  IconButton(
                    tooltip: '编辑并重发',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                IconButton(
                  tooltip: '删除',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _assistantBubble(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.hasReasoning)
              ThinkingBlock(text: message.reasoning ?? ''),
            if (message.hasToolCalls) ToolCallBlock(calls: message.toolCalls),
            if ((message.content ?? '').trim().isNotEmpty)
              markdownView(message.content ?? ''),
            if (message.usage.isNotEmpty) ...[
              const SizedBox(height: 4),
              UsageBadge(usage: message.usage),
            ],
          ],
        ),
      ),
    );
  }
}
