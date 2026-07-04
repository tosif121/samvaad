import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'incoming_call_screen.dart';
import 'login_screen.dart';
import '../services/sip_socket_service.dart';
import '../services/ringtone_service.dart';

class DialpadScreen extends StatefulWidget {
  const DialpadScreen({super.key});

  @override
  State<DialpadScreen> createState() => _DialpadScreenState();
}

class _DialpadScreenState extends State<DialpadScreen>
    with WidgetsBindingObserver {
  final _sip = SipSocketService();
  StreamSubscription? _sipSubscription;
  final _phoneController = TextEditingController();
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  final _phoneFocusNode = FocusNode();
  bool _isShowingIncomingDialog = false;
  bool _isOnCall = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  String _activeCallNumber = '';
  int _callSeconds = 0;
  Timer? _callTimer;

  // Guards against re-showing the incoming call screen for a call that was
  // just manually declined/answered, in case a lifecycle resume event
  // fires before SipSocketService's callState has fully settled.
  String? _lastHandledNumber;
  DateTime? _lastHandledAt;

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  @override
  void initState() {
    debugPrint('[SCREEN] DialpadScreen ACTIVE');
    super.initState();
    _initRenderers();
    WidgetsBinding.instance.addObserver(this);
    _initSip();
    _phoneFocusNode.addListener(() {
      if (_phoneFocusNode.hasFocus) {
        _phoneFocusNode.unfocus();
      }
    });

  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      RingtoneService().clearNotification();

      final recentlyHandledSameNumber = _lastHandledNumber != null &&
          _lastHandledNumber == _sip.incomingNumber &&
          _lastHandledAt != null &&
          DateTime.now().difference(_lastHandledAt!) <
              const Duration(seconds: 3);

      if (_sip.callState == CallState.ringing &&
          !_isShowingIncomingDialog &&
          !_isOnCall &&
          !recentlyHandledSameNumber &&
          _sip.isRegistered) {
        _showIncomingCall(_sip.incomingNumber);
      }
    }
  }



  Future<bool> _requestPermissions({required bool isVideo}) async {
    final statuses = await [Permission.microphone, Permission.camera].request();
    final micStatus = statuses[Permission.microphone]!;
    final camStatus = statuses[Permission.camera]!;
    
    debugPrint('[PERMISSION] mic: ${micStatus.isGranted}, cam: ${camStatus.isGranted}');
    if (isVideo && !camStatus.isGranted) return false;
    return micStatus.isGranted;
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _sipSubscription?.cancel();
    _callTimer?.cancel();
    _phoneController.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initSip() async {
    _sipSubscription = _sip.events.listen((event) async {
      if (!mounted) return;
      final type = event['event'] as String;
      debugPrint('[DIALPAD] Received SIP Event: $type');

      switch (type) {
        case 'incomingCall':
          final number = event['number'] as String? ?? 'Unknown';
          if (_isOnCall) break;
          if (_isShowingIncomingDialog) break;

          final recentlyHandledSameNumber = _lastHandledNumber == number &&
              _lastHandledAt != null &&
              DateTime.now().difference(_lastHandledAt!) <
                  const Duration(seconds: 3);
          if (recentlyHandledSameNumber) {
            await _sip.rejectCall();
            break;
          }

          RingtoneService().stopRinging();

          if (_appLifecycleState != AppLifecycleState.resumed) {
            if (_isShowingIncomingDialog && mounted) {
              Navigator.of(context).pop();
              _isShowingIncomingDialog = false;
            }
          } else {
            _showIncomingCall(number);
          }
          break;

        case 'callAnswered':
          _isShowingIncomingDialog = false;
          _isOnCall = true;
          _lastHandledNumber = _sip.incomingNumber;
          _lastHandledAt = DateTime.now();
          if (_activeCallNumber.isEmpty) {
            _activeCallNumber = _sip.incomingNumber;
          }
          RingtoneService().stopRinging();
          _startCallTimer();
          if (mounted) setState(() {});
          break;

        case 'streamAdded':
          if (mounted) {
            setState(() {
              if (_localRenderer.srcObject != _sip.localStream) {
                _localRenderer.srcObject = _sip.localStream as MediaStream?;
              }
              if (_remoteRenderer.srcObject != _sip.remoteStream) {
                _remoteRenderer.srcObject = _sip.remoteStream as MediaStream?;
              }
            });
          }
          break;

        case 'callEnded':
        case 'callFailed':
          _isOnCall = false;
          _isShowingIncomingDialog = false;
          _lastHandledNumber = _activeCallNumber.isNotEmpty
              ? _activeCallNumber
              : _sip.incomingNumber;
          _lastHandledAt = DateTime.now();
          _activeCallNumber = '';
          _callTimer?.cancel();
          _callSeconds = 0;
          RingtoneService().stopRinging();
          if (mounted) setState(() {});
          break;

        case 'registered':
          if (mounted) setState(() {});
          break;

        case 'registrationFailed':
          if (mounted) setState(() {});
          break;

        default:
          if (mounted) setState(() {});
      }
    });

    await _sip.connect();
    if (mounted) setState(() {});
  }

  void _startCallTimer() {
    _callTimer?.cancel();
    _callTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isOnCall) {
        setState(() => _callSeconds++);
      } else {
        timer.cancel();
      }
    });
  }

  String get _formattedTime {
    final m = (_callSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_callSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _showIncomingCall(String number) async {
    final callId = _sip.activeCallId ?? 'unknown_id';
    final callState = _sip.callState.name;
    debugPrint('[DIALPAD] _showIncomingCall invoked for $number. Call ID: $callId, State: $callState');

    if (_isShowingIncomingDialog) {
      debugPrint('[DIALPAD] _showIncomingCall aborted: _isShowingIncomingDialog is true');
      return;
    }
    if (_isOnCall) {
      debugPrint('[DIALPAD] _showIncomingCall aborted: _isOnCall is true');
      return;
    }
    _isShowingIncomingDialog = true;
    RingtoneService().cleanupForegroundService();
    await Future.delayed(const Duration(milliseconds: 200));
    RingtoneService().startRinging();
    RingtoneService().clearNotification();

    if (!mounted) return;
    final result = await showGeneralDialog<dynamic>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      pageBuilder: (ctx, anim, secondaryAnim) => IncomingCallScreen(
        phoneNumber: number,
        onDismiss: () => _isShowingIncomingDialog = false,
      ),
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        return FadeTransition(opacity: anim, child: child);
      },
    );

    _isShowingIncomingDialog = false;
    _lastHandledNumber = number;
    _lastHandledAt = DateTime.now();

    if (result == 'answer') {
      if (!_sip.isRegistered) {
        int waitCount = 0;
        while (!_sip.isRegistered && mounted) {
          await Future.delayed(const Duration(milliseconds: 100));
          waitCount++;
          if (waitCount > 50) break;
        }
      }
      if (!mounted) return;
      RingtoneService().clearNotification();
      _activeCallNumber = number;
      if (!await _requestPermissions(isVideo: false)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permissions are required to answer calls')),
          );
        }
        return;
      }
      await _sip.answerCall();
      _isOnCall = true;
      _startCallTimer();
      if (mounted) setState(() {});
    } else if (result == true) {
      // call was already answered (via callAnswered event)
      RingtoneService().clearNotification();
      _isOnCall = true;
      _startCallTimer();
      if (mounted) setState(() {});
    } else {
      RingtoneService().clearNotification();
    }
  }

  void _onDialPadTap(String value) {
    if (_phoneController.text.length < 10) {
      _phoneController.text += value;
    }
  }

  void _onDeleteTap() {
    if (_phoneController.text.isNotEmpty) {
      _phoneController.text = _phoneController.text.substring(
        0, _phoneController.text.length - 1,
      );
    }
  }

  void _onClearTap() {
    _phoneController.clear();
  }

  Future<void> _onCallPressed() async {
    final number = _phoneController.text.trim();
    if (number.isEmpty) return;
    if (!await _requestPermissions(isVideo: false)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permissions are required to make calls')),
        );
      }
      return;
    }
    _activeCallNumber = number;
    _isOnCall = true;
    _phoneController.clear();
    _sip.makeCall(number);
    setState(() {});
  }

  Future<void> _onVideoCallPressed() async {
    final number = _phoneController.text.trim();
    if (number.isEmpty) return;
    if (!await _requestPermissions(isVideo: true)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permissions are required to make video calls')),
        );
      }
      return;
    }
    _activeCallNumber = number;
    _isOnCall = true;
    _phoneController.clear();
    _sip.makeVideoCall(number);
    setState(() {});
  }

  Future<void> _endCall() async {
    await _sip.endCall();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isOnCall ? 'On Call' : 'Samvaad'),
        titleSpacing: 16,
        automaticallyImplyLeading: false,
        actions: [
          if (!_isOnCall)
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () async {
                _sip.disconnect();
                await _sip.clearCredentials();
                if (mounted) {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  );
                }
              },
              tooltip: 'Logout',
            ),
        ],
      ),
      body: SafeArea(
        child: _isOnCall ? _buildOnCallUI() : _buildIdleUI(),
      ),
    );
  }

  Widget _buildIdleUI() {
    return Column(
      children: [
        // Status indicator
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _sip.isRegistered ? Icons.check_circle : Icons.hourglass_empty,
                size: 14,
                color: _sip.isRegistered ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 6),
              Text(
                _sip.isRegistered
                    ? 'Ready'
                    : _sip.isConnected
                        ? 'Registering...'
                        : 'Connecting...',
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              ),
            ],
          ),
        ),

        // Number display
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: _phoneController,
            focusNode: _phoneFocusNode,
            readOnly: true,
            showCursor: false,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500, letterSpacing: 2),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: 'Enter number',
              hintStyle: const TextStyle(color: Colors.grey, fontSize: 20),
              suffixIcon: GestureDetector(
                onTap: _onDeleteTap,
                onLongPress: _onClearTap,
                child: Icon(
                  Icons.backspace_outlined,
                  color: _phoneController.text.isEmpty ? Colors.grey[300] : Colors.grey[600],
                ),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),

        // Dialpad grid
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildDialRow(['1', '2', '3']),
                _buildDialRow(['4', '5', '6']),
                _buildDialRow(['7', '8', '9']),
                _buildDialRow(['*', '0', '#']),
              ],
            ),
          ),
        ),

        // Call button and status
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: _onCallPressed,
                    child: Container(
                      width: 64,
                      height: 64,
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
                      child: const Icon(Icons.call, color: Colors.white, size: 32),
                    ),
                  ),
                  const SizedBox(width: 32),
                  GestureDetector(
                    onTap: _onVideoCallPressed,
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blue.withValues(alpha: 0.4),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.videocam, color: Colors.white, size: 32),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDialRow(List<String> keys) {
    return Expanded(
      child: Row(
        children: keys.map((key) => Expanded(
          child: GestureDetector(
            onTap: () => _onDialPadTap(key),
            child: Container(
              margin: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                key,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        )).toList(),
      ),
    );
  }

  Widget _buildVideoView() {
    if (!_sip.isVideoCall) return const SizedBox.shrink();
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
        ),
        if (!_sip.isLocalVideoMuted)
          Positioned(
            right: 20,
            top: 20,
            width: 120,
            height: 160,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white24, width: 2),
                borderRadius: BorderRadius.circular(12),
                color: Colors.black54,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: RTCVideoView(
                  _localRenderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildOnCallUI() {
    return Stack(
      children: [
        _buildVideoView(),
        Column(
          children: [
            if (!_sip.isVideoCall) ...[
              const SizedBox(height: 48),
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFF4299EB).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF4299EB).withValues(alpha: 0.4),
                    width: 3,
                  ),
                ),
                child: const Icon(
                  Icons.person,
                  size: 42,
                  color: Color(0xFF4299EB),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _activeCallNumber,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1a1a1a),
                  letterSpacing: 1,
                ),
              ),
            ],
            if (_sip.isVideoCall) const SizedBox(height: 48),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: _sip.isVideoCall ? Colors.black54 : Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.access_time, size: 16, color: _sip.isVideoCall ? Colors.white : Colors.green),
                  const SizedBox(width: 6),
                  Text(
                    _formattedTime,
                    style: TextStyle(
                      fontSize: 16,
                      color: _sip.isVideoCall ? Colors.white : Colors.green,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (_sip.isVideoCall) ...[
                    _buildControlButton(
                      icon: Icons.switch_camera,
                      label: 'Flip',
                      isActive: false,
                      onPressed: () => _sip.switchCamera(),
                    ),
                    _buildControlButton(
                      icon: _sip.isLocalVideoMuted ? Icons.videocam_off : Icons.videocam,
                      label: _sip.isLocalVideoMuted ? 'Show Video' : 'Hide Video',
                      isActive: _sip.isLocalVideoMuted,
                      onPressed: () {
                        setState(() {
                          _sip.toggleVideo(!_sip.isLocalVideoMuted);
                        });
                      },
                    ),
                  ],
                  _buildControlButton(
                    icon: _sip.isMuted ? Icons.mic_off : Icons.mic,
                    label: _sip.isMuted ? 'Unmute' : 'Mute',
                    isActive: _sip.isMuted,
                    onPressed: () {
                      setState(() {
                        _sip.mute(!_sip.isMuted);
                      });
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: _endCall,
              child: Container(
                width: 60,
                height: 60,
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
                child: const Icon(Icons.call_end, color: Colors.white, size: 32),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ],
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    bool isActive = false,
    VoidCallback? onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: isActive ? const Color(0xFF4299EB) : Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(
              icon,
              size: 24,
              color: isActive ? Colors.white : const Color(0xFF4299EB),
            ),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ],
      ),
    );
  }
}