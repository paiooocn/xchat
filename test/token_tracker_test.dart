import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/agent/llm_client.dart';
import 'package:xchat/agent/token_tracker.dart';
import 'package:xchat/config/config_manager.dart';
import 'package:xchat/session/session_io.dart';
import 'package:xchat/session/session_model.dart';

void main() {
  late Directory tmp;
  late ChatSession session;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('xchat_test_tt_');
    ConfigManager.instance.initForTest(tmp);
  });

  setUp(() async {
    session = ChatSession(
      id: 'test-session-${DateTime.now().microsecondsSinceEpoch}',
      sandbox: '/tmp',
      systemPrompt: '',
    );
    await SessionIo.write(session);
  });

  group('TokenTracker.apply', () {
    Future<Message> applyOnce(LlmUsage usage, {String text = 'a'}) async {
      final m = Message(role: Role.assistant, text: text);
      session.messages.add(m);
      await TokenTracker.apply(session, m, usage);
      return m;
    }

    test('第一轮 usage 写入 assistant 与 system 累计', () async {
      final m = await applyOnce(LlmUsage(100, 50, 10, 0));
      final back = await SessionIo.read(session.id);
      // 取 session 中已写入的 assistant
      final a = back.messages.last;
      expect(a.input, 100);
      expect(a.output, 50);
      expect(a.cache, 10); // cacheRead + cacheWrite
      expect(back.sysInput, 100);
      expect(back.sysOutput, 50);
      expect(back.sysCache, 10);
      expect(back.sysContext, 150); // input + output
    });

    test('多轮累加正确', () async {
      await applyOnce(LlmUsage(100, 50, 10, 0), text: 'first');
      await applyOnce(LlmUsage(200, 80, 20, 0), text: 'second');
      final back = await SessionIo.read(session.id);
      expect(back.sysInput, 300);
      expect(back.sysOutput, 130);
      expect(back.sysCache, 30);
      expect(back.sysContext, 280); // 最近一轮 input+output
      expect(back.messages.length, 2);
      expect(back.messages[0].input, 100);
      expect(back.messages[1].input, 200);
    });

    test('cacheRead + cacheWrite 都计入 cache', () async {
      await applyOnce(LlmUsage(100, 50, 30, 70));
      final back = await SessionIo.read(session.id);
      expect(back.messages.last.cache, 100); // 30 + 70
      expect(back.sysCache, 100);
    });

    test('context 是最近一轮 input+output', () async {
      await applyOnce(LlmUsage(500, 200, 0, 0), text: 'old');
      await applyOnce(LlmUsage(1000, 400, 0, 0), text: 'new');
      final back = await SessionIo.read(session.id);
      expect(back.sysContext, 1400);
    });
  });
}
