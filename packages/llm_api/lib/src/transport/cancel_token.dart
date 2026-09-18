/// Cooperative cancellation shared by every provider call.
library;

import 'dart:async';

import '../core/errors.dart';

/// A one-shot cancel signal.
///
/// Pass the same token to a whole turn (including all tool rounds) to make
/// "stop generating" instant: it aborts the in-flight HTTP request rather than
/// merely ignoring the rest of the stream.
class CancelToken {
  CancelToken();

  /// A token that also cancels when [parent] does.
  factory CancelToken.link(CancelToken? parent) {
    final token = CancelToken();
    if (parent != null) {
      if (parent.isCancelled) {
        token.cancel(parent.reason);
      } else {
        parent.whenCancelled.then((_) => token.cancel(parent.reason));
      }
    }
    return token;
  }

  final Completer<void> _completer = Completer<void>();
  Object? _reason;

  bool get isCancelled => _completer.isCompleted;

  Object? get reason => _reason;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _completer.future;

  void cancel([Object? reason]) {
    if (_completer.isCompleted) return;
    _reason = reason;
    _completer.complete();
  }

  /// Throws [RequestCancelledException] if already cancelled.
  void throwIfCancelled() {
    if (isCancelled) {
      throw RequestCancelledException(reason?.toString());
    }
  }
}
