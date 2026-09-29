import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/message_attachment.dart';
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

  /// Copies the message's **raw** text — never the rendered widget — so the
  /// clipboard holds the original Markdown source and can be pasted verbatim
  /// into another editor/chat.
  static Future<void> copyRaw(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('已复制 Markdown 原文'),
        duration: Duration(seconds: 2),
      ),
    );
  }

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

  Widget _copyButton(BuildContext context, String text, {String tooltip = '复制 Markdown 原文'}) =>
      IconButton(
        tooltip: tooltip,
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        onPressed: text.isEmpty ? null : () => copyRaw(context, text),
        icon: const Icon(Icons.copy_all_outlined),
      );

  Widget _userBubble(BuildContext context) {
    final theme = Theme.of(context);
    final text = message.content ?? '';
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (message.hasAttachments) _attachmentStrip(context),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: text.isEmpty ? const SizedBox.shrink() : markdownView(text),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _copyButton(context, text),
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

  /// Thumbnails for the images a user turn carried. Missing files
  /// are shown as a muted chip rather than a broken image box.
  Widget _attachmentStrip(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        children: [
          for (final file in message.attachments)
            if (!file.isAvailable)
              _missingChip(theme, file.name)
            else
              _thumbnail(context, file),
        ],
      ),
    );
  }

  Widget _missingChip(ThemeData theme, String name) => Tooltip(
        message: name,
        child: Chip(
          avatar: Icon(Icons.broken_image_outlined, size: 16, color: theme.disabledColor),
          label: const Text('文件已丢失'),
          visualDensity: VisualDensity.compact,
        ),
      );

  Widget _thumbnail(BuildContext context, MessageAttachment file) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => _showFullscreen(context, file),
          child: Image.file(
            File(file.path!),
            width: 120,
            height: 120,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox(
              width: 120,
              height: 120,
              child: Icon(Icons.broken_image_outlined),
            ),
          ),
        ),
      );

  void _showFullscreen(BuildContext context, MessageAttachment file) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: InteractiveViewer(
          maxScale: 6,
          child: Image.file(File(file.path!), fit: BoxFit.contain),
        ),
      ),
    );
  }

  Widget _assistantBubble(BuildContext context) {
    final text = message.content ?? '';
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
            if (text.trim().isNotEmpty)
              markdownView(text),
            if (message.usage.isNotEmpty) ...[
              const SizedBox(height: 4),
              UsageBadge(usage: message.usage),
            ],
            // The reply is copied from its Markdown source, never from the
            // rendered (syntax-highlighted) view.
            if (text.isNotEmpty || message.hasReasoning)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _copyButton(context, text),
                  if (onDelete != null)
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
}
