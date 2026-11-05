import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llm_api/llm_api.dart' as llm;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xchat/core/app_paths.dart';
import 'package:xchat/data/index_repository.dart';
import 'package:xchat/data/session_repository.dart';
import 'package:xchat/data/xml/session_xml.dart';
import 'package:xchat/llm/outbound_adapter.dart';
import 'package:xchat/models/app_config.dart';
import 'package:xchat/models/message_attachment.dart';
import 'package:xchat/models/provider_config.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_message.dart';
import 'package:xchat/models/task_item.dart';
import 'package:xchat/session/session_controller.dart';
import 'package:xchat/session/session_ops.dart';

final _provider = ProviderConfig(id: 'p', baseUrl: 'https://example.com/v1');

/// 一条带标注的任务（`tasks/t1` 的标题为「任务一」）。
Session _taskSession() => Session(
      id: 'ts1',
      sandbox: '/tmp/s',
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025),
      kind: SessionKind.task,
      tasks: [TaskItem(id: 't1', title: '任务一', content: '做第一件事')],
      messages: [
        SessionMessage(role: MessageRole.system, content: 'sys'),
        SessionMessage(
          role: MessageRole.user,
          id: 'u1',
          content: '做第一件事',
          taskId: 't1',
          premark: '【任务：任务一】',
        ),
      ],
    );

SessionMessage _firstUser(Session session) =>
    session.messages.firstWhere((m) => m.role == MessageRole.user);

Future<List<llm.ChatMessage>> _build(Session session) =>
    buildChatMessages(session, provider: _provider);

Future<SessionController> _controller(Session session) async {
  final tmp = Directory.systemTemp.createTempSync('xchat_premark');
  final paths = await AppPaths.init(overrideRoot: tmp.path);
  final controller = SessionController(
    repository: SessionRepository(paths, IndexRepository(paths)),
    config: AppConfig(),
    providerResolver: (id) => _provider,
  );
  controller.open(session);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('TaskItem.premark', () {
    test('有标题 → 【任务：标题】；无标题 → 首行内容；全空 → null', () {
      expect(TaskItem(id: 't', title: '一', content: '正文').premark, '【任务：一】');
      expect(TaskItem(id: 't', content: '第一行\n第二行').premark, '【任务：第一行】');
      expect(TaskItem(id: 't').premark, isNull);
    });
  });

  group('XML 往返', () {
    test('premark 写成 <user><premark>，读回逐字相同', () {
      final xml = SessionXml.encode(_taskSession());
      expect(xml.contains('<premark><![CDATA[【任务：任务一】]]></premark>'), isTrue);
      // 标注写在 <content> 之前（同一 <user> 元素内）。
      final userBlock = xml.substring(xml.indexOf('<user '), xml.indexOf('</user>'));
      expect(userBlock.indexOf('<premark>'), lessThan(userBlock.indexOf('<content>')));

      final decoded = SessionXml.decode(xml, filePath: '/tmp/sessions/ts1.xml');
      expect(_firstUser(decoded).premark, '【任务：任务一】');
      expect(_firstUser(decoded).content, '做第一件事');
    });

    test('多行 / 含 ]]> 的标注也能往返', () {
      final session = _taskSession();
      _firstUser(session).premark = '【任务：一】\n第二行 ]]> 尾巴';
      final decoded = SessionXml.decode(
        SessionXml.encode(session),
        filePath: '/tmp/sessions/ts1.xml',
      );
      expect(_firstUser(decoded).premark, '【任务：一】\n第二行 ]]> 尾巴');
    });

    test('没有 premark 的 user 不写 <premark>（旧文件字节不变）', () {
      final session = _taskSession();
      _firstUser(session).premark = null;
      final xml = SessionXml.encode(session);
      expect(xml.contains('<premark'), isFalse);
      expect(
        _firstUser(SessionXml.decode(xml, filePath: '/tmp/sessions/ts1.xml'))
            .premark,
        isNull,
      );
    });
  });

  group('出站', () {
    test('标注插在正文前一行', () async {
      final built = await _build(_taskSession());
      expect(built.last.content, '【任务：任务一】\n做第一件事');
    });

    test('写入时冻结：任务改名后历史消息仍用旧标注', () async {
      final session = _taskSession();
      session.tasks.first.title = '改过的名字';
      expect((await _build(session)).last.content, '【任务：任务一】\n做第一件事');
    });

    test('任务项被删掉 → 落盘的标注也不再发（归属校验）', () async {
      final session = _taskSession();
      session.tasks.clear();
      expect((await _build(session)).last.content, '做第一件事');
    });

    test('正文为空的消息不单独发一行标注', () async {
      final session = _taskSession();
      _firstUser(session).content = '';
      expect((await _build(session)).last.content, '');
    });

    test('旧存档没有 premark → 按 task_id 反查标题（只读，不回写）', () async {
      final session = _taskSession();
      _firstUser(session).premark = null;
      expect((await _build(session)).last.content, '【任务：任务一】\n做第一件事');
      expect(_firstUser(session).premark, isNull);
    });

    test('带附件时标注是第一个 text part', () async {
      final session = _taskSession();
      session.messages.add(SessionMessage(
        role: MessageRole.user,
        id: 'u2',
        taskId: 't1',
        premark: '【任务：任务一】',
        content: '看这张图',
        attachments: [
          // 不存在的文件 → 图片载入失败，但标注（text part）仍应在最前。
          MessageAttachment(
              mimeType: 'image/png', name: 'x.png', path: '/nope/x.png'),
        ],
      ));
      final parts = (await _build(session)).last.parts!;
      expect(parts.first, isA<llm.TextPart>());
      expect((parts.first as llm.TextPart).text, '【任务：任务一】\n');
    });

    test('普通会话（无 task）逐字不变', () async {
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
      expect((await _build(session)).last.content, 'hi');
    });
  });

  group('删除', () {
    test('删掉 user 消息 → XML 里连 <premark> 一起消失', () {
      final session = _taskSession();
      SessionOps.deleteMessage(
        session,
        session.messages.indexWhere((m) => m.role == MessageRole.user),
      );
      final xml = SessionXml.encode(session);
      expect(xml.contains('<premark'), isFalse);
      expect(xml.contains('<user'), isFalse);
      // 任务项本身还在（内容里的「做第一件事」来自 <task><content>）。
      expect(xml.contains('做第一件事'), isTrue);
    });

    test('删掉任务项 → 它的对话与 <premark> 一并删除', () {
      final session = _taskSession();
      session.removeTask('t1');
      final xml = SessionXml.encode(session);
      expect(xml.contains('<premark'), isFalse);
      expect(xml.contains('<user'), isFalse);
      expect(xml.contains('做第一件事'), isFalse);
    });
  });

  group('写入点', () {
    test('seedTaskMessage 的首条消息带标注，正文不含标题', () async {
      final session = _taskSession();
      session.messages.removeWhere((m) => m.role == MessageRole.user);
      final controller = await _controller(session);

      expect(await controller.seedTaskMessage(session.tasks.first), isTrue);
      final message = session.taskMessages('t1').single;
      expect(message.content, '做第一件事');
      expect(message.premark, '【任务：任务一】');
      // 落盘后读回仍带标注。
      final reloaded = SessionXml.decode(
        SessionXml.encode(session),
        filePath: '/tmp/sessions/ts1.xml',
      );
      expect(_firstUser(reloaded).premark, '【任务：任务一】');
    });
  });
}
