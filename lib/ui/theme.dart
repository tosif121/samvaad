import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'tokens.dart';

/// App theme: custom seed palette exposed via `ColorScheme.fromSeed`,
/// light + dark variants. Dark is the primary experience.
abstract final class SamvaadTheme {
  static const Color seed = Color(0xFF5B6CFF);
  static const Color success = Color(0xFF23C56E);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      secondary: success,
    ).copyWith(
      surface: const Color(0xFFFBFBFD),
      surfaceContainerLow: const Color(0xFFF2F3F8),
      surfaceContainer: const Color(0xFFECEDF3),
      surfaceContainerHigh: const Color(0xFFE4E6EF),
      onSurface: const Color(0xFF171A26),
    );
    return _build(scheme);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      secondary: success,
    ).copyWith(
      surface: const Color(0xFF0F121B),
      surfaceContainerLow: const Color(0xFF151A26),
      surfaceContainer: const Color(0xFF1A1F2E),
      surfaceContainerHigh: const Color(0xFF202637),
      onSurface: const Color(0xFFE9EBF3),
      outline: const Color(0xFF3A4053),
    );
    return _build(scheme);
  }

  static ThemeData _build(ColorScheme cs) {
    final isDark = cs.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      brightness: cs.brightness,
      scaffoldBackgroundColor: cs.surface,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: cs.onSurface),
        titleTextStyle: TextStyle(
          color: cs.onSurface,
          fontSize: AppType.heading,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: cs.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
          side: BorderSide(color: cs.outline.withValues(alpha: 0.5)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cs.surfaceContainer,
        elevation: 0,
        height: 68,
        indicatorColor: cs.primary.withValues(alpha: 0.16),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: AppType.caption - 1,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w800
                : FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? cs.onSurface
                : cs.onSurface.withValues(alpha: 0.55),
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? cs.primary
                : cs.onSurface.withValues(alpha: 0.5),
            size: 24,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: cs.outline.withValues(alpha: 0.4),
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: cs.onSurface.withValues(alpha: 0.6),
        textColor: cs.onSurface,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: cs.surfaceContainerHigh,
        selectedColor: cs.primary.withValues(alpha: 0.18),
        side: BorderSide(color: cs.outline.withValues(alpha: 0.5)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        labelStyle: TextStyle(
          fontSize: AppType.body - 1,
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
        secondaryLabelStyle: TextStyle(
          fontSize: AppType.body - 1,
          fontWeight: FontWeight.w700,
          color: cs.onSurface,
        ),
        checkmarkColor: cs.primary,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm + 2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          textStyle: TextStyle(
            fontSize: AppType.body,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xxl,
            vertical: AppSpacing.lg,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
          ),
          textStyle: TextStyle(
            fontSize: AppType.subheading,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: cs.primary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm + 2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          side: BorderSide(color: cs.primary.withValues(alpha: 0.45)),
          textStyle: TextStyle(
            fontSize: AppType.body - 1,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: cs.primary,
          textStyle: TextStyle(
            fontSize: AppType.body - 1,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? cs.primary
              : cs.onSurface.withValues(alpha: 0.6),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? cs.primary.withValues(alpha: 0.35)
              : cs.onSurface.withValues(alpha: 0.15),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? const Color(0xFF2A3042)
            : cs.onSurface,
        contentTextStyle: TextStyle(
          color: isDark ? cs.onSurface : cs.surface,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: cs.primary,
        circularTrackColor: cs.primary.withValues(alpha: 0.15),
      ),
    );
  }
}

/// Persisted theme-mode override (defaults to system; dark is the authored
/// primary experience).
class ThemeController {
  ThemeController._();

  static final ThemeController instance = ThemeController._();

  final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.dark);

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('theme_mode');
      if (saved != null && saved != 'system') {
        mode.value = ThemeMode.values.firstWhere(
          (m) => m.name == saved,
          orElse: () => ThemeMode.dark,
        );
      } else {
        mode.value = ThemeMode.dark;
      }
    } catch (_) {}
  }

  Future<void> set(ThemeMode value) async {
    mode.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('theme_mode', value.name);
    } catch (_) {}
  }
}
