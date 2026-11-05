import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reference-counted Android **foreground service** that keeps the process out
/// of the "cached" bucket while a turn is streaming.
///
/// Android freezes or kills a backgrounded process (Doze, cached-app freezer,
/// OEM cleaners) — the SSE socket dies and the answer is cut in half. A
/// foreground service with a low-priority notification is the only supported
/// way to keep working. Started while the app is in the foreground, so
/// Android 12+'s "no background FGS start" rule does not apply.
///
/// Every call is best-effort: on desktop / iOS / tests the channel is missing
/// and the call is silently ignored, so callers never need `Platform` checks.
class KeepAlive {
  KeepAlive._();

  static const MethodChannel _channel = MethodChannel('xchat/keep_alive');

  static int _depth = 0;
  static String _text = _defaultText;

  static const _defaultText = '正在生成回答…';

  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// How many callers currently need the service (0 = not running).
  static int get depth => _depth;

  /// Marks one long-running request. Pairs with [end] in a `finally`.
  static Future<void> begin({String? text}) async {
    if (!_supported) return;
    _text = text ?? _text;
    _depth += 1;
    if (_depth > 1) return;
    try {
      await _channel.invokeMethod<void>('start', <String, Object?>{'text': _text});
    } on MissingPluginException {
      // Not wired on this platform build.
    } catch (error) {
      debugPrint('KeepAlive.begin 失败: $error');
    }
  }

  /// Releases one request; the service stops when the last one ends.
  static Future<void> end() async {
    if (!_supported) return;
    if (_depth == 0) return;
    _depth -= 1;
    if (_depth > 0) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Not wired on this platform build.
    } catch (error) {
      debugPrint('KeepAlive.end 失败: $error');
    }
  }

  /// Force-stops the service (app shutdown, tests).
  static Future<void> stopAll() async {
    _depth = 0;
    await end();
  }
}
