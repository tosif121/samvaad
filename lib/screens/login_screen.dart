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

const _defaultServer = 'wss://devapp.iotcom.io:8089/ws';
const _defaultHost = 'devapp.iotcom.io:8089';

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

    _sub = _sip.events.listen((event) {
      if (!mounted) return;
      final type = event['event'] as String;
      if (type == 'registered') {
        setState(() => _connecting = false);
        FcmService()
            .init(); // Re-initialize FCM to send token with new credentials
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const DialpadScreen()),
        );
      } else if (type == 'registrationFailed') {
        setState(() {
          _connecting = false;
          _error = 'Registration failed — check credentials';
        });
      }
    });
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
      final url = Uri.parse('https://devapp.iotcom.io/userlogin/$rawUsername');
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': rawUsername, 'password': password}),
          )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);

      if (response.statusCode != 200 || data['success'] == false) {
        final msg =
            data['message'] ?? 'Login failed. Please check credentials.';
        setState(() {
          _connecting = false;
          _error = msg;
        });
        return;
      }

      final userData = data['userData'];
      if (userData is Map) {
        final expiryRaw = userData['ExpiryDate'];
        if (expiryRaw != null) {
          final expiry = DateTime.tryParse(expiryRaw.toString());
          if (expiry != null) {
            final daysLeft = expiry.difference(DateTime.now()).inDays;
            if (daysLeft < 0) {
              final daysExpired = -daysLeft;
              if (daysExpired > 5) {
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

      await UserData.init();

      final creds = _buildCreds();
      await _requestPermissions();
      await _sip.saveCredentials(creds);
      unawaited(_sip.connect(creds).then((_) {}));
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('savedUsername', rawUsername);
      await prefs.setString('savedPassword', password);
      final creds = _buildCreds();
      await _requestPermissions();
      await _sip.saveCredentials(creds);
      unawaited(_sip.connect(creds).then((_) {}));
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
                                onPressed: _connecting ? null : _login,
                                child: _connecting
                                    ? SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                          color: cs.onPrimary,
                                        ),
                                      )
                                    : const Text('Login'),
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
