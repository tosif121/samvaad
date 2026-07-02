import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/sip_socket_service.dart';
import '../services/ringtone_service.dart';

const _kNativeChannel = MethodChannel('com.samwad/ringtone');

// ─── Design tokens ──────────────────────────────────────────────────────────
const _kBlue      = Color(0xFF2563EB);
const _kBlueLt    = Color(0xFF3B82F6);
const _kRed       = Color(0xFFEF4444);
const _kBg        = Color(0xFF0F1115);
const _kSurface   = Color(0xFF181A20);
const _kDivider   = Color(0xFF2A2D36);
const _kTextSec   = Color(0xFFB8BDC9);

class VideoCallScreen extends StatefulWidget {
  final String phoneNumber;
  const VideoCallScreen({super.key, required this.phoneNumber});

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final SipSocketService _sip = SipSocketService();
  final RTCVideoRenderer _localRenderer  = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  // ── State ──────────────────────────────────────────────────────────────────
  bool _isConnected   = false;
  bool _isMuted       = false;
  bool _isCameraOff   = false;
  bool _isEndingCall  = false;
  bool _isFrontCamera = true;
  bool _renderersReady = false;
  bool _swapped       = false;
  bool _controlsVisible = true;
  bool _isInPip       = false;
  int  _seconds       = 0;

  // PIP drag position
  Offset _pipOffset = const Offset(0, 0);
  bool _pipPositioned = false;

  StreamSubscription? _sipSubscription;
  Timer? _timer;
  Timer? _streamPollTimer;
  Timer? _controlsHideTimer;

  // Animations
  late AnimationController _pulseCtrl;
  late Animation<double>    _pulseAnim;
  late AnimationController _controlsCtrl;
  late Animation<double>    _controlsAnim;
  late AnimationController _connectCtrl;
  late Animation<double>    _connectAnim;

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addObserver(this);
    RingtoneService().stopRinging();
    RingtoneService().clearNotification();
    RingtoneService().cleanupForegroundService();
    FlutterCallkitIncoming.endAllCalls();

    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _controlsCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
    _controlsAnim = CurvedAnimation(parent: _controlsCtrl, curve: Curves.easeOut);
    _controlsCtrl.value = 1.0;

    _connectCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _connectAnim = CurvedAnimation(parent: _connectCtrl, curve: Curves.easeOut);

