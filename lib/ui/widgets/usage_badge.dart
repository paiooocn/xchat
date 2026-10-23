import 'package:flutter/material.dart';

import '../../models/token_usage.dart';

/// Compact token count: `1.23K` / `12.34M` / `1.23B`.
/// Counts below 1000 are shown as-is (no unit).
String formatTokensCompact(int value) {
  if (value.abs() < 1000) return '$value';
  if (value.abs() < 1000000) return '${(value / 1000).toStringAsFixed(2)}K';
  if (value.abs() < 1000000000) {
    return '${(value / 1000000).toStringAsFixed(2)}M';
  }
  return '${(value / 1000000000).toStringAsFixed(2)}B';
}

/// Full token count with thousands separators: `1,234,567`.
String formatTokensFull(int value) {
  final negative = value < 0;
  final digits = value.abs().toString();
  final buf = StringBuffer(negative ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return buf.toString();
}

/// Compact token-usage chip: `in ↑ / out ↓ / cache ⚡`.
///
/// Numbers are abbreviated (`1.23K`); hovering a field shows the exact
/// count with thousands separators.
class UsageBadge extends StatelessWidget {
  const UsageBadge({super.key, required this.usage, this.contextTokens});

  final TokenUsage usage;
  final int? contextTokens;

  @override
  Widget build(BuildContext context) {
    if (usage.isEmpty && contextTokens == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final parts = <({String label, int value})>[
      if (usage.input != null) (label: 'in', value: usage.input!),
      if (usage.output != null) (label: 'out', value: usage.output!),
      if (usage.cache != null) (label: 'cache', value: usage.cache!),
      if (contextTokens != null) (label: 'ctx', value: contextTokens!),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0)
            Text('·', style: style),
          Tooltip(
            message: '${parts[i].label} ${formatTokensFull(parts[i].value)}',
            child: Text(
              '${parts[i].label} ${formatTokensCompact(parts[i].value)}',
              style: style,
            ),
          ),
        ],
      ],
    );
  }
}
