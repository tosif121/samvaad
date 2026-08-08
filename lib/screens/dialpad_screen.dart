import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'incoming_call_screen.dart';
import '../services/fcm_service.dart';
import 'login_screen.dart';
import '../models/call_log_entry.dart';
import '../services/call_log_service.dart';
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
  final _callLog = CallLogService();
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
  String? _username;

  int _tabIndex = 0;
  CallLogEntry? _activeLogEntry;
  bool _callWasAnswered = false;
  String _callBridgeId = '';
  String? _currentBreak;
  DateTime? _breakStartedAt;
  Timer? _breakTimer;
  bool _dispositionShowing = false;

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
    _callLog.load();
    _loadUsername();
    _restoreBreakState();
    _phoneFocusNode.addListener(() {
      if (_phoneFocusNode.hasFocus) {
        _phoneFocusNode.unfocus();
      }
    });
  }

  Future<void> _restoreBreakState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('selectedBreak');
      if (saved != null && saved.isNotEmpty && saved != 'Break') {
        final startRaw = prefs.getString('breakStartTime_$saved');
        final startedAt = startRaw != null
            ? DateTime.tryParse(startRaw)
            : null;
        if (mounted) {
          setState(() {
            _currentBreak = saved;
            _breakStartedAt = startedAt ?? DateTime.now();
          });
          _startBreakTimer();
        }
      }
    } catch (_) {}
  }

  void _startBreakTimer() {
    _breakTimer?.cancel();
    _breakTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _currentBreak != null) setState(() {});
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
    _breakTimer?.cancel();
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
          debugPrint('[DIALPAD] Incoming call event received for $number | shouldAutoAnswer=${_sip.shouldAutoAnswerNextCall} | isOnCall=$_isOnCall');

          if (_sip.shouldAutoAnswerNextCall) {
            debugPrint('[AUTO_ANSWER] AUTO-ANSWERING incoming call from Asterisk PSTN for $number...');
            _sip.shouldAutoAnswerNextCall = false;
            RingtoneService().stopRinging();
            if (_activeCallNumber.isEmpty) {
              _activeCallNumber = number;
            }
            _callWasAnswered = true;
            _activeLogEntry ??= _createLogEntry(
              number: number,
              direction: CallLogDirection.outgoing,
              source: 'Auto Dial',
            );
            await _sip.answerCall();
            if (!mounted) return;
            _isOnCall = true;
            _startCallTimer();
            setState(() {});
            debugPrint('[AUTO_ANSWER] Auto-answer complete. Active call connected.');
            break;
          }

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

          _callWasAnswered = false;
          _activeLogEntry = _createLogEntry(
            number: number,
            direction: CallLogDirection.incoming,
            source: event['fromQueue'] == true ? 'Queue' : 'Incoming',
          );

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
          _callWasAnswered = true;
          _callBridgeId = _callBridgeId.isEmpty
              ? _sip.bridgeID
              : _callBridgeId;
          _activeLogEntry ??= _createLogEntry(
            number: _activeCallNumber,
            direction: CallLogDirection.incoming,
            source: 'Incoming',
          );
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
          final wasAnswered = _callWasAnswered;
          final endedNumber = _activeCallNumber.isNotEmpty
              ? _activeCallNumber
              : _sip.incomingNumber;
          final endedBridge = _callBridgeId;
          await _finalizeActiveCall(failed: type == 'callFailed');
          _isOnCall = false;
          _isShowingKeypad = false;
          _isShowingIncomingDialog = false;
          _lastHandledNumber = endedNumber.isNotEmpty
              ? endedNumber
              : _activeCallNumber;
          _lastHandledAt = DateTime.now();
          _activeCallNumber = '';
          _callBridgeId = '';
          _callTimer?.cancel();
          _callSeconds = 0;
          RingtoneService().stopRinging();
          if (mounted) setState(() {});
          if (type == 'callEnded' && wasAnswered && mounted) {
            unawaited(_runPostCallFlow(
              bridgeId: endedBridge,
              number: endedNumber,
            ));
          }
          break;

        case 'registered':
          if (mounted) setState(() {});
          break;

        case 'missedCallsUpdated':
          if (mounted) setState(() {});
          break;

        case 'followUpsUpdated':
          if (mounted) setState(() {});
          break;

        case 'recentCallsUpdated':
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
        '[DIALPAD] _showIncomingCall invoked for $number. Call ID: $callId, State: $callState');

    if (_isShowingIncomingDialog) {
      debugPrint(
          '[DIALPAD] _showIncomingCall aborted: _isShowingIncomingDialog is true');
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
      // When the ring was triggered by the queue poll before the SIP INVITE
      // landed, wait briefly for the real call to arrive before answering.
      int callWait = 0;
      while (mounted &&
          _sip.callState != CallState.ringing &&
          _sip.activeCallId == null &&
          callWait < 80) {
        await Future.delayed(const Duration(milliseconds: 100));
        callWait++;
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

    final source = await _pickDialSource();
    if (source == null || !mounted) return;

    _activeCallNumber = number;
    _callWasAnswered = false;
    _callBridgeId = '';
    _activeLogEntry = _createLogEntry(
      number: number,
      direction: CallLogDirection.outgoing,
      source: source,
    );
    _isOnCall = true;
    _phoneController.clear();
    setState(() {});

    debugPrint('[DIALPAD_CALL] Triggering dialNumber for $number (source: $source)...');
    final ok = await _sip.dialNumber(number, dialSource: source);
    debugPrint('[DIALPAD_CALL] dialNumber result for $number: $ok');
    if (ok && _callBridgeId.isEmpty) {
      _callBridgeId = _sip.bridgeID;
    }
    if (!ok) {
      debugPrint('[DIALPAD_CALL] REST /dialnumber returned false — falling back to direct SIP INVITE');
      await _sip.makeCall(number);
    }
  }

  CallLogEntry _createLogEntry({
    required String number,
    required CallLogDirection direction,
    String source = 'Manual',
  }) {
    return CallLogEntry(
      id: '${direction.name}-${DateTime.now().millisecondsSinceEpoch}',
      number: number,
      direction: direction,
      type: _sip.isVideoCall ? CallLogType.video : CallLogType.audio,
      source: source,
      startedAt: DateTime.now(),
      bridgeId: _callBridgeId.isEmpty ? null : _callBridgeId,
    );
  }

  Future<void> _finalizeActiveCall({bool failed = false}) async {
    final entry = _activeLogEntry;
    final wasAnswered = _callWasAnswered;
    _activeLogEntry = null;
    _callWasAnswered = false;
    if (entry == null) return;
    final shouldBeMissed = entry.direction == CallLogDirection.incoming &&
        !wasAnswered;
    final direction = shouldBeMissed
        ? CallLogDirection.missed
        : entry.direction;
    await _callLog.upsert(
      entry.copyWith(
        direction: direction,
        endedAt: DateTime.now(),
        durationSec: _callSeconds,
      ),
    );
  }

  Future<String?> _pickDialSource() {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => const _DialSourceSheet(),
    );
  }

  Future<void> _runPostCallFlow({
    required String bridgeId,
    required String number,
  }) async {
    await _sip.sendCallEnded();
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted || _dispositionShowing) return;
    await _showDispositionSheet(bridgeId: bridgeId, number: number);
  }

  Future<void> _showDispositionSheet({
    required String bridgeId,
    required String number,
  }) async {
    if (!mounted) return;
    _dispositionShowing = true;
    String? result;
    try {
      result = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) =>
            _DispositionSheet(bridgeId: bridgeId, number: number),
      );
    } finally {
      _dispositionShowing = false;
    }
    final disposition = result ?? 'Auto Disposed';
    await _sip.submitDisposition(
      bridgeId: bridgeId,
      disposition: disposition,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Disposition saved: $disposition'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /*
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
    _sip.makeCall(number, video: true);
    setState(() {});
  }
  */

  Future<void> _endCall() async {
    await _sip.endCall();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isOnCall ? 'On Call' : 'Samvaad'),
        titleSpacing: 16,
        centerTitle: false,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: _isOnCall ? _buildOnCallUI() : _buildTabs(),
      ),
      bottomNavigationBar: _isOnCall ? null : _buildNavBar(),
    );
  }

  Widget _buildTabs() {
    return IndexedStack(
      index: _tabIndex,
      children: [
        _buildDialerTab(),
        _buildRecentTab(),
        _buildSettingsTab(),
      ],
    );
  }

  Widget _buildNavBar() {
    return ValueListenableBuilder<int>(
      valueListenable: _callLog.unseenMissed,
      builder: (context, unseen, _) {
        return NavigationBar(
          selectedIndex: _tabIndex,
          height: 72,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (index) {
            setState(() {
              _tabIndex = index;
            });
            if (index == 1) {
              _callLog.markMissedSeen();
            }
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.dialpad_outlined),
              selectedIcon: Icon(Icons.dialpad_rounded),
              label: 'Dialer',
            ),
            NavigationDestination(
              icon: Badge.count(
                count: unseen,
                isLabelVisible: unseen > 0,
                child: const Icon(Icons.history_outlined),
              ),
              selectedIcon: Badge.count(
                count: unseen,
                isLabelVisible: unseen > 0,
                child: const Icon(Icons.history_rounded),
              ),
              label: 'Recent',
            ),
            const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings_rounded),
              label: 'Settings',
            ),
          ],
        );
      },
    );
  }

  Future<void> _logout() async {
    await FcmService().removeTokenFromBackend();
    _sip.disconnect();
    await _sip.clearCredentials();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
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

  Widget _buildQueueBadge() {
    final count = _sip.queueCount;
    if (count <= 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.queue_rounded, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Text(
              'Call Queue: ($count)',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: cs.primary,
              ),
            ),
          ],
        ),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 24, top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildCallButton(
            icon: Icons.call_rounded,
            color: const Color(0xFF22C55E),
            onTap: _onCallPressed,
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

  Widget _buildDialerTab() {
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
                      _buildQueueBadge(),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: isTablet ? 400 : null,
                        child: _buildNumberDisplay(),
                      ),
                      const SizedBox(height: 32),
                      _buildCallButtons(),
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
            _buildQueueBadge(),
            _buildNumberDisplay(),
            Expanded(child: _buildDialpadGrid()),
            _buildCallButtons(),
            const SizedBox(height: 8),
          ],
        );
      },
    );
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

  // ---------------------------------------------------------------------
  // Recent (call history) tab
  // ---------------------------------------------------------------------

  Widget _buildRecentTab() {
    return ValueListenableBuilder<List<CallLogEntry>>(
      valueListenable: _callLog.entries,
      builder: (context, list, _) {
        final missedCount = _sip.missedCalls.length;
        final followUpCount = _sip.followUps.length;
        final merged = _mergedHistory(list);
        return ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: _buildHistoryActionCard(
                      icon: Icons.phone_missed_rounded,
                      label: 'Missed Calls',
                      badge: missedCount,
                      color: Theme.of(context).colorScheme.error,
                      onTap: missedCount > 0 ? _showMissedCallsSheet : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildHistoryActionCard(
                      icon: Icons.schedule_rounded,
                      label: 'Follow-up Calls',
                      badge: followUpCount,
                      color: Theme.of(context).colorScheme.primary,
                      onTap: followUpCount > 0 ? _showFollowUpsSheet : null,
                    ),
                  ),
                ],
              ),
            ),
            if (merged.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 120),
                child: _buildEmptyState(
                  icon: Icons.history_rounded,
                  title: 'No recent calls',
                  subtitle:
                      'Incoming, outgoing and missed calls will appear here.',
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Call History',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _confirmClearHistory,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('Clear'),
                    ),
                  ],
                ),
              ),
              for (final group in _groupEntriesByDay(merged)) ...[
                _buildDayHeader(group.key),
                for (final entry in group.value) _buildRecentTile(entry),
              ],
            ],
          ],
        );
      },
    );
  }

  List<CallLogEntry> _mergedHistory(List<CallLogEntry> local) {
    final byKey = <String, CallLogEntry>{};
    for (final entry in _sip.recentCalls) {
      byKey[_historyKey(entry)] = entry;
    }
    for (final entry in local) {
      byKey[_historyKey(entry)] = entry;
    }
    final merged = byKey.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return merged;
  }

  String _historyKey(CallLogEntry entry) {
    if (entry.bridgeId != null && entry.bridgeId!.isNotEmpty) {
      return 'bridge:${entry.bridgeId}';
    }
    final min = DateTime(
      entry.startedAt.year,
      entry.startedAt.month,
      entry.startedAt.day,
      entry.startedAt.hour,
      entry.startedAt.minute,
    );
    return '${min.millisecondsSinceEpoch}_${entry.number}';
  }

  Widget _buildHistoryActionCard({
    required IconData icon,
    required String label,
    required int badge,
    required Color color,
    required VoidCallback? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: color.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: color.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (badge > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$badge',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showMissedCallsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _MissedCallsSheet(
        missedCalls: List.from(_sip.missedCalls),
        onCallBack: _callBackNumber,
      ),
    );
  }

  Future<void> _showFollowUpsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _FollowUpsSheet(
        followUps: List.from(_sip.followUps),
        onCallBack: _callBackNumber,
      ),
    );
  }

  Future<void> _callBackNumber(
    String number, {
    String? callbackId,
  }) async {
    if (!mounted) return;
    final ok = await _sip.dialMissedCall(number);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not call back the number')),
      );
      return;
    }
    if (callbackId != null && callbackId.isNotEmpty) {
      unawaited(_sip.updateCallbackStatus(callbackId, 'completed'));
    }
    _activeCallNumber = number;
    _callWasAnswered = false;
    _callBridgeId = _sip.bridgeID;
    _activeLogEntry = _createLogEntry(
      number: number,
      direction: CallLogDirection.outgoing,
      source: 'Call Back',
    );
    _isOnCall = true;
    _phoneController.clear();
    setState(() {});
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  List<MapEntry<DateTime, List<CallLogEntry>>> _groupEntriesByDay(
    List<CallLogEntry> list,
  ) {
    final map = <DateTime, List<CallLogEntry>>{};
    for (final entry in list) {
      final day = DateTime(
        entry.startedAt.year,
        entry.startedAt.month,
        entry.startedAt.day,
      );
      map.putIfAbsent(day, () => []).add(entry);
    }
    final keys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return keys.map((k) => MapEntry(k, map[k]!)).toList();
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${day.day} ${months[day.month - 1]}';
  }

  Widget _buildDayHeader(DateTime day) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Text(
        _dayLabel(day),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: cs.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m == 0) return '${s}s';
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  String _timeLabel(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Widget _buildRecentTile(CallLogEntry entry) {
    final cs = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (entry.direction) {
      CallLogDirection.incoming => (Icons.call_received_rounded, cs.secondary),
      CallLogDirection.outgoing => (Icons.call_made_rounded, cs.primary),
      CallLogDirection.missed => (Icons.call_missed_rounded, cs.error),
    };
    final duration = _formatDuration(entry.durationSec);
    final time = _timeLabel(entry.startedAt);

    return ListTile(
      onTap: () => _dialFromHistory(entry),
      onLongPress: () => _confirmDeleteEntry(entry),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(
        entry.number,
        style: TextStyle(
          fontSize: 16,
          fontWeight: entry.isMissed ? FontWeight.w700 : FontWeight.w600,
          color: entry.isMissed ? cs.error : cs.onSurface,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (entry.source.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  entry.source,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.primary,
                  ),
                ),
              ),
            Text(
              [
                time,
                if (duration.isNotEmpty) duration,
                if (entry.type == CallLogType.video) 'Video',
              ].join('  ·  '),
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
      trailing: IconButton(
        icon: Icon(Icons.call_rounded, color: cs.secondary, size: 22),
        tooltip: 'Call back',
        onPressed: () => _dialFromHistory(entry),
      ),
    );
  }

  void _dialFromHistory(CallLogEntry entry) {
    setState(() {
      _phoneController.text = entry.number;
      _tabIndex = 0;
    });
  }

  Future<void> _confirmDeleteEntry(CallLogEntry entry) async {
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete call?'),
        content: Text('Remove ${entry.number} from recent calls?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _callLog.remove(entry.id);
    }
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 40, color: cs.primary.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Settings tab
  // ---------------------------------------------------------------------

  Widget _buildSettingsTab() {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildProfileCard(cs),
        const SizedBox(height: 16),
        _buildSectionTitle('Agent Status'),
        _buildAgentStatusCard(cs),
        const SizedBox(height: 16),
        _buildSectionTitle('Break'),
        _buildBreakCard(cs),
        const SizedBox(height: 16),
        _buildSectionTitle('Data'),
        _buildHistoryCard(cs),
        const SizedBox(height: 24),
        _buildLogoutCard(cs),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: cs.primary,
        ),
      ),
    );
  }

  Widget _buildProfileCard(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.primary.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: cs.primary,
            child: const Icon(Icons.person, size: 30, color: Colors.white),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _username ?? 'User',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _sip.isRegistered
                      ? 'Registered'
                      : _sip.isConnected
                          ? 'Registering...'
                          : 'Disconnected',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _sip.isRegistered
                        ? cs.secondary
                        : Colors.orange.shade700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatAgentStatus(String status) {
    switch (status) {
      case 'NOT_INUSE':
        return 'Ready';
      case 'INUSE':
        return 'On a call';
      case 'Disposition':
        return 'Wrap-up';
      case 'UNAVAILABLE':
        return 'Unavailable';
      default:
        return status.isEmpty ? '—' : status;
    }
  }

  Widget _buildAgentStatusCard(ColorScheme cs) {
    return _settingsCard(
      cs,
      children: [
        _settingsRow(
          icon: Icons.wifi_rounded,
          iconColor: _sip.isRegistered ? cs.secondary : Colors.orange,
          title: 'SIP Registration',
          value: _sip.isRegistered
              ? 'Connected'
              : _sip.isConnected
                  ? 'Registering...'
                  : 'Offline',
        ),
        _settingsRow(
          icon: Icons.verified_user_outlined,
          iconColor: cs.primary,
          title: 'Agent Status',
          value: _formatAgentStatus(_sip.agentStatus),
        ),
        _settingsRow(
          icon: Icons.queue_rounded,
          iconColor: cs.primary,
          title: 'Calls in Queue',
          value: _sip.queueCount > 0 ? '$_sip.queueCount' : 'None',
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () async {
              final ok = await _sip.sendUserReady();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ok
                        ? 'Agent set to Ready'
                        : 'Failed to set Ready state'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            icon: const Icon(Icons.check_circle_outline_rounded),
            label: const Text('Set Agent Ready'),
          ),
        ),
      ],
    );
  }

  Widget _buildBreakCard(ColorScheme cs) {
    final options = _sip.breakOptions.isNotEmpty
        ? List<dynamic>.from(_sip.breakOptions)
        : const <dynamic>['General Break'];
    final onBreak = _currentBreak != null;
    final breakIcon = onBreak
        ? _breakIconFor(_currentBreak!)
        : Icons.free_breakfast_outlined;
    return _settingsCard(
      cs,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(breakIcon, size: 20, color: cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                onBreak ? 'On break: $_currentBreak' : 'Take Break',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (onBreak) ...[
              Icon(Icons.schedule_rounded, size: 16, color: cs.primary),
              const SizedBox(width: 4),
              Text(
                _breakElapsedLabel(),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  color: cs.primary,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in options) _buildBreakChip(option, cs),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: onBreak ? _removeBreak : null,
            icon: const Icon(Icons.event_available_rounded),
            label: const Text('Remove Break'),
          ),
        ),
      ],
    );
  }

  Widget _buildBreakChip(dynamic option, ColorScheme cs) {
    final label = _breakLabel(option);
    final type = _breakType(option);
    final selected = _currentBreak == type;
    return FilterChip(
      label: Text(label),
      avatar: Icon(
        _breakIconFor(label),
        size: 16,
        color: selected ? cs.primary : null,
      ),
      selected: selected,
      selectedColor: cs.primary.withValues(alpha: 0.12),
      checkmarkColor: cs.primary,
      showCheckmark: false,
      onSelected: (_) => _setBreak(type),
    );
  }

  String _breakLabel(dynamic option) {
    if (option is Map) {
      final label = option['label'] ??
          option['name'] ??
          option['title'] ??
          option['value'] ??
          option['type'];
      if (label != null) return label.toString();
    }
    return option?.toString() ?? 'Break';
  }

  String _breakType(dynamic option) {
    if (option is Map) {
      final type = option['value'] ??
          option['type'] ??
          option['name'] ??
          option['id'];
      if (type != null) return type.toString();
    }
    return option?.toString() ?? 'General Break';
  }

  IconData _breakIconFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('lunch') ||
        l.contains('dinner') ||
        l.contains('meal')) {
      return Icons.restaurant_rounded;
    }
    if (l.contains('coffee') || l.contains('tea') || l.contains('drink')) {
      return Icons.local_cafe_rounded;
    }
    if (l.contains('short') ||
        l.contains('quick') ||
        l.contains('brief')) {
      return Icons.timer_outlined;
    }
    if (l.contains('meeting') ||
        l.contains('call') ||
        l.contains('conference')) {
      return Icons.groups_rounded;
    }
    if (l.contains('break') || l.contains('rest') || l.contains('pause')) {
      return Icons.free_breakfast_rounded;
    }
    return Icons.self_improvement_rounded;
  }

  String _breakElapsedLabel() {
    final start = _breakStartedAt;
    if (_currentBreak == null || start == null) return '00:00';
    final elapsed = DateTime.now().difference(start).inSeconds;
    final m = (elapsed ~/ 60).toString().padLeft(2, '0');
    final s = (elapsed % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _setBreak(String type) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentBreak = type;
      _breakStartedAt = DateTime.now();
    });
    _startBreakTimer();
    await prefs.setString('selectedBreak', type);
    await prefs.setString(
      'breakStartTime_$type',
      _breakStartedAt!.toUtc().toIso8601String(),
    );
    await _sip.setAgentBreak(type);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Break set: $_currentBreak'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _removeBreak() async {
    final prefs = await SharedPreferences.getInstance();
    final oldType = _currentBreak;
    _breakTimer?.cancel();
    setState(() {
      _currentBreak = null;
      _breakStartedAt = null;
    });
    if (oldType != null) {
      await prefs.remove('selectedBreak');
      await prefs.remove('breakStartTime_$oldType');
    }
    await _sip.removeAgentBreak();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Break removed'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _buildHistoryCard(ColorScheme cs) {
    return _settingsCard(
      cs,
      children: [
        _settingsRow(
          icon: Icons.delete_sweep_rounded,
          iconColor: cs.error,
          title: 'Call History',
          value: '${_callLog.entries.value.length} saved',
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.error,
            ),
            onPressed: _confirmClearHistory,
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Clear Call History'),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClearHistory() async {
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear call history?'),
        content: const Text('This will remove all saved calls.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _callLog.clear();
    }
  }

  Widget _buildLogoutCard(ColorScheme cs) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: cs.error,
          foregroundColor: Colors.white,
        ),
        onPressed: _logout,
        icon: const Icon(Icons.logout_rounded),
        label: const Text('Logout'),
      ),
    );
  }

  Widget _settingsCard(
    ColorScheme cs, {
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outline.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _settingsRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
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
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: RTCVideoView(
              _remoteRenderer,
              objectFit:
                  RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
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
            _CallControlButton(
              icon: Icons.flip_camera_android_rounded,
              label: 'Flip',
              isOnDark: isVideo,
              onPressed: () => _sip.switchCamera(),
            ),
            _CallControlButton(
              icon: _sip.isLocalVideoMuted
                  ? Icons.videocam_off_rounded
                  : Icons.videocam_rounded,
              label: _sip.isLocalVideoMuted ? 'Show Video' : 'Hide Video',
              isActive: _sip.isLocalVideoMuted,
              isOnDark: isVideo,
              onPressed: () {
                setState(() {
                  _sip.toggleVideo(!_sip.isLocalVideoMuted);
                });
              },
            ),
          ],
          _CallControlButton(
            icon:
                _sip.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: _sip.isMuted ? 'Unmute' : 'Mute',
            isActive: _sip.isMuted,
            isOnDark: isVideo,
            onPressed: () {
              setState(() {
                _sip.mute(!_sip.isMuted);
              });
            },
          ),
          if (!isVideo)
            _CallControlButton(
              icon: _sip.isSpeakerOn
                  ? Icons.volume_up_rounded
                  : Icons.volume_down_rounded,
              label: 'Speaker',
              isActive: _sip.isSpeakerOn,
              isOnDark: isVideo,
              onPressed: () {
                _sip.toggleSpeaker(!_sip.isSpeakerOn);
                setState(() {});
              },
            ),
          if (!isVideo)
            _CallControlButton(
              icon: _sip.isHeld
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded,
              label: _sip.isHeld ? 'Resume' : 'Hold',
              isActive: _sip.isHeld,
              isOnDark: isVideo,
              onPressed: () {
                setState(() {
                  _sip.toggleHold(!_sip.isHeld);
                });
              },
            ),
          if (!isVideo)
            _CallControlButton(
              icon: _isShowingKeypad
                  ? Icons.grid_view_rounded
                  : Icons.dialpad_rounded,
              label: _isShowingKeypad ? 'Close' : 'Keypad',
              isActive: _isShowingKeypad,
              isOnDark: isVideo,
              onPressed: () {
                setState(() {
                  _isShowingKeypad = !_isShowingKeypad;
                });
              },
            ),
          if (!isVideo)
            _CallControlButton(
              icon: Icons.call_made_rounded,
              label: 'Transfer',
              disabled: _sip.bridgeID.isEmpty,
              isOnDark: isVideo,
              onPressed: () async {
                final ok = await _sip.requestTransfer();
                if (mounted && !ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Transfer request failed')),
                  );
                }
              },
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

class _CallControlButton extends StatefulWidget {
  const _CallControlButton({
    required this.icon,
    required this.label,
    this.isActive = false,
    this.disabled = false,
    this.isOnDark = false,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final bool disabled;
  final bool isOnDark;
  final FutureOr<void> Function()? onPressed;

  @override
  State<_CallControlButton> createState() => _CallControlButtonState();
}

class _CallControlButtonState extends State<_CallControlButton> {
  bool _processing = false;
  Timer? _releaseTimer;

  @override
  void dispose() {
    _releaseTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (_processing || widget.disabled || widget.onPressed == null) return;
    setState(() => _processing = true);
    try {
      final result = widget.onPressed!();
      if (result is Future) await result;
    } finally {
      _releaseTimer?.cancel();
      _releaseTimer = Timer(const Duration(milliseconds: 200), () {
        if (mounted) setState(() => _processing = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isOnDark = widget.isOnDark;
    final isActive = widget.isActive;
    final disabled = widget.disabled || _processing;
    final bgColor = isActive
        ? cs.primary
        : isOnDark
            ? Colors.white.withValues(alpha: 0.15)
            : Colors.grey.shade100;
    final fgColor =
        isActive ? Colors.white : (isOnDark ? Colors.white : cs.onSurface);
    final labelColor = isActive
        ? cs.primary
        : isOnDark
            ? Colors.white.withValues(alpha: 0.7)
            : cs.onSurface.withValues(alpha: 0.6);

    return GestureDetector(
      onTap: disabled ? null : _handleTap,
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: bgColor,
                shape: BoxShape.circle,
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
              child: _processing
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : Icon(widget.icon, size: 24, color: fgColor),
            ),
            const SizedBox(height: 6),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: labelColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _dispositionOptions = [
  'Auto Disposed',
  'Completed',
  'No Answer',
  'Busy',
  'Wrong Number',
  'Not Interested',
  'Call Back',
  'Follow Up',
  'DND',
];

class _DispositionSheet extends StatefulWidget {
  const _DispositionSheet({required this.bridgeId, required this.number});

  final String bridgeId;
  final String number;

  @override
  State<_DispositionSheet> createState() => _DispositionSheetState();
}

class _DispositionSheetState extends State<_DispositionSheet> {
  String _selected = 'Auto Disposed';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Call Disposition',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.number,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: RadioGroup<String>(
                groupValue: _selected,
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selected = value);
                  }
                },
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final option in _dispositionOptions)
                      RadioListTile<String>(
                        value: option,
                        title: Text(
                          option,
                          style: TextStyle(
                            fontWeight: option == _selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: option == _selected
                                ? cs.primary
                                : cs.onSurface,
                          ),
                        ),
                        activeColor: cs.primary,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () =>
                    Navigator.of(context).pop(_selected),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Save Disposition'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _dialSourceOptions = [
  (icon: Icons.dialpad_rounded, label: 'Manual', value: 'Manual'),
  (icon: Icons.bolt_rounded, label: 'Auto Dial', value: 'Auto Dial'),
  (icon: Icons.replay_rounded, label: 'Call Back', value: 'Call Back'),
];

class _DialSourceSheet extends StatelessWidget {
  const _DialSourceSheet();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Call From',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Choose how this call is sourced',
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 16),
            for (final option in _dialSourceOptions) ...[
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                tileColor: cs.primary.withValues(alpha: 0.06),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(option.icon, color: cs.primary, size: 20),
                ),
                title: Text(
                  option.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).pop(option.value),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Bottom-sheet widgets shared by the Recent tab
// ---------------------------------------------------------------------

DateTime? _parseEpochMs(dynamic value) {
  if (value == null) return null;
  try {
    final ms = int.tryParse(value.toString());
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  } catch (_) {
    return null;
  }
}

String _formatSheetTime(DateTime time) {
  final now = DateTime.now();
  final diff = now.difference(time);
  String relative;
  if (diff.inSeconds < 60) {
    relative = 'just now';
  } else if (diff.inMinutes < 60) {
    relative = '${diff.inMinutes}m ago';
  } else if (diff.inHours < 24) {
    relative = '${diff.inHours}h ago';
  } else if (diff.inDays < 7) {
    relative = '${diff.inDays}d ago';
  } else {
    relative = '${time.day}/${time.month}/${time.year}';
  }
  final h = time.hour.toString().padLeft(2, '0');
  final m = time.minute.toString().padLeft(2, '0');
  return '$relative  ·  $h:$m';
}

String _displayNumber(String number) {
  var n = number.trim();
  if (n.startsWith('+91')) n = n.substring(3);
  return n;
}

class _MissedCallsSheet extends StatelessWidget {
  const _MissedCallsSheet({
    required this.missedCalls,
    required this.onCallBack,
  });

  final List<dynamic> missedCalls;
  final Future<void> Function(String number) onCallBack;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final groups = <String, List<dynamic>>{};
    for (final call in missedCalls) {
      final caller =
          (call is Map ? (call['Caller'] ?? 'Unknown') : 'Unknown').toString();
      groups.putIfAbsent(caller, () => []).add(call);
    }
    final sorted = groups.entries.toList()
      ..sort((a, b) {
        final at = _latestTime(a.value);
        final bt = _latestTime(b.value);
        return bt.compareTo(at);
      });

    return _sheetContainer(
      cs: cs,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sheetHeader(
            cs: cs,
            icon: Icons.phone_missed_rounded,
            iconColor: cs.error,
            title: 'Missed Calls',
            subtitle: '${missedCalls.length} total',
          ),
          const SizedBox(height: 8),
          if (sorted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  'All caught up!',
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
                ),
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final group in sorted)
                    _missedGroupTile(
                      context,
                      cs,
                      caller: group.key,
                      calls: group.value,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  DateTime _latestTime(List<dynamic> calls) {
    var latest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final call in calls) {
      final t = _parseEpochMs(call is Map ? call['startTime'] : null);
      if (t != null && t.isAfter(latest)) latest = t;
    }
    return latest;
  }

  Widget _missedGroupTile(
    BuildContext context,
    ColorScheme cs, {
    required String caller,
    required List<dynamic> calls,
  }) {
    final latest = _latestTime(calls);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: cs.error.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.phone_missed_rounded, color: cs.error, size: 22),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              _displayNumber(caller),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (calls.length > 1) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: cs.error,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${calls.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        _formatSheetTime(latest),
        style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5)),
      ),
      trailing: IconButton(
        icon: Icon(Icons.call_rounded, color: cs.secondary, size: 24),
        tooltip: 'Call back',
        onPressed: () => onCallBack(_displayNumber(caller)),
      ),
    );
  }
}

class _FollowUpsSheet extends StatelessWidget {
  const _FollowUpsSheet({
    required this.followUps,
    required this.onCallBack,
  });

  final List<dynamic> followUps;
  final Future<void> Function(String number, {String? callbackId})
      onCallBack;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _sheetContainer(
      cs: cs,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sheetHeader(
            cs: cs,
            icon: Icons.schedule_rounded,
            iconColor: cs.primary,
            title: 'Follow-up Calls',
            subtitle: '${followUps.length} scheduled',
          ),
          const SizedBox(height: 8),
          if (followUps.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  'No follow-up calls scheduled',
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
                ),
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final item in followUps)
                    _followUpTile(context, cs, item),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _field(Map<dynamic, dynamic>? map, String key, String fallback) {
    final v = map?[key];
    if (v == null) return fallback;
    final s = v.toString();
    return s.isEmpty ? fallback : s;
  }

  Widget _followUpTile(BuildContext context, ColorScheme cs, dynamic item) {
    final map = item is Map ? Map<dynamic, dynamic>.from(item) : null;
    final phone = _field(map, 'phoneNumber', '');
    final comment = _field(map, 'comment', '');
    final callbackId = _field(map, '_id', '');
    final status = _field(map, 'status', '').toLowerCase();
    final scheduledRaw = map?['scheduledAt'] ?? map?['scheduledtime'];
    final scheduled =
        _parseEpochMs(scheduledRaw) ?? DateTime.tryParse('$scheduledRaw');
    final isDone = status.contains('completed') || status.contains('done');
    final color = isDone ? cs.onSurface.withValues(alpha: 0.3) : cs.primary;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(
          isDone ? Icons.check_rounded : Icons.call_received_rounded,
          color: color,
          size: 22,
        ),
      ),
      title: Text(
        phone.isEmpty ? 'Unknown' : _displayNumber(phone),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: isDone ? cs.onSurface.withValues(alpha: 0.4) : cs.onSurface,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (comment.isNotEmpty)
              Text(
                comment,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            Text(
              [
                if (scheduled != null) _formatSheetTime(scheduled),
                if (status.isNotEmpty && status != 'pending') status,
              ].join('  ·  '),
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
      trailing: isDone
          ? null
          : IconButton(
              icon: Icon(Icons.call_rounded, color: cs.secondary, size: 24),
              tooltip: 'Call',
              onPressed: () =>
                  onCallBack(_displayNumber(phone), callbackId: callbackId),
            ),
    );
  }
}

Widget _sheetContainer({
  required ColorScheme cs,
  required Widget child,
}) {
  return Container(
    decoration: BoxDecoration(
      color: cs.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
    ),
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
    child: SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: child,
      ),
    ),
  );
}

Widget _sheetHeader({
  required ColorScheme cs,
  required IconData icon,
  required Color iconColor,
  required String title,
  required String subtitle,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
