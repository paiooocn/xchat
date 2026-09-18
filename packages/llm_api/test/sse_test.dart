import 'dart:convert';

import 'package:llm_api/llm_api.dart';
import 'package:llm_api/llm_api_testing.dart';
import 'package:test/test.dart';

Future<List<SseEvent>> decode(String raw, {int fragmentSize = 1}) async {
  final bytes = utf8.encode(raw);
  final chunks = <List<int>>[];
  for (var start = 0; start < bytes.length; start += fragmentSize) {
    final end = start + fragmentSize > bytes.length ? bytes.length : start + fragmentSize;
    chunks.add(bytes.sublist(start, end));
  }
  return decodeSse(Stream<List<int>>.fromIterable(chunks)).toList();
}

void main() {
  group('decodeSse', () {
    test('parses a simple frame', () async {
      final events = await decode('data: {"a":1}\n\n');
      expect(events, hasLength(1));
      expect(events.single.data, '{"a":1}');
      expect(events.single.event, isNull);
    });

    test('joins multiple data lines with a newline', () async {
      final events = await decode('data: line1\ndata: line2\n\n');
      expect(events.single.data, 'line1\nline2');
    });

    test('reads the event/id/retry fields', () async {
      final events = await decode('event: ping\nid: 42\nretry: 1500\ndata: x\n\n');
      expect(events.single.event, 'ping');
      expect(events.single.id, '42');
      expect(events.single.retry, const Duration(milliseconds: 1500));
      expect(events.single.data, 'x');
    });

    test('skips comments and tolerates a missing space', () async {
      final events = await decode(': keep-alive\ndata:no-space\n\n');
      expect(events, hasLength(1));
      expect(events.single.data, 'no-space');
    });

    test('handles CRLF line endings', () async {
      final events = await decode('event: message\r\ndata: {"a":1}\r\n\r\ndata: {"b":2}\r\n\r\n');
      expect(events.map((e) => e.data), <String>['{"a":1}', '{"b":2}']);
    });

    test('emits a trailing frame that is never blank-line terminated', () async {
      final events = await decode('data: {"a":1}\n\ndata: {"b":2}');
      expect(events.map((e) => e.data), <String>['{"a":1}', '{"b":2}']);
    });

    test('survives UTF-8 sequences split across chunks', () async {
      final events = await decode('data: {"text":"你好世界"}\n\n', fragmentSize: 1);
      expect(jsonDecode(events.single.data), <String, Object?>{'text': '你好世界'});
    });

    test('flags the DONE sentinel', () async {
      final events = await decode('data: [DONE]\n\n');
      expect(events.single.isDone, isTrue);
    });

    test('passes empty data through untouched', () async {
      final events = await decode('data:\n\n');
      expect(events.single.data, '');
    });
  });

  group('sseBytes helper', () {
    test('splits the body into fragments and terminates with [DONE]', () async {
      final chunks = await sseBytes(<Object?>[
        <String, Object?>{'a': 1},
      ], fragmentSize: 5).toList();
      final text = utf8.decode(chunks.expand((c) => c).toList());
      expect(text, 'data: {"a":1}\n\ndata: [DONE]\n\n');
      expect(chunks.length, greaterThan(1));
    });

    test('supports raw frames', () async {
      final chunks = await sseBytes(<Object?>[
        const RawSse('event: message_start\ndata: {"type":"message_start"}'),
      ], sendDone: false).toList();
      final text = utf8.decode(chunks.expand((c) => c).toList());
      final events = await decodeSse(Stream<List<int>>.value(utf8.encode(text))).toList();
      expect(events.single.event, 'message_start');
      expect(events.single.data, '{"type":"message_start"}');
    });
  });
}
