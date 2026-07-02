import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dialpad_screen.dart';
import '../services/auth_service.dart';
import '../services/sip_socket_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  final SipSocketService _sip = SipSocketService();
  StreamSubscription? _sipSubscription;

  @override
  void initState() {
    super.initState();
    _checkAutoLogin();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _sipSubscription?.cancel();
    super.dispose();
  }

  // Auto-login with saved credentials if available
  Future<void> _checkAutoLogin() async {
    final prefsUsername = await AuthService.getSavedUsername();
    if (prefsUsername != null) {
      _usernameController.text = prefsUsername;
    }

    final hasCreds = await AuthService.hasCredentials();
    if (!hasCreds) return;

    setState(() => _isLoading = true);

    await _requestPermissions();

    // Attempt SIP registration to validate saved credentials
    _sipSubscription?.cancel();
    _sipSubscription = _sip.events.listen((event) {
      if (!mounted) return;
      final type = event['event'] as String;
      switch (type) {
        case 'registered':
          // Registration successful - navigate to dialpad
          _sipSubscription?.cancel();
          _navigateToDialpad();
          break;
        case 'registrationFailed':
          // Registration failed - clear credentials and show login screen
          _sipSubscription?.cancel();
          AuthService.clearAuthData();
          if (mounted) setState(() => _isLoading = false);
          break;
        case 'connectionLost':
          // Connection lost - show login screen
          _sipSubscription?.cancel();
          if (mounted) setState(() => _isLoading = false);
          break;
      }
    });

    // Start SIP registration
    await _sip.connect();
  }

  void _navigateToDialpad() {
    final username = _usernameController.text.trim();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => DialpadScreen(
          userName: username.isNotEmpty ? username : 'User',
          userEmail: username,
        ),
      ),
    );
  }

  /// Request all runtime permissions needed for calls (Android).
  Future<bool> _requestPermissions() async {
    final mic = await Permission.microphone.request();
    await Permission.notification.request();
    return mic.isGranted;
  }

  Future<void> _handleLogin() async {
    if (_usernameController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter username and password')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Save credentials for SIP registration
      final username = _usernameController.text.trim();
      final password = _passwordController.text.trim();
      await AuthService.saveCredentials(username, password);

      if (!mounted) return;

      // Request permissions before SIP registration
      await _requestPermissions();

      // Attempt SIP registration to validate credentials
      _sipSubscription?.cancel();
      _sipSubscription = _sip.events.listen((event) {
        if (!mounted) return;
        final type = event['event'] as String;
        switch (type) {
          case 'registered':
            // Registration successful - navigate to dialpad
            _sipSubscription?.cancel();
            _navigateToDialpad();
            break;
          case 'registrationFailed':
            // Registration failed - show error
            _sipSubscription?.cancel();
            setState(() => _isLoading = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Incorrect username or password')),
            );
            break;
          case 'connectionLost':
            // Connection lost - show error
            _sipSubscription?.cancel();
            setState(() => _isLoading = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Connection failed. Please check your network.')),
            );
            break;
        }
      });

      // Start SIP registration
      await _sip.connect();
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF1a1a1a);
    final hintColor = isDark ? const Color(0xFF8B92A8) : Colors.grey[600]!;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          // Decorative background elements
          Positioned(
            top: -100,
            right: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF4299EB).withValues(alpha: 0.1),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -150,
            left: -150,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF4299EB).withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          // Main content
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Logo/Icon
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: const Color(0xFF4299EB),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFF4299EB,
                            ).withValues(alpha: 0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.phone_in_talk_rounded,
                        size: 50,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 48),
                    // Welcome text
                    Text(
                      'Welcome Back',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Sign in to continue to Samvaad',
                      style: TextStyle(fontSize: 16, color: hintColor),
                    ),
                    const SizedBox(height: 48),
                    // Username field
                    TextField(
                      controller: _usernameController,
                      enabled: !_isLoading,
                      inputFormatters: [
                        FilteringTextInputFormatter.deny(RegExp(r'\s')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        prefixIcon: Icon(
                          Icons.person_outline,
                          color: Color(0xFF4299EB),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Password field
                    TextField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      enabled: !_isLoading,
                      inputFormatters: [
                        FilteringTextInputFormatter.deny(RegExp(r'\s')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(
                          Icons.lock_outline,
                          color: Color(0xFF4299EB),
                        ),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            color: hintColor,
                          ),
                          onPressed: _isLoading
                              ? null
                              : () {
                                  setState(() {
                                    _obscurePassword = !_obscurePassword;
                                  });
                                },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Forgot password
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _isLoading ? null : () {},
                        child: const Text(
                          'Forgot password?',
                          style: TextStyle(
                            color: Color(0xFF4299EB),
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Login button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleLogin,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : const Text(
                                'Sign In',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
