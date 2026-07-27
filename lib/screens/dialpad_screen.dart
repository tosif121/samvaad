import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'incoming_call_screen.dart';
import '../services/fcm_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'login_screen.dart';
import '../services/sip_socket_service.dart';
import '../services/ringtone_service.dart';
import '../services/callkit_service.dart';

import '../services/oem_optimization_service.dart';

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
  bool _isShowingKeypad = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  String _activeCallNumber = '';
  int _callSeconds = 0;
  Timer? _callTimer;
  String? _fcmToken;
  String? _username;

  String? _lastHandledNumber;
  DateTime? _lastHandledAt;

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    debugPrint('[SCREEN] DialpadScreen ACTIVE');
    super.initState();

    if (_sip.callState == CallState.onCall ||
        _sip.isAnswering ||
        _sip.shouldAutoAnswerNextCall ||
        CallKitService().isCallKitAnswering) {
      _isOnCall = true;
      _activeCallNumber = _sip.incomingNumber;
      _startCallTimer();
    }

    _initRenderers();
    WidgetsBinding.instance.addObserver(this);
    _initSip();
    _fetchFcmToken();
    _loadUsername();
    _phoneFocusNode.addListener(() {
      if (_phoneFocusNode.hasFocus) {
        _phoneFocusNode.unfocus();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      OemOptimizationService().checkAndShowOemGuidanceDialog(context);
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

      debugPrint('[DIALPAD] Lifecycle RESUMED. '
          'CallState: ${_sip.callState.name}, '
          'incomingNumber: ${_sip.incomingNumber}, '
          'isShowingDialog: $_isShowingIncomingDialog, '
          'isOnCall: $_isOnCall, '
          'recentlyHandled: $recentlyHandledSameNumber, '
          'isCallKitAnswering: ${CallKitService().isCallKitAnswering}, '
          'isAnswering: ${_sip.isAnswering}, '
          'shouldAutoAnswer: ${_sip.shouldAutoAnswerNextCall}');

      if (_sip.callState == CallState.ringing &&
          !_isShowingIncomingDialog &&
          !_isOnCall &&
          !recentlyHandledSameNumber &&
          !CallKitService().isCallKitAnswering &&
          !_sip.isAnswering &&
          !_sip.shouldAutoAnswerNextCall &&
          _sip.isRegistered) {
        _showIncomingCall(_sip.incomingNumber);
      }
    }
  }

  Future<bool> _requestPermissions({required bool isVideo}) async {
    final statuses =
        await [Permission.microphone, Permission.camera].request();
    final micStatus = statuses[Permission.microphone]!;
    final camStatus = statuses[Permission.camera]!;

    debugPrint(
        '[PERMISSION] mic: ${micStatus.isGranted}, cam: ${camStatus.isGranted}');
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
          if (_sip.callState == CallState.onCall) break;
          if (_sip.isAnswering || _sip.shouldAutoAnswerNextCall || CallKitService().isCallKitAnswering) {
            debugPrint('[DIALPAD] Skipping incomingCall event because call is being answered automatically or via notification');
            break;
          }

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
                _localRenderer.srcObject =
                    _sip.localStream as MediaStream?;
              }
              if (_remoteRenderer.srcObject != _sip.remoteStream) {
                _remoteRenderer.srcObject =
                    _sip.remoteStream as MediaStream?;
              }
            });
          }
          break;

        case 'callEnded':
        case 'callFailed':
          _isOnCall = false;
          _isShowingKeypad = false;
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

    debugPrint(
        '[DIALPAD] _showIncomingCall invoked for $number. '
        'CallID: $callId, CallState: $callState, '
        'isShowingDialog: $_isShowingIncomingDialog, '
        'isCallKitAnswering: ${CallKitService().isCallKitAnswering}, '
        'isAnswering: ${_sip.isAnswering}, '
        'shouldAutoAnswer: ${_sip.shouldAutoAnswerNextCall}, '
        'isOnCall: $_isOnCall');

    if (_isShowingIncomingDialog || CallKitService().isCallKitAnswering || _sip.isAnswering || _sip.shouldAutoAnswerNextCall) {
      debugPrint(
          '[DIALPAD] _showIncomingCall ABORTED: call is being answered automatically or via notification');
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

    if (result == 'answer' || result == 'answer_video') {
      final isVideoAns = result == 'answer_video';
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
      if (!await _requestPermissions(isVideo: isVideoAns)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content:
                    Text('Permissions are required to answer calls')),
          );
        }
        return;
      }
      await _sip.answerCall(isVideo: isVideoAns);
      _isOnCall = true;
      _startCallTimer();
      if (mounted) setState(() {});
    } else if (result == true) {
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
        0,
        _phoneController.text.length - 1,
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
          const SnackBar(
              content:
                  Text('Permissions are required to make calls')),
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
          const SnackBar(
              content:
                  Text('Permissions are required to make video calls')),
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
    final isOnActiveCall = _isOnCall ||
        _sip.callState == CallState.onCall ||
        _sip.isAnswering ||
        _sip.shouldAutoAnswerNextCall ||
        CallKitService().isCallKitAnswering;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(isOnActiveCall ? 'On Call' : 'Samvaad'),
            const SizedBox(width: 10),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _sip.isRegistered
                    ? const Color(0xFF00C853)
                    : (_sip.isConnected ? Colors.orange : Colors.red),
              ),
            ),
          ],
        ),
        titleSpacing: 16,
        centerTitle: false,
        automaticallyImplyLeading: false,
        actions: [
          if (!isOnActiveCall)
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.menu_rounded),
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
        ],
      ),
      drawer: isOnActiveCall ? null : _buildDrawer(),
      body: SafeArea(
        child: isOnActiveCall ? _buildOnCallUI() : _buildIdleUI(),
      ),
    );
  }

  Widget _buildDrawer() {
    final cs = Theme.of(context).colorScheme;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              width: double.infinity,
              color: cs.primary.withValues(alpha: 0.1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: cs.primary,
                    child: Text(
                      (_username != null && _username!.isNotEmpty)
                          ? _username![0].toUpperCase()
                          : 'U',
                      style: const TextStyle(
                        fontSize: 24,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _username ?? 'User',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(
                _sip.isRegistered
                    ? Icons.check_circle_rounded
                    : (_sip.isConnected
                        ? Icons.sync_rounded
                        : Icons.error_outline_rounded),
                color: _sip.isRegistered
                    ? cs.secondary
                    : (_sip.isConnected ? Colors.orange : cs.error),
              ),
              title: const Text('SIP Status'),
              subtitle: Text(
                _sip.isRegistered
                    ? 'Registered'
                    : (_sip.isConnected
                        ? 'Registering...'
                        : 'Disconnected — Tap to reconnect'),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () async {
                  setState(() {});
                  await _sip.connect();
                  if (mounted) setState(() {});
                },
              ),
              onTap: () async {
                setState(() {});
                await _sip.connect();
                if (mounted) setState(() {});
              },
            ),
            const Divider(),

            const Spacer(),
            const Divider(),
            ListTile(
              leading: Icon(Icons.logout_rounded, color: cs.error),
              title: Text('Logout', style: TextStyle(color: cs.error)),
              onTap: () async {
                await FcmService().removeTokenFromBackend();
                _sip.disconnect();
                await _sip.clearCredentials();
                if (!context.mounted) return;
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _sip.isRegistered
                  ? Theme.of(context).colorScheme.secondary
                  : Colors.orange,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _sip.isRegistered
                ? 'Ready'
                : _sip.isConnected
                    ? 'Registering...'
                    : 'Connecting...',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.5),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNumberDisplay() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
      padding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outline.withValues(alpha: 0.3)),
      ),
      constraints: const BoxConstraints(minHeight: 64),
      child: TextField(
        controller: _phoneController,
        focusNode: _phoneFocusNode,
        readOnly: true,
        showCursor: false,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          letterSpacing: 3,
          color: cs.onSurface,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
          hintText: 'Enter number',
          hintStyle: TextStyle(
            color: cs.onSurface.withValues(alpha: 0.25),
            fontSize: 20,
            letterSpacing: 0,
            fontWeight: FontWeight.w500,
          ),
          suffixIcon: GestureDetector(
            onTap: _onDeleteTap,
            onLongPress: _onClearTap,
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.surface,
                shape: BoxShape.circle,
                border: Border.all(
                  color: cs.outline.withValues(alpha: 0.3),
                ),
              ),
              child: Icon(
                Icons.backspace_outlined,
                size: 20,
                color: _phoneController.text.isEmpty
                    ? cs.onSurface.withValues(alpha: 0.15)
                    : cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildDialpadGrid() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildDialRow(['1', '2', '3']),
          _buildDialRow(['4', '5', '6']),
          _buildDialRow(['7', '8', '9']),
          _buildDialRow(['*', '0', '#']),
        ],
      ),
    );
  }

  Widget _buildDialpadKey(String key) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Material(
          color: cs.surface,
          borderRadius: BorderRadius.circular(16),
          elevation: 0,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _onDialPadTap(key),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: cs.outline.withValues(alpha: 0.15)),
              ),
              child: Text(
                key,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCallButtons() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24, top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Visibility(
            visible: false, // Hidden for VC-only mode
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildCallButton(
                  icon: Icons.call_rounded,
                  color: cs.secondary,
                  onTap: _onCallPressed,
                ),
                const SizedBox(width: 28),
              ],
            ),
          ),
          _buildCallButton(
            icon: Icons.videocam_rounded,
            color: cs.primary,
            onTap: _onVideoCallPressed,
          ),
        ],
      ),
    );
  }

  Widget _buildCallButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 68,
        height: 68,
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
        child: Icon(icon, color: Colors.white, size: 30),
      ),
    );
  }

  Widget _buildIdleUI() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > 640;
        final isTablet = constraints.maxWidth > 900;
        final dialpadMaxWidth = isTablet ? 440.0 : 380.0;

        if (isLandscape) {
          return Row(
            children: [
              Expanded(
                flex: 1,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildStatusIndicator(),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: isTablet ? 400 : null,
                        child: _buildNumberDisplay(),
                      ),
                      const SizedBox(height: 32),
                      _buildCallButtons(),
                      const SizedBox(height: 8),
                      _buildFcmTokenDisplay(),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 1,
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: dialpadMaxWidth),
                    child: _buildDialpadGrid(),
                  ),
                ),
              ),
            ],
          );
        }

        return Column(
          children: [
            _buildStatusIndicator(),
            _buildNumberDisplay(),
            Expanded(child: _buildDialpadGrid()),
            _buildCallButtons(),
            const SizedBox(height: 8),
            _buildFcmTokenDisplay(),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Future<void> _fetchFcmToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (mounted && token != null) {
        setState(() => _fcmToken = token);
      }
    } catch (e) {
      debugPrint('Error fetching FCM token: $e');
    }
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    final credsStr = prefs.getString('sip_credentials');
    if (credsStr != null) {
      final creds = jsonDecode(credsStr);
      if (mounted) {
        setState(() {
          _username = creds['username'];
        });
      }
    }
  }

  Widget _buildFcmTokenDisplay() {
    return const SizedBox.shrink();
  }

  Widget _buildDialRow(List<String> keys) {
    return Expanded(
      child: Row(
        children:
            keys.map((key) => _buildDialpadKey(key)).toList(),
      ),
    );
  }

  Widget _buildVideoView() {
    if (!_sip.isVideoCall) return const SizedBox.shrink();

    try {
      if (_remoteRenderer.textureId != null &&
          _remoteRenderer.srcObject != _sip.remoteStream &&
          _sip.remoteStream != null) {
        _remoteRenderer.srcObject = _sip.remoteStream as MediaStream?;
      }
      if (_localRenderer.textureId != null &&
          _localRenderer.srcObject != _sip.localStream &&
          _sip.localStream != null) {
        _localRenderer.srcObject = _sip.localStream as MediaStream?;
      }
    } catch (e) {
      debugPrint('[DIALPAD] Error setting renderer srcObject: $e');
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: _remoteRenderer.textureId != null
                ? RTCVideoView(
                    _remoteRenderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                : const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
          ),
        ),
        if (!_sip.isLocalVideoMuted)
          Positioned(
            right: 16,
            top: 48,
            width: 110,
            height: 150,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                    width: 2),
                borderRadius: BorderRadius.circular(14),
                color: Colors.black54,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: RTCVideoView(
                  _localRenderer,
                  mirror: true,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildOnCallUI() {
    final cs = Theme.of(context).colorScheme;
    final isVideo = _sip.isVideoCall;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;
        final isWide = constraints.maxWidth > 600;

        return Stack(
          fit: StackFit.expand,
          children: [
            _buildVideoView(),
            Positioned.fill(
              child: Container(
                decoration: isVideo
                    ? const BoxDecoration()
                    : BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            cs.surface,
                            cs.surface.withValues(alpha: 0.95),
                          ],
                        ),
                      ),
                child: SafeArea(
                  child: isVideo
                      ? _buildVideoCallContent(isLandscape, isWide)
                      : _buildAudioCallContent(isLandscape, isWide),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAudioCallContent(bool isLandscape, bool isWide) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        const Spacer(flex: 2),
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.08),
            shape: BoxShape.circle,
            border: Border.all(
              color: cs.primary.withValues(alpha: 0.2),
              width: 3,
            ),
          ),
          child: Icon(
            Icons.person,
            size: 60,
            color: cs.primary,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          _activeCallNumber.isEmpty ? 'Unknown' : _activeCallNumber,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: cs.secondary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.access_time_rounded,
                size: 18,
                color: cs.secondary,
              ),
              const SizedBox(width: 8),
              Text(
                _sip.isHeld ? 'On Hold' : _formattedTime,
                style: TextStyle(
                  fontSize: 18,
                  color: cs.secondary,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
        if (_isShowingKeypad) ...[
          const SizedBox(height: 16),
          SizedBox(
            height: 260,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isWide ? 120 : 32,
              ),
              child: Column(
                children: [
                  _buildDtmfRow(['1', '2', '3']),
                  _buildDtmfRow(['4', '5', '6']),
                  _buildDtmfRow(['7', '8', '9']),
                  _buildDtmfRow(['*', '0', '#']),
                ],
              ),
            ),
          ),
        ] else
          const Spacer(flex: 2),
        Center(
          child: _buildCallControls(
              isVideo: false, cs: cs, isLandscape: isLandscape),
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: _endCall,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: cs.error,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: cs.error.withValues(alpha: 0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.call_end_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildVideoCallContent(bool isLandscape, bool isWide) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 60),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.access_time_rounded,
                  size: 18,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Text(
                  _sip.isHeld ? 'On Hold' : _formattedTime,
                  style: const TextStyle(
                    fontSize: 18,
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        if (_isShowingKeypad) ...[
          SizedBox(
            height: 260,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isWide ? 120 : 32,
              ),
              child: Column(
                children: [
                  _buildDtmfRow(['1', '2', '3']),
                  _buildDtmfRow(['4', '5', '6']),
                  _buildDtmfRow(['7', '8', '9']),
                  _buildDtmfRow(['*', '0', '#']),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Center(
          child: _buildCallControls(
              isVideo: true, cs: cs, isLandscape: isLandscape),
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: _endCall,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: cs.error,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: cs.error.withValues(alpha: 0.35),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.call_end_rounded,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildCallControls({
    required bool isVideo,
    required ColorScheme cs,
    required bool isLandscape,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: isLandscape ? 12 : 16,
        runSpacing: 16,
        alignment: WrapAlignment.center,
        children: [
          if (isVideo) ...[
            _buildControlButton(
              icon: Icons.flip_camera_android_rounded,
              label: 'Flip',
              isActive: false,
              onPressed: () => _sip.switchCamera(),
              isVideo: isVideo,
            ),
            _buildControlButton(
              icon: _sip.isLocalVideoMuted
                  ? Icons.videocam_off_rounded
                  : Icons.videocam_rounded,
              label:
                  _sip.isLocalVideoMuted ? 'Show Video' : 'Hide Video',
              isActive: _sip.isLocalVideoMuted,
              onPressed: () {
                setState(() {
                  _sip.toggleVideo(!_sip.isLocalVideoMuted);
                });
              },
              isVideo: isVideo,
            ),
          ],
          _buildControlButton(
            icon:
                _sip.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: _sip.isMuted ? 'Unmute' : 'Mute',
            isActive: _sip.isMuted,
            onPressed: () {
              setState(() {
                _sip.mute(!_sip.isMuted);
              });
            },
            isVideo: isVideo,
          ),
          if (!isVideo)
            _buildControlButton(
              icon: _sip.isSpeakerOn
                  ? Icons.volume_up_rounded
                  : Icons.volume_down_rounded,
              label: 'Speaker',
              isActive: _sip.isSpeakerOn,
              onPressed: () {
                _sip.toggleSpeaker(!_sip.isSpeakerOn);
                setState(() {});
              },
              isVideo: isVideo,
            ),
          if (!isVideo)
            _buildControlButton(
              icon: _sip.isHeld
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded,
              label: _sip.isHeld ? 'Resume' : 'Hold',
              isActive: _sip.isHeld,
              onPressed: () {
                setState(() {
                  _sip.toggleHold(!_sip.isHeld);
                });
              },
              isVideo: isVideo,
            ),
        ],
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    bool isActive = false,
    VoidCallback? onPressed,
    required bool isVideo,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isOnDark = isVideo;
    final bgColor = isActive
        ? cs.primary
        : isOnDark
            ? Colors.white.withValues(alpha: 0.15)
            : Colors.grey.shade100;
    final fgColor = isActive
        ? Colors.white
        : isOnDark
            ? Colors.white
            : cs.onSurface;
    final labelColor = isActive
        ? cs.primary
        : isOnDark
            ? Colors.white.withValues(alpha: 0.7)
            : cs.onSurface.withValues(alpha: 0.6);
    final borderColor = isActive
        ? null
        : isOnDark
            ? null
            : Colors.grey.shade200;

    return GestureDetector(
      onTap: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: bgColor,
              shape: BoxShape.circle,
              border: borderColor != null
                  ? Border.all(color: borderColor, width: 1)
                  : null,
              boxShadow: [
                if (!isOnDark)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                if (isActive)
                  BoxShadow(
                    color: cs.primary.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
              ],
            ),
            child: Icon(icon, size: 24, color: fgColor),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
              color: labelColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDtmfKey(String key) {
    final isVideo = _sip.isVideoCall;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Material(
          color: Colors.white.withValues(alpha: isVideo ? 0.1 : 0.08),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _sip.sendDTMF(key),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.1),
                ),
              ),
              child: Text(
                key,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDtmfRow(List<String> keys) {
    return Expanded(
      child: Row(
        children:
            keys.map((key) => _buildDtmfKey(key)).toList(),
      ),
    );
  }
}
