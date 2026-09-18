/// Test doubles for the transport layer.
///
/// Everything above [HttpTransport] is pure data transformation, so feeding it
/// hand-written SSE frames gives you a real end-to-end test of wire encoding,
/// streaming decode, thinking extraction and the tool loop — with no network.
///
/// ```dart
/// final transport = MockHttpTransport.sse(<Map<String, Object?>>[
///   {'choices': [{'delta': {'reasoning_content': 'let me think'}}]},
///   {'choices': [{'delta': {'content': 'hi'}}]},
/// ]);
/// final provider = OpenAICompatibleProvider(config: …, transport: transport);
/// final response = await provider.complete(request);
/// ```
library;

import 'dart:async';
import 'dart:convert';

import '../transport/cancel_token.dart';
import '../transport/transport.dart';

/// A frame written to the wire verbatim (multi-line `event:`/`data:` blocks,
/// comments, intentionally malformed frames).
class RawSse {
  const RawSse(this.text);

  final String text;

  @override
  String toString() => text;
}

/// Encodes [frames] as an SSE body, optionally chopped into awkward fragments
/// so the SSE decoder has to cope with split tags and split UTF-8 sequences.
Stream<List<int>> sseBytes(
  Iterable<Object?> frames, {
  bool sendDone = true,
  int? fragmentSize,
  Duration? gap,
}) async* {
  final buffer = StringBuffer();
  for (final frame in frames) {
    if (frame is RawSse) {
      buffer.write('${frame.text}\n\n');
    } else if (frame is String) {
      buffer.write('data: $frame\n\n');
    } else {
      buffer.write('data: ${jsonEncode(frame)}\n\n');
    }
  }
  if (sendDone) buffer.write('data: [DONE]\n\n');
  final encoded = utf8.encode(buffer.toString());

  if (fragmentSize == null) {
    if (gap != null) await Future<void>.delayed(gap);
    yield encoded;
    return;
  }
  for (var start = 0; start < encoded.length; start += fragmentSize) {
    final end = start + fragmentSize > encoded.length ? encoded.length : start + fragmentSize;
    if (gap != null) await Future<void>.delayed(gap);
    yield encoded.sublist(start, end);
  }
}

/// A transport that answers with canned responses and records every request.
class MockHttpTransport implements HttpTransport {
  MockHttpTransport(this.handler);

  /// Always answers with the same SSE frames.
  factory MockHttpTransport.sse(
    Iterable<Object?> frames, {
    int statusCode = 200,
    int? fragmentSize,
    Map<String, List<String>>? headers,
  }) =>
      MockHttpTransport((request) => TransportResponse(
            statusCode: statusCode,
            headers: headers ?? <String, List<String>>{'content-type': <String>['text/event-stream']},
            byteStream: sseBytes(frames, fragmentSize: fragmentSize),
            uri: request.uri,
          ));

  /// Always answers with the same JSON body.
  factory MockHttpTransport.json(Object? payload, {int statusCode = 200}) =>
      MockHttpTransport((request) => TransportResponse.json(
            payload,
            statusCode: statusCode,
            uri: request.uri,
          ));

  /// Always fails with the given status/body.
  factory MockHttpTransport.error(int statusCode, String body) =>
      MockHttpTransport((request) => TransportResponse.text(
            body,
            statusCode: statusCode,
            uri: request.uri,
          ));

  final FutureOr<TransportResponse> Function(TransportRequest request) handler;

  /// Every request seen, in order.
  final List<TransportRequest> requests = <TransportRequest>[];

  /// The most recent request (handy for asserting the wire format).
  TransportRequest? get lastRequest => requests.isEmpty ? null : requests.last;

  /// Decoded JSON body of the most recent request.
  Map<String, Object?> get lastBody {
    final body = lastRequest?.jsonBody;
    return body is Map<String, Object?> ? body : <String, Object?>{};
  }

  /// The `messages` array of the most recent request.
  List<Map<String, Object?>> get lastMessages {
    final raw = lastBody['messages'];
    if (raw is! List) return const <Map<String, Object?>>[];
    return raw.whereType<Map>().map((e) => e.cast<String, Object?>()).toList();
  }

  @override
  Future<TransportResponse> send(TransportRequest request, {CancelToken? cancel}) async {
    cancel?.throwIfCancelled();
    requests.add(request);
    return handler(request);
  }

  @override
  void close({bool force = false}) {}
}

/// Plays a different response per call — perfect for tool-call loops, where the
/// first round asks for a tool and the second round answers.
class ScriptedTransport implements HttpTransport {
  ScriptedTransport(this.scripts);

  /// Each entry is invoked for the n-th request; the last one repeats.
  final List<FutureOr<TransportResponse> Function(TransportRequest request)> scripts;

  final List<TransportRequest> requests = <TransportRequest>[];

  @override
  Future<TransportResponse> send(TransportRequest request, {CancelToken? cancel}) async {
    cancel?.throwIfCancelled();
    final index = requests.length;
    requests.add(request);
    final script = index < scripts.length ? scripts[index] : scripts.last;
    return script(request);
  }

  /// Builds a scripted SSE round.
  static FutureOr<TransportResponse> Function(TransportRequest) sse(
    Iterable<Object?> frames, {
    int statusCode = 200,
    int? fragmentSize,
  }) =>
      (request) => TransportResponse(
            statusCode: statusCode,
            headers: <String, List<String>>{'content-type': <String>['text/event-stream']},
            byteStream: sseBytes(frames, fragmentSize: fragmentSize),
            uri: request.uri,
          );

  @override
  void close({bool force = false}) {}
}
