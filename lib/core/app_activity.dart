import 'package:flutter/widgets.dart';
import 'package:llm_api/llm_api.dart' as llm;

/// App-wide lifecycle state.
///
/// Two jobs:
/// * tell the LLM transport how much **active** (foreground) time elapsed, so a
///   frozen / suspended process does not get its stream declared "stalled" the
///   moment the app comes back (see `llm.ActivityClock`);
/// * let the chat UI know the app is in the background, so it can warn that the
///   system may interrupt the running turn.
///
/// `inactive` is deliberately **not** treated as background: it also fires for
/// the notification shade, a permission dialog or an incoming call, where the
/// process keeps running normally.
class AppActivity extends ChangeNotifier
    with WidgetsBindingObserver
    implements llm.ActivityClock {
  AppActivity._();

  static final AppActivity instance = AppActivity._();

  /// Closed background spans, oldest first (bounded — see [_maxSpans]).
  final List<(DateTime from, DateTime to)> _backgroundSpans =
      <(DateTime, DateTime)>[];
  static const _maxSpans = 64;

  DateTime? _pausedAt;

  /// Whether the app is currently in the foreground.
  @override
  bool get isActive => _pausedAt == null;

  /// When the app entered the background (`null` while in the foreground).
  DateTime? get pausedAt => _pausedAt;

  /// How long the app has been in the background right now.
  Duration get backgroundFor =>
      _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);

  /// Registers the lifecycle observer. Safe to call once from `main()`.
  void attach() {
    WidgetsBinding.instance.addObserver(this);
    _pausedAt = null;
  }

  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        final paused = _pausedAt;
        _pausedAt = null;
        if (paused != null) {
          final now = DateTime.now();
          _backgroundSpans.add((paused, now));
          if (_backgroundSpans.length > _maxSpans) {
            _backgroundSpans.removeAt(0);
          }
          notifyListeners();
        }
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (_pausedAt == null) {
          _pausedAt = DateTime.now();
          notifyListeners();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  DateTime now() => DateTime.now();

  @override
  Duration activeSince(DateTime since) {
    final end = DateTime.now();
    var active = end.difference(since);
    for (final (from, to) in _backgroundSpans) {
      if (!to.isAfter(since)) continue;
      final start = from.isBefore(since) ? since : from;
      if (to.isAfter(start)) active -= to.difference(start);
    }
    final paused = _pausedAt;
    if (paused != null) {
      final start = paused.isBefore(since) ? since : paused;
      if (end.isAfter(start)) active -= end.difference(start);
    }
    return active.isNegative ? Duration.zero : active;
  }

  /// Whether any part of `since..now` was spent in the background — used to
  /// explain a failed turn ("the system interrupted it while you were away").
  bool wasBackgroundedSince(DateTime since) {
    if (_pausedAt != null && !_pausedAt!.isBefore(since)) return true;
    for (final (from, to) in _backgroundSpans) {
      if (to.isAfter(since) || (from.isBefore(since) && to.isAfter(since))) {
        return true;
      }
    }
    return false;
  }

  /// Background time accumulated inside `since..now`.
  Duration backgroundSince(DateTime since) {
    var total = Duration.zero;
    for (final (from, to) in _backgroundSpans) {
      if (!to.isAfter(since)) continue;
      final start = from.isBefore(since) ? since : from;
      if (to.isAfter(start)) total += to.difference(start);
    }
    final paused = _pausedAt;
    if (paused != null) {
      final start = paused.isBefore(since) ? since : paused;
      final end = DateTime.now();
      if (end.isAfter(start)) total += end.difference(start);
    }
    return total;
  }
}
