import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/data/xml/session_xml.dart';
import 'package:xchat/models/message_attachment.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_message.dart';
import 'package:xchat/models/session_params.dart';

void main() {
  group('MessageAttachment', () {
    test('infers mime type from the file extension', () {
      final image = MessageAttachment.fromFile('/tmp/a/shot.png')!;
      expect(image.mimeType, 'image/png');

      expect(MessageAttachment.fromFile('/tmp/a/notes.txt'), isNull);
      expect(MessageAttachment.fromFile('/tmp/a/voice.m4a'), isNull);
    });

    test('reads back bytes written to disk', () async {
      final file = File('${Directory.systemTemp.path}/xchat_attachment_test.png');
      await file.writeAsBytes([1, 2, 3, 250]);
      final attachment = MessageAttachment.fromFile(file.path)!;
      expect(await attachment.readBytes(), [1, 2, 3, 250]);
      await file.delete();
    });

    test('reports a missing file as unavailable', () {
      final attachment = MessageAttachment(
        mimeType: 'image/png',
        path: '/definitely/not/here.png',
      );
      expect(attachment.isAvailable, isFalse);
    });
  });

  group('SessionXml attachments', () {
    test('round-trips image attachments', () {
      final session = Session(
        id: 's1',
        sandbox: '/tmp/xchat/sessions',
        createdAt: DateTime.utc(2025, 1, 15),
        updatedAt: DateTime.utc(2025, 1, 15),
        params: SessionParams(),
        messages: [
          SessionMessage(
            role: MessageRole.user,
            id: 'm1',
            content: '这两段是什么',
            attachments: [
              MessageAttachment(
                mimeType: 'image/jpeg',
                name: 'a.jpg',
                path: '/tmp/xchat/sessions/attachments/m1-1.jpg',
              ),
              MessageAttachment(
                mimeType: 'image/png',
                name: 'b.png',
                path: '/tmp/xchat/sessions/attachments/m1-2.png',
              ),
            ],
          ),
        ],
      );

      final decoded = SessionXml.decode(
        SessionXml.encode(session),
        filePath: '/tmp/xchat/sessions/s1.xml',
      );
      final user = decoded.messages.firstWhere((m) => m.role == MessageRole.user);
      expect(user.content, '这两段是什么');
      expect(user.attachments, hasLength(2));
      expect(user.attachments.first.mimeType, 'image/jpeg');
      expect(user.attachments.first.name, 'a.jpg');
      expect(user.attachments.last.mimeType, 'image/png');
    });

    test('a user message without attachments stays unchanged', () {
      final session = Session(
        id: 's2',
        sandbox: '/tmp/xchat/sessions',
        createdAt: DateTime.utc(2025, 1, 15),
        updatedAt: DateTime.utc(2025, 1, 15),
        params: SessionParams(),
        messages: [SessionMessage(role: MessageRole.user, id: 'm1', content: '你好')],
      );
      final xml = SessionXml.encode(session);
      expect(xml, isNot(contains('<attachments>')));
      final decoded = SessionXml.decode(xml, filePath: '/tmp/xchat/sessions/s2.xml');
      expect(decoded.messages.firstWhere((m) => m.role == MessageRole.user).attachments, isEmpty);
    });
  });
}
