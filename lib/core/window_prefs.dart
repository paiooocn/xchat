import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../models/app_config.dart';

/// True on desktop platforms where the native window is user-resizable.
bool get isDesktopWindow =>
    !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

/// Smallest window the UI is usable at (shared with the startup WindowOptions).
const kMinimumWindowSize = Size(960, 600);

/// Applies a `宽x高` preset ([value], e.g. `'1280x960'`) to the main window.
///
/// Idempotent: safe to call any number of times. Note that on Linux a resize
/// issued before the window is mapped can be dropped by GTK/WM, so callers must
/// invoke this again on the first frame after `runApp` (see `main.dart`).
Future<void> applyWindowSize(String value) async {
  try {
    final size = parseWindowSize(value) ?? (width: 1280, height: 720);
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(kMinimumWindowSize);
    await windowManager.setSize(
      Size(size.width.toDouble(), size.height.toDouble()),
    );
    await windowManager.center();
  } catch (error) {
    // Never let window plumbing break startup / settings; surface it instead.
    debugPrint('应用窗口尺寸失败($value): $error');
  }
}
