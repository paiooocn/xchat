/// `dart:io` implementation of [HttpTransport] with connection pooling,
/// watchdog timeouts and hard cancellation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/errors.dart';
import 'activity_clock.dart';
import 'cancel_token.dart';
import 'transport.dart';

/// Default transport, backed by [HttpClient].
class IoHttpTransport implements HttpTransport {
  IoHttpTransport({
    HttpClient? client,
    this.userAgent = 'llm_api/0.1 (+dart)',
    this.clock = const AlwaysActiveClock(),
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout ??= const Duration(seconds: 20);
    _client.autoUncompress = true;
  }

  final HttpClient _client;
  final String userAgent;

  /// Decides how much of the idle budget actually elapsed — see
  /// [ActivityClock]; a mobile host passes its lifecycle-aware clock so a
  /// backgrounded app is not declared "stalled" the moment it resumes.
  final ActivityClock clock;

  bool _closed = false;

  /// Access to the underlying client (proxies, bad certificates, …).
  HttpClient get client => _client;

  @override
  Future<TransportResponse> send(TransportRequest request, {CancelToken? cancel}) async {
    if (_closed) throw StateError('IoHttpTransport has been closed');
    cancel?.throwIfCancelled();

    final HttpClientRequest httpRequest;
    try {
      final open = _client.openUrl(request.method, request.uri);
      final timedOpen = request.connectTimeout == null ? open : open.timeout(request.connectTimeout!);
      httpRequest = await timedOpen;
    } on TimeoutException catch (error) {
      throw TransportException(
        'Connection to ${request.uri.host} timed out',
        uri: request.uri,
        cause: error,
      );
    } on SocketException catch (error) {
      throw TransportException(
        'Could not connect to ${request.uri.host}: ${error.message}',
        uri: request.uri,
        cause: error,
      );
    } on HandshakeException catch (error) {
      throw TransportException(
        'TLS handshake failed for ${request.uri.host}',
        uri: request.uri,
        cause: error,
        retryable: false,
      );
    }

    // Hard cancellation: aborting the request tears down the socket, which
    // makes the response stream error out and unblocks the pipeline.
    if (cancel != null) {
      unawaited(cancel.whenCancelled.then((_) {
        try {
          httpRequest.abort(RequestCancelledException(cancel.reason?.toString()));
        } catch (_) {
          // already finished
        }
      }));
    }

    httpRequest.headers.set(HttpHeaders.userAgentHeader, userAgent);
    request.headers.forEach((name, value) {
      if (name.toLowerCase() == 'content-length') return;
      httpRequest.headers.set(name, value);
    });

    final body = request.jsonBody;
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      httpRequest.headers.contentType = ContentType.json;
      httpRequest.headers.set(HttpHeaders.contentLengthHeader, bytes.length.toString());
      httpRequest.add(bytes);
    }

    HttpClientResponse response;
    try {
      response = await httpRequest.close();
    } on SocketException catch (error) {
      if (cancel?.isCancelled ?? false) {
        throw RequestCancelledException(cancel!.reason?.toString());
      }
      throw TransportException(
        'Connection lost while sending to ${request.uri.host}: ${error.message}',
        uri: request.uri,
        cause: error,
      );
    } on HttpException catch (error) {
      if (cancel?.isCancelled ?? false) {
        throw RequestCancelledException(cancel!.reason?.toString());
      }
      throw TransportException(
        'HTTP error talking to ${request.uri.host}: ${error.message}',
        uri: request.uri,
        cause: error,
      );
    }

    Stream<List<int>> stream = response;
    if (request.idleTimeout != null) {
      stream = _withIdleWatchdog(stream, request.idleTimeout!, request.uri);
    }


    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) {
      headers[name] = values;
    });

    return TransportResponse(
      statusCode: response.statusCode,
      reasonPhrase: response.reasonPhrase,
      headers: headers,
      byteStream: stream,
      uri: request.uri,
    );
  }

  /// Errors the stream if the provider stops sending for too long — a stalled
  /// SSE connection would otherwise hang the UI forever.
  ///
  /// The budget is measured in **active** time ([clock]): a mobile OS suspends
  /// a backgrounded app, and the naive `Stream.timeout` would fire the moment
  /// it resumes with a bogus "stalled" error over a healthy socket.
  Stream<List<int>> _withIdleWatchdog(
    Stream<List<int>> source,
    Duration timeout,
    Uri uri,
  ) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    Timer? timer;
    var lastActivity = clock.now();
    var finished = false;

    void stopTimer() {
      timer?.cancel();
      timer = null;
    }

    void complete([Object? error, StackTrace? stack]) {
      if (finished) return;
      finished = true;
      stopTimer();
      if (error != null) controller.addError(error, stack);
      unawaited(controller.close());
    }

    late final void Function() arm;

    void onTimeout() {
      if (finished) return;
      // Still inside the budget (the process was frozen / the app is in the
      // background): keep waiting without counting that time.
      if (timeout - clock.activeSince(lastActivity) > Duration.zero) {
        arm();
        return;
      }
      complete(TransportException(
        'No data received for ${timeout.inSeconds}s (stream stalled)',
        uri: uri,
      ));
      unawaited(subscription?.cancel());
    }

    arm = () {
      stopTimer();
      final left = timeout - clock.activeSince(lastActivity);
      timer = Timer(left > Duration.zero ? left : Duration.zero, onTimeout);
    };

    controller = StreamController<List<int>>(
      onListen: () {
        subscription = source.listen(
          (chunk) {
            if (finished) return;
            lastActivity = clock.now();
            arm();
            controller.add(chunk);
          },
          onError: (Object error, StackTrace stack) {
            if (finished) return;
            stopTimer();
            complete(error, stack);
          },
          onDone: () => complete(),
          cancelOnError: false,
        );
        arm();
      },
      onCancel: () {
        finished = true;
        stopTimer();
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _client.close(force: force);
  }
}
