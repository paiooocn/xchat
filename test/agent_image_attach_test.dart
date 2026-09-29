import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llm_api/llm_api.dart' as llm;
import 'package:xchat/agent/tools/image_attach.dart';
import 'package:xchat/agent/tools/path_guard.dart';
import 'package:xchat/llm/outbound_adapter.dart';
import 'package:xchat/models/app_config.dart';
import 'package:xchat/models/message_attachment.dart';
import 'package:xchat/models/provider_config.dart';
import 'package:xchat/models/session.dart';
import 'package:xchat/models/session_message.dart';
import 'package:xchat/models/session_params.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('xchat-attach');
  });

  tearDown(() async {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  File write(String name, List<int> bytes) {
    final file = File('${sandbox.path}/$name')..writeAsBytesSync(bytes);
    return file;
  }

  group('resolveAttachableImage', () {
    test('accepts a sandbox image under the cap', () async {
      final file = write('shot.png', [1, 2, 3, 4]);
      final result = await resolveAttachableImage(
        guard: PathGuard(sandbox.path),
        maxBytes: 1024,
        rawPath: 'shot.png',
      );
      expect(result.ok, isTrue);
      expect(result.attachment!.mimeType, 'image/png');
      expect(File(result.attachment!.path!).existsSync(), isTrue);
      expect(file.path, contains(sandbox.path));
    });

    test('refuses a path outside the sandbox', () async {
      final result = await resolveAttachableImage(
        guard: PathGuard(sandbox.path),
        maxBytes: 1024,
        rawPath: '../escape.png',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('沙箱'));
    });

    test('refuses an unsupported type and a missing file', () async {
      write('notes.txt', [1]);
      final bad = await resolveAttachableImage(
        guard: PathGuard(sandbox.path),
        maxBytes: 1024,
        rawPath: 'notes.txt',
      );
      expect(bad.ok, isFalse);
      expect(bad.error, contains('不支持'));

      final missing = await resolveAttachableImage(
        guard: PathGuard(sandbox.path),
        maxBytes: 1024,
        rawPath: 'nope.png',
      );
      expect(missing.ok, isFalse);
      expect(missing.error, contains('不存在'));
    });

    test('refuses an oversized image and names the cap', () async {
      write('big.png', List<int>.filled(4096, 7));
      final result = await resolveAttachableImage(
        guard: PathGuard(sandbox.path),
        maxBytes: 1024,
        rawPath: 'big.png',
      );
      expect(result.ok, isFalse);
      expect(result.sizeBytes, 4096);
      expect(result.error, contains('超过上限'));
    });

    test('maxBytes 0 disables the cap', () async {
      write('big.png', List<int>.filled(4096, 7));
      final result = await resolveAttachableImage(
        guard: PathGuard(sandbox.path),
        maxBytes: 0,
        rawPath: 'big.png',
      );
      expect(result.ok, isTrue);
    });
  });

  group('buildChatMessages with tool-produced images', () {
    Session sessionWith(List<SessionMessage> messages) => Session(
          id: 's1',
          sandbox: sandbox.path,
          createdAt: DateTime.utc(2025, 1, 15),
          updatedAt: DateTime.utc(2025, 1, 15),
          params: SessionParams(),
          messages: messages,
        );

    final provider = ProviderConfig(id: 'p', baseUrl: 'https://example.com/v1');

    test('an image on a tool message rides out as a following user turn',
        () async {
      final file = write('shot.png', [1, 2, 3]);
      final session = sessionWith([
        SessionMessage(
          role: MessageRole.assistant,
          id: 'm1',
          toolCalls: [ToolCallData(id: 'c1', name: 'shell', arguments: '{}')],
        ),
        SessionMessage(
          role: MessageRole.tool,
          id: 'm2',
          toolCallId: 'c1',
          toolName: 'shell',
          content: 'OK: 已附加图片 shot.png',
          attachments: [
            MessageAttachment(mimeType: 'image/png', name: 'shot.png', path: file.path),
          ],
        ),
      ]);

      final built = await buildChatMessages(session, provider: provider);
      expect(built, hasLength(3));
      expect(built[0].role, llm.ChatRole.assistant);
      expect(built[1].role, llm.ChatRole.tool);
      expect(built[1].content, contains('已附加图片'));
      // The tool message itself stays text-only (OpenAI-compatible constraint).
      expect(built[1].parts, isNull);
      expect(built[2].role, llm.ChatRole.user);
      expect(built[2].parts, hasLength(1));
      expect(built[2].parts!.single, isA<llm.ImagePart>());
    });

    test('a plain tool result stays a single message', () async {
      final session = sessionWith([
        SessionMessage(
          role: MessageRole.tool,
          id: 'm1',
          toolCallId: 'c1',
          toolName: 'read_file',
          content: 'hello',
        ),
      ]);
      final built = await buildChatMessages(session, provider: provider);
      expect(built, hasLength(1));
      expect(built.single.role, llm.ChatRole.tool);
    });

    test('a user turn with an image is unchanged (one message, text last)',
        () async {
      final file = write('a.png', [1, 2, 3]);
      final session = sessionWith([
        SessionMessage(
          role: MessageRole.user,
          id: 'm1',
          content: '这是什么',
          attachments: [
            MessageAttachment(mimeType: 'image/png', name: 'a.png', path: file.path),
          ],
        ),
      ]);
      final built = await buildChatMessages(session, provider: provider);
      expect(built, hasLength(1));
      expect(built.single.parts, hasLength(2));
      expect(built.single.parts!.first, isA<llm.ImagePart>());
      expect(built.single.parts!.last, isA<llm.TextPart>());
    });
  });

  group('AppConfig.maxAttachmentBytes', () {
    test('defaults to 5MB and round-trips', () {
      final config = AppConfig();
      expect(config.maxAttachmentBytes, 5 * 1024 * 1024);

      final restored = AppConfig.fromJson(config.toJson());
      expect(restored.maxAttachmentBytes, 5 * 1024 * 1024);
    });

    test('clamps absurd values', () {
      final config = AppConfig.fromJson(
        <String, Object?>{'max_attachment_bytes': 1 << 40},
      );
      expect(config.maxAttachmentBytes, kMaxAttachmentBytesCap);
      final none = AppConfig.fromJson(<String, Object?>{'max_attachment_bytes': 0});
      expect(none.maxAttachmentBytes, 0);
    });
  });
}
