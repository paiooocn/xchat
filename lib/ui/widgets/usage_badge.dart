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

/// 耗时的紧凑写法：`3 秒` / `2 分 5 秒` / `1 小时 3 分`。
///
/// 负值按 0 处理（旧存档 / 时钟回拨时可能算出负跨度）。
String formatDuration(Duration span) {
  final d = span.isNegative ? Duration.zero : span;
  if (d.inHours > 0) return '${d.inHours} 小时 ${d.inMinutes % 60} 分';
  if (d.inMinutes > 0) return '${d.inMinutes} 分 ${d.inSeconds % 60} 秒';
  return '${d.inSeconds} 秒';
}

/// One segment of the [UsageBadge] row: a short label, the text shown in the
/// row, and the exact value revealed on hover.
class _Chip {
  const _Chip(this.label, this.text, this.tooltip);

  final String label;
  final String text;
  final String tooltip;
}

/// Compact token-usage chip: `in ↑ / out ↓ / cache ⚡`（cache 显示缓存利用率）
/// + 可选的会话累计耗时。
///
/// Numbers are abbreviated (`1.23K`); hovering a field shows the exact
/// count with thousands separators.
class UsageBadge extends StatelessWidget {
  const UsageBadge({
    super.key,
    required this.usage,
    this.contextTokens,
    this.duration,
  });

  final TokenUsage usage;
  final int? contextTokens;

  /// 会话累计耗时（总耗时）；为空不显示。
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final rate = usage.cacheRate;
    if (usage.isEmpty && contextTokens == null && duration == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final chips = <_Chip>[
      if (usage.input != null)
        _Chip(
          'in',
          formatTokensCompact(usage.input!),
          'in ${formatTokensFull(usage.input!)}',
        ),
      if (usage.output != null)
        _Chip(
          'out',
          formatTokensCompact(usage.output!),
          'out ${formatTokensFull(usage.output!)}',
        ),
      // cache 显示「缓存利用率 = cache / input」；input 缺失时退回原始计数。
      if (usage.cache != null)
        if (rate != null)
          _Chip(
            'cache',
            '${(rate * 100).round()}%',
            'cache ${formatTokensFull(usage.cache!)} / in '
                '${formatTokensFull(usage.input!)} = '
                '${(rate * 100).toStringAsFixed(2)}%',
          )
        else
          _Chip(
            'cache',
            formatTokensCompact(usage.cache!),
            'cache ${formatTokensFull(usage.cache!)}',
          ),
      if (contextTokens != null)
        _Chip(
          'ctx',
          formatTokensCompact(contextTokens!),
          'ctx ${formatTokensFull(contextTokens!)}',
        ),
      if (duration != null)
        _Chip('耗时', formatDuration(duration!), '总耗时 ${duration!.inSeconds} 秒'),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < chips.length; i++) ...[
          if (i > 0) Text('·', style: style),
          Tooltip(
            message: chips[i].tooltip,
            child: Text('${chips[i].label} ${chips[i].text}', style: style),
          ),
        ],
      ],
    );
  }
}
