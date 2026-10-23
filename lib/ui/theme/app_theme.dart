import 'package:flutter/material.dart';

import 'app_fonts.dart';

/// 应用设计系统：配色 / 圆角 / 控件外观。
///
/// 目标是桌面端与移动端观感一致：低饱和中性色底 + 单一强调色，统一
/// 8/12/16/20 圆角与 1px 分隔线，控件在浅色 / 深色两套主题下只换色不换形。
abstract final class AppTheme {
  const AppTheme._();

  /// 圆角尺寸（与设计稿保持一致，避免各处随手取值）。
  static const double radiusSmall = 8;
  static const double radiusMedium = 12;
  static const double radiusLarge = 16;
  static const double radiusXLarge = 20;

  /// 侧边栏宽度（宽屏布局）。
  static const double sidebarWidth = 288;

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5B6CFF),
      brightness: brightness,
    ).copyWith(
      surface: isDark ? const Color(0xFF121317) : const Color(0xFFFFFFFF),
      surfaceContainerLowest:
          isDark ? const Color(0xFF0E0F13) : const Color(0xFFFFFFFF),
      surfaceContainerLow:
          isDark ? const Color(0xFF17181D) : const Color(0xFFF7F8FA),
      surfaceContainer:
          isDark ? const Color(0xFF1D1F25) : const Color(0xFFF1F2F6),
      surfaceContainerHigh:
          isDark ? const Color(0xFF24262E) : const Color(0xFFEAEBF0),
      surfaceContainerHighest:
          isDark ? const Color(0xFF2C2F38) : const Color(0xFFE2E4EA),
      onSurface: isDark ? const Color(0xFFE9EAEE) : const Color(0xFF17181D),
      onSurfaceVariant:
          isDark ? const Color(0xFF9EA2AE) : const Color(0xFF5A5F6D),
      outline: isDark ? const Color(0xFF3A3D47) : const Color(0xFFC9CCD6),
      outlineVariant:
          isDark ? const Color(0xFF262830) : const Color(0xFFE4E6EC),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: AppFonts.sans,
    );

    final text = base.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );

    return base.copyWith(
      textTheme: text.copyWith(
        titleLarge:
            text.titleLarge?.copyWith(fontWeight: FontWeight.w600, height: 1.3),
        titleMedium:
            text.titleMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.35),
        titleSmall:
            text.titleSmall?.copyWith(fontWeight: FontWeight.w600, height: 1.35),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.55),
        bodySmall: text.bodySmall?.copyWith(height: 1.5),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
        labelMedium: text.labelMedium?.copyWith(fontWeight: FontWeight.w500),
        labelSmall: text.labelSmall?.copyWith(letterSpacing: 0.2),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleMedium?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 20),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: text.bodyMedium,
        subtitleTextStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        // Rounded selection highlight (sidebar session rows).
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
        selectedTileColor: scheme.primary.withValues(alpha: 0.10),
        selectedColor: scheme.onSurface,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
        border: _inputBorder(scheme.outlineVariant),
        enabledBorder: _inputBorder(scheme.outlineVariant),
        focusedBorder: _inputBorder(scheme.primary, width: 1.4),
        errorBorder: _inputBorder(scheme.error),
        focusedErrorBorder: _inputBorder(scheme.error, width: 1.4),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.primary.withValues(alpha: 0.14),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
        labelStyle: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          side: BorderSide(color: scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall + 2),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        textStyle: text.bodyMedium,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2C2F38) : const Color(0xFF2A2D36),
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        textStyle: text.labelSmall?.copyWith(color: Colors.white),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurfaceVariant.withValues(alpha: 0.35),
        ),
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll(6),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(radiusMedium),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}
