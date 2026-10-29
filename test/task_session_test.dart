import 'package:flutter_test/flutter_test.dart';
import 'package:llm_api/llm_api.dart' as llm;
import 'package:xchat/data/xml/session_xml.dart';
import 'package:xchat/llm/outbound_adapter.dart';
import 'package:xchat/models/message_attachment.dart';
import 'package:xchat/models/provider_config.dart';
import 'package:xchat/models/catalog_index.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_message.dart';
import 'package:xchat/models/task_item.dart';
import 'package:xchat/session/session_ops.dart';

Session _taskSession() => Session(
      id: 'ts1',
      sandbox: '/tmp/s',
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
      kind: SessionKind.task,
      tasks: [
        TaskItem(id: 't1', title: '任务一', content: '做第一件事'),
        TaskItem(id: 't2', title: '任务二', content: '做第二件事', done: true),
      ],
      messages: [
        SessionMessage(role: MessageRole.system, content: 'sys'),
        SessionMessage(
            role: MessageRole.user, id: 'u1', content: '做第一件事', taskId: 't1'),
        SessionMessage(
            role: MessageRole.assistant, id: 'a1', content: '好的', taskId: 't1'),
        SessionMessage(
            role: MessageRole.user, id: 'u2', content: '做第二件事', taskId: 't2'),
        SessionMessage(
          role: MessageRole.assistant,
          id: 'a2',
          content: '第二个',
          taskId: 't2',
          toolCalls: [ToolCallData(id: 'c2', name: 'shell', arguments: '{}')],
        ),
        SessionMessage(
          role: MessageRole.tool,
          id: 'tr2',
          taskId: 't2',
          toolCallId: 'c2',
          toolName: 'shell',
          content: 'ok',
        ),
      ],
    );

