import 'package:flutter/material.dart';

import '../../models/provider_config.dart';
import '../theme/app_theme.dart';

/// 厂家（Provider）胶囊：与会话内模型选择同款布局，勾选列表切换厂家。
class ProviderPicker extends StatelessWidget {
  const ProviderPicker({
    super.key,
    required this.providers,
    required this.value,
    required this.onChanged,
  });

  final List<ProviderConfig> providers;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = providers.firstWhere(
      (item) => item.id == value,
      orElse: () => providers.first,
    );
    return PopupMenuButton<String>(
      tooltip: '切换厂家',
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final provider in providers)
          CheckedPopupMenuItem(
            value: provider.id,
            checked: provider.id == current.id,
            child: Text(provider.name),
          ),
      ],
      child: Tooltip(
        message: '厂家：${current.name}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_outlined, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  current.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 16, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话内「切换模型」的同款胶囊：厂家 · 模型 + 下拉勾选列表。
///
/// 供聊天面板与首页快捷配置共用，保证两处组件与布局一致。
class ModelPicker extends StatelessWidget {
  const ModelPicker({
    super.key,
    required this.provider,
    required this.model,
    required this.onChanged,
    this.enabled = true,
  });

  final ProviderConfig provider;

  /// 当前模型（可能不在 [provider].models 里，例如手填 ID）。
  final String model;

  final ValueChanged<String> onChanged;

  /// false（如未配置厂家）时只展示文案，不弹菜单。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final models = <String>{
      ...provider.models,
      if (model.isNotEmpty) model,
    }.toList();
    final label = model.isNotEmpty ? model : provider.name;
    final full = '${provider.name} · $label';
    if (!enabled || models.isEmpty) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Text(
          full,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return PopupMenuButton<String>(
      tooltip: '切换模型（限同一提供商）',
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final value in models)
          CheckedPopupMenuItem(
            value: value,
            checked: value == model,
            child: Text(value),
          ),
      ],
      child: Tooltip(
        message: full,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.memory, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  full,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 16, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
