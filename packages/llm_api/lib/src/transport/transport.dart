/// HTTP abstraction so the library is not tied to `dart:io`.
library;

import 'dart:async';
import 'dart:convert';

import 'cancel_token.dart';

/// An outgoing HTTP request.
class TransportRequest {
  TransportRequest({
    required this.uri,
    this.method = 'POST',
    Map<String, String>? headers,
    Map<String, Object?>? jsonBody,
    this.connectTimeout,
    this.idleTimeout,
  })  : headers = headers ?? <String, String>{},
        jsonBody = jsonBody;

  final Uri uri;
  final String method;
  final Map<String, String> headers;

  /// Body to be JSON-encoded; `null` for GET-ish requests.
  final Map<String, Object?>? jsonBody;

  /// Time allowed to establish the connection.
  final Duration? connectTimeout;

  /// Max silence between two body chunks (streaming watchdog).
  final Duration? idleTimeout;

  /// Pretty view for error messages and tests.
  Map<String, Object?> toDebugJson() => {
        'method': method,
        'uri': uri.toString(),
        'headers': headers.map((key, value) =>
            MapEntry(key, _isSecret(key) ? '***' : value)),
        if (jsonBody != null) 'body': jsonBody,
      };

  static bool _isSecret(String header) {
    final lowered = header.toLowerCase();
    return lowered.contains('authorization') ||
        lowered.contains('api-key') ||
        lowered.contains('x-goog-api-key');
  }
}

/// An incoming HTTP response.
class TransportResponse {
  TransportResponse({
    required this.statusCode,
    required this.byteStream,
    Map<String, List<String>>? headers,
    this.uri,
    this.reasonPhrase = '',
  }) : headers = headers ?? <String, List<String>>{};

  /// 200-style response carrying an SSE body.
  factory TransportResponse.sse(
    Stream<List<int>> byteStream, {
    int statusCode = 200,
    Uri? uri,
    Map<String, List<String>>? headers,
  }) =>
      TransportResponse(
        statusCode: statusCode,
        byteStream: byteStream,
        headers: headers ?? <String, List<String>>{'content-type': <String>['text/event-stream']},
        uri: uri,
      );

  /// JSON response built from text (tests, or non-streaming calls).
  factory TransportResponse.json(
    Object? payload, {
    int statusCode = 200,
    Uri? uri,
    Map<String, List<String>>? headers,
  }) =>
      TransportResponse(
        statusCode: statusCode,
        byteStream: Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
        headers: headers ?? <String, List<String>>{'content-type': <String>['application/json']},
        uri: uri,
      );

  /// Plain text response (used for error bodies in tests).
  factory TransportResponse.text(
    String body, {
    int statusCode = 200,
    Uri? uri,
    Map<String, List<String>>? headers,
  }) =>
      TransportResponse(
        statusCode: statusCode,
        byteStream: Stream<List<int>>.value(utf8.encode(body)),
        headers: headers ?? <String, List<String>>{'content-type': <String>['text/plain']},
        uri: uri,
      );

  final int statusCode;
  final String reasonPhrase;
  final Stream<List<int>> byteStream;
  final Map<String, List<String>> headers;
  final Uri? uri;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Flattened headers (last value wins).
  Map<String, String> get flatHeaders => <String, String>{
        for (final entry in headers.entries)
          entry.key.toLowerCase(): entry.value.isEmpty ? '' : entry.value.last,
      };

  /// Drains the body as text. Required before retrying: it releases the socket.
  Future<String> readAsString() async {
    final bytes = await byteStream.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// Pluggable HTTP client.
///
/// The default implementation is `IoHttpTransport` (`dart:io`). Provide your own
/// to run on Flutter web (`package:http` / XHR), to add mTLS, to route through a
/// proxy, or to return canned responses in tests (`MockHttpTransport`).
abstract class HttpTransport {
  Future<TransportResponse> send(TransportRequest request, {CancelToken? cancel});

  /// Releases pooled connections.
  void close({bool force = false}) {}
}