void main() {
  group('任务式会话 XML', () {
    test('任务项与 task_id 往返', () {
      final xml = SessionXml.encode(_taskSession());
      expect(xml.contains('kind="task"'), isTrue);
      expect(xml.contains('<tasks>'), isTrue);
      expect(xml.contains('task_id="t1"'), isTrue);

      final decoded =
          SessionXml.decode(xml, filePath: '/tmp/sessions/ts1.xml');
      expect(decoded.kind, SessionKind.task);
      expect(decoded.tasks.length, 2);
      expect(decoded.tasks.first.title, '任务一');
      expect(decoded.tasks.first.content, '做第一件事');
      expect(decoded.tasks.last.done, isTrue);
      // 消息归属保留（含 thinking/tool 消息，显示时按 taskId 过滤）。
      expect(decoded.taskMessages('t1').length, 2);
      expect(decoded.taskMessages('t2').length, 3);
      expect(decoded.taskMessages('t2').last.role, MessageRole.tool);
    });

    test('旧会话文件没有 kind/task_id → 普通会话', () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<chat sandbox="/tmp/s">
  <meta>
    <id>old</id>
    <created_at>2025-01-01T00:00:00.000Z</created_at>
    <updated_at>2025-01-01T00:00:00.000Z</updated_at>
    <tool_calls>0</tool_calls>
    <tool_calls_limit>0</tool_calls_limit>
    <params></params>
  </meta>
  <system><![CDATA[sys]]></system>
  <user id="u1"><![CDATA[hi]]></user>
</chat>''';
      final decoded = SessionXml.decode(xml, filePath: '/tmp/sessions/old.xml');
      expect(decoded.kind, SessionKind.normal);
      expect(decoded.isTaskSession, isFalse);
      expect(decoded.tasks, isEmpty);
      expect(decoded.messages.last.taskId, isNull);
    });

    test('普通会话不写任务节点', () {
      final normal = Session(
        id: 'n1',
        sandbox: '/tmp/s',
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
        messages: [SessionMessage(role: MessageRole.system, content: 'sys')],
      );
      expect(SessionXml.encode(normal).contains('<tasks>'), isFalse);
      expect(SessionXml.encode(normal).contains('kind='), isFalse);
    });
  });

  group('任务式会话索引', () {
    test('kind 与任务计数往返', () {
      final entry = SessionIndexEntry.fromSession(_taskSession());
      expect(entry.kind, SessionKind.task);
      expect(entry.taskCount, 2);
      expect(entry.taskDoneCount, 1);

      final back = SessionIndexEntry.fromJson(entry.toJson());
      expect(back.kind, SessionKind.task);
      expect(back.taskCount, 2);
      expect(back.taskDoneCount, 1);
      expect(back.toSession().isTaskSession, isTrue);
    });

    test('普通会话索引不带任务计数字段', () {
      final entry = SessionIndexEntry.fromSession(Session(
        id: 'n1',
        sandbox: '/tmp/s',
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
      ));
      expect(entry.toJson().containsKey('task_count'), isFalse);
      expect(entry.kind, SessionKind.normal);
      expect(CatalogIndex.version, 4);
    });
  });

  group('按任务项限定的会话操作', () {
    test('lastUserIndex 只在目标任务内查找', () {
      final session = _taskSession();
      expect(SessionOps.lastUserIndex(session), 3); // t2 的 user
      expect(SessionOps.lastUserIndex(session, onlyTaskId: 't1'), 1);
      expect(SessionOps.lastUserIndex(session, onlyTaskId: 'nope'), -1);
    });

    test('editLastUser 只删除本任务的消息，别任务的对话保留', () {
      final session = _taskSession();
      final ok = SessionOps.editLastUser(session, '改过的第一件事', onlyTaskId: 't1');
      expect(ok, isTrue);
      expect(session.messages[1].content, '改过的第一件事');
      // t1 的 assistant 被删掉，t2 的三条消息原样保留。
      expect(session.taskMessages('t1').length, 1);
      expect(session.taskMessages('t2').length, 3);
    });

    test('deleteMessage 只连带删除同任务的工具结果', () {
      final session = _taskSession();
      final index = session.messages.indexWhere((m) => m.id == 'a2');
      SessionOps.deleteMessage(session, index);
      expect(session.messages.any((m) => m.id == 'a2'), isFalse);
      expect(session.messages.any((m) => m.id == 'tr2'), isFalse);
      expect(session.taskMessages('t1').length, 2);
    });

    test('removeTask 连带清掉该任务的消息', () {
      final session = _taskSession();
      session.removeTask('t2');
      expect(session.tasks.length, 1);
      expect(session.taskMessages('t2'), isEmpty);
      expect(session.messages.any((m) => m.role == MessageRole.tool), isFalse);
      expect(session.taskMessages('t1').length, 2);
    });
  });

  group('Markdown 批量导入', () {
    test('## 标题分段，正文归入对应任务', () {
      final tasks = parseTaskMarkdown('''
## 任务一
第一步
第二步

## 任务二
做点别的
''');
      expect(tasks.length, 2);
      expect(tasks[0].title, '任务一');
      expect(tasks[0].content, '第一步\n第二步');
      expect(tasks[1].title, '任务二');
      expect(tasks[1].content, '做点别的');
    });

    test('### 不当作分段边界', () {
      final tasks = parseTaskMarkdown('## A\n### 小节\n内容');
      expect(tasks.length, 1);
      expect(tasks.single.content, '### 小节\n内容');
    });

    test('没有 ## 时整段作为一个任务', () {
      final tasks = parseTaskMarkdown('只有一段正文\n第二行');
      expect(tasks.length, 1);
      expect(tasks.single.title, isEmpty);
      expect(tasks.single.displayTitle, '只有一段正文');
      expect(tasks.single.promptText, '只有一段正文\n第二行');
    });

    test('第一个 ## 之前的正文保留为无标题任务', () {
      final tasks = parseTaskMarkdown('前言行\n\n## 一\n正文一');
      expect(tasks.length, 2);
      expect(tasks.first.title, isEmpty);
      expect(tasks.first.content, '前言行');
      expect(tasks.last.title, '一');
    });

    test('空白输入得到空列表', () {
      expect(parseTaskMarkdown('   \n\n'), isEmpty);
    });
  });

  group('出站任务锚（每条 user 消息首行）', () {
    final provider = ProviderConfig(id: 'p', baseUrl: 'https://example.com/v1');

    Future<List<llm.ChatMessage>> build(Session session) =>
        buildChatMessages(session, provider: provider);

    test('任务内每条 user 消息都带标题，普通会话不受影响', () async {
      final session = _taskSession();
      session.messages.add(SessionMessage(
          role: MessageRole.user, id: 'u3', content: '这个要不要加索引？', taskId: 't1'));
      final built = await build(session);

      final users = built.where((m) => m.role == llm.ChatRole.user).toList();
      // 三条 user：t1 首条、t2 首条、t1 追问。
      expect(users.map((m) => m.content).toList(), [
        '【任务：任务一】\n做第一件事',
        '【任务：任务二】\n做第二件事',
        '【任务：任务一】\n这个要不要加索引？',
      ]);
    });

    test('标题只出现一次（首条不重复加锚）', () async {
      final built = await build(_taskSession());
      final first = built.firstWhere((m) => m.role == llm.ChatRole.user);
      expect('【任务：任务一】'.allMatches(first.content!).length, 1);
      expect(first.content, '【任务：任务一】\n做第一件事');
    });

    test('任务项已删除的消息不加锚', () async {
      final session = _taskSession()..tasks.removeWhere((t) => t.id == 't1');
      final built = await build(session);
      final users = built.where((m) => m.role == llm.ChatRole.user).toList();
      expect(users.first.content, '做第一件事');
      expect(users.last.content, '【任务：任务二】\n做第二件事');
    });

    test('带附件的 user 消息把锚作为第一个 text part', () async {
      final session = _taskSession();
      session.messages.add(SessionMessage(
        role: MessageRole.user,
        id: 'u9',
        taskId: 't1',
        content: '看这张图',
        attachments: [
          // 不存在的文件 → 图片载入失败，但锚（text part）仍应在最前。
          MessageAttachment(mimeType: 'image/png', name: 'x.png', path: '/nope/x.png'),
        ],
      ));
      final built = await build(session);
      final last = built.last;
      expect(last.role, llm.ChatRole.user);
      // 多模态消息：锚是第一个 text part（图片文件已丢失会降级成文字标记）。
      final parts = last.parts!;
      expect(parts.first, isA<llm.TextPart>());
      expect((parts.first as llm.TextPart).text, '【任务：任务一】\n');
      expect(parts.length, 3);
    });

    test('续判消息也带锚（同一次 turn 的 user 消息）', () async {
      final session = _taskSession();
      session.messages.add(SessionMessage(
          role: MessageRole.user, id: 'u4', content: '继续', taskId: 't2'));
      final built = await build(session);
      expect(built.last.content, '【任务：任务二】\n继续');
    });

    test('普通会话（无 tasks / 无 task_id）逐字不变', () async {
      final session = Session(
        id: 'n1',
        sandbox: '/tmp/s',
        createdAt: DateTime.utc(2025),
        updatedAt: DateTime.utc(2025),
        messages: [
          SessionMessage(role: MessageRole.system, content: 'sys'),
          SessionMessage(role: MessageRole.user, id: 'u1', content: 'hi'),
        ],
      );
      final built = await build(session);
      expect(built.last.content, 'hi');
    });
  });

  group('TaskItem', () {
    test('displayTitle 回落到内容首行并截断', () {
      final task = TaskItem(id: 'x', content: '  这一行将成为标题 ${'a' * 60}');
      expect(task.displayTitle.startsWith('这一行将成为标题'), isTrue);
      expect(task.displayTitle.endsWith('…'), isTrue);
      expect(task.promptText, startsWith('这一行将成为标题'));
    });

    test('无标题无内容时给出占位标题', () {
      expect(TaskItem(id: 'x').displayTitle, '(未命名任务)');
      expect(TaskItem(id: 'x').promptText, '(未命名任务)');
    });

    test('首条 user 消息只放内容（标题由出站层加锚）', () {
      final task = TaskItem(id: 'x', title: '修复登录', content: '点击登录没反应');
      expect(task.promptText, '点击登录没反应');
      expect(task.anchorTitle, '修复登录');
    });

    test('只有标题时首条消息用标题，锚也用标题', () {
      final task = TaskItem(id: 'x', title: '只看标题');
      expect(task.promptText, '只看标题');
      expect(task.anchorTitle, '只看标题');
    });

    test('无标题任务用内容首行做锚', () {
      final task = TaskItem(id: 'x', content: '只有内容');
      expect(task.promptText, '只有内容');
      expect(task.anchorTitle, '只有内容');
    });

    test('空任务没有锚', () {
      expect(TaskItem(id: 'x').anchorTitle, isNull);
    });
  });
}
