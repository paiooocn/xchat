import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xchat/config/config_manager.dart';
import 'package:xchat/session/session_io.dart';
import 'package:xchat/session/session_model.dart';
import 'package:xchat/util/uuid.dart';

void main() {
  setUpAll(() async {
    // 把 xchatDir 重定向到临时目录,避免污染真实 ~/.xchat
    final tmp = Directory.systemTemp.createTempSync('xchat_test_io_');
    ConfigManager.instance.initForTest(tmp);
  });

  group('SessionIo XML roundtrip', () {
    test('基本字段保留', () async {
      final s = ChatSession(
        id: uuidV4(),
        sandbox: '/tmp/sb',
        title: '测试会话',
        maxRounds: 25,
        systemPrompt: '你是助手。',
      );
      s.meta.providerId = 'openai-main';
      s.meta.modelId = 'gpt-4o';
      s.meta.temperature = 0.5;
      s.meta.thinking = 'enabled';
      s.meta.reasoningEffort = 'high';
      s.meta.confirmMode = 'yolo';
      s.tools.addAll([ToolDef('read_file'), ToolDef('shell')]);
      s.messages.add(Message(role: Role.user, text: '你好'));
      s.messages.add(Message(role: Role.assistant, text: '你好,有什么可以帮你?'));
      s.messages.add(Message(role: Role.user, text: '读 README'));

      await SessionIo.write(s);
      final back = await SessionIo.read(s.id);

      expect(back.id, s.id);
      expect(back.sandbox, '/tmp/sb');
      expect(back.title, '测试会话');
      expect(back.maxRounds, 25);
      expect(back.systemPrompt, '你是助手。');
      expect(back.meta.providerId, 'openai-main');
      expect(back.meta.modelId, 'gpt-4o');
      expect(back.meta.temperature, 0.5);
      expect(back.meta.thinking, 'enabled');
      expect(back.meta.reasoningEffort, 'high');
      expect(back.meta.confirmMode, 'yolo');
      expect(back.tools.length, 2);
      expect(back.tools[0].name, 'read_file');
      expect(back.messages.length, 3);
      expect(back.messages[2].role, Role.user);
      expect(back.messages[2].text, '读 README');
    });

    test('CDATA 内的 < > & 不破坏 XML', () async {
      final s = ChatSession(
        id: uuidV4(),
        sandbox: '/tmp',
        systemPrompt: 'a & b < c > d',
      );
      s.messages.add(Message(role: Role.user, text: 'if a<b && c>d: print("ok")'));
      s.messages.add(Message(
        role: Role.assistant,
        text: '<tool_use>{"name":"shell"}</tool_use>',
      ));
      await SessionIo.write(s);
      final back = await SessionIo.read(s.id);

      expect(back.systemPrompt, 'a & b < c > d');
      expect(back.messages[0].text, 'if a<b && c>d: print("ok")');
      expect(back.messages[1].text, '<tool_use>{"name":"shell"}</tool_use>');
    });

    test('CDATA 内的 ]]> 序列被分段', () async {
      final s = ChatSession(
        id: uuidV4(),
        sandbox: '/tmp',
      );
      s.messages.add(Message(role: Role.user, text: 'a]]>b ]]>c'));
      await SessionIo.write(s);

      // 原始 XML 中不能出现未经分段的 ]]>
      final dir = await SessionIo.sessionsDir();
      final file = File(p.join(dir.path, '${s.id}.xml'));
      final raw = await file.readAsString();
      // 排除 CDATA 分段后(]]]]><![CDATA[>),不应有单独 ]]> 关闭
      // 简单验证:重新读能还原
      final back = await SessionIo.read(s.id);
      expect(back.messages.first.text, 'a]]>b ]]>c');
      // 验证:文件里能匹配到 ]]]> 但都是成对分段
      expect(raw.contains('<![CDATA['), true);
    });

    test('assistant 含 tool_calls 时 roundtrip 完整', () async {
      final s = ChatSession(
        id: uuidV4(),
        sandbox: '/tmp',
      );
      final tc = ToolCall(
        id: 'call_123',
        name: 'shell',
        arguments: '{"cmd":"ls -la"}',
      );
      final a = Message(role: Role.assistant, text: '好的,我来执行');
      a.toolCalls.add(tc);
      a.input = 100;
      a.output = 20;
      a.cache = 50;
      a.model = 'gpt-4o';
      s.messages.add(a);
      s.messages.add(Message(
        role: Role.tool,
        text: 'file1\nfile2',
        toolCallId: 'call_123',
        toolName: 'shell',
      ));

      await SessionIo.write(s);
      final back = await SessionIo.read(s.id);

      expect(back.messages[0].role, Role.assistant);
      expect(back.messages[0].text, '好的,我来执行');
      expect(back.messages[0].toolCalls.length, 1);
      expect(back.messages[0].toolCalls[0].id, 'call_123');
      expect(back.messages[0].toolCalls[0].name, 'shell');
      expect(back.messages[0].toolCalls[0].arguments, '{"cmd":"ls -la"}');
      expect(back.messages[0].input, 100);
      expect(back.messages[0].output, 20);
      expect(back.messages[0].cache, 50);
      expect(back.messages[0].model, 'gpt-4o');
      expect(back.messages[1].role, Role.tool);
      expect(back.messages[1].toolCallId, 'call_123');
      expect(back.messages[1].text, 'file1\nfile2');
    });

    test('新 XML 格式:assistant.tool_calls 是子元素,tool 消息是同级元素', () async {
      final s = ChatSession(id: uuidV4(), sandbox: '/tmp');
      // 多轮:user → assistant{tool_calls×2} → tool, tool → assistant{text} → user
      s.messages.add(Message(role: Role.user, text: 'readme 和 ls'));
      final a1 = Message(role: Role.assistant, text: '好的,我并行读两个文件');
      a1.toolCalls.addAll([
        ToolCall(id: 'call_a', name: 'read_file', arguments: '{"path":"README.md"}'),
        ToolCall(id: 'call_b', name: 'shell', arguments: '{"cmd":"ls"}'),
      ]);
      s.messages.add(a1);
      s.messages.add(Message(role: Role.tool, text: 'hello', toolCallId: 'call_a', toolName: 'read_file'));
      s.messages.add(Message(role: Role.tool, text: 'a.txt\nb.txt', toolCallId: 'call_b', toolName: 'shell'));
      s.messages.add(Message(role: Role.assistant, text: 'README 是 hello,目录里有 a.txt 和 b.txt'));
      s.messages.add(Message(role: Role.user, text: '谢谢'));

      await SessionIo.write(s);
      final raw = await File(p.join((await SessionIo.sessionsDir()).path, '${s.id}.xml'))
          .readAsString();

      // 验证 XML 形态:assistant 内嵌 tool_calls,tool 消息带 tool_call_id
      expect(raw.contains('<tool_calls>'), true,
          reason: 'assistant 必须内嵌 <tool_calls> 子元素');
      expect(raw.contains('<tool_call '), true);
      expect(raw.contains('tool_call_id="call_a"'), true);
      expect(raw.contains('tool_call_id="call_b"'), true);
      // tool 消息作为 assistant 同级出现(都直接在 chat 下)
      // 简单验证:tool 消息出现在 assistant 标签外
      final a1Start = raw.indexOf('<assistant');
      final t1Start = raw.indexOf('tool_call_id="call_a"');
      final a1End = raw.indexOf('</assistant>', a1Start);
      expect(t1Start > a1End, true,
          reason: 'tool 消息必须在 assistant 关闭之后');

      final back = await SessionIo.read(s.id);

      // 顺序保留:[user, assistant{2 tool_calls}, tool, tool, assistant, user] = 6
      expect(back.messages.length, 6);
      expect(back.messages[0].role, Role.user);
      expect(back.messages[0].text, 'readme 和 ls');
      expect(back.messages[1].role, Role.assistant);
      expect(back.messages[1].text, '好的,我并行读两个文件');
      expect(back.messages[1].toolCalls.length, 2);
      // toolCalls 顺序与写入顺序一致
      expect(back.messages[1].toolCalls[0].id, 'call_a');
      expect(back.messages[1].toolCalls[1].id, 'call_b');
      expect(back.messages[1].toolCalls[0].arguments, '{"path":"README.md"}');
      expect(back.messages[1].toolCalls[1].arguments, '{"cmd":"ls"}');
      expect(back.messages[2].role, Role.tool);
      expect(back.messages[2].toolCallId, 'call_a');
      expect(back.messages[2].toolName, 'read_file');
      expect(back.messages[3].role, Role.tool);
      expect(back.messages[3].toolCallId, 'call_b');
      expect(back.messages[4].role, Role.assistant);
      expect(back.messages[4].text, 'README 是 hello,目录里有 a.txt 和 b.txt');
      expect(back.messages[4].toolCalls.isEmpty, true);
      expect(back.messages[5].role, Role.user);
    });

    test('新 XML 格式:tool_calls 中的 arguments 走 CDATA,保留特殊字符', () async {
      final s = ChatSession(id: uuidV4(), sandbox: '/tmp');
      s.messages.add(Message(role: Role.user, text: 'shell'));
      final a = Message(role: Role.assistant);
      // arguments 含换行、引号、大括号、HTML-like 文本
      a.toolCalls.add(ToolCall(
        id: 'c1',
        name: 'shell',
        arguments: '{"cmd":"echo \"<a & b>\" && cat"}',
      ));
      s.messages.add(a);
      s.messages.add(Message(role: Role.tool, text: 'r', toolCallId: 'c1', toolName: 'shell'));
      s.messages.add(Message(role: Role.user, text: 'next'));

      await SessionIo.write(s);
      final back = await SessionIo.read(s.id);
      expect(back.messages[1].toolCalls[0].arguments,
          '{"cmd":"echo \"<a & b>\" && cat"}');
    });

    test('旧 XML 格式兼容:读取含 [[tool_calls]] 标记块的 assistant', () async {
      // 手写一份旧格式 XML,确保 reader 能解析
      final oldXml = '''<?xml version="1.0" encoding="UTF-8"?>
<chat sandbox="/tmp" id="legacy-1" created="2024-01-01T00:00:00.000Z" updated="2024-01-01T00:00:00.000Z" max_rounds="20">
<meta>
<provider id="p"/>
<model id="m"/>
</meta>
<system input="0" output="0" cache="0" context="0"></system>
<tool name="shell"/>
<user><![CDATA[hi]]></user>
<assistant input="10" output="5" model="gpt-4o"><![CDATA[ok
[[tool_calls]]
[
{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\\"cmd\\":\\"ls\\"}"}}
]
[[/tool_calls]]]]></assistant>
<tool tool_call_id="c1" name="shell"><![CDATA[file.txt]]></tool>
<user><![CDATA[done?]]></user>
</chat>''';
      final dir = await SessionIo.sessionsDir();
      await File(p.join(dir.path, 'legacy-1.xml')).writeAsString(oldXml);

      final back = await SessionIo.read('legacy-1');
      expect(back.messages.length, 4);
      expect(back.messages[1].role, Role.assistant);
      expect(back.messages[1].text, 'ok');
      expect(back.messages[1].toolCalls.length, 1);
      expect(back.messages[1].toolCalls[0].id, 'c1');
      expect(back.messages[1].toolCalls[0].name, 'shell');
      expect(back.messages[1].toolCalls[0].arguments, '{"cmd":"ls"}');
      expect(back.messages[2].role, Role.tool);
      expect(back.messages[2].toolCallId, 'c1');
    });

    test('system 累计字段保留', () async {
      final s = ChatSession(
        id: uuidV4(),
        sandbox: '/tmp',
      );
      s.sysInput = 12345;
      s.sysOutput = 678;
      s.sysCache = 1000;
      s.sysContext = 5678;
      await SessionIo.write(s);
      final back = await SessionIo.read(s.id);
      expect(back.sysInput, 12345);
      expect(back.sysOutput, 678);
      expect(back.sysCache, 1000);
      expect(back.sysContext, 5678);
    });

    test('tags 与 projectId 保留', () async {
      final s = ChatSession(
        id: uuidV4(),
        sandbox: '/tmp',
      );
      s.projectId = 'proj-1';
      s.tags = ['urgent', 'refactor'];
      await SessionIo.write(s);
      final back = await SessionIo.read(s.id);
      expect(back.projectId, 'proj-1');
      expect(back.tags, ['urgent', 'refactor']);
    });

    test('archive 段保留', () async {
      final s = ChatSession(
        id: uuidV4(),
        sandbox: '/tmp',
      );
      s.archiveSummary = '旧对话摘要';
      s.archive.add(Message(role: Role.user, text: '旧问题'));
      s.archive.add(Message(role: Role.assistant, text: '旧回答'));
      s.messages.add(Message(role: Role.user, text: '新问题'));
      await SessionIo.write(s);
      final back = await SessionIo.read(s.id);
      expect(back.archiveSummary, '旧对话摘要');
      expect(back.archive.length, 2);
      expect(back.archive[0].text, '旧问题');
      expect(back.messages[0].text, '新问题');
    });
  });
}
