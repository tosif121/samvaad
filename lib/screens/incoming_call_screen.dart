import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/sip_socket_service.dart';
import '../services/ringtone_service.dart';

// Design tokens (shared with video_call_screen)
const _icBlue    = Color(0xFF2563EB);
const _icBlueLt  = Color(0xFF3B82F6);
const _icRed     = Color(0xFFEF4444);
const _icGreen   = Color(0xFF22C55E);
const _icBg      = Color(0xFF0F1115);
const _icSurface = Color(0xFF181A20);
const _icTextSec = Color(0xFFB8BDC9);

class IncomingCallScreen extends StatefulWidget {
  final String phoneNumber;
  final VoidCallback? onDismiss;

  const IncomingCallScreen({super.key, required this.phoneNumber, this.onDismiss});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with TickerProviderStateMixin {
  final _sip = SipSocketService();
  StreamSubscription? _sipSubscription;
  bool _dismissed = false;

  late AnimationController _pulseCtrl;
  late AnimationController _slideCtrl;
  late Animation<double> _pulse1;
  late Animation<double> _pulse2;
  late Animation<double> _pulse3;
  late Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();

    // Staggered pulse rings
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat();
    _pulse1 = Tween<double>(begin: 0.7, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: const Interval(0.0, 0.7, curve: Curves.easeOut)));
    _pulse2 = Tween<double>(begin: 0.6, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: const Interval(0.15, 0.85, curve: Curves.easeOut)));
    _pulse3 = Tween<double>(begin: 0.5, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: const Interval(0.3, 1.0, curve: Curves.easeOut)));

    // Slide-up entry
    _slideCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero).animate(
        CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut));
    _slideCtrl.forward();

    _sipSubscription = _sip.events.listen((event) {
      if (!mounted || _dismissed) return;
      final type = event['event'] as String;
      if (type == 'callEnded' || type == 'callFailed') {
        _dismissed = true;
        widget.onDismiss?.call();
        RingtoneService().stopRinging();
        if (mounted) Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _slideCtrl.dispose();
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    super.dispose();
  }

  Future<void> _decline() async {
    if (_dismissed) return;
    HapticFeedback.heavyImpact();
    _dismissed = true;
    widget.onDismiss?.call();
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    RingtoneService().clearNotification();
    if (mounted) Navigator.of(context).pop(false);
    await _sip.rejectCall();
  }

  void _acceptAudio() {
    if (_dismissed) return;
    HapticFeedback.mediumImpact();
    _dismissed = true;
    widget.onDismiss?.call();
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    RingtoneService().clearNotification();
    if (mounted) Navigator.of(context).pop({'answer': true, 'video': false});
  }

  void _acceptVideo() {
    if (_dismissed) return;
    HapticFeedback.mediumImpact();
    _dismissed = true;
    widget.onDismiss?.call();
    _sipSubscription?.cancel();
    RingtoneService().stopRinging();
    RingtoneService().clearNotification();
    if (mounted) Navigator.of(context).pop({'answer': true, 'video': true});
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = _sip.isVideo;
    final mq  = MediaQuery.of(context);
    final sw  = mq.size.width;
    final sh  = mq.size.height;
    final sf  = (sw / 360.0).clamp(0.78, 1.25);
    final compact = sh < 680;

    return Scaffold(
      backgroundColor: _icBg,
      body: SafeArea(
        child: SlideTransition(
          position: _slideAnim,
          child: Column(
            children: [
              SizedBox(height: compact ? 28.0 : 52.0),

              // ── Call type badge ─────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: (isVideo ? _icBlueLt : _icGreen).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: (isVideo ? _icBlueLt : _icGreen).withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                      color: isVideo ? _icBlueLt : _icGreen,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isVideo ? 'Incoming Video Call' : 'Incoming Call',
                      style: TextStyle(
                        fontSize: 13,
                        color: isVideo ? _icBlueLt : _icGreen,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),

              SizedBox(height: compact ? 24.0 : 48.0),

              // ── Pulsing avatar ──────────────────────────────────────────
              Builder(builder: (_) {
                final outerR = (200 * sf).clamp(160.0, 230.0);
                final midR   = (160 * sf).clamp(128.0, 185.0);
                final innR   = (128 * sf).clamp(100.0, 150.0);
                final avatarR= (108 * sf).clamp(86.0,  124.0);
                final iconSz = (56  * sf).clamp(44.0,   66.0);
                return SizedBox(
                  width: outerR, height: outerR,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _pulse3,
                        builder: (_, __) => Opacity(
                          opacity: (1.0 - _pulse3.value).clamp(0.0, 0.15),
                          child: Container(
                            width: outerR * _pulse3.value, height: outerR * _pulse3.value,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: _icBlueLt.withValues(alpha: 0.12)),
                          ),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: _pulse2,
                        builder: (_, __) => Opacity(
                          opacity: (1.0 - _pulse2.value).clamp(0.0, 0.20),
                          child: Container(
                            width: midR * _pulse2.value, height: midR * _pulse2.value,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: _icBlueLt.withValues(alpha: 0.15)),
                          ),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: _pulse1,
                        builder: (_, __) => Opacity(
                          opacity: (1.0 - _pulse1.value).clamp(0.0, 0.30),
                          child: Container(
                            width: innR * _pulse1.value, height: innR * _pulse1.value,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: _icBlueLt.withValues(alpha: 0.20)),
                          ),
                        ),
                      ),
                      Container(
                        width: avatarR, height: avatarR,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle, color: _icSurface,
                          border: Border.all(color: _icBlueLt.withValues(alpha: 0.5), width: 2),
                        ),
                        child: Icon(Icons.person_rounded, size: iconSz, color: _icBlueLt),
                      ),
                    ],
                  ),
                );
              }),

              SizedBox(height: compact ? 20.0 : 32.0),

              // ── Caller name ─────────────────────────────────────────────
              Text(
                widget.phoneNumber,
                style: TextStyle(
                  fontSize: (28 * sf).clamp(22.0, 34.0),
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isVideo ? 'Wants to video call you' : 'Calling you',
                style: const TextStyle(fontSize: 15, color: _icTextSec),
              ),

              const Spacer(),

              // ── Action row ──────────────────────────────────────────────
              Padding(
                padding: EdgeInsets.symmetric(horizontal: (sw * 0.06).clamp(16.0, 48.0)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _ActionButton(icon: Icons.call_end_rounded, label: 'Decline', color: _icRed,    btnSize: (68 * sf).clamp(58.0, 78.0), onTap: _decline),
                    _ActionButton(icon: Icons.call_rounded,     label: 'Audio',   color: _icGreen,  btnSize: (68 * sf).clamp(58.0, 78.0), onTap: _acceptAudio),
                    _ActionButton(icon: Icons.videocam_rounded, label: 'Video',   color: _icBlueLt, btnSize: (68 * sf).clamp(58.0, 78.0), onTap: _acceptVideo),
                  ],
                ),
              ),

              SizedBox(height: compact ? 28.0 : 52.0),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Reusable action button ────────────────────────────────────────────────────
class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final double btnSize;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.btnSize = 68,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
    _scale = Tween<double>(begin: 1.0, end: 0.92)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp:   (_) { _ctrl.reverse(); widget.onTap(); },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: widget.btnSize, height: widget.btnSize,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.40),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Icon(widget.icon, color: Colors.white, size: widget.btnSize * 0.44),
            ),
            const SizedBox(height: 8),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: widget.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
