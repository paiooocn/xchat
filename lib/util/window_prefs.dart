import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:path/path.dart' as p;

import '../config/config_manager.dart';

/// 桌面窗口尺寸记忆:启动时恢复上次尺寸,窗口尺寸稳定后写盘。
/// 文件位置:`~/.xchat/window.json`,结构 `{"w":1280,"h":720}`。
class WindowPrefs {
  WindowPrefs._();
  static final WindowPrefs instance = WindowPrefs._();

  static const String _fileName = 'window.json';
  static const Size _default = Size(1280, 720);
  static const Size _minSize = Size(640, 480);

  Timer? _debounce;
  Size? _lastSaved;

  File get _file => File(p.join(ConfigManager.instance.xchatDir.path, _fileName));

  /// 启动时调用,返回上次记住的尺寸(若没有则返回默认)。
  /// 同时记录 baseline,避免 didChangeMetrics 首次回调时把默认值写回去。
  Size loadOrDefault() {
    try {
      final f = _file;
      if (!f.existsSync()) return _default;
      final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final w = (raw['w'] as num?)?.toDouble();
      final h = (raw['h'] as num?)?.toDouble();
      if (w == null || h == null) return _default;
      // 防止 0 / 负数 / 异常巨大
      final sz = Size(
        w.clamp(_minSize.width, 8192),
        h.clamp(_minSize.height, 8192),
      );
      _lastSaved = sz;
      return sz;
    } catch (_) {
      return _default;
    }
  }

  /// 尺寸变化后调用;800ms 内多次触发只写一次盘。
  /// [now] 是当前物理尺寸(由 didChangeMetrics 拿到)。
  void scheduleSave(Size now) {
    if (now.width < _minSize.width || now.height < _minSize.height) return;
    if (_lastSaved != null &&
        (_lastSaved!.width - now.width).abs() < 0.5 &&
        (_lastSaved!.height - now.height).abs() < 0.5) {
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      _writeNow(now);
    });
  }

  /// 立刻落盘(应用退出 / AppLifecycleState.detached 时调用)。
  Future<void> flush(Size now) async {
    _debounce?.cancel();
    if (now.width < _minSize.width || now.height < _minSize.height) return;
    _writeNow(now);
  }

  void _writeNow(Size sz) {
    try {
      _file.writeAsStringSync(
        jsonEncode({'w': sz.width, 'h': sz.height}),
        flush: true,
      );
      _lastSaved = sz;
    } catch (_) {
      // 写盘失败不致命,忽略。
    }
  }
}