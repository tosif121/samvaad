import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
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
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/avatar.dart';
import '../ui/widgets/buttons.dart';
import '../ui/widgets/call_history_tile.dart';
import '../ui/widgets/chips.dart';
import '../ui/widgets/common.dart';
import '../ui/widgets/follow_up_tile.dart';
import '../ui/widgets/missed_call_group_card.dart';

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

  final Set<String> _callBackingCallers = {};
  final Set<String> _completingCallbacks = {};
  final ValueNotifier<bool> _permissionRefresher = ValueNotifier(false);

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
        final startedAt = startRaw != null ? DateTime.tryParse(startRaw) : null;
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

      final recentlyHandledSameNumber =
          _lastHandledNumber != null &&
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

    debugPrint(
      '[PERMISSION] mic: ${micStatus.isGranted}, cam: ${camStatus.isGranted}',
    );
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
          debugPrint(
            '[DIALPAD] Incoming call event received for $number | shouldAutoAnswer=${_sip.shouldAutoAnswerNextCall} | isOnCall=$_isOnCall',
          );

          if (_sip.shouldAutoAnswerNextCall) {
            debugPrint(
              '[AUTO_ANSWER] AUTO-ANSWERING incoming call from Asterisk PSTN for $number...',
            );
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
            debugPrint(
              '[AUTO_ANSWER] Auto-answer complete. Active call connected.',
            );
            break;
          }

          if (_isOnCall) break;
          if (_isShowingIncomingDialog) break;

          final recentlyHandledSameNumber =
              _lastHandledNumber == number &&
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
          _callBridgeId = _callBridgeId.isEmpty ? _sip.bridgeID : _callBridgeId;
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
            unawaited(
              _runPostCallFlow(bridgeId: endedBridge, number: endedNumber),
            );
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
      '[DIALPAD] _showIncomingCall invoked for $number. Call ID: $callId, State: $callState',
    );

    if (_isShowingIncomingDialog) {
      debugPrint(
        '[DIALPAD] _showIncomingCall aborted: _isShowingIncomingDialog is true',
      );
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
              content: Text('Permissions are required to answer calls'),
            ),
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
            content: Text('Permissions are required to make calls'),
          ),
        );
      }
      return;
    }

    const source = 'Manual';

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

    debugPrint(
      '[DIALPAD_CALL] Triggering dialNumber for $number (source: $source)...',
    );
    final ok = await _sip.dialNumber(number, dialSource: source);
    debugPrint('[DIALPAD_CALL] dialNumber result for $number: $ok');
    if (ok && _callBridgeId.isEmpty) {
      _callBridgeId = _sip.bridgeID;
    }
    if (!ok) {
      debugPrint(
        '[DIALPAD_CALL] REST /dialnumber returned false — falling back to direct SIP INVITE',
      );
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
    final shouldBeMissed =
        entry.direction == CallLogDirection.incoming && !wasAnswered;
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
    await _sip.submitDisposition(bridgeId: bridgeId, disposition: disposition);
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
      body: SafeArea(child: _isOnCall ? _buildOnCallUI() : _buildDashboard()),
      bottomNavigationBar: _isOnCall ? null : _buildNavBar(),
    );
  }

  Widget _buildDashboard() {
    return Column(
      children: [
        _buildShellBar(),
        Expanded(child: _buildTabs()),
      ],
    );
  }

  Widget _buildShellBar() {
    final cs = Theme.of(context).colorScheme;
    final onBreak = _currentBreak != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          AvatarBubble(name: _username, size: 40, accent: true),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _username ?? 'Agent',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.subheading - 1,
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                StatusChip(
                  status: _sip.isRegistered
                      ? SipStatus.connected
                      : SipStatus.connecting,
                  compact: true,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (onBreak && _breakStartedAt != null)
            BreakTimerChip(
              startedAt: _breakStartedAt!,
              breakLabel: _currentBreak!,
              onTap: _removeBreak,
            )
          else
            PressableScale(
              onTap: _showBreakQuickSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm + 2,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: cs.tertiary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                  border: Border.all(color: cs.tertiary.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.free_breakfast_rounded,
                      size: 15,
                      color: cs.tertiary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Take Break',
                      style: TextStyle(
                        fontSize: AppType.overline,
                        fontWeight: FontWeight.w800,
                        color: cs.tertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showBreakQuickSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _BreakQuickSheet(
        breakOptions: List<dynamic>.from(_sip.breakOptions),
        currentBreak: _currentBreak,
        onSetBreak: (type) {
          Navigator.of(context).pop();
          _setBreak(type);
        },
        onRemoveBreak: () {
          Navigator.of(context).pop();
          _removeBreak();
        },
      ),
    );
  }

  Widget _buildTabs() {
    return IndexedStack(
      index: _tabIndex,
      children: [
        _buildDialerTab(),
        _buildRecentTab(),
        _buildMissedTab(),
        _buildFollowUpsTab(),
        _buildSettingsTab(),
      ],
    );
  }

  Widget _buildNavBar() {
    return ValueListenableBuilder<int>(
      valueListenable: _callLog.unseenMissed,
      builder: (context, unseen, _) {
        final missedCount = _sip.missedCalls.length;
        final followUpCount = _sip.followUps.length;
        return NavigationBar(
          selectedIndex: _tabIndex,
          height: 68,
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
            NavigationDestination(
              icon: Badge.count(
                count: missedCount,
                isLabelVisible: missedCount > 0,
                child: const Icon(Icons.phone_missed_outlined),
              ),
              selectedIcon: Badge.count(
                count: missedCount,
                isLabelVisible: missedCount > 0,
                child: const Icon(Icons.phone_missed_rounded),
              ),
              label: 'Missed',
            ),
            NavigationDestination(
              icon: Badge.count(
                count: followUpCount,
                isLabelVisible: followUpCount > 0,
                child: const Icon(Icons.schedule_outlined),
              ),
              selectedIcon: Badge.count(
                count: followUpCount,
                isLabelVisible: followUpCount > 0,
                child: const Icon(Icons.schedule_rounded),
              ),
              label: 'Follow-ups',
            ),
            const NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune_rounded),
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
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  Widget _buildQueueBadge() {
    final count = _sip.queueCount;
    if (count <= 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InfoChip(
        icon: Icons.queue_rounded,
        label: 'Call Queue: ($count)',
        color: cs.primary,
      ),
    );
  }

  Widget _buildNumberDisplay() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(32, 32, 32, 4),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadii.xl),
            border: Border.all(color: cs.outline.withValues(alpha: 0.5)),
          ),
          constraints: const BoxConstraints(minHeight: 64),
          child: TextField(
            controller: _phoneController,
            focusNode: _phoneFocusNode,
            readOnly: true,
            showCursor: false,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppType.display - 2,
              fontWeight: FontWeight.w800,
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
                fontSize: AppType.heading,
                letterSpacing: 0,
                fontWeight: FontWeight.w500,
              ),
              suffixIcon: GestureDetector(
                onTap: _onDeleteTap,
                onLongPress: _onClearTap,
                child: Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainer,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: cs.outline.withValues(alpha: 0.4),
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
        ),
      ],
    );
  }

  Widget _buildDialpadGrid() {
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: 264,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDialRow(['1', '2', '3']),
            _buildDialRow(['4', '5', '6']),
            _buildDialRow(['7', '8', '9']),
            _buildDialRow(['*', '0', '#']),
          ],
        ),
      ),
    );
  }

  static const Map<String, String> _dialLetters = {
    '1': '',
    '2': 'ABC',
    '3': 'DEF',
    '4': 'GHI',
    '5': 'JKL',
    '6': 'MNO',
    '7': 'PQRS',
    '8': 'TUV',
    '9': 'WXYZ',
    '*': '',
    '0': '+',
    '#': '',
  };

  Widget _buildDialpadKey(String key) {
    final cs = Theme.of(context).colorScheme;
    final letters = _dialLetters[key] ?? '';
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: PressableScale(
          onTap: () => _onDialPadTap(key),
          child: AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                shape: BoxShape.circle,
                border: Border.all(color: cs.outline.withValues(alpha: 0.4)),
              ),
              alignment: Alignment.center,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    key,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                      height: 1,
                    ),
                  ),
                  if (letters.isNotEmpty)
                    Text(
                      letters,
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                        color: cs.onSurface.withValues(alpha: 0.35),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDialRow(List<String> keys) {
    return Row(children: keys.map((key) => _buildDialpadKey(key)).toList());
  }

  Widget _buildCallButtons() {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg, top: AppSpacing.sm),
      child: GradientCallButton(
        icon: Icons.call_rounded,
        onTap: _onCallPressed,
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
            _buildQueueBadge(),
            const SizedBox(height: 4),
            _buildNumberDisplay(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: _buildDialpadGrid(),
              ),
            ),
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
        final cs = Theme.of(context).colorScheme;
        final merged = _mergedHistory(list);
        if (merged.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(top: 64),
            child: const EmptyState(
              icon: Icons.history_rounded,
              title: 'No recent calls',
              subtitle: 'Incoming, outgoing and missed calls will appear here.',
            ),
          );
        }
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.xs,
                  AppSpacing.xs,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Recent Calls',
                        style: TextStyle(
                          fontSize: AppType.heading,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                          color: cs.onSurface,
                        ),
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
            ),
            for (final group in _groupEntriesByDay(merged))
              SliverMainAxisGroup(
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _StickyDayHeaderDelegate(
                      label: _dayLabel(group.key),
                      color: Theme.of(context).colorScheme.surface,
                    ),
                  ),
                  SliverList.builder(
                    itemCount: group.value.length,
                    itemBuilder: (context, i) {
                      final entry = group.value[i];
                      return CallHistoryTile(
                        entry: entry,
                        onTap: () => _dialFromHistory(entry),
                        onCallBack: () => _dialFromHistory(entry),
                        onDelete: () async {
                          await _callLog.remove(entry.id);
                        },
                      );
                    },
                  ),
                ],
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
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

  // ---------------------------------------------------------------------
  // Missed Calls tab
  // ---------------------------------------------------------------------

  Widget _buildMissedTab() {
    final cs = Theme.of(context).colorScheme;
    final missed = _sip.missedCalls;
    if (missed.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 64),
        child: const EmptyState(
          icon: Icons.phone_missed_rounded,
          title: 'All caught up',
          subtitle: 'Missed calls will show up here while you are on calls.',
        ),
      );
    }

    final groups = <String, List<dynamic>>{};
    for (final call in missed) {
      final caller = (call is Map ? (call['Caller'] ?? 'Unknown') : 'Unknown')
          .toString();
      groups.putIfAbsent(caller, () => []).add(call);
    }
    final sorted = groups.entries.toList()
      ..sort(
        (a, b) => _latestCallTime(b.value).compareTo(_latestCallTime(a.value)),
      );

    return AnimatedSwitcher(
      duration: AppMotion.normal,
      child: ListView(
        key: ValueKey(missed.length),
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Text(
              'Missed Calls',
              style: TextStyle(
                fontSize: AppType.heading,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
                color: cs.onSurface,
              ),
            ),
          ),
          for (final group in sorted)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: MissedCallGroupCard(
                caller: group.key,
                count: group.value.length,
                lastAttempt: _latestCallTime(group.value),
                callBacking: _callBackingCallers.contains(group.key),
                onCallBack: () => _callBackNumber(group.key),
              ),
            ),
        ],
      ),
    );
  }

  DateTime _latestCallTime(List<dynamic> calls) {
    var latest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final call in calls) {
      final raw = call is Map ? call['startTime'] : null;
      final ms = int.tryParse(raw?.toString() ?? '');
      if (ms != null) {
        final t = DateTime.fromMillisecondsSinceEpoch(ms);
        if (t.isAfter(latest)) latest = t;
      }
    }
    return latest;
  }

  // ---------------------------------------------------------------------
  // Follow-ups tab
  // ---------------------------------------------------------------------

  Widget _buildFollowUpsTab() {
    final cs = Theme.of(context).colorScheme;
    final followUps = _sip.followUps;
    if (followUps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 64),
        child: const EmptyState(
          icon: Icons.schedule_rounded,
          title: 'No follow-ups',
          subtitle: 'Scheduled callbacks will appear here as a task queue.',
        ),
      );
    }

    final sorted = List<dynamic>.from(followUps)
      ..sort((a, b) {
        final at = _followUpTime(a);
        final bt = _followUpTime(b);
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return at.compareTo(bt);
      });

    final now = DateTime.now();
    return AnimatedSwitcher(
      duration: AppMotion.normal,
      child: ListView(
        key: ValueKey(followUps.length),
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Text(
              'Follow-up Calls',
              style: TextStyle(
                fontSize: AppType.heading,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
                color: cs.onSurface,
              ),
            ),
          ),
          for (final item in sorted) _followUpTile(item, now),
        ],
      ),
    );
  }

  DateTime? _followUpTime(dynamic item) {
    if (item is! Map) return null;
    final raw = item['scheduledAt'] ?? item['scheduledtime'];
    final ms = int.tryParse(raw?.toString() ?? '');
    if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime.tryParse(raw?.toString() ?? '');
  }

  Widget _followUpTile(dynamic item, DateTime now) {
    final map = item is Map ? Map<dynamic, dynamic>.from(item) : {};
    String field(String key) {
      final v = map[key];
      return v?.toString() ?? '';
    }

    final phone = field('phoneNumber').isNotEmpty
        ? field('phoneNumber')
        : field('contactNumber');
    final comment = field('comment');
    final status = field('status');
    final callbackId = field('_id').isNotEmpty ? field('_id') : field('id');
    final scheduled = _followUpTime(item);
    final overdue =
        scheduled != null &&
        scheduled.isBefore(now) &&
        !status.toLowerCase().contains('complete');

    return FollowUpTile(
      phone: phone,
      scheduledAt: scheduled,
      comment: comment,
      status: status,
      callbackId: callbackId,
      overdue: overdue,
      completing:
          callbackId.isNotEmpty && _completingCallbacks.contains(callbackId),
      onCallBack: phone.isEmpty
          ? null
          : () => _callBackNumber(phone, callbackId: callbackId),
    );
  }

  Future<void> _callBackNumber(String number, {String? callbackId}) async {
    if (!mounted) return;
    final caller = number.trim();
    if (caller.isNotEmpty) setState(() => _callBackingCallers.add(caller));
    if (callbackId != null && callbackId.isNotEmpty) {
      setState(() => _completingCallbacks.add(callbackId));
    }
    final ok = await _sip.dialMissedCall(number);
    if (!mounted) return;
    if (caller.isNotEmpty) setState(() => _callBackingCallers.remove(caller));
    if (!ok) {
      if (callbackId != null && callbackId.isNotEmpty) {
        setState(() => _completingCallbacks.remove(callbackId));
      }
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
    if (mounted && Navigator.of(context).canPop()) {
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
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${day.day} ${months[day.month - 1]}';
  }

  void _dialFromHistory(CallLogEntry entry) {
    setState(() {
      _phoneController.text = entry.number;
      _tabIndex = 0;
    });
  }

  // ---------------------------------------------------------------------
  // Settings tab
  // ---------------------------------------------------------------------

  Widget _buildSettingsTab() {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _buildProfileCard(cs),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('Appearance'),
        _buildAppearanceCard(cs),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('Agent Status'),
        _buildAgentStatusCard(cs),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('Break'),
        _buildBreakCard(cs),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('Permissions'),
        _buildPermissionsCard(cs),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('Data'),
        _buildHistoryCard(cs),
        const SizedBox(height: AppSpacing.xl),
        _buildLogoutCard(cs),
        const SizedBox(height: AppSpacing.md),
      ],
    );
  }

  Widget _buildProfileCard(ColorScheme cs) {
    final isDark = cs.brightness == Brightness.dark;
    final (label, color) = _sip.isRegistered
        ? ('Registered', cs.secondary)
        : _sip.isConnected
        ? ('Registering...', _warnColor(cs))
        : ('Disconnected', cs.error);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: isDark
            ? cs.primary.withValues(alpha: 0.1)
            : cs.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.xl),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          AvatarBubble(name: _username, size: 56, accent: true),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _username ?? 'User',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.heading,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                StatusChip(
                  status: _sip.isRegistered
                      ? SipStatus.connected
                      : _sip.isConnected
                      ? SipStatus.connecting
                      : SipStatus.failed,
                  label: label,
                  compact: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Warning/amber that reads well in both light and dark themes.
  Color _warnColor(ColorScheme cs) {
    return cs.brightness == Brightness.dark
        ? const Color(0xFFFFB74D)
        : const Color(0xFFEF6C00);
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
    return SettingsCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        SettingsRow(
          icon: Icons.wifi_rounded,
          iconColor: _sip.isRegistered ? cs.secondary : _warnColor(cs),
          title: 'SIP Registration',
          value: _sip.isRegistered
              ? 'Connected'
              : _sip.isConnected
              ? 'Registering...'
              : 'Offline',
        ),
        const SizedBox(height: AppSpacing.sm),
        SettingsRow(
          icon: Icons.verified_user_outlined,
          iconColor: cs.primary,
          title: 'Agent Status',
          value: _formatAgentStatus(_sip.agentStatus),
        ),
        const SizedBox(height: AppSpacing.sm),
        SettingsRow(
          icon: Icons.queue_rounded,
          iconColor: cs.primary,
          title: 'Calls in Queue',
          value: _sip.queueCount > 0 ? '$_sip.queueCount' : 'None',
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () async {
              final ok = await _sip.sendUserReady();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok ? 'Agent set to Ready' : 'Failed to set Ready state',
                    ),
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
        ? breakIconFor(_currentBreak!)
        : Icons.free_breakfast_outlined;
    return SettingsCard(
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
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                onBreak ? 'On break: $_currentBreak' : 'Take Break',
                style: TextStyle(
                  fontSize: AppType.body,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (onBreak) ...[
              Icon(Icons.schedule_rounded, size: 16, color: cs.primary),
              const SizedBox(width: AppSpacing.xxs),
              Text(
                _breakElapsedLabel(),
                style: TextStyle(
                  fontSize: AppType.body,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  color: cs.primary,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [for (final option in options) _buildBreakChip(option, cs)],
        ),
        const SizedBox(height: AppSpacing.sm),
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
        breakIconFor(label),
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
    return SettingsCard(
      children: [
        SettingsRow(
          icon: Icons.delete_sweep_rounded,
          iconColor: cs.error,
          title: 'Call History',
          value: '${_callLog.entries.value.length} saved',
        ),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.error,
              side: BorderSide(color: cs.error.withValues(alpha: 0.5)),
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
          foregroundColor: cs.onError,
        ),
        onPressed: _logout,
        icon: const Icon(Icons.logout_rounded),
        label: const Text('Logout'),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Appearance
  // ---------------------------------------------------------------------

  Widget _buildAppearanceCard(ColorScheme cs) {
    return SettingsCard(
      children: [
        ValueListenableBuilder<ThemeMode>(
          valueListenable: ThemeController.instance.mode,
          builder: (context, mode, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsRow(
                  icon: Icons.palette_outlined,
                  iconColor: cs.primary,
                  title: 'Theme',
                  value: switch (mode) {
                    ThemeMode.dark => 'Dark',
                    ThemeMode.light => 'Light',
                    ThemeMode.system => 'Dark',
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined),
                        label: Text('Dark'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined),
                        label: Text('Light'),
                      ),
                    ],
                    selected: {
                      switch (mode) {
                        ThemeMode.light => ThemeMode.light,
                        _ => ThemeMode.dark,
                      },
                    },
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) {
                      ThemeController.instance.set(selection.first);
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------

  Future<bool> _ensurePermission(Permission permission) async {
    final status = await permission.status;
    if (status.isGranted) return true;
    final result = await permission.request();
    if (result.isGranted) return true;
    if (!kIsWeb && result.isPermanentlyDenied) {
      await openAppSettings();
    }
    return false;
  }

  Future<void> _togglePermission(Permission permission) async {
    final status = await permission.status;
    if (status.isGranted) {
      await openAppSettings();
      return;
    }
    final granted = await _ensurePermission(permission);
    _permissionRefresher.value = !_permissionRefresher.value;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            granted
                ? 'Permission granted'
                : 'Permission denied — check app settings',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _permissionRow({
    required IconData icon,
    required String title,
    required Permission permission,
    required ColorScheme cs,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: _permissionRefresher,
      builder: (context, _, child) {
        return FutureBuilder<PermissionStatus>(
          future: permission.status,
          builder: (context, snapshot) {
            final granted = snapshot.data?.isGranted ?? false;
            return SettingsRow(
              icon: icon,
              iconColor: granted ? cs.secondary : _warnColor(cs),
              title: title,
              value: granted ? 'Granted' : 'Denied',
              trailing: Switch(
                value: granted,
                onChanged: (_) => _togglePermission(permission),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPermissionsCard(ColorScheme cs) {
    return SettingsCard(
      children: [
        _permissionRow(
          icon: Icons.mic_rounded,
          title: 'Microphone',
          permission: Permission.microphone,
          cs: cs,
        ),
        _permissionRow(
          icon: Icons.videocam_rounded,
          title: 'Camera',
          permission: Permission.camera,
          cs: cs,
        ),
        _permissionRow(
          icon: Icons.notifications_rounded,
          title: 'Notifications',
          permission: Permission.notification,
          cs: cs,
        ),
      ],
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
            right: 16,
            top: 48,
            width: 110,
            height: 150,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(14),
                color: Colors.black54,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
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
                    : BoxDecoration(color: cs.surface),
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
          child: Icon(Icons.person, size: 60, color: cs.primary),
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
              Icon(Icons.access_time_rounded, size: 18, color: cs.secondary),
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
              padding: EdgeInsets.symmetric(horizontal: isWide ? 120 : 32),
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
            isVideo: false,
            cs: cs,
            isLandscape: isLandscape,
          ),
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
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.access_time_rounded, size: 18, color: Colors.white),
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
              padding: EdgeInsets.symmetric(horizontal: isWide ? 120 : 32),
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
            isVideo: true,
            cs: cs,
            isLandscape: isLandscape,
          ),
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
    final buttons = <Widget>[
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
        icon: _sip.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
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
          icon: _sip.isHeld ? Icons.play_arrow_rounded : Icons.pause_rounded,
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
      _CallControlButton(
        icon: Icons.fiber_manual_record_rounded,
        label: 'Record',
        disabled: true,
        isOnDark: isVideo,
        onPressed: null,
      ),
    ];

    final spacing = isLandscape ? 12.0 : 16.0;
    final mid = (buttons.length / 2).ceil();

    Widget row(List<Widget> items) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) SizedBox(width: spacing),
            items[i],
          ],
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row(buttons.take(mid).toList()),
          SizedBox(height: spacing),
          row(buttons.skip(mid).toList()),
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
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
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
      child: Row(children: keys.map((key) => _buildDtmfKey(key)).toList()),
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
    final fgColor = isActive
        ? Colors.white
        : (isOnDark ? Colors.white : cs.onSurface);
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
                onPressed: () => Navigator.of(context).pop(_selected),
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

// ---------------------------------------------------------------------
// Bottom-sheet widgets shared by the dashboard
// ---------------------------------------------------------------------

String _breakLabel(dynamic option) {
  if (option is Map) {
    final label =
        option['label'] ??
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
    final type =
        option['value'] ?? option['type'] ?? option['name'] ?? option['id'];
    if (type != null) return type.toString();
  }
  return option?.toString() ?? 'General Break';
}

IconData breakIconFor(String label) {
  final l = label.toLowerCase();
  if (l.contains('lunch') || l.contains('dinner') || l.contains('meal')) {
    return Icons.restaurant_rounded;
  }
  if (l.contains('coffee') || l.contains('tea') || l.contains('drink')) {
    return Icons.local_cafe_rounded;
  }
  if (l.contains('short') || l.contains('quick') || l.contains('brief')) {
    return Icons.timer_outlined;
  }
  if (l.contains('meeting') || l.contains('call') || l.contains('conference')) {
    return Icons.groups_rounded;
  }
  if (l.contains('break') || l.contains('rest') || l.contains('pause')) {
    return Icons.free_breakfast_rounded;
  }
  return Icons.self_improvement_rounded;
}

/// Quick break picker shown from the shell bar "Take Break" chip.
class _BreakQuickSheet extends StatelessWidget {
  const _BreakQuickSheet({
    required this.breakOptions,
    required this.currentBreak,
    required this.onSetBreak,
    required this.onRemoveBreak,
  });

  final List<dynamic> breakOptions;
  final String? currentBreak;
  final ValueChanged<String> onSetBreak;
  final VoidCallback onRemoveBreak;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final onBreak = currentBreak != null;
    return _sheetContainer(
      cs: cs,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sheetHeader(
            cs: cs,
            icon: onBreak
                ? breakIconFor(currentBreak!)
                : Icons.free_breakfast_rounded,
            iconColor: cs.tertiary,
            title: onBreak ? 'On break: $currentBreak' : 'Take a Break',
            subtitle: onBreak
                ? 'Break is running'
                : 'Pick a break type to start',
          ),
          const SizedBox(height: 16),
          if (breakOptions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No break options available',
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in breakOptions) _buildChip(cs, option),
              ],
            ),
          if (onBreak) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onRemoveBreak,
                icon: const Icon(Icons.event_available_rounded),
                label: const Text('Remove Break'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChip(ColorScheme cs, dynamic option) {
    final label = _breakLabel(option);
    final type = _breakType(option);
    final selected = currentBreak == type;
    return FilterChip(
      label: Text(label),
      avatar: Icon(
        breakIconFor(label),
        size: 16,
        color: selected ? cs.tertiary : null,
      ),
      selected: selected,
      selectedColor: cs.tertiary.withValues(alpha: 0.14),
      checkmarkColor: cs.tertiary,
      showCheckmark: false,
      onSelected: (_) => onSetBreak(type),
    );
  }
}

/// Pinned day header for the Recent tab.
class _StickyDayHeaderDelegate extends SliverPersistentHeaderDelegate {
  _StickyDayHeaderDelegate({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  double get minExtent => 32;

  @override
  double get maxExtent => 32;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: color,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 4, AppSpacing.lg, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: AppType.overline,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: cs.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickyDayHeaderDelegate oldDelegate) {
    return oldDelegate.label != label || oldDelegate.color != color;
  }
}

Widget _sheetContainer({required ColorScheme cs, required Widget child}) {
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
