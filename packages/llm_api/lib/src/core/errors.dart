/// Error hierarchy for `llm_api`.
library;

import 'dart:convert';

/// Base class of every error thrown by this package.
class LlmApiException implements Exception {
  LlmApiException(
    this.message, {
    this.statusCode,
    this.body,
    this.uri,
    this.retryable = false,
    this.cause,
  });

  /// Human readable description.
  final String message;

  /// HTTP status code, when the failure came from a response.
  final int? statusCode;

  /// Raw response body (truncated in [toString]).
  final String? body;

  /// Endpoint that failed.
  final Uri? uri;

  /// Whether retrying the same request could plausibly succeed.
  final bool retryable;

  /// Underlying error, if any.
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer(runtimeType.toString())
      ..write(': ')
      ..write(message);
    if (statusCode != null) buffer.write(' [HTTP $statusCode]');
    if (uri != null) buffer.write(' ($uri)');
    if (cause != null) buffer.write('\n  caused by: $cause');
    final snippet = body;
    if (snippet != null && snippet.isNotEmpty) {
      final cut = snippet.length > 600 ? '${snippet.substring(0, 600)}…' : snippet;
      buffer.write('\n  body: $cut');
    }
    return buffer.toString();
  }
}

/// 401/403 — bad or missing credentials.
class AuthenticationException extends LlmApiException {
  AuthenticationException(
    String message, {
    int? statusCode,
    String? body,
    Uri? uri,
    Object? cause,
  }) : super(
          message,
          statusCode: statusCode,
          body: body,
          uri: uri,
          cause: cause,
          retryable: false,
        );
}

/// 404 — model/endpoint does not exist.
class ModelNotFoundException extends LlmApiException {
  ModelNotFoundException(
    String message, {
    int? statusCode,
    String? body,
    Uri? uri,
    Object? cause,
  }) : super(
          message,
          statusCode: statusCode,
          body: body,
          uri: uri,
          cause: cause,
          retryable: false,
        );
}

/// 429 — rate limited or out of quota. [retryAfter] comes from `Retry-After`.
class RateLimitException extends LlmApiException {
  RateLimitException(
    String message, {
    int? statusCode,
    String? body,
    Uri? uri,
    Object? cause,
    this.retryAfter,
  }) : super(
          message,
          statusCode: statusCode,
          body: body,
          uri: uri,
          cause: cause,
          retryable: true,
        );

  final Duration? retryAfter;
}

/// The prompt + expected completion no longer fit in the context window.
///
/// Typically thrown as HTTP 400 with a message mentioning `context length`,
/// `too many tokens`, `maximum context`, …
class ContextLengthException extends LlmApiException {
  ContextLengthException(
    String message, {
    int? statusCode,
    String? body,
    Uri? uri,
    Object? cause,
  }) : super(
          message,
          statusCode: statusCode,
          body: body,
          uri: uri,
          cause: cause,
          retryable: false,
        );
}

/// 408/409/5xx and socket level failures.
class TransportException extends LlmApiException {
  TransportException(
    String message, {
    int? statusCode,
    String? body,
    Uri? uri,
    Object? cause,
    bool retryable = true,
  }) : super(
          message,
          statusCode: statusCode,
          body: body,
          uri: uri,
          cause: cause,
          retryable: retryable,
        );
}

/// The response was well-formed HTTP but did not look like the provider's API.
class ProtocolException extends LlmApiException {
  ProtocolException(
    String message, {
    String? body,
    Uri? uri,
    Object? cause,
  }) : super(message, body: body, uri: uri, cause: cause, retryable: false);
}

/// The caller cancelled the request through a `CancelToken`.
class RequestCancelledException extends LlmApiException {
  RequestCancelledException([String? message])
      : super(message ?? 'Request cancelled', retryable: false);
}

/// Maps an HTTP status + body onto the right exception type.
LlmApiException mapHttpError({
  required int statusCode,
  required String body,
  required Uri uri,
  Map<String, String>? headers,
}) {
  final details = _extractErrorMessage(body);
  final message = details ?? 'HTTP $statusCode';
  final lowered = (details ?? body).toLowerCase();

  if (statusCode == 401 || statusCode == 403) {
    return AuthenticationException(message, statusCode: statusCode, body: body, uri: uri);
  }
  if (statusCode == 429) {
    return RateLimitException(
      message,
      statusCode: statusCode,
      body: body,
      uri: uri,
      retryAfter: _parseRetryAfter(headers),
    );
  }
  if (statusCode == 404 ||
      (statusCode == 400 && lowered.contains('model') && lowered.contains('not found'))) {
    return ModelNotFoundException(message, statusCode: statusCode, body: body, uri: uri);
  }
  if (statusCode == 400 || statusCode == 413 || statusCode == 422) {
    if (_looksLikeContextOverflow(lowered)) {
      return ContextLengthException(message, statusCode: statusCode, body: body, uri: uri);
    }
    return LlmApiException(message, statusCode: statusCode, body: body, uri: uri);
  }
  return TransportException(
    message,
    statusCode: statusCode,
    body: body,
    uri: uri,
    retryable: statusCode >= 500 || statusCode == 408 || statusCode == 409,
  );
}

bool _looksLikeContextOverflow(String lowered) {
  const needles = [
    'context length',
    'context_length',
    'maximum context',
    'context window',
    'too many tokens',
    'reduce the length',
    'prompt is too long',
    'input is too long',
    'exceeds the maximum',
  ];
  return needles.any(lowered.contains);
}

/// Extracts `error.message` / `message` / `detail` out of an error body.
String? _extractErrorMessage(String body) {
  if (body.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map) {
        final message = error['message'];
        if (message is String && message.isNotEmpty) return message;
        // OpenRouter / Anthropic style: {"error": {"message": …}} handled above,
        // Gemini style: {"error": {"message": …, "status": …}} too.
      }
      for (final key in const ['message', 'detail', 'error_description', 'msg']) {
        final value = decoded[key];
        if (value is String && value.isNotEmpty) return value;
      }
    }
  } on FormatException {
    // fall through to the raw body
  }
  final trimmed = body.trim();
  if (trimmed.length > 400) return trimmed.substring(0, 400);
  return trimmed;
}

Duration? _parseRetryAfter(Map<String, String>? headers) {
  if (headers == null) return null;
  final raw = headers['retry-after'] ?? headers['Retry-After'] ?? headers['x-ratelimit-reset-requests'];
  if (raw == null) return null;
  final seconds = int.tryParse(raw.trim());
  if (seconds != null) return Duration(seconds: seconds);
  final millis = double.tryParse(raw.trim());
  if (millis != null) return Duration(milliseconds: millis.round());
  try {
    return DateTime.parse(raw).difference(DateTime.now());
  } on FormatException {
    return null;
  }
}
