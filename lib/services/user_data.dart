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
      // Auto-dial always starts Paused each session (webphone behaviour), so
      // the first tap on the toggle always starts it rather than pausing a
      // state persisted from a previous run.
      _autoDialActive = false;
      _autoDialCountdownSeconds = _prefs?.getInt('auto_dial_countdown_seconds') ?? 3;
      final tokenStr = _prefs?.getString('token');
      if (tokenStr == null || tokenStr.isEmpty) return;
      final decoded = jsonDecode(tokenStr);
      if (decoded is Map) {
        final ud = decoded['userData'];
        if (ud is Map) {
          _userData = Map<String, dynamic>.from(ud);
          for (final key in ['breakoptions', 'breakOptions', 'BreakOptions', 'breaks']) {
            if (!_userData!.containsKey(key) && decoded.containsKey(key)) {
              _userData![key] = decoded[key];
            }
          }
        } else {
          _userData = Map<String, dynamic>.from(decoded);
        }
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
  static bool isBreaksEnabled() {
    final val = _userData?['isBreaksEnabled'] ??
        _userData?['isBreakEnabled'] ??
        _userData?['breaksEnabled'] ??
        _userData?['breakEnabled'] ??
        _userData?['break'];
    if (val is bool) return val;
    if (val is num) return val != 0;
    if (val is String) {
      final lower = val.trim().toLowerCase();
      if (lower == 'false' || lower == '0' || lower == 'no') return false;
      return true;
    }
    return true;
  }

  /// When true, phone numbers are masked (webphone `numberMasking`).
  static bool isNumberMasking() => _bool('numberMasking', fallback: false);

  static bool _autoDialActive = false;
  static int _autoDialCountdownSeconds = 3;

  /// Auto-dial mode state (Active vs Paused).
  static bool isAutoDialActive() => _autoDialActive;

  static Future<void> setAutoDialActive(bool value) async {
    _autoDialActive = value;
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

  static List<dynamic> breakOptions() {
    dynamic options = _userData?['breakoptions'] ??
        _userData?['breakOptions'] ??
        _userData?['BreakOptions'] ??
        _userData?['break_options'] ??
        _userData?['breaks'];

    if (options is String && options.trim().isNotEmpty) {
      try {
        options = jsonDecode(options);
      } catch (_) {}
    }

    if (options is List) {
      return options;
    }
    return const [];
  }

  /// Strips +91, 0091, 91 (for 12-digit Indian numbers), or leading +
  /// so numbers are uniformly handled and displayed without any prefix.
  static String cleanPhoneNumber(String number) {
    var n = number.trim();
    if (n.startsWith('sip:')) {
      n = n.substring(4).split('@').first;
    }
    if (n.startsWith('+91')) {
      n = n.substring(3);
    } else if (n.startsWith('0091')) {
      n = n.substring(4);
    } else if (n.startsWith('91') && n.length == 12 && RegExp(r'^\d+$').hasMatch(n)) {
      n = n.substring(2);
    } else if (n.startsWith('+')) {
      n = n.substring(1);
    }
    return n.trim();
  }

  /// Webphone-compatible number masking: keep the last two digits, `*` the
  /// rest, never mask 1-2 digit numbers, and drop the country prefix so the
  /// UI never shows +91/0091.
  static String maskNumber(String number) {
    var n = cleanPhoneNumber(number);
    if (n.isEmpty) return n;
    if (!isNumberMasking()) return n;
    if (n.length <= 2) return n;
    final masked = n
        .substring(0, n.length - 2)
        .replaceAll(RegExp(r'.'), '*');
    return '$masked${n.substring(n.length - 2)}';
  }
}
