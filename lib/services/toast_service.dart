import 'package:flutter/material.dart';

/// Global, context-free toasts for services. Wired once in MaterialApp via
/// [messengerKey]; shows a SnackBar only when an API/operation fails.
class ToastService {
  ToastService._();

  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  static String? _lastMessage;
  static DateTime _lastShownAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Shows an error SnackBar. Dedupes identical messages within 5s so
  /// periodic background polls don't spam the UI.
  static void show(String message) {
    final now = DateTime.now();
    final repeated =
        message == _lastMessage &&
        now.difference(_lastShownAt) < const Duration(seconds: 5);
    if (repeated) return;
    _lastMessage = message;
    _lastShownAt = now;

    messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
  }
}