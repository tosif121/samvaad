import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/sip_credentials.dart';
import '../services/sip_socket_service.dart';
import '../services/user_data.dart';
import 'dialpad_screen.dart';
import '../services/fcm_service.dart';

import '../services/toast_service.dart';

const _defaultServer = 'wss://app.samvaad.io:8089/ws';
const _defaultHost = 'app.samvaad.io:8089';

/// Attempts a silent re-login using the credentials saved from the last
/// successful login. Returns true when the token/session was refreshed and
/// [UserData] reloaded; false when no saved credentials exist or the login
/// request failed (the caller should fall back to the login screen).
Future<bool> autoLoginWithSavedCredentials() async {
  final prefs = await SharedPreferences.getInstance();
  final username = prefs.getString('savedUsername') ?? '';
  final password = prefs.getString('savedPassword') ?? '';
  if (username.isEmpty || password.isEmpty) {
    debugPrint('[AUTO_LOGIN] ℹ️ No saved credentials found (username empty: ${username.isEmpty}, password empty: ${password.isEmpty})');
    return false;
  }
  try {
    final url = Uri.parse('https://app.samvaad.io/userlogin/$username');
    debugPrint('[AUTO_LOGIN] 🚀 Requesting auto-login:');
    debugPrint('[AUTO_LOGIN]   URL: $url');
    debugPrint('[AUTO_LOGIN]   Username: $username');
    debugPrint('[AUTO_LOGIN]   Password length: ${password.length}');
    final stopwatch = Stopwatch()..start();
    final response = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'username': username, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
    stopwatch.stop();

    debugPrint('[AUTO_LOGIN] 📥 Response received in ${stopwatch.elapsedMilliseconds}ms:');
    debugPrint('[AUTO_LOGIN]   Status Code: ${response.statusCode}');
    debugPrint('[AUTO_LOGIN]   Body: ${response.body}');
    final data = jsonDecode(response.body);
    final message = (data is Map ? data['message'] : null)?.toString();
    final isAlreadyLoggedIn = message != null &&
        message.toLowerCase().contains('already login');
    final isWrongInfo = message != null &&
        message.toLowerCase().contains('wrong login');

    if (response.statusCode != 200 ||
        data is! Map ||
        data['success'] == false ||
        data['token'] == null ||
        isAlreadyLoggedIn ||
        isWrongInfo) {
      debugPrint('[AUTO_LOGIN] ❌ Auto-login rejected: message="$message", success=${data is Map ? data['success'] : 'null'}, hasToken=${data is Map && data['token'] != null}, isAlreadyLoggedIn=$isAlreadyLoggedIn, isWrongInfo=$isWrongInfo');
      return false;
    }
    debugPrint('[AUTO_LOGIN] ✅ Auto-login successful for user: $username');
    await prefs.setString('token', jsonEncode(data));
    await UserData.init();
    debugPrint('[AUTO_LOGIN] 👤 UserData loaded: username=${UserData.username()}, campaign=${UserData.campaign()}, campaignName=${UserData.campaignName()}');
    return true;
  } catch (e, st) {
    debugPrint('[AUTO_LOGIN] ❌ Exception during auto-login: $e\n$st');
    return false;
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  final _sip = SipSocketService();
  StreamSubscription? _sub;
  bool _connecting = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void initState() {
    super.initState();

    _sub = _sip.events.listen((event) async {
      if (!mounted) return;
      final type = event['event'] as String;
      if (type == 'registered') {
        setState(() => _connecting = false);
        FcmService().init();
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const DialpadScreen()),
        );
      } else if (type == 'registrationFailed') {
        final cause = (event['cause'] ?? '').toString();
        final authFailed = cause.contains('401') ||
            cause.toLowerCase().contains('unauthorized');
        if (authFailed) {
          await _clearSavedSession();
        }
        if (mounted) {
          setState(() {
            _connecting = false;
            _error = authFailed
                ? 'Username or password is wrong'
                : 'Registration failed — check credentials';
          });
        }
      }
    });
  }

  /// Wipes the persisted token + saved credentials so a stale/expired SIP
  /// session (401) never auto-reconnects with bad credentials again.
  Future<void> _clearSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('savedUsername');
    await prefs.remove('savedPassword');
    await _sip.clearCredentials();
  }

  Future<void> _requestPermissions() async {
    await Permission.microphone.request();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  SipCredentials _buildCreds() {
    String user = _usernameController.text.trim();
    final sipUser = user.replaceAll('@', '-');
    return SipCredentials(
      serverUrl: _defaultServer,
      sipUri: 'sip:$sipUser@$_defaultHost',
      username: sipUser,
      password: _passwordController.text,
      displayName: sipUser,
    );
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    final rawUsername = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    setState(() {
      _connecting = true;
      _error = null;
    });

    try {
      final url = Uri.parse('https://app.samvaad.io/userlogin/$rawUsername');
      final payload = {'username': rawUsername, 'password': password};
      debugPrint('[LOGIN_API] 🚀 Starting login request:');
      debugPrint('[LOGIN_API]   Endpoint: POST $url');
      debugPrint('[LOGIN_API]   Username: "$rawUsername"');
      debugPrint('[LOGIN_API]   Password length: ${password.length}');
      final stopwatch = Stopwatch()..start();
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));
      stopwatch.stop();

      debugPrint('[LOGIN_API] 📥 Response received in ${stopwatch.elapsedMilliseconds}ms:');
      debugPrint('[LOGIN_API]   Status Code: ${response.statusCode}');
      debugPrint('[LOGIN_API]   Body: ${response.body}');

      final data = jsonDecode(response.body);
      final message = (data is Map ? data['message'] : null)?.toString();
      final isAlreadyLoggedIn = message != null &&
          message.toLowerCase().contains('already login');
      final isWrongInfo = message != null &&
          message.toLowerCase().contains('wrong login');

      debugPrint('[LOGIN_API] 🔍 Response Check:');
      debugPrint('[LOGIN_API]   data is Map: ${data is Map}');
      debugPrint('[LOGIN_API]   success: ${data is Map ? data['success'] : null}');
      debugPrint('[LOGIN_API]   message: "$message"');
      debugPrint('[LOGIN_API]   hasToken: ${data is Map && data['token'] != null}');
      debugPrint('[LOGIN_API]   isAlreadyLoggedIn: $isAlreadyLoggedIn');
      debugPrint('[LOGIN_API]   isWrongInfo: $isWrongInfo');

      if (response.statusCode != 200 ||
          data is! Map ||
          data['success'] == false ||
          data['token'] == null ||
          isAlreadyLoggedIn ||
          isWrongInfo ||
          (message != null && message != 'success' && data['userData'] == null)) {
        final msg = message ?? 'Login failed. Please check credentials.';
        debugPrint('[LOGIN_API] ❌ Login REJECTED: $msg (alreadyLoggedIn=$isAlreadyLoggedIn)');
        if (isAlreadyLoggedIn) {
          ToastService.show('User already login somewhere else');
        }
        setState(() {
          _connecting = false;
          _error = msg;
        });
        return;
      }

      final userData = data['userData'];
      debugPrint('[LOGIN_API] 📋 userData: $userData');
      if (userData is Map) {
        final expiryRaw = userData['ExpiryDate'];
        debugPrint('[LOGIN_API]   ExpiryDate raw: $expiryRaw');
        if (expiryRaw != null) {
          final expiry = DateTime.tryParse(expiryRaw.toString());
          if (expiry != null) {
            final daysLeft = expiry.difference(DateTime.now()).inDays;
            debugPrint('[LOGIN_API]   Subscription days left: $daysLeft');
            if (daysLeft < 0) {
              final daysExpired = -daysLeft;
              if (daysExpired > 5) {
                debugPrint('[LOGIN_API] ❌ Subscription expired by $daysExpired days');
                setState(() {
                  _connecting = false;
                  _error =
                      'Your subscription has expired. Please renew to continue.';
                });
                return;
              }
            }
          }
        }
      }

      // Save token, username, password and credentials
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', jsonEncode(data));
      await prefs.setString('savedUsername', rawUsername);
      await prefs.setString('savedPassword', password);
      debugPrint('[LOGIN_API] 💾 Saved token, savedUsername, and savedPassword');

      await UserData.init();
      debugPrint('[LOGIN_API] 👤 UserData loaded: username=${UserData.username()}, campaign=${UserData.campaign()}, campaignName=${UserData.campaignName()}');

      final creds = _buildCreds();
      debugPrint('[LOGIN_API] 🔑 Built SIP credentials: uri=${creds.sipUri}, user=${creds.username}, server=${creds.serverUrl}');
      await _requestPermissions();
      await _sip.saveCredentials(creds);
      debugPrint('[LOGIN_API] 🔌 Connecting SIP WebSocket...');
      unawaited(_sip.connect(creds).then((_) {}));
      debugPrint('[LOGIN_API] ✅ Login process completed successfully');
    } catch (e, st) {
      debugPrint('[LOGIN_API] ❌ Exception during login: $e\n$st');
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = 'Login failed. Please check your connection.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    final isWide = size.width > 600;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isWide ? 440 : 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.phone_in_talk_rounded,
                      size: 48,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Samvaad',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sign in to continue',
                    style: TextStyle(
                      fontSize: 16,
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 40),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextFormField(
                              controller: _usernameController,
                              decoration: const InputDecoration(
                                labelText: 'Username',
                                prefixIcon: Icon(Icons.person_outline_rounded),
                              ),
                              textInputAction: TextInputAction.next,
                              validator: (v) => v == null || v.trim().isEmpty
                                  ? 'Required'
                                  : null,
                            ),
                            const SizedBox(height: 18),
                            TextFormField(
                              controller: _passwordController,
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(
                                  Icons.lock_outline_rounded,
                                ),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_off_rounded
                                        : Icons.visibility_rounded,
                                  ),
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                ),
                              ),
                              obscureText: _obscurePassword,
                              textInputAction: TextInputAction.done,
                              onFieldSubmitted: (_) => _login(),
                              validator: (v) =>
                                  v == null || v.isEmpty ? 'Required' : null,
                            ),
                            const SizedBox(height: 28),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: cs.error.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.error_outline_rounded,
                                        size: 20,
                                        color: cs.error,
                                      ),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          _error!,
                                          style: TextStyle(
                                            color: cs.error,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: cs.primary,
                                  foregroundColor: Colors.white,
                                  disabledBackgroundColor:
                                      cs.primary.withValues(alpha: 0.6),
                                  disabledForegroundColor: Colors.white70,
                                  elevation: 2,
                                  padding: EdgeInsets.zero,
                                  alignment: Alignment.center,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                onPressed: _connecting ? null : _login,
                                child: _connecting
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Center(
                                        child: Text(
                                          'Login',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
