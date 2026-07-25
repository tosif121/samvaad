import 'dart:async';
import 'package:flutter/material.dart';
import '../services/sip_socket_service.dart';
import '../services/callkit_service.dart';
import 'dialpad_screen.dart';

class ConnectingCallScreen extends StatefulWidget {
  final String callerName;
  final String callerNumber;

  const ConnectingCallScreen({
    super.key,
    required this.callerName,
    required this.callerNumber,
  });

  @override
  State<ConnectingCallScreen> createState() => _ConnectingCallScreenState();
}

class _ConnectingCallScreenState extends State<ConnectingCallScreen> {
  final _sip = SipSocketService();
  StreamSubscription? _sipSubscription;
  String _statusText = 'Registering & Connecting Call...';

  @override
  void initState() {
    super.initState();
    debugPrint('[SCREEN] ConnectingCallScreen ACTIVE for ${widget.callerName}');

    _sip.shouldAutoAnswerNextCall = true;
    CallKitService().isCallKitAnswering = true;

    _updateStatusText();

    _sipSubscription = _sip.events.listen((event) {
      if (!mounted) return;
      final type = event['event'] as String;
      debugPrint('[CONNECTING_SCREEN] SIP Event: $type');

      if (type == 'callEnded' || type == 'callFailed') {
        if (mounted) {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          } else {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const DialpadScreen()),
            );
          }
        }
      } else if (type == 'callAnswered') {
        if (mounted) {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop('connected');
          } else {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const DialpadScreen()),
            );
          }
        }
      } else if (type == 'registered') {
        setState(() => _statusText = 'Answering Call...');
        _sip.answerCall();
      } else if (type == 'connectionRestored') {
        setState(() => _statusText = 'Registering SIP...');
      }
    });

    _connectAndAnswer();
  }

  void _updateStatusText() {
    if (_sip.isRegistered) {
      _statusText = 'Answering Call...';
    } else if (_sip.isConnected) {
      _statusText = 'Registering SIP...';
    } else {
      _statusText = 'Connecting to Server...';
    }
  }

  Future<void> _connectAndAnswer() async {
    try {
      if (!_sip.isRegistered) {
        await _sip.connect();
      }
      await _sip.answerCall();
    } catch (e) {
      debugPrint('[CONNECTING_SCREEN] Error answering call: $e');
    }
  }

  @override
  void dispose() {
    _sipSubscription?.cancel();
    super.dispose();
  }

  Future<void> _cancel() async {
    await _sip.endCall();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final displayName = widget.callerName.isNotEmpty ? widget.callerName : widget.callerNumber;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _cancel();
        }
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(),
                Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: cs.primary.withValues(alpha: 0.3),
                      width: 3,
                    ),
                  ),
                  child: Icon(
                    Icons.person_rounded,
                    size: 56,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  displayName.isNotEmpty ? displayName : 'Incoming Call',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _statusText,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
