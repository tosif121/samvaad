import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/sip_socket_service.dart';
import '../widgets/dial_button.dart';
import '../services/ringtone_service.dart';

class OutgoingCallScreen extends StatefulWidget {
  final String phoneNumber;

  const OutgoingCallScreen({super.key, required this.phoneNumber});

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  final SipSocketService _sip = SipSocketService();

  bool _isConnected = false;
  bool _showKeypad = false;
  bool _isSpeakerOn = false;
  bool _isEndingCall = false;
  int _seconds = 0;
  StreamSubscription? _sipSubscription;
  Timer? _timer;

  @override
  void initState() {
    print('[SCREEN] OutgoingCallScreen ACTIVE');
    super.initState();
    RingtoneService().stopRinging();
    RingtoneService().clearNotification();
    RingtoneService().cleanupForegroundService();
    FlutterCallkitIncoming.endAllCalls();
    Helper.setSpeakerphoneOn(false);

    if (_sip.callState == CallState.onCall) {
      _isConnected = true;
      _startTimer();
    }

    _sipSubscription = _sip.events.listen((event) {
      if (!mounted) return;
      final type = event['event'] as String;
      switch (type) {
        case 'callAnswered':
          if (!_isConnected) {
            setState(() => _isConnected = true);
            _startTimer();
          }
          break;
        case 'callFailed':
          if (!_isEndingCall) _showErrorAndPop(event['reason'] as String?);
          break;
        case 'callEnded':
          if (!_isEndingCall) Navigator.of(context).pop();
          break;
      }
    });
  }

  @override
  void dispose() {
    _sipSubscription?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isConnected) {
        setState(() => _seconds++);
      } else {
        timer.cancel();
      }
    });
  }

  String get _formattedTime {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _toggleMute() {
    _sip.mute(!_sip.isMuted);
    setState(() {});
  }

  void _toggleHold() {
    _sip.toggleHold();
    setState(() {});
  }

  void _showErrorAndPop(String? reason) {
    if (!mounted) return;
    _isEndingCall = true;
    final msg = _friendlyError(reason);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Call Failed'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              if (mounted) Navigator.of(context).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String _friendlyError(String? reason) {
    if (reason == null) return 'Call could not be connected.';
    if (reason.contains('404')) return 'Extension not found (404). Check the number and try again.';
    if (reason.contains('408')) return 'Request timed out (408). No answer.';
    if (reason.contains('480')) return 'User temporarily unavailable (480).';
    if (reason.contains('486')) return 'User is busy (486).';
    if (reason.contains('487')) return 'Call cancelled.';
    if (reason.contains('403')) return 'Call not authorized (403).';
    if (reason.contains('503')) return 'Service unavailable (503). Try again later.';
    return 'Call failed: $reason';
  }

  Future<void> _endCall() async {
    _isEndingCall = true;
    await _sip.endCall();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final mq      = MediaQuery.of(context);
    final sw      = mq.size.width;
    final sh      = mq.size.height;
    final sf      = (sw / 360.0).clamp(0.78, 1.25);
    final compact = sh < 680;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F1115),
        body: SafeArea(
          child: Column(
            children: [
              SizedBox(height: compact ? 28.0 : 48.0),

              // ── Avatar ──────────────────────────────────────────────────
              Container(
                width:  (100 * sf).clamp(80.0, 116.0),
                height: (100 * sf).clamp(80.0, 116.0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF181A20),
                  border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.5), width: 2),
                ),
                child: Icon(Icons.person_rounded, size: (52 * sf).clamp(40.0, 62.0), color: const Color(0xFF3B82F6)),
              ),

              SizedBox(height: compact ? 12.0 : 20.0),

              // ── Number ──────────────────────────────────────────────────
              Text(
                widget.phoneNumber,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: (26 * sf).clamp(20.0, 30.0),
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),

              const SizedBox(height: 10),

              // ── Status pill ──────────────────────────────────────────────
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _isConnected
                    ? Container(
                        key: const ValueKey('connected'),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                        decoration: BoxDecoration(
                          color: const Color(0xFF22C55E).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF22C55E).withValues(alpha: 0.3), width: 0.5),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(width: 7, height: 7,
                              decoration: const BoxDecoration(color: Color(0xFF22C55E), shape: BoxShape.circle)),
                            const SizedBox(width: 7),
                            Text(_formattedTime,
                              style: const TextStyle(fontSize: 15, color: Color(0xFF22C55E), fontWeight: FontWeight.w600)),
                          ],
                        ),
                      )
                    : Container(
                        key: const ValueKey('calling'),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF59E0B).withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.25), width: 0.5),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFF59E0B))),
                            const SizedBox(width: 8),
                            const Text('Ringing...', style: TextStyle(fontSize: 15, color: Color(0xFFF59E0B), fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
              ),

              const Spacer(),

              // ── Controls / Keypad ────────────────────────────────────────
              if (_showKeypad)
                _buildKeypad()
              else
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: (sw * 0.06).clamp(16.0, 32.0)),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: compact ? 10.0 : 16.0),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.08), width: 0.5),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _OcCtrlBtn(
                          icon: _sip.isHeld ? Icons.play_arrow_rounded : Icons.pause_rounded,
                          label: _sip.isHeld ? 'Resume' : 'Hold',
                          isActive: _sip.isHeld,
                          enabled: _isConnected,
                          btnSize: (52 * sf).clamp(44.0, 62.0),
                          onTap: _isConnected ? _toggleHold : null,
                        ),
                        _OcCtrlBtn(
                          icon: _sip.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                          label: _sip.isMuted ? 'Unmute' : 'Mute',
                          isActive: _sip.isMuted,
                          btnSize: (52 * sf).clamp(44.0, 62.0),
                          onTap: _toggleMute,
                        ),
                        _OcCtrlBtn(
                          icon: _isSpeakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded,
                          label: 'Speaker',
                          isActive: _isSpeakerOn,
                          activeColor: const Color(0xFF2563EB),
                          btnSize: (52 * sf).clamp(44.0, 62.0),
                          onTap: () async {
                            final v = !_isSpeakerOn;
                            await Helper.setSpeakerphoneOn(v);
                            setState(() => _isSpeakerOn = v);
                          },
                        ),
                        _OcCtrlBtn(
                          icon: Icons.dialpad_rounded,
                          label: 'Keypad',
                          btnSize: (52 * sf).clamp(44.0, 62.0),
                          onTap: () => setState(() => _showKeypad = true),
                        ),
                      ],
                    ),
                  ),
                ),

              SizedBox(height: compact ? 16.0 : 28.0),

              // ── End call ─────────────────────────────────────────────────
              GestureDetector(
                onTap: () { HapticFeedback.heavyImpact(); _endCall(); },
                child: Container(
                  width:  (64 * sf).clamp(56.0, 74.0),
                  height: (64 * sf).clamp(56.0, 74.0),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(color: const Color(0xFFEF4444).withValues(alpha: 0.45), blurRadius: 20, spreadRadius: 2),
                    ],
                  ),
                  child: Icon(Icons.call_end_rounded, color: Colors.white, size: (30 * sf).clamp(24.0, 36.0)),
                ),
              ),

              SizedBox(height: compact ? 20.0 : 40.0),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        children: [
          _buildDtmfRow(['1', '2', '3']),
          const SizedBox(height: 6),
          _buildDtmfRow(['4', '5', '6']),
          const SizedBox(height: 6),
          _buildDtmfRow(['7', '8', '9']),
          const SizedBox(height: 6),
          _buildDtmfRow(['*', '0', '#']),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => setState(() => _showKeypad = false),
            icon: const Icon(Icons.keyboard_hide_rounded, size: 18, color: Color(0xFFB8BDC9)),
            label: const Text('Hide Keypad', style: TextStyle(color: Color(0xFFB8BDC9))),
          ),
        ],
      ),
    );
  }

  Widget _buildDtmfRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits.map((d) => DialButton(
        digit: d,
        onPressed: () => _sip.sendDTMF(d),
        backgroundColor: const Color(0xFF1C1E26),
        foregroundColor: Colors.white,
        letterColor: const Color(0xFF6B7280),
      )).toList(),
    );
  }
}

