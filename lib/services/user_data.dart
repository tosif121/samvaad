import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Reads the agent's configuration from the login token payload (`userData`)
/// and mirrors how the webphone consumes those fields.
class UserData {
  UserData._();

  static Map<String, dynamic>? _userData;
  static SharedPreferences? _prefs;

  /// Loads and caches `userData` from the saved login token. Call once at
  /// startup and again after a fresh login so the dashboard uses new values.
  static Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _autoDialActive = _prefs?.getBool('auto_dial_active') ?? true;
      _autoDialCountdownSeconds = _prefs?.getInt('auto_dial_countdown_seconds') ?? 3;
      final tokenStr = _prefs?.getString('token');
      if (tokenStr == null || tokenStr.isEmpty) return;
      final decoded = jsonDecode(tokenStr);
      if (decoded is Map) {
        final ud = decoded['userData'];
        if (ud is Map) _userData = Map<String, dynamic>.from(ud);
      }
    } catch (_) {}
  }

  static Map<String, dynamic>? get current => _userData;

  static bool _bool(String key, {required bool fallback}) {
    final value = _userData?[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    return fallback;
  }

  static String _str(String key) => _userData?[key]?.toString() ?? '';

  /// Gates whether the disposition sheet is shown after a call ends.
  static bool isDispositionEnabled() => _bool('disposition', fallback: true);

  /// Gates whether the agent can take breaks.
  static bool isBreaksEnabled() => _bool('isBreaksEnabled', fallback: true);

  /// When true, phone numbers are masked (webphone `numberMasking`).
  static bool isNumberMasking() => _bool('numberMasking', fallback: false);

  static bool _autoDialActive = true;
  static int _autoDialCountdownSeconds = 3;

  /// Auto-dial mode state (Active vs Paused).
  static bool isAutoDialActive() => _autoDialActive;

  static Future<void> setAutoDialActive(bool value) async {
    _autoDialActive = value;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setBool('auto_dial_active', value);
  }

  /// Auto-dial countdown timer seconds (default 3s).
  static int autoDialCountdownSeconds() => _autoDialCountdownSeconds;

  static Future<void> setAutoDialCountdownSeconds(int seconds) async {
    _autoDialCountdownSeconds = seconds;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setInt('auto_dial_countdown_seconds', seconds);
  }

  static String campaignName() => _str('campaignName');

  static String userId() => _str('userid');

  static String adminUser() => _str('adminuser');

  static String username() => _str('username');

  static String campaign() => _str('campaign');

  static String? expiryDate() => _userData?['ExpiryDate']?.toString();

  /// Theme preference pushed from the backend via `uiPreferences.themeMode`.
  static String? themeMode() {
    final prefs = _userData?['uiPreferences'];
    if (prefs is Map) {
      final t = prefs['themeMode']?.toString();
      if (t != null && t.isNotEmpty) return t;
    }
    return null;
  }

  static List<dynamic> dispositionOptions() =>
      (_userData?['dispostionOptions'] as List?) ?? const [];

  static List<dynamic> breakOptions() =>
      (_userData?['breakoptions'] as List?) ?? const [];

  /// Webphone-compatible number masking: keep the last two digits, `*` the
  /// rest, preserve the +91 prefix, and never mask 1-2 digit numbers.
  static String maskNumber(String number) {
    if (!isNumberMasking() || number.isEmpty) return number;
    if (number.startsWith('+91')) {
      final rest = number.substring(3);
      if (rest.length <= 2) return number;
      final masked = rest
          .substring(0, rest.length - 2)
          .replaceAll(RegExp(r'.'), '*');
      return '+91$masked${rest.substring(rest.length - 2)}';
    }
    if (number.length <= 2) return number;
    final masked = number
        .substring(0, number.length - 2)
        .replaceAll(RegExp(r'.'), '*');
    return '$masked${number.substring(number.length - 2)}';
  }
}
