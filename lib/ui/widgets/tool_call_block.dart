import 'package:flutter/material.dart';

import '../../models/session_message.dart';
import '../theme/app_fonts.dart';
import 'markdown_view.dart';

/// Renders an assistant's tool calls, plus any matching tool results.
class ToolCallBlock extends StatelessWidget {
  const ToolCallBlock({
    super.key,
    required this.calls,
    this.results = const <String>[],
  });

  final List<ToolCallData> calls;

  /// Pre-formatted result lines (`✓ name: preview` / `✗ …`).
  final List<String> results;

  @override
  Widget build(BuildContext context) {
    if (calls.isEmpty && results.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final call in calls)
                _ToolCallEntry(call: call),
              for (final line in results)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    line,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolCallEntry extends StatelessWidget {
  const _ToolCallEntry({required this.call});

  final ToolCallData call;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      dense: true,
      leading: Icon(Icons.build_outlined, size: 18, color: theme.colorScheme.primary),
      title: Text(call.name, style: theme.textTheme.labelLarge),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              call.arguments.isEmpty ? '{}' : _pretty(call.arguments),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _pretty(String raw) {
    // Argument fragments may be partial; show as-is when not valid JSON.
    return raw;
  }
}

/// Renders a tool-result message body (collapsible).
class ToolResultBlock extends StatefulWidget {
  const ToolResultBlock({
    super.key,
    required this.content,
    required this.isError,
    this.initiallyExpanded = false,
  });

  final String content;
  final bool isError;
  final bool initiallyExpanded;

  @override
  State<ToolResultBlock> createState() => _ToolResultBlockState();
}

class _ToolResultBlockState extends State<ToolResultBlock> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isError = widget.isError;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: (isError ? theme.colorScheme.errorContainer : theme.colorScheme.surfaceContainerHighest)
            .withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    isError ? Icons.error_outline : Icons.check_circle_outline,
                    size: 15,
                    color: isError ? theme.colorScheme.error : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text('工具结果', style: theme.textTheme.labelMedium),
                  const Spacer(),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: markdownView(widget.content),
            ),
        ],
      ),
    );
  }
}
