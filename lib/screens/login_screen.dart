import 'dart:async';
import 'package:flutter/material.dart';
import '../models/sip_credentials.dart';
import '../services/sip_socket_service.dart';
import 'dialpad_screen.dart';

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

    _tryAutoLogin();
  }

  Future<void> _tryAutoLogin() async {
    await _sip.loadCredentials();
    if (_sip.hasCredentials && mounted) {
      setState(() => _connecting = true);
      unawaited(_sip.connect().then((_) {}));
    }
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
    // Replace @ with - for SIP URI compatibility (common with Asterisk).
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

    final creds = _buildCreds();

    setState(() {
      _connecting = true;
      _error = null;
    });

    await _sip.saveCredentials(creds);
    unawaited(_sip.connect(creds).then((_) {}));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.phone_in_talk,
                    size: 64,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Samvaad',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'SIP Phone',
                    style: TextStyle(color: Colors.grey[500], fontSize: 15),
                  ),
                  const SizedBox(height: 40),
                  TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () =>
                            setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _login(),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 32),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(color: Colors.red[700]),
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
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
                          : const Text(
                              'Connect',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w600),
                            ),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
