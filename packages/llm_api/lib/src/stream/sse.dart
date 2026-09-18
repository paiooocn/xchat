/// Server-Sent Events decoder.
library;

import 'dart:async';
import 'dart:convert';

/// One decoded SSE frame.
class SseEvent {
  const SseEvent({this.event, this.id, this.retry, this.data = ''});

  /// Value of the `event:` field, when present.
  final String? event;

  /// Value of the `id:` field.
  final String? id;

  /// Value of the `retry:` field.
  final Duration? retry;

  /// `data:` lines joined with `\n`.
  final String data;

  bool get isDone => data.trim() == '[DONE]';

  @override
  String toString() => 'SseEvent(${event ?? 'message'}, ${data.length} chars)';
}

/// Turns a raw byte stream into [SseEvent]s.
///
/// Handles everything real gateways throw at it: `\n` and `\r\n` line endings,
/// multi-line `data:` payloads, comment lines (`: keep-alive`), fields without a
/// space after the colon, UTF-8 sequences split across chunk boundaries, and a
/// final frame that is never terminated by a blank line.
Stream<SseEvent> decodeSse(Stream<List<int>> bytes) async* {
  String? eventName;
  String? eventId;
  Duration? retry;
  final data = <String>[];
  var buffer = '';

  void reset() {
    eventName = null;
    eventId = null;
    retry = null;
    data.clear();
  }

  SseEvent? take() {
    if (data.isEmpty && eventName == null && eventId == null && retry == null) return null;
    final event = SseEvent(
      event: eventName,
      id: eventId,
      retry: retry,
      data: data.join('\n'),
    );
    reset();
    return event;
  }

  final pending = <SseEvent>[];

  void handleLine(String line) {
    if (line.isEmpty) {
      final event = take();
      if (event != null) pending.add(event);
      return;
    }
    if (line.startsWith(':')) return; // comment / heartbeat
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        data.add(value);
      case 'event':
        eventName = value;
      case 'id':
        eventId = value;
      case 'retry':
        final millis = int.tryParse(value);
        if (millis != null) retry = Duration(milliseconds: millis);
    }
  }

  await for (final chunk in bytes.transform(const Utf8Decoder(allowMalformed: true))) {
    buffer += chunk;
    var start = 0;
    while (true) {
      final newline = buffer.indexOf('\n', start);
      if (newline < 0) break;
      var line = buffer.substring(start, newline);
      start = newline + 1;
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      handleLine(line);
      for (final event in pending) {
        yield event;
      }
      pending.clear();
    }
    if (start > 0) buffer = buffer.substring(start);
  }

  if (buffer.isNotEmpty) {
    var line = buffer;
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    handleLine(line);
  }
  final last = take();
  if (last != null) pending.add(last);
  for (final event in pending) {
    yield event;
  }
}
