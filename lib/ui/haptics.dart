import 'package:flutter/services.dart';

/// Centralized haptic feedback. No-ops gracefully on unsupported platforms.
abstract final class Haptics {
  static Future<void> tap() async {
    try {
      await HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  static Future<void> select() async {
    try {
      await HapticFeedback.selectionClick();
    } catch (_) {}
  }

  static Future<void> light() async {
    try {
      await HapticFeedback.lightImpact();
    } catch (_) {}
  }

  static Future<void> success() async {
    try {
      await HapticFeedback.heavyImpact();
    } catch (_) {}
  }
}
