import 'package:flutter/material.dart';

/// The theme widget tests run with.
///
/// **Why not the default theme?**
///
/// Material 3's default ink animation on android is `InkSparkle`, and it
/// loads the runtime shader `shaders/ink_sparkle.frag` when it paints. The
/// **test** asset bundle compiles that shader for the Vulkan runtime stage
/// only (`flutter_tools/lib/src/build_system/tools/shader_compiler.dart`:
/// `TargetPlatform.tester → --sksl --runtime-stage-vulkan`), while
/// `flutter_tester` renders with the SkSL backend — so the engine throws
///
/// ```text
/// Asset 'shaders/ink_sparkle.frag' does not contain appropriate runtime
/// stage data for current backend (SkSL). Found stages: Vulkan
/// ```
///
/// and every test that paints an ink splash (a plain `tester.tap` is enough)
/// fails.
///
/// `InkRipple` needs no runtime shader, so tests use it. The shipped app is
/// unaffected: on a device the shader is compiled for that platform's stages
/// and `InkSparkle` loads fine.
///
/// This mirrors the default `MaterialApp` theme (`ThemeData()`) — only the
/// ink animation differs.
ThemeData testTheme() =>
    ThemeData().copyWith(splashFactory: InkRipple.splashFactory);
