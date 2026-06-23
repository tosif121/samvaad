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
    super.initState();
    _sipSubscription = _sip.events.listen((event) {
      if (!mounted || _dismissed) return;
      final type = event['event'] as String;
      if (type == 'callEnded' || type == 'callFailed') {
        _dismissed = true;
        _onDismiss();
        RingtoneService().stopRinging();
        Navigator.of(context).pop();
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

  void _decline() {
    _dismissed = true;
    _onDismiss();
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    _sip.rejectCall();
    if (mounted) Navigator.of(context).pop();
  }

  void _accept() {
    _dismissed = true;
    _onDismiss();
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    _sip.answerCall();
    if (mounted) Navigator.of(context).pop();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),
            // Incoming call label
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
            // Pulsing avatar
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
            // Phone number
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
              'Calling...',
              style: TextStyle(fontSize: 15, color: Colors.grey[500]),
            ),
            const Spacer(),
            // Accept / Decline buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 64),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Decline
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
                  // Accept
                  Column(
                    children: [
                      GestureDetector(
                        onTap: _accept,
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
                        'Accept',
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
