import 'package:flutter/material.dart';

import '../../models/session_params.dart';
import '../theme/app_theme.dart';

/// 思考开关 + 思考强度：两个紧凑图标按钮（32×32），勾选菜单。
///
/// 聊天面板与首页快捷配置共用，保证交互与视觉一致。
class ReasoningToggles extends StatelessWidget {
  const ReasoningToggles({
    super.key,
    required this.thinking,
    required this.onThinkingChanged,
    required this.effort,
    required this.effortOptions,
    required this.onEffortChanged,
    this.effortTooltip,
  });

  final ThinkingSwitch thinking;
  final ValueChanged<ThinkingSwitch> onThinkingChanged;

  /// 当前思考强度；'' = 不传入。
  final String effort;
  final List<String> effortOptions;
  final ValueChanged<String> onEffortChanged;

  /// 思考强度菜单的 tooltip 前缀（可附带最大输出 tokens 等说明）。
  final String? effortTooltip;

  static String thinkingLabel(ThinkingSwitch value) => switch (value) {
        ThinkingSwitch.auto => 'auto（由模型决定）',
        ThinkingSwitch.on => 'on（开启思考）',
        ThinkingSwitch.off => 'off（关闭思考）',
      };

  static IconData thinkingIcon(ThinkingSwitch value) => switch (value) {
        ThinkingSwitch.on => Icons.psychology,
        ThinkingSwitch.off => Icons.psychology_outlined,
        ThinkingSwitch.auto => Icons.auto_awesome,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<ThinkingSwitch>(
          tooltip: '思考开关：${thinkingLabel(thinking)}',
          onSelected: onThinkingChanged,
          itemBuilder: (context) => [
            for (final value in ThinkingSwitch.values)
              CheckedPopupMenuItem(
                value: value,
                checked: value == thinking,
                child: Text(thinkingLabel(value)),
              ),
          ],
          child: _ReasoningIcon(
            icon: thinkingIcon(thinking),
            active: thinking == ThinkingSwitch.on,
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (effortOptions.isNotEmpty)
          PopupMenuButton<String>(
            tooltip: effortTooltip ??
                '思考强度：${effort.isEmpty ? '默认（不传入）' : effort}',
            onSelected: onEffortChanged,
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: '',
                checked: effort.isEmpty,
                child: const Text('默认（不传入）'),
              ),
              for (final value in effortOptions)
                CheckedPopupMenuItem(
                  value: value,
                  checked: value == effort,
                  child: Text(value),
                ),
            ],
            child: _ReasoningIcon(
              icon: Icons.tune,
              active: effort.isNotEmpty,
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _ReasoningIcon extends StatelessWidget {
  const _ReasoningIcon({
    required this.icon,
    required this.active,
    required this.color,
  });

  final IconData icon;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active
            ? scheme.primary.withValues(alpha: 0.12)
            : scheme.surfaceContainerHigh.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Icon(icon, size: 17, color: active ? scheme.primary : color),
    );
  }
}
