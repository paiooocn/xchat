import 'package:flutter/material.dart';

import '../../models/app_config.dart';
import '../../models/shell_policy.dart';

/// 发送前的「shell 提级」确认：清理 / 删除类任务在高危等级下才允许执行。
///
/// 判定：shell 的**未登记命令**仍是 2 级（`AppConfig.shellBaseLevel`），且这条
/// 用户消息是「清理 / 删除 + 文件 / 文件夹 / 目录 / 邮件 / 邮箱」类任务
/// （`isCleanupDeleteTask`）。为 3 级时无需提示——用户本来就要逐条审批。
bool needsShellEscalationPrompt(String? text, AppConfig config) =>
    config.shellBaseLevel < kShellBaseLevelMax && isCleanupDeleteTask(text);

/// 需要时弹出**红色**的提级警告框。
///
/// 返回 `true` = 用户确认，继续发送（该轮未登记命令按 3 级处理）；
/// `false` = 取消（或直接关掉弹窗），调用方**不得发送**这条消息。
Future<bool> confirmShellEscalationIfNeeded(
  BuildContext context, {
  required String? text,
  required AppConfig config,
}) async {
  if (!needsShellEscalationPrompt(text, config)) return true;
  return confirmShellEscalation(context);
}

/// 红色的提级警告框；确认返回 `true`，取消 / 关闭返回 `false`。
Future<bool> confirmShellEscalation(BuildContext context) async {
  final theme = Theme.of(context);
  final error = theme.colorScheme.error;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('shell-escalation-dialog'),
      // 高危提示：红底 + 红边，与普通确认框明显区分。
      backgroundColor: Color.alphaBlend(error.withValues(alpha: 0.08), theme.colorScheme.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: error, width: 1.5),
      ),
      icon: Icon(Icons.warning_amber_rounded, color: error, size: 34),
      title: Text(
        '高危操作提示',
        style: TextStyle(color: error, fontWeight: FontWeight.bold),
      ),
      content: Text(
        '检测到本次要求涉及删除文件 / 文件夹 / 目录 / 邮件 / 邮箱等高危操作，'
        '而 shell 的未登记命令当前是 2 级（普通/自动审批）。\n\n'
        '这类任务应在 3 级 shell 下执行：点「确认并发送」后，'
        '本轮对话会临时把未登记命令提到 3 级（每条这样的命令都会先弹审批），'
        '本轮结束后自动回到 2 级。\n\n'
        '点「取消」则不会发送这条消息。',
        style: TextStyle(fontSize: 13.5, height: 1.45, color: error),
      ),
      actions: [
        TextButton(
          key: const Key('shell-escalation-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text('取消', style: TextStyle(color: error.withValues(alpha: 0.85))),
        ),
        FilledButton(
          key: const Key('shell-escalation-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('确认并发送'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
