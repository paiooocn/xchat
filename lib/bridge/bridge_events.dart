import 'dart:async';

class BridgeEvents {
  static final _controllers = <String, StreamController<Map<String, dynamic>>>{};
  static final _pendingConfirm = <String, _ConfirmWaiter>{};

  // 修复 #4 (真元凶): WebView 端的 JS 在 mount 完之前 window._xchat_dispatch 是 undefined,
  // 此时 Dart 侧的 runJavaScript 调用被 listener 自身的 && 守卫吞掉,事件被静默丢弃。
  // 对于 chat 场景,user_appended / chunk / done / error 这些事件如果在 JS ready 前
  // 全部丢失,前端永远 setRunning(false) 不了 → 输入框永久 disabled。
  // 解决:WebViewHost 在 _subscribeEvents 中先注册 listener,然后立即把 controller
  // 的 stream 缓存到 _eventLog;WebView 端 JS 在 mount 完调用 window.xchat.notifyReady()
  // 经由 chat.ready 桥接方法,通知 Dart 把累积的事件 flush 给 JS。
  static final _eventLog = <Map<String, dynamic>>[]; // 每个事件一个 payload
  static final _eventNames = <String>[];
  static bool _ready = false;

  static Stream<Map<String, dynamic>> on(String event) {
    return _controllers.putIfAbsent(event, () => StreamController.broadcast()).stream;
  }

  static void emit(String event, Map<String, dynamic> payload) {
    final c = _controllers[event];
    if (_ready) {
      if (c != null && !c.isClosed) c.add(payload);
    } else {
      // ready 前:既写入 controller(给 Dart 内其他 listener)又入缓冲队列
      // 供 WebView ready 后 flush。Stream 的 buffered 版本会把已发的旧数据
      // 转发给新订阅者,但这里监听者在 emit 前已订阅,所以额外写缓冲。
      _eventNames.add(event);
      _eventLog.add(Map<String, dynamic>.from(payload));
      if (c != null && !c.isClosed) c.add(payload);
    }
  }

  /// WebView 端 JS mount 完成后回调,把 ready 之前缓冲的事件一次性发出。
  static List<Map<String, dynamic>> drainPending() {
    final out = <Map<String, dynamic>>[];
    for (int i = 0; i < _eventLog.length; i++) {
      out.add({'event': _eventNames[i], 'payload': _eventLog[i]});
    }
    _eventLog.clear();
    _eventNames.clear();
    _ready = true;
    return out;
  }

  static bool get isReady => _ready;
  static int get pendingCount => _eventLog.length;

  static Future<Map<String, dynamic>> waitForConfirm(String sessionId, String callId) {
    final key = '$sessionId:$callId';
    final waiter = _ConfirmWaiter();
    _pendingConfirm[key] = waiter;
    return waiter.future;
  }

  static void resolveConfirm(String sessionId, String callId, Map<String, dynamic> decision) {
    final key = '$sessionId:$callId';
    final w = _pendingConfirm.remove(key);
    w?.complete(decision);
  }

  static void cancelPendingConfirms() {
    for (final w in _pendingConfirm.values) {
      w.complete({'allow': false, 'reason': 'cancelled'});
    }
    _pendingConfirm.clear();
  }
}

class _ConfirmWaiter {
  final Completer<Map<String, dynamic>> _c = Completer();
  Future<Map<String, dynamic>> get future => _c.future;
  void complete(Map<String, dynamic> v) {
    if (!_c.isCompleted) _c.complete(v);
  }
}
