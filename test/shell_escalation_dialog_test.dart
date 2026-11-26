import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/models/app_config.dart';
import 'package:xchat/ui/widgets/shell_escalation_dialog.dart';

void main() {
  group('needsShellEscalationPrompt', () {
    test('2 级 + 清理/删除类消息 → 需要提示', () {
      final config = AppConfig();
      expect(config.shellBaseLevel, 2);
      expect(needsShellEscalationPrompt('帮我删除这些临时文件', config), isTrue);
      expect(needsShellEscalationPrompt('清理一下下载目录', config), isTrue);
      expect(needsShellEscalationPrompt('把旧邮件全部删除', config), isTrue);
    });

    test('普通消息不提示', () {
      final config = AppConfig();
      expect(needsShellEscalationPrompt('解释一下这个函数的实现', config), isFalse);
      expect(needsShellEscalationPrompt('删掉这个字段的校验', config), isFalse);
      expect(needsShellEscalationPrompt('', config), isFalse);
    });

    test('已设为 3 级时不提示（本来就要逐条审批）', () {
      final config = AppConfig()..toolApprovals['shell'] = 3;
      expect(config.shellBaseLevel, 3);
      expect(needsShellEscalationPrompt('删除所有临时文件', config), isFalse);
    });
  });

  group('提级警告框', () {
    /// 渲染一个「发送」按钮：点击后走一遍发送前判定，结果回调 [onResult]。
    Future<void> pumpSend(
      WidgetTester tester, {
      required String text,
      required AppConfig config,
      required void Function(bool) onResult,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onResult(await confirmShellEscalationIfNeeded(
                context,
                text: text,
                config: config,
              )),
              child: const Text('send'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('send'));
      await tester.pumpAndSettle();
    }

    testWidgets('命中时弹出红色警告框，点取消 → 不发送', (tester) async {
      final config = AppConfig();
      bool? result;
      await pumpSend(tester,
          text: '删除所有临时文件', config: config, onResult: (v) => result = v);

      final dialog = find.byKey(const Key('shell-escalation-dialog'));
      expect(dialog, findsOneWidget);
      expect(find.text('高危操作提示'), findsOneWidget);

      // 红色：图标 / 标题同色，且不是默认主色。
      final icon = tester.widget<Icon>(find.byIcon(Icons.warning_amber_rounded));
      final title = tester.widget<Text>(find.text('高危操作提示'));
      expect(icon.color, isNotNull);
      expect(title.style?.color, icon.color);
      expect(icon.color, isNot(Colors.blue));

      await tester.tap(find.byKey(const Key('shell-escalation-cancel')));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(result, isFalse);
    });

    testWidgets('点确认 → 返回 true（继续发送）', (tester) async {
      final config = AppConfig();
      bool? result;
      await pumpSend(tester,
          text: '删除所有临时文件', config: config, onResult: (v) => result = v);
      await tester.tap(find.byKey(const Key('shell-escalation-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shell-escalation-dialog')), findsNothing);
      expect(result, isTrue);
    });

    testWidgets('未命中时不弹框，直接返回 true', (tester) async {
      final config = AppConfig();
      bool? result;
      await pumpSend(tester,
          text: '帮我读一下 README', config: config, onResult: (v) => result = v);
      expect(find.byKey(const Key('shell-escalation-dialog')), findsNothing);
      expect(result, isTrue);
    });
  });
}
