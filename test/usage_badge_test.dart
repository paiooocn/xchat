import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_message.dart';
import 'package:xchat/models/token_usage.dart';
import 'package:xchat/ui/widgets/usage_badge.dart';
import 'helpers/test_theme.dart';

void main() {
  group('TokenUsage.cacheRate', () {
    test('cache / input', () {
      expect(
        const TokenUsage(input: 1000, cache: 750).cacheRate,
        closeTo(0.75, 1e-9),
      );
      expect(
        const TokenUsage(input: 800, cache: 800).cacheRate,
        1.0,
      );
    });

    test('cache 超过 input 时夹到 1', () {
      expect(const TokenUsage(input: 100, cache: 250).cacheRate, 1.0);
    });

    test('input 或 cache 缺失 / input 为 0 → null', () {
      expect(const TokenUsage(input: 1000).cacheRate, isNull);
      expect(const TokenUsage(cache: 500).cacheRate, isNull);
      expect(const TokenUsage(input: 0, cache: 500).cacheRate, isNull);
      expect(TokenUsage.empty.cacheRate, isNull);
    });
  });

  group('Session.totalAssistantDuration', () {
    Session sessionWith(List<SessionMessage> messages) => Session(
          id: 's1',
          sandbox: '/tmp/s',
          createdAt: DateTime.utc(2025),
          updatedAt: DateTime.utc(2025),
          messages: [SessionMessage(role: MessageRole.system, content: 'sys'), ...messages],
        );

    test('空会话为 0', () {
      expect(sessionWith(<SessionMessage>[]).totalAssistantDuration, Duration.zero);
    });

    test('单轮 = 接收 − 本轮起始 user 发送', () {
      final session = sessionWith([
        SessionMessage(
          role: MessageRole.user,
          content: 'q',
          sentAt: DateTime.utc(2025, 1, 1, 0, 0, 0),
        ),
        SessionMessage(
          role: MessageRole.assistant,
          content: 'a',
          receivedAt: DateTime.utc(2025, 1, 1, 0, 1, 30),
        ),
      ]);
      expect(session.totalAssistantDuration, const Duration(seconds: 90));
    });

    test('同一轮多条 assistant 只按最后一条计一次（不重复累计）', () {
      final session = sessionWith([
        SessionMessage(
          role: MessageRole.user,
          content: 'q',
          sentAt: DateTime.utc(2025, 1, 1, 0, 0, 0),
        ),
        SessionMessage(
          role: MessageRole.assistant,
          content: 'round1',
          receivedAt: DateTime.utc(2025, 1, 1, 0, 0, 10),
        ),
        SessionMessage(role: MessageRole.tool, content: 'ok'),
        SessionMessage(
          role: MessageRole.assistant,
          content: 'round2',
          receivedAt: DateTime.utc(2025, 1, 1, 0, 1, 0),
        ),
      ]);
      // 1 分整，而不是 10 秒 + 60 秒。
      expect(session.totalAssistantDuration, const Duration(seconds: 60));
    });

    test('多轮累加', () {
      final session = sessionWith([
        SessionMessage(
          role: MessageRole.user,
          content: 'q1',
          sentAt: DateTime.utc(2025, 1, 1, 0, 0, 0),
        ),
        SessionMessage(
          role: MessageRole.assistant,
          content: 'a1',
          receivedAt: DateTime.utc(2025, 1, 1, 0, 0, 30),
        ),
        SessionMessage(
          role: MessageRole.user,
          content: 'q2',
          sentAt: DateTime.utc(2025, 1, 1, 0, 1, 40),
        ),
        SessionMessage(
          role: MessageRole.assistant,
          content: 'a2',
          receivedAt: DateTime.utc(2025, 1, 1, 0, 2, 30),
        ),
      ]);
      expect(session.totalAssistantDuration, const Duration(seconds: 80));
    });

    test('缺时间戳的轮次不计入（旧存档）', () {
      final session = sessionWith([
        SessionMessage(role: MessageRole.user, content: 'q-no-time'),
        SessionMessage(
          role: MessageRole.assistant,
          content: 'a',
          receivedAt: DateTime.utc(2025, 1, 1, 0, 1, 0),
        ),
      ]);
      expect(session.totalAssistantDuration, Duration.zero);
    });

    test('只有 user 没有 assistant 的轮次不计入', () {
      final session = sessionWith([
        SessionMessage(
          role: MessageRole.user,
          content: 'q',
          sentAt: DateTime.utc(2025, 1, 1, 0, 0, 0),
        ),
      ]);
      expect(session.totalAssistantDuration, Duration.zero);
    });

    test('接收早于发送（时钟回拨）按 0 计', () {
      final session = sessionWith([
        SessionMessage(
          role: MessageRole.user,
          content: 'q',
          sentAt: DateTime.utc(2025, 1, 1, 0, 1, 0),
        ),
        SessionMessage(
          role: MessageRole.assistant,
          content: 'a',
          receivedAt: DateTime.utc(2025, 1, 1, 0, 0, 0),
        ),
      ]);
      expect(session.totalAssistantDuration, Duration.zero);
    });
  });

  group('UsageBadge', () {
    testWidgets('cache 显示缓存利用率，并显示总耗时', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: const Scaffold(
          body: UsageBadge(
            usage: TokenUsage(input: 900, output: 200, cache: 675),
            duration: Duration(minutes: 2, seconds: 5),
          ),
        ),
      ));
      expect(find.text('in 900'), findsOneWidget);
      expect(find.text('out 200'), findsOneWidget);
      expect(find.text('cache 75%'), findsOneWidget);
      expect(find.text('耗时 2 分 5 秒'), findsOneWidget);
    });

    testWidgets('input 缺失时 cache 退回原始计数', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: const Scaffold(
          body: UsageBadge(usage: TokenUsage(cache: 500)),
        ),
      ));
      expect(find.text('cache 500'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('无 cache / 无耗时时不显示对应项', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: const Scaffold(
          body: UsageBadge(usage: TokenUsage(input: 10, output: 5)),
        ),
      ));
      expect(find.text('in 10'), findsOneWidget);
      expect(find.text('out 5'), findsOneWidget);
      expect(find.textContaining('cache'), findsNothing);
      expect(find.textContaining('耗时'), findsNothing);
    });

    testWidgets('全空时渲染为空', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: testTheme(),
        home: const Scaffold(body: UsageBadge(usage: TokenUsage.empty)),
      ));
      expect(find.byType(SizedBox), findsWidgets);
      expect(find.textContaining('in '), findsNothing);
    });
  });
}
