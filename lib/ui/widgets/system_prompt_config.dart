import 'package:flutter/material.dart';

import '../../models/expertise.dart';
import '../theme/app_theme.dart';

/// 会话模板「系统提示词」配置区：文本输入 / AI专长 两种互斥方式。
///
/// - 文本输入：多行手动输入；
/// - AI专长：从 [expertises] 中多选 badge，最终由 [composeExpertisePrompt]
///   按专长库固定顺序组合（与点击顺序无关）。
///
/// 本组件只负责展示与交互，状态（当前模式、已选 id、文本控制器）由父页面持有，
/// 这样切换模式时两侧数据都不会被清空。
class SystemPromptConfig extends StatelessWidget {
  const SystemPromptConfig({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.controller,
    required this.expertises,
    required this.selectedIds,
    required this.onToggleExpertise,
    this.textLabel = '系统提示词（{sandbox} 自动替换为会话 sandbox 路径）',
    this.textMinLines = 3,
    this.textMaxLines = 8,
  });

  final SystemPromptMode mode;
  final ValueChanged<SystemPromptMode> onModeChanged;

  /// 「文本输入」一侧的多行输入框控制器。
  final TextEditingController controller;

  /// 专长库（未排序也可，展示与组合都按 `sort` 升序）。
  final List<Expertise> expertises;

  /// 当前选中的专长 id（顺序不影响最终组合）。
  final Set<String> selectedIds;

  final ValueChanged<String> onToggleExpertise;

  final String textLabel;
  final int textMinLines;
  final int textMaxLines;

  static const String expertiseHint =
      '选择一个或多个 AI 专长，系统将按专长库中的顺序自动组合为系统提示词。';
  static const String emptyLibraryText = '暂无可用的 AI 专长。';
  static const String emptySelectionText = '请至少选择一个 AI 专长。';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<SystemPromptMode>(
          segments: const <ButtonSegment<SystemPromptMode>>[
            ButtonSegment(
              value: SystemPromptMode.text,
              icon: Icon(Icons.edit_outlined, size: 16),
              label: Text('文本输入'),
            ),
            ButtonSegment(
              value: SystemPromptMode.expertise,
              icon: Icon(Icons.auto_awesome, size: 16),
              label: Text('AI专长'),
            ),
          ],
          selected: <SystemPromptMode>{mode},
          onSelectionChanged: (selection) => onModeChanged(selection.first),
        ),
        const SizedBox(height: 12),
        if (mode == SystemPromptMode.text)
          TextField(
            controller: controller,
            minLines: textMinLines,
            maxLines: textMaxLines,
            decoration: InputDecoration(
              labelText: textLabel,
              border: const OutlineInputBorder(),
            ),
          )
        else
          _buildExpertisePanel(context),
      ],
    );
  }

  Widget _buildExpertisePanel(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 停用项不进模板的待选项（仍可去「AI专长管理」启用 / 编辑）。
    final library =
        sortExpertiseLibrary(expertises).where((item) => item.enabled).toList();
    final hasSelection = library.any(
      (item) => selectedIds.any(item.matchesId),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(expertiseHint, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        if (library.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Icon(Icons.inbox_outlined, size: 18, color: scheme.outline),
                const SizedBox(width: 8),
                Expanded(child: Text(emptyLibraryText)),
              ],
            ),
          )
        else
          // 与上方系统提示词输入框同宽、同款描边；badge 间距约 12px。
          ExpertiseBadges(
            expertises: expertises,
            selectedIds: selectedIds,
            onToggle: onToggleExpertise,
          ),
        if (!hasSelection) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: scheme.error),
              const SizedBox(width: 6),
              Text(
                emptySelectionText,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 专长 badge 组：与提示词输入框同宽、同款描边，只展示启用的专长。
class ExpertiseBadges extends StatelessWidget {
  const ExpertiseBadges({
    super.key,
    required this.expertises,
    required this.selectedIds,
    required this.onToggle,
    this.framed = true,
    this.centered = false,
    this.dense = false,
  });

  final List<Expertise> expertises;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggle;

  /// 是否套用与输入框同款的描边外框（模板页用，首页欢迎页用紧凑居中版）。
  final bool framed;

  /// badge 是否整体居中排布。
  final bool centered;

  /// 紧凑样式：背景/字号与输入栏下区「项目文件夹」胶囊一致（首页用）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final library =
        sortExpertiseLibrary(expertises).where((item) => item.enabled).toList();
    final wrap = Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: centered ? WrapAlignment.center : WrapAlignment.start,
      children: [
        for (final expertise in library)
          ExpertiseBadge(
            expertise: expertise,
            selected: selectedIds.any(expertise.matchesId),
            onTap: () => onToggle(expertise.id),
            dense: dense,
          ),
      ],
    );
    if (!framed) return wrap;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 96),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: wrap,
    );
  }
}

/// 单个专长标签胶囊：选中时绿色填充（无对勾），悬停 / 长按展示说明。
class ExpertiseBadge extends StatelessWidget {
  const ExpertiseBadge({
    super.key,
    required this.expertise,
    required this.selected,
    required this.onTap,
    this.dense = false,
  });

  final Expertise expertise;
  final bool selected;
  final VoidCallback onTap;

  /// 紧凑样式（首页）：背景 / 字号对齐输入栏下区胶囊。
  final bool dense;

  static const Color _selectedColor = Color(0xFF43A047);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = expertise.description.trim();
    final tooltip = description.isEmpty
        ? expertise.name
        : '${expertise.name}\n\n$description';
    final selectedColor = selected ? _selectedColor : null;
    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.longPress,
      child: Semantics(
        button: true,
        selected: selected,
        label: expertise.name,
        value: description,
        child: InkWell(
          key: Key('expertise-badge-${expertise.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(
            dense ? AppTheme.radiusMedium : 18,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 10 : 12,
              vertical: dense ? 7 : 7,
            ),
            decoration: BoxDecoration(
              color: selectedColor ??
                  (dense
                      ? scheme.surfaceContainerHigh.withValues(alpha: 0.7)
                      : scheme.surfaceContainerHighest),
              borderRadius: BorderRadius.circular(
                dense ? AppTheme.radiusMedium : 18,
              ),
              border: dense
                  ? null
                  : Border.all(
                      color: selectedColor ?? scheme.outlineVariant,
                    ),
            ),
            child: Text(
              expertise.name,
              style: dense
                  ? theme.textTheme.labelMedium?.copyWith(
                      color: selected ? Colors.white : scheme.onSurfaceVariant,
                    )
                  : theme.textTheme.bodyMedium?.copyWith(
                      color:
                          selected ? Colors.white : scheme.onSurfaceVariant,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
