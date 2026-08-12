import 'dart:async';
import 'package:flutter/material.dart';
import '../services/sip_socket_service.dart';
import '../services/ringtone_service.dart';

class IncomingCallScreen extends StatefulWidget {
  final String phoneNumber;
  final VoidCallback? onDismiss;

  const IncomingCallScreen({
    super.key,
    required this.phoneNumber,
    this.onDismiss,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  final _sip = SipSocketService();
  StreamSubscription? _sipSubscription;
  bool _dismissed = false;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    debugPrint('[SCREEN] IncomingCallScreen ACTIVE for ${widget.phoneNumber}');
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _sipSubscription = _sip.events.listen((event) {
      if (!mounted || _dismissed) return;
      try {
        final type = event['event'] as String;

        if (type == 'callEnded' || type == 'callFailed') {
          _dismissed = true;
          _onDismiss();
          RingtoneService().stopRinging();
          RingtoneService().clearNotification();
          _popDialog(false);
        } else if (type == 'callAnswered') {
          _dismissed = true;
          _onDismiss();
          _sipSubscription?.cancel();
          RingtoneService().stopRinging();
          RingtoneService().clearNotification();
          _popDialog(true);
        }
      } catch (e, st) {
        debugPrint('[INCOMING_CALL] Event handling error: $e');
        debugPrintStack(stackTrace: st);
        _dismissed = true;
        _onDismiss();
        RingtoneService().stopRinging();
        RingtoneService().clearNotification();
        _popDialog(false);
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    super.dispose();
  }

  void _onDismiss() {
    widget.onDismiss?.call();
  }

  // Pops this dialog only if it is still the topmost route. The dialpad
  // screen's own callEnded handler may have already popped the dialog via
  // the root navigator; popping again would remove DialpadScreen and leave
  // a blank screen.
  void _popDialog(dynamic result) {
    if (!mounted) return;
    try {
      final current = ModalRoute.of(context);
      if (current == null || !current.isCurrent) return;
      final nav = Navigator.of(context);
      if (nav.canPop()) {
        nav.pop(result);
      }
    } catch (e, st) {
      debugPrint('[INCOMING_CALL] Pop error: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  Future<void> _decline() async {
    debugPrint('[INCOMING_CALL] Decline button pressed for ${widget.phoneNumber}');
    _dismissed = true;
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    RingtoneService().clearNotification();

    await _sip.rejectCall();

    debugPrint('[INCOMING_CALL] Call rejected successfully');
    _onDismiss();
    _popDialog(false);
  }

  Future<void> _acceptCall() async {
    debugPrint('[INCOMING_CALL] Answer button pressed for ${widget.phoneNumber}');
    _dismissed = true;
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    RingtoneService().clearNotification();

    try {
      _onDismiss();
      _popDialog('answer');
      debugPrint('[INCOMING_CALL] Call answered successfully');
    } catch (e, st) {
      debugPrint('[INCOMING_CALL] Answer failed: $e');
      debugPrintStack(stackTrace: st);
      _popDialog(false);
    }
  }

  /*
  Future<void> _acceptVideoCall() async {
    _dismissed = true;
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    RingtoneService().clearNotification();

    try {
      debugPrint("Accept Video pressed");
      _onDismiss();
      if (mounted) {
        Navigator.of(context).pop('answer_video');
      }
    } catch (e, st) {
      debugPrint("Accept Video failed: $e");
      debugPrintStack(stackTrace: st);
    }
  }
  */

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Text(
                'Incoming Call',
                style: TextStyle(
                  fontSize: 13,
                  color: cs.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            const SizedBox(height: 48),
            AnimatedBuilder(
              animation: _pulseAnim,
              builder: (context, child) {
                return Transform.scale(scale: _pulseAnim.value, child: child);
              },
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: cs.primary.withValues(alpha: 0.2),
                    width: 4,
                  ),
                ),
                child: Icon(Icons.person, size: 56, color: cs.primary),
              ),
            ),
            const SizedBox(height: 32),
            Text(
              _stripCountryCode(widget.phoneNumber),
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'is calling you',
              style: TextStyle(
                fontSize: 15,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildActionButton(
                    context,
                    icon: Icons.call_end_rounded,
                    label: 'Decline',
                    color: cs.error,
                    onTap: _decline,
                  ),
                  _buildActionButton(
                    context,
                    icon: Icons.call_rounded,
                    label: 'Answer',
                    color: Colors.green,
                    onTap: _acceptCall,
                  ),
                  /*
                  _buildActionButton(
                    context,
                    icon: Icons.videocam_rounded,
                    label: 'Video',
                    color: cs.primary,
                    onTap: _acceptVideoCall,
                  ),
                  */
                ],
              ),
            ),
            const SizedBox(height: 64),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

String _stripCountryCode(String number) {
  var n = number.trim();
  if (n.startsWith('+91')) n = n.substring(3);
  if (n.startsWith('0091')) n = n.substring(4);
  return n;
}
