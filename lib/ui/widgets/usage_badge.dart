import 'package:flutter/material.dart';

import '../../models/token_usage.dart';

/// Compact token-usage chip: `in ↑ / out ↓ / cache ⚡`.
class UsageBadge extends StatelessWidget {
  const UsageBadge({super.key, required this.usage, this.contextTokens});

  final TokenUsage usage;
  final int? contextTokens;

  @override
  Widget build(BuildContext context) {
    if (usage.isEmpty && contextTokens == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final parts = <String>[
      if (usage.input != null) 'in ${usage.input}',
      if (usage.output != null) 'out ${usage.output}',
      if (usage.cache != null) 'cache ${usage.cache}',
      if (contextTokens != null) 'ctx $contextTokens',
    ];
    return Text(
      parts.join(' · '),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
