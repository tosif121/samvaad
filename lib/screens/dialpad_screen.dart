import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'outgoing_call_screen.dart';
import 'incoming_call_screen.dart';
import 'login_screen.dart';
import '../widgets/dial_button.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../services/sip_socket_service.dart';

class DialpadScreen extends StatefulWidget {
  final String userName;
  final String userEmail;

  const DialpadScreen({
    super.key,
    required this.userName,
    required this.userEmail,
  });

  @override
  State<DialpadScreen> createState() => _DialpadScreenState();
}

class _DialpadScreenState extends State<DialpadScreen> {
  String _dialedNumber = '';
  final _sip = SipSocketService();
  StreamSubscription? _sipSubscription;

  @override
  void initState() {
    super.initState();
    _requestMicrophonePermission();
    _initSip();
  }

  Future<void> _requestMicrophonePermission() async {
    // Permission is handled by flutter_webrtc at call time.
    // No pre-fetch needed - avoids Android audio resource conflicts.
  }

  @override
  void dispose() {
    _sipSubscription?.cancel();
    _sip.disconnect();
    super.dispose();
  }

  Future<void> _initSip() async {
    // Listen for SIP events before connecting
    _sipSubscription = _sip.events.listen((event) {
      if (!mounted) return;
      final type = event['event'] as String;
      print('[DIALPAD] Received SIP Event: $type | Data: $event');

      switch (type) {
        case 'incomingCall':
          if (_sip.callState == CallState.onCall) {
            print('[DIALPAD] Suppressing incomingCall screen because already on a call');
            break;
          }
          final number = event['number'] as String? ?? 'Unknown';
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => IncomingCallScreen(phoneNumber: number),
            ),
          );
          break;

        case 'registrationFailed':
          _showConnectionError('registration_failed');
          break;

        case 'connectionLost':
          final reason = event['reason'] as String? ?? 'unknown';
          _showConnectionError(reason);
          break;
      }
    });

    // Connect SIP WebSocket + register
    await _sip.connect();
  }

  void _showConnectionError(String reason) {
    final isRegistrationFail = reason == 'registration_failed';
    final msg = isRegistrationFail
        ? 'Registration failed. Please try again.'
        : reason == 'session_expired'
            ? 'Session expired. Please login again.'
            : 'Poor connection. Please login again.';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(isRegistrationFail ? 'Registration Failed' : 'Connection Lost'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              if (isRegistrationFail) {
                _sip.disconnect();
                await _sip.connect();
              } else {
                await AuthService.logout();
                if (mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                    (route) => false,
                  );
                }
              }
            },
            child: Text(isRegistrationFail ? 'Reconnect' : 'OK'),
          ),
        ],
      ),
    );
  }

  void _onDigitPressed(String digit) {
    setState(() => _dialedNumber += digit);
  }

  void _onBackspace() {
    if (_dialedNumber.isNotEmpty) {
      setState(
        () => _dialedNumber = _dialedNumber.substring(
          0,
          _dialedNumber.length - 1,
        ),
      );
    }
  }

  Future<void> _onCall() async {
    if (_dialedNumber.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Initiating call...'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );

    _sip.setDialedNumber(_dialedNumber);
    final result = await ApiService.dialNumber(_dialedNumber);
    if (!mounted) return;

    if (result['success'] == true) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OutgoingCallScreen(phoneNumber: _dialedNumber),
        ),
      );
      setState(() => _dialedNumber = '');
    } else {
      _sip.setDialedNumber('');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message'] ?? 'Failed to initiate call'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Samvaad'),
        titleSpacing: 16,
        automaticallyImplyLeading: false,
        actions: [
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: SafeArea(

        child: Column(

          children: [
            const Spacer(),
            const SizedBox(height: 40),
            // Number display row with backspace
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Center(
                      child: Text(
                        _dialedNumber.isEmpty ? 'Enter number' : _dialedNumber,
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w500,
                          color: _dialedNumber.isEmpty
                              ? Colors.grey[400]
                              : const Color(0xFF1a1a1a),
                          letterSpacing: 2,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                  if (_dialedNumber.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.backspace_outlined),
                      onPressed: _onBackspace,
                      color: Colors.grey[600],
                    ),
                ],
              ),
            ),
            const SizedBox(height:  40),
            // Dialpad
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  _buildDialRow(['1', '2', '3']),
                  const SizedBox(height: 16),
                  _buildDialRow(['4', '5', '6']),
                  const SizedBox(height: 16),
                  _buildDialRow(['7', '8', '9']),
                  const SizedBox(height: 16),
                  _buildDialRow(['*', '0', '#']),
                ],
              ),
            ),
            const SizedBox(height: 32),
            // Call button
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.green.withValues(alpha: 0.4),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: IconButton(
                icon: const Icon(Icons.call, size: 32),
                color: Colors.white,
                onPressed: _onCall,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildDialRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits
          .map((d) => DialButton(digit: d, onPressed: () => _onDigitPressed(d)))
          .toList(),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(24, 60, 24, 32),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF4299EB),
                  const Color(0xFF4299EB).withValues(alpha: 0.8),
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      widget.userName.isNotEmpty
                          ? widget.userName[0].toUpperCase()
                          : 'U',
                      style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF4299EB),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.userName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.userEmail,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Online',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.all(16),
              child: ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text(
                  'Logout',
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () async {
                  _sip.disconnect();
                  await AuthService.logout();
                  if (context.mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                      (route) => false,
                    );
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