// ── Outgoing call control button ──────────────────────────────────────────────
class _OcCtrlBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final bool enabled;
  final Color activeColor;
  final double btnSize;
  final VoidCallback? onTap;

  const _OcCtrlBtn({
    required this.icon,
    required this.label,
    this.isActive = false,
    this.enabled = true,
    this.activeColor = const Color(0xFFEF4444),
    this.btnSize = 52,
    this.onTap,
  });

  @override
  State<_OcCtrlBtn> createState() => _OcCtrlBtnState();
}

class _OcCtrlBtnState extends State<_OcCtrlBtn> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
    _scale = Tween<double>(begin: 1.0, end: 0.90)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final iconColor = widget.isActive ? widget.activeColor : Colors.white;
    final bgColor = widget.isActive
        ? widget.activeColor.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.08);

    return GestureDetector(
      onTapDown: widget.enabled && widget.onTap != null ? (_) => _ctrl.forward() : null,
      onTapUp:   widget.enabled && widget.onTap != null ? (_) { _ctrl.reverse(); HapticFeedback.lightImpact(); widget.onTap!(); } : null,
      onTapCancel: () => _ctrl.reverse(),
      child: Opacity(
        opacity: widget.enabled ? 1.0 : 0.35,
        child: ScaleTransition(
          scale: _scale,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: widget.btnSize, height: widget.btnSize,
                decoration: BoxDecoration(
                  color: bgColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.isActive
                        ? widget.activeColor.withValues(alpha: 0.35)
                        : Colors.white.withValues(alpha: 0.12),
                    width: 1,
                  ),
                ),
                child: Icon(widget.icon, size: widget.btnSize * 0.46, color: iconColor),
              ),
              const SizedBox(height: 5),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  color: widget.isActive ? widget.activeColor : const Color(0xFFB8BDC9),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
