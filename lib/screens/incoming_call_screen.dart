import 'dart:async';
import 'package:flutter/material.dart';
import '../services/sip_socket_service.dart';
import '../services/ringtone_service.dart';

class IncomingCallScreen extends StatefulWidget {
  final String phoneNumber;
  final VoidCallback? onDismiss;

  const IncomingCallScreen({super.key, required this.phoneNumber, this.onDismiss});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  final _sip = SipSocketService();
  StreamSubscription? _sipSubscription;
  bool _dismissed = false;

  @override
  void initState() {
    debugPrint('[SCREEN] IncomingCallScreen ACTIVE');
    super.initState();
    _sipSubscription = _sip.events.listen((event) {
      if (!mounted || _dismissed) return;
      final type = event['event'] as String;

      if (type == 'callEnded' || type == 'callFailed') {
        _dismissed = true;
        _onDismiss();
        RingtoneService().stopRinging();
        RingtoneService().clearNotification();
        Navigator.of(context).pop(false);
      } else if (type == 'callAnswered') {
        _dismissed = true;
        _onDismiss();
        _sipSubscription?.cancel();
        RingtoneService().stopRinging();
        RingtoneService().clearNotification();
        Navigator.of(context).pop(true);
      }
    });
  }

  @override
  void dispose() {
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    super.dispose();
  }

  void _onDismiss() {
    widget.onDismiss?.call();
  }

  Future<void> _decline() async {
    _dismissed = true;
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    RingtoneService().clearNotification();

    await _sip.rejectCall();

    _onDismiss();
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _acceptCall() async {
    _dismissed = true;
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    RingtoneService().clearNotification();

    try {
      debugPrint("Accept pressed");
      _onDismiss();
      if (mounted) {
        Navigator.of(context).pop('answer');
      }
    } catch (e, st) {
      debugPrint("Accept failed: $e");
      debugPrintStack(stackTrace: st);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF4299EB).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Incoming Call',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF4299EB),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 40),
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF4299EB).withValues(alpha: 0.06),
                  ),
                ),
                Container(
                  width: 130,
                  height: 130,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF4299EB).withValues(alpha: 0.1),
                  ),
                ),
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF4299EB).withValues(alpha: 0.15),
                    border: Border.all(
                      color: const Color(0xFF4299EB),
                      width: 3,
                    ),
                  ),
                  child: const Icon(
                    Icons.person,
                    size: 50,
                    color: Color(0xFF4299EB),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 36),
            Text(
              widget.phoneNumber,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1a1a1a),
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'is calling you',
              style: TextStyle(fontSize: 15, color: Colors.grey[500]),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(
                    children: [
                      GestureDetector(
                        onTap: _decline,
                        child: Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            color: Colors.redAccent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.redAccent.withValues(alpha: 0.4),
                                blurRadius: 16,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.call_end,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Decline',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      GestureDetector(
                        onTap: _acceptCall,
                        child: Container(
                          width: 68,
                          height: 68,
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
                          child: const Icon(
                            Icons.call,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Answer',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 72),
          ],
        ),
      ),
    );
  }
}
