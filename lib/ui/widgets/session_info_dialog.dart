import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../models/session.dart';
import '../../models/session_params.dart';
import '../theme/app_fonts.dart';

/// Read-only panel with everything known about one session: the XML file path,
/// the token usage stored on the `system` element, the model / thinking
/// settings, the enabled tools, the complete system prompt and the
/// created / updated timestamps.
class SessionInfoDialog extends StatelessWidget {
  const SessionInfoDialog({
    super.key,
    required this.session,
    required this.filePath,
  });

  final Session session;

  /// Absolute path of the session XML file.
  final String filePath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usage = session.cumulativeUsage;
    final prompt = session.systemPrompt.trim();
    final format = DateFormat('yyyy-MM-dd HH:mm:ss');
    final thinking = switch (session.params.thinking) {
      ThinkingSwitch.auto => 'auto（由模型决定）',
      ThinkingSwitch.on => 'on（开启思考）',
      ThinkingSwitch.off => 'off（关闭思考）',
    };
    final effort = session.params.reasoningEffort ?? '';

    return AlertDialog(
      title: Text('会话信息', style: theme.textTheme.titleSmall),
      content: SizedBox(
        width: 640,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Section(theme, '会话文件'),
                _CopyValue(label: '路径', value: filePath),
                _Value(label: '工作目录', value: session.sandbox),
                const SizedBox(height: 14),
                _Section(theme, 'Token 用量'),
                _Value(label: '输入 input', value: _tokens(usage.input)),
                _Value(label: '输出 output', value: _tokens(usage.output)),
                _Value(label: '缓存 cache', value: _tokens(usage.cache)),
                _Value(label: '上下文 context', value: _tokens(session.contextTokens)),
                const SizedBox(height: 14),
                _Section(theme, '模型与思考'),
                _Value(
                  label: '模型',
                  value: session.model.isEmpty ? '（未设置）' : session.model,
                ),
                _Value(
                  label: '提供商',
                  value: session.provider.isEmpty ? '（未设置）' : session.provider,
                ),
                _Value(label: '思考开关', value: thinking),
                _Value(label: '思考档位', value: effort.isEmpty ? '（未设置）' : effort),
                const SizedBox(height: 14),
                _Section(theme, '启动的工具'),
                _Value(
                  label: '已启用',
                  value: session.tools.isEmpty ? '（未启用）' : session.tools.join('、'),
                ),
                _Value(label: '已调用', value: _calledTools(session)),
                const SizedBox(height: 14),
                _Section(theme, '系统提示词'),
                _Prompt(value: prompt.isEmpty ? '（空）' : prompt),
                const SizedBox(height: 14),
                _Section(theme, '时间'),
                _Value(
                  label: '创建时间',
                  value: format.format(session.createdAt.toLocal()),
                ),
                _Value(
                  label: '更新时间',
                  value: format.format(session.updatedAt.toLocal()),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// Formats a token count with K/M/B units (2 decimals); values below 1K are
  /// printed as-is.
  static String _tokens(int? value) {
    if (value == null) return '—';
    const kilo = 1000;
    const mega = 1000 * 1000;
    const giga = 1000 * 1000 * 1000;
    if (value >= giga) return '${(value / giga).toStringAsFixed(2)}B';
    if (value >= mega) return '${(value / mega).toStringAsFixed(2)}M';
    if (value >= kilo) return '${(value / kilo).toStringAsFixed(2)}K';
    return '$value';
  }

  /// Distinct tool names actually invoked during the session.
  static String _calledTools(Session session) {
    final names = <String>{};
    for (final message in session.messages) {
      for (final call in message.toolCalls) {
        if (call.name.isNotEmpty) names.add(call.name);
      }
    }
    return names.isEmpty ? '（无）' : names.join('、');
  }
}

/// A small section heading.
class _Section extends StatelessWidget {
  const _Section(this.theme, this.title);

  final ThemeData theme;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A `label: value` row.
class _Value extends StatelessWidget {
  const _Value({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// A `label: value` row with a copy button (used for the file path).
class _CopyValue extends StatelessWidget {
  const _CopyValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
              ),
            ),
          ),
          IconButton(
            tooltip: '复制路径',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制路径')),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The complete system prompt, rendered in a monospaced box.
class _Prompt extends StatelessWidget {
  const _Prompt({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: SelectableText(
        value,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: AppFonts.mono,
          fontFamilyFallback: AppFonts.monoFallback,
          height: 1.5,
        ),
      ),
    );
  }
}
