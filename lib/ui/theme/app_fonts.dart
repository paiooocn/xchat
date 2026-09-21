/// Central font configuration.
///
/// Fonts are bundled as assets (see the `fonts:` section in `pubspec.yaml`)
/// so text renders identically on every platform (Android / iOS / macOS /
/// Windows / Linux) instead of falling back to each system's default CJK font.
abstract final class AppFonts {
  const AppFonts._();

  /// UI / body font — Noto Sans SC (思源黑体简体, SIL OFL-1.1).
  static const String sans = 'NotoSansSC';

  /// Monospace font — JetBrains Mono (SIL OFL-1.1), for code & editors.
  static const String mono = 'JetBrainsMono';

  /// Fallback chain for the monospace font: JetBrains Mono carries no CJK
  /// glyphs, so Chinese characters fall back to Noto Sans SC.
  static const List<String> monoFallback = <String>[sans];
}