    _initRenderers();
    _scheduleControlsHide();
    // Tell native layer a call screen is open (enables auto-PiP on home press)
    _kNativeChannel.invokeMethod('setCallActive', {'active': true}).catchError((_) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      // Give the EGL surface a moment to settle after PiP/background before re-binding streams
      Future.delayed(const Duration(milliseconds: 300), _attachStreams);
      if (_isInPip) setState(() => _isInPip = false);
    } else if (state == AppLifecycleState.inactive) {
      // User pressed home / switched app during active call — enter PiP
      if (_isConnected && !_isInPip) {
        setState(() => _isInPip = true);
        _kNativeChannel.invokeMethod('enterPip').catchError((_) {});
      }
    }
  }

  // ── Renderers + SIP events ─────────────────────────────────────────────────
  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (!mounted) return;
    setState(() => _renderersReady = true);
    _attachStreams();

    if (_sip.callState == CallState.onCall) {
      setState(() => _isConnected = true);
      _connectCtrl.forward();
      _startTimer();
      _startStreamPoll();
    }

    _sipSubscription = _sip.events.listen((event) {
      if (!mounted) return;
      final type = event['event'] as String;
      switch (type) {
        case 'callAnswered':
          setState(() => _isConnected = true);
          _connectCtrl.forward();
          _startTimer();
          _attachStreams();
          _startStreamPoll();
          break;
        case 'streamUpdated':
          _attachStreams();
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

  void _attachStreams() {
    if (!mounted || !_renderersReady) return;
    final local  = _sip.localStream;
    final remote = _sip.remoteStream;
    bool changed = false;
    if (local  != null && _localRenderer.srcObject  != local)  { _localRenderer.srcObject  = local;  changed = true; }
    if (remote != null && _remoteRenderer.srcObject != remote) { _remoteRenderer.srcObject = remote; changed = true; }
    if (changed && mounted) setState(() {});
  }

  void _startStreamPoll() {
    _streamPollTimer?.cancel();
    int ticks = 0;
    _streamPollTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      ticks++;
      _attachStreams();
      if (ticks >= 20) t.cancel();
    });
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  String get _formattedTime {
    final h = _seconds ~/ 3600;
    final m = (_seconds % 3600) ~/ 60;
    final s = _seconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2,'0')}:${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
    }
    return '${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
  }

  // ── Controls auto-hide ─────────────────────────────────────────────────────
  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    if (!_controlsVisible) return;
    _controlsHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isConnected) _hideControls();
    });
  }

  void _showControls() {
    if (_controlsVisible) { _scheduleControlsHide(); return; }
    setState(() => _controlsVisible = true);
    _controlsCtrl.forward();
    _scheduleControlsHide();
  }

  void _hideControls() {
    if (!mounted) return;
    setState(() => _controlsVisible = false);
    _controlsCtrl.reverse();
  }

  // ── Call actions ───────────────────────────────────────────────────────────
  void _toggleMute() {
    HapticFeedback.lightImpact();
    _sip.mute(!_sip.isMuted);
    setState(() => _isMuted = _sip.isMuted);
  }

  Future<void> _toggleCamera() async {
    HapticFeedback.lightImpact();
    final stream = _sip.localStream;
    if (stream == null) return;
    for (final t in stream.getVideoTracks()) { t.enabled = _isCameraOff; }
    setState(() => _isCameraOff = !_isCameraOff);
  }

  Future<void> _switchCamera() async {
    HapticFeedback.lightImpact();
    final stream = _sip.localStream;
    if (stream == null) return;
    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
      setState(() => _isFrontCamera = !_isFrontCamera);
    } catch (e) { debugPrint('[VideoCall] switchCamera: $e'); }
  }

  Future<void> _endCall() async {
    HapticFeedback.heavyImpact();
    _isEndingCall = true;
    await _sip.endCall();
    if (mounted) Navigator.of(context).pop();
  }

  void _showErrorAndPop(String? reason) {
    if (!mounted) return;
    _isEndingCall = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Call Failed', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        content: Text(_friendlyError(reason), style: const TextStyle(color: _kTextSec)),
        actions: [
          TextButton(
            onPressed: () { Navigator.of(ctx).pop(); if (mounted) Navigator.of(context).pop(); },
            child: const Text('OK', style: TextStyle(color: _kBlue, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  String _friendlyError(String? reason) {
    if (reason == null) return 'Call could not be connected.';
    if (reason.contains('404')) return 'Extension not found (404).';
    if (reason.contains('408')) return 'Request timed out (408).';
    if (reason.contains('480')) return 'Temporarily unavailable (480).';
    if (reason.contains('486')) return 'User is busy (486).';
    if (reason.contains('487')) return 'Call cancelled.';
    if (reason.contains('403')) return 'Not authorized (403).';
    if (reason.contains('503')) return 'Service unavailable (503).';
    return 'Call failed: $reason';
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.removeObserver(this);
    // Tell native layer call screen is gone
    _kNativeChannel.invokeMethod('setCallActive', {'active': false}).catchError((_) {});
    _sipSubscription?.cancel();
    _timer?.cancel();
    _streamPollTimer?.cancel();
    _controlsHideTimer?.cancel();
    _pulseCtrl.dispose();
    _controlsCtrl.dispose();
    _connectCtrl.dispose();
    // Detach streams before disposing renderers to prevent EGL renderer errors
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final size       = MediaQuery.of(context).size;
    final mq         = MediaQuery.of(context);
    // Responsive scale factor: 1.0 at 360dp width, scales proportionally
    final sf         = (size.width / 360.0).clamp(0.8, 1.3);
    final pipW       = (110 * sf).roundToDouble();
    final pipH       = (160 * sf).roundToDouble();
    final panelH     = (90  * sf).clamp(78.0, 110.0);
    final ctrlBtnSz  = (52  * sf).clamp(44.0, 64.0).roundToDouble();
    final ctrlIconSz = (24  * sf).clamp(20.0, 30.0).roundToDouble();
    final ctrlFontSz = (11  * sf).clamp(9.0, 13.0);
    final bottomPad  = (mq.padding.bottom > 0 ? 12.0 : 24.0);

    final hasRemote  = _renderersReady && _remoteRenderer.srcObject != null;
    final hasLocal   = _renderersReady && _localRenderer.srcObject  != null && !_isCameraOff;
    final fsRenderer = _swapped ? _localRenderer  : _remoteRenderer;
    final pipRenderer= _swapped ? _remoteRenderer : _localRenderer;
    final fsMirror   = _swapped && _isFrontCamera;
    final pipMirror  = !_swapped && _isFrontCamera;
    final hasFull    = _swapped ? hasLocal  : hasRemote;
    final hasPip     = _swapped ? hasRemote : hasLocal;

    // Default PIP position — top-right below status bar
    if (!_pipPositioned) {
      _pipOffset = Offset(size.width - pipW - 16.0, 100.0 + mq.padding.top);
    }

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: _kBg,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _showControls,
          child: Stack(
            fit: StackFit.expand,
            children: [

              // ── Full-screen video / waiting ──────────────────────────────
              hasFull
                  ? RTCVideoView(
                      fsRenderer,
                      mirror: fsMirror,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : _WaitingBackground(
                      phoneNumber: widget.phoneNumber,
                      isConnected: _isConnected,
                      pulseAnim: _pulseAnim,
                    ),

              // ── Top scrim ───────────────────────────────────────────────
              Positioned(
                top: 0, left: 0, right: 0, height: (size.height * 0.28).clamp(140.0, 220.0),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xCC000000), Colors.transparent],
                    ),
                  ),
                ),
              ),

              // ── Bottom scrim ─────────────────────────────────────────────
              Positioned(
                bottom: 0, left: 0, right: 0, height: (size.height * 0.32).clamp(180.0, 280.0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xDD000000), Colors.transparent],
                    ),
                  ),
                ),
              ),

              // ── Draggable PIP ────────────────────────────────────────────
              if (hasPip)
                Positioned(
                  left: _pipOffset.dx,
                  top:  _pipOffset.dy,
                  child: _DraggablePip(
                    renderer: pipRenderer,
                    mirror:   pipMirror,
                    width: pipW,
                    height: pipH,
                    onTap: () => setState(() => _swapped = !_swapped),
                    onDragUpdate: (delta) {
                      setState(() {
                        _pipPositioned = true;
                        _pipOffset = Offset(
                          (_pipOffset.dx + delta.dx).clamp(8.0, size.width  - pipW - 8.0),
                          (_pipOffset.dy + delta.dy).clamp(8.0, size.height - pipH - 8.0),
                        );
                      });
                    },
                  ),
                ),

              // ── Top bar (fade with controls) ─────────────────────────────
              Positioned(
                top: 0, left: 0, right: 0,
                child: FadeTransition(
                  opacity: _controlsAnim,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: Row(
                        children: [
                          // Back / minimize
                          _GlassIconButton(
                            icon: Icons.keyboard_arrow_down_rounded,
                            size: 26,
                            onTap: () {
                              Navigator.of(context).pop();
                            },
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.phoneNumber,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.3,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 3),
                                FadeTransition(
                                  opacity: _connectAnim,
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 7, height: 7,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF22C55E),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        _formattedTime,
                                        style: const TextStyle(
                                          color: Color(0xFF22C55E),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (!_isConnected)
                                  const Text(
                                    'Connecting...',
                                    style: TextStyle(color: Color(0xFFF59E0B), fontSize: 13, fontWeight: FontWeight.w500),
                                  ),
                              ],
                            ),
                          ),
                          // HD / encryption badge
                          if (_isConnected)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white24, width: 0.5),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(Icons.hd_rounded, color: Colors.white70, size: 14),
                                  SizedBox(width: 4),
                                  Icon(Icons.lock_rounded, color: Colors.white70, size: 12),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ── Bottom glass control panel ────────────────────────────────
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: FadeTransition(
                  opacity: _controlsAnim,
                  child: SafeArea(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPad),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Glass panel
                          ClipRRect(
                            borderRadius: BorderRadius.circular(28),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                              child: Container(
                                height: panelH,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(28),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 0.5),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                  children: [
                                    _CtrlButton(
                                      icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                                      label: _isMuted ? 'Unmute' : 'Mute',
                                      isActive: _isMuted,
                                      activeColor: _kRed,
                                      btnSize: ctrlBtnSz,
                                      iconSize: ctrlIconSz,
                                      fontSize: ctrlFontSz,
                                      onTap: _toggleMute,
                                    ),
                                    _CtrlButton(
                                      icon: _isCameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded,
                                      label: _isCameraOff ? 'Start' : 'Camera',
                                      isActive: _isCameraOff,
                                      activeColor: _kRed,
                                      btnSize: ctrlBtnSz,
                                      iconSize: ctrlIconSz,
                                      fontSize: ctrlFontSz,
                                      onTap: _toggleCamera,
                                    ),
                                    _CtrlButton(
                                      icon: Icons.flip_camera_android_rounded,
                                      label: 'Flip',
                                      btnSize: ctrlBtnSz,
                                      iconSize: ctrlIconSz,
                                      fontSize: ctrlFontSz,
                                      onTap: _switchCamera,
                                    ),
                                    _CtrlButton(
                                      icon: Icons.volume_up_rounded,
                                      label: 'Speaker',
                                      btnSize: ctrlBtnSz,
                                      iconSize: ctrlIconSz,
                                      fontSize: ctrlFontSz,
                                      onTap: () {},
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: (16 * sf).clamp(12.0, 24.0)),
                          // End call
                          _EndCallButton(onTap: _endCall, size: (64 * sf).clamp(56.0, 72.0)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Waiting / no-video background ─────────────────────────────────────────────
class _WaitingBackground extends StatelessWidget {
  final String phoneNumber;
  final bool isConnected;
  final Animation<double> pulseAnim;

  const _WaitingBackground({
    required this.phoneNumber,
    required this.isConnected,
    required this.pulseAnim,
  });

  @override
  Widget build(BuildContext context) {
    final w  = MediaQuery.of(context).size.width;
    final sf = (w / 360.0).clamp(0.8, 1.3);
    final r1 = (160 * sf).roundToDouble();
    final r2 = (130 * sf).roundToDouble();
    final r3 = (100 * sf).roundToDouble();
    final ic = (52  * sf).clamp(40.0, 64.0);

    return Container(
      color: _kBg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: pulseAnim,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: r1, height: r1,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _kBlue.withValues(alpha: 0.06),
                    ),
                  ),
                  Container(
                    width: r2, height: r2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _kBlue.withValues(alpha: 0.10),
                    ),
                  ),
                  Container(
                    width: r3, height: r3,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _kSurface,
                      border: Border.all(color: _kBlueLt.withValues(alpha: 0.6), width: 2),
                    ),
                    child: Icon(Icons.person_rounded, size: ic, color: _kBlueLt),
                  ),
                ],
              ),
            ),
            SizedBox(height: (24 * sf).clamp(16.0, 32.0)),
            Text(
              phoneNumber,
              style: TextStyle(
                color: Colors.white,
                fontSize: (26 * sf).clamp(20.0, 30.0),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 10),
            if (!isConnected)
              const Text('Calling...', style: TextStyle(color: _kTextSec, fontSize: 15))
            else
              const Text('Waiting for video...', style: TextStyle(color: _kTextSec, fontSize: 15)),
            if (!isConnected) ...[
              const SizedBox(height: 20),
              SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _kBlueLt.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Draggable PIP ──────────────────────────────────────────────────────────────
class _DraggablePip extends StatelessWidget {
  final RTCVideoRenderer renderer;
  final bool mirror;
  final double width;
  final double height;
  final VoidCallback onTap;
  final void Function(Offset delta) onDragUpdate;

  const _DraggablePip({
    required this.renderer,
    required this.mirror,
    required this.width,
    required this.height,
    required this.onTap,
    required this.onDragUpdate,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onPanUpdate: (d) => onDragUpdate(d.delta),
      child: Container(
        width: width, height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 1),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 16, offset: const Offset(0, 4)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Stack(
            fit: StackFit.expand,
            children: [
              RTCVideoView(
                renderer,
                mirror: mirror,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
              // Swap hint
              Positioned(
                bottom: 6, right: 6,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.swap_vert_rounded, size: 13, color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Glass icon button ─────────────────────────────────────────────────────────
class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;

  const _GlassIconButton({required this.icon, required this.size, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 0.5),
        ),
        child: Icon(icon, color: Colors.white, size: size),
      ),
    );
  }
}

// ── Control button ────────────────────────────────────────────────────────────
class _CtrlButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final double btnSize;
  final double iconSize;
  final double fontSize;
  final VoidCallback? onTap;

  const _CtrlButton({
    required this.icon,
    required this.label,
    this.isActive = false,
    this.activeColor = _kRed,
    this.btnSize  = 52,
    this.iconSize = 24,
    this.fontSize = 11,
    this.onTap,
  });

  @override
  State<_CtrlButton> createState() => _CtrlButtonState();
}

class _CtrlButtonState extends State<_CtrlButton> with SingleTickerProviderStateMixin {
  late AnimationController _pressCtrl;
  late Animation<double> _pressAnim;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
    _pressAnim = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _pressCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _pressCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.isActive
        ? widget.activeColor.withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.10);
    final iconColor = widget.isActive ? widget.activeColor : Colors.white;

    return GestureDetector(
      onTapDown: (_) => _pressCtrl.forward(),
      onTapUp: (_) { _pressCtrl.reverse(); widget.onTap?.call(); },
      onTapCancel: () => _pressCtrl.reverse(),
      child: ScaleTransition(
        scale: _pressAnim,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: widget.btnSize, height: widget.btnSize,
              decoration: BoxDecoration(
                color: bgColor,
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.isActive ? widget.activeColor.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.15),
                  width: 1,
                ),
              ),
              child: Icon(widget.icon, size: widget.iconSize, color: iconColor),
            ),
            const SizedBox(height: 4),
            Text(
              widget.label,
              style: TextStyle(
                color: widget.isActive ? widget.activeColor : Colors.white70,
                fontSize: widget.fontSize,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── End Call Button ───────────────────────────────────────────────────────────
class _EndCallButton extends StatefulWidget {
  final VoidCallback onTap;
  final double size;
  const _EndCallButton({required this.onTap, this.size = 64});

  @override
  State<_EndCallButton> createState() => _EndCallButtonState();
}

class _EndCallButtonState extends State<_EndCallButton> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 120));
    _anim = Tween<double>(begin: 1.0, end: 0.9).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
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
        scale: _anim,
        child: Container(
          width: widget.size, height: widget.size,
          decoration: BoxDecoration(
            color: _kRed,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: _kRed.withValues(alpha: 0.45), blurRadius: 24, spreadRadius: 2),
            ],
          ),
          child: Icon(Icons.call_end_rounded, color: Colors.white, size: widget.size * 0.46),
        ),
      ),
    );
  }
}
