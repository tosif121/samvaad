import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'outgoing_call_screen.dart';
import 'incoming_call_screen.dart';
import 'video_call_screen.dart';
import 'login_screen.dart';
import '../widgets/dial_button.dart';
import '../services/auth_service.dart';
import '../services/sip_socket_service.dart';
import '../services/ringtone_service.dart';
import '../services/fcm_service.dart';
import '../services/callkit_service.dart';

class DialpadScreen extends StatefulWidget {
  final String userName;
  final String userEmail;

  const DialpadScreen({
    super.key,
    required this.userName,
    required this.userEmail,
  });

  @override
  State<DialpadScreen> createState() => _DialpadScreenState();
}

class _DialpadScreenState extends State<DialpadScreen> with WidgetsBindingObserver {
  String _dialedNumber = '';
  final _sip = SipSocketService();
  StreamSubscription? _sipSubscription;
  bool _isOutgoingCall = false;
  bool _isShowingIncomingDialog = false;
  final Set<String> _recentlyHandled = {};
  String _lastIncomingNumber = '';
  bool _callHandled = false;
  bool _navigatedToCallScreen = false;
  int _incomingCallCount = 0;
  bool _pendingAutoAnswer = false;
  bool _broughtToForegroundByCallKit = false;
  DateTime? _appStartedAt;

  @override
  void initState() {
    print('[SCREEN] DialpadScreen ACTIVE');
    super.initState();
    _appStartedAt = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    _requestMicrophonePermission();

    // Check pending CallKit action FIRST — before SIP init
    _checkPendingCallkitAction().then((_) {
      if (!mounted) return;
      // If we navigated away (CallKit answer), skip everything else
      if (_navigatedToCallScreen) {
        print('[DIALPAD] CallKit answer navigated — skipping SIP + FCM init');
        return;
      }
      // Start SIP initialization
      _initSip();
      // Then check FCM as fallback
      _checkPendingFcmCall();
      _initFcm();
    });
  }

  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('[LIFECYCLE] $state');
    _appLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      print('[DIALPAD] App resumed | callState=${_sip.callState.name} | isShowingDialog=$_isShowingIncomingDialog | callHandled=$_callHandled | navi=$_navigatedToCallScreen');
      if (_navigatedToCallScreen) return;
      RingtoneService().clearNotification();
      // Check for pending CallKit action (accept/decline from native notification)
      _checkPendingCallkitAction().then((_) {
        if (!mounted || _navigatedToCallScreen) return;
        _checkPendingFcmCall();
        final appJustStarted = _appStartedAt != null &&
            DateTime.now().difference(_appStartedAt!).inSeconds < 10;
        if (_sip.callState == CallState.ringing &&
            !_isShowingIncomingDialog &&
            !_callHandled &&
            !_pendingAutoAnswer &&
            !_broughtToForegroundByCallKit &&
            !appJustStarted) {
          print('[DIALPAD] Resume: showing incoming call dialog for ${_sip.incomingNumber}');
          if (_sip.isRegistered) {
            _showIncomingCall(_sip.incomingNumber);
          } else {
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted && !_navigatedToCallScreen && _sip.isRegistered && _sip.callState == CallState.ringing) {
                _showIncomingCall(_sip.incomingNumber);
              }
            });
          }
        } else {
          print('[DIALPAD] Resume: skipping incoming call dialog');
        }
      });
    }
  }

  Future<void> _initFcm() async {
    print('[DIALPAD] _initFcm() called');
    await _requestNotificationPermission();
    await FcmService().init();
    await Future.delayed(const Duration(milliseconds: 300));
    print('[DIALPAD] _initFcm() completed');
    if (!mounted) return;
    print('[DIALPAD] _initFcm: about to check pending FCM');
    await _checkPendingFcmCall();
    print('[DIALPAD] _initFcm: done checking pending, calling setState');
    setState(() {});
  }

  Future<void> _checkPendingFcmCall() async {
    print('[DIALPAD] _checkPendingFcmCall: checking...');
    if (_sip.hasPendingAnswer || _sip.callState != CallState.idle) {
      print('[DIALPAD] _checkPendingFcmCall: call already being handled — skipping');
      return;
    }
    final number = await FcmService().getPendingFcmCall();
    if (number == null || number.isEmpty) {
      print('[DIALPAD] _checkPendingFcmCall: none found');
      return;
    }
    
    // Check if user tapped notification (auto-answer flag)
    final autoAnswer = await FcmService().getAutoAnswerFlag();
    await FcmService().clearPendingFcmCall();
    
    print('[DIALPAD] Pending FCM call found for: $number | autoAnswer=$autoAnswer | callState=${_sip.callState.name} | callHandled=$_callHandled');
    if (_sip.callState != CallState.idle) {
      print('[DIALPAD] Skipping pending FCM — SIP not idle');
      return;
    }

    // Set flag — will auto-answer when SIP incomingCall event arrives
    _pendingAutoAnswer = autoAnswer;
    _broughtToForegroundByCallKit = true;
    RingtoneService().stopRinging();
    await RingtoneService().clearNotification();
    await RingtoneService().cleanupForegroundService();
    await FlutterCallkitIncoming.endAllCalls();
    print('[DIALPAD] FCM answer: flag set (autoAnswer=$autoAnswer) — will auto-answer when SIP connects');
  }

  Future<void> _checkPendingCallkitAction() async {
    final action = await CallKitService().getPendingAction();
    if (action == null) return;
    await CallKitService().clearPendingAction();

    if (action['action'] == 'decline') {
      print('[DIALPAD] CallKit pending action: DECLINE — cleanup');
      await RingtoneService().cleanupForegroundService();
      await RingtoneService().clearNotification();
      await FcmService().clearPendingFcmCall();
      return;
    }
    if (action['action'] != 'answer') return;

    final number = action['number'] as String? ?? 'Unknown';
    print('[DIALPAD] CallKit pending action: ANSWER for $number — will auto-answer when SIP connects');
    _pendingAutoAnswer = true;
    _broughtToForegroundByCallKit = true;
    RingtoneService().stopRinging();
    await RingtoneService().clearNotification();
    await RingtoneService().cleanupForegroundService();
    await FcmService().clearPendingFcmCall();
    await FlutterCallkitIncoming.endAllCalls();
  }

  Future<void> _requestNotificationPermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.notification.status;
      if (status.isDenied || status.isPermanentlyDenied) {
        await Permission.notification.request();
      }
      final alertStatus = await Permission.systemAlertWindow.status;
      if (!alertStatus.isGranted) {
        await Permission.systemAlertWindow.request();
      }
      try {
        await FlutterCallkitIncoming.requestFullIntentPermission();
      } catch (e) {
        print('Failed to request full intent permission: $e');
      }
    }
  }

  Future<void> _requestMicrophonePermission() async {
    await Permission.microphone.request();
    await Permission.camera.request();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sipSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initSip() async {
    // Check if already connected/registered from login screen
    if (_sip.isConnected && _sip.isRegistered) {
      print('[DIALPAD] SIP already connected and registered from login — skipping connect');
      // Still listen for events
      _sipSubscription = _sip.events.listen((event) async {
        if (!mounted) return;
        final type = event['event'] as String;
        print('[DIALPAD] Received SIP Event: $type | Data: $event');
        _handleSipEvent(type, event);
      });
      return;
    }

    // Listen for SIP events before connecting
    _sipSubscription = _sip.events.listen((event) async {
      if (!mounted) return;
      final type = event['event'] as String;
      print('[DIALPAD] Received SIP Event: $type | Data: $event');
      _handleSipEvent(type, event);
    });

    // Connect SIP WebSocket + register
    await _sip.connect();
    if (mounted) setState(() {});
  }

  Future<void> _handleSipEvent(String type, Map<String, dynamic> event) async {
    switch (type) {
      case 'incomingCall':
        _incomingCallCount++;
        final number = event['number'] as String? ?? 'Unknown';
        print('[DIALPAD] incomingCall#$_incomingCallCount number=$number | callState=${_sip.callState.name} | isShowingDialog=$_isShowingIncomingDialog | callHandled=$_callHandled | navi=$_navigatedToCallScreen');

        // Guard: don't show UI if already navigating to call screen
        if (_navigatedToCallScreen) {
          print('[DIALPAD] Skipping incomingCall — already navigating to call screen');
          break;
        }

        // Guard: don't show UI if already in a call or already handling one
        if (_sip.callState == CallState.onCall || _isShowingIncomingDialog || _callHandled || _sip.hasPendingAnswer) {
          print('[DIALPAD] Skipping incomingCall — guard condition met');
          break;
        }

        if (_recentlyHandled.contains(number)) {
          print('[DIALPAD] Number $number recently handled in memory — rejecting');
          await _sip.rejectCall();
          break;
        }
        RingtoneService().stopRinging();

        // AUTO-ANSWER: User accepted from CallKit/FCM before SIP connected
        // Also skip dialog if app just started (killed → brought to foreground by CallKit)
        final appJustStarted = _appStartedAt != null &&
            DateTime.now().difference(_appStartedAt!).inSeconds < 10;
        if (_pendingAutoAnswer || _broughtToForegroundByCallKit || appJustStarted) {
          print('[DIALPAD] Auto-answer: pending=$_pendingAutoAnswer broughtByCallKit=$_broughtToForegroundByCallKit appJustStarted=$appJustStarted — answering directly, no dialog');
          _pendingAutoAnswer = false;
          _broughtToForegroundByCallKit = false;
          await _sip.answerCall(video: _sip.isVideo);
          _navigatedToCallScreen = true;
          if (mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => _sip.isVideo
                    ? VideoCallScreen(phoneNumber: number)
                    : OutgoingCallScreen(phoneNumber: number),
              ),
            );
          }
          break;
        }

        if (_appLifecycleState != AppLifecycleState.resumed) {
          print('[DIALPAD] App is backgrounded — CallKit handles from FCM');
          if (_isShowingIncomingDialog && mounted) {
            Navigator.of(context).pop();
            _isShowingIncomingDialog = false;
          }
        } else {
          print('[DIALPAD] Foreground — checking if CallKit is already showing');
          try {
            final active = await FlutterCallkitIncoming.activeCalls();
            if (active.isNotEmpty) {
              print('[DIALPAD] CallKit already active — skipping Flutter dialog');
              break;
            }
          } catch (_) {}
          _showIncomingCall(number);
        }
        break;

      case 'callAnswered':
        print('[DIALPAD] callAnswered — stop ringing');
        _callHandled = false;
        _isShowingIncomingDialog = false;
        _recentlyHandled.clear();
          RingtoneService().stopRinging();
          if (_sip.incomingNumber.isNotEmpty && !_isOutgoingCall && !_navigatedToCallScreen) {
            _navigatedToCallScreen = true;
            final num = _sip.incomingNumber;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => _sip.isVideo
                    ? VideoCallScreen(phoneNumber: num)
                    : OutgoingCallScreen(phoneNumber: num),
              ),
            );
          }
          break;

        case 'callEnded':
        case 'callFailed':
          print('[DIALPAD] $type — clearing state');
          _callHandled = false;
          _pendingAutoAnswer = false;
          // Keep recently handled number for 15 seconds to prevent immediate re-ringing from PBX
          Future.delayed(const Duration(seconds: 15), () {
            if (mounted) {
              _recentlyHandled.clear();
            }
          });
          RingtoneService().stopRinging();
          _isOutgoingCall = false;
          _lastIncomingNumber = '';
          _isShowingIncomingDialog = false;
          _navigatedToCallScreen = false;
          // Don't pop navigator here — the owning screen (IncomingCall or OutgoingCall)
          // will handle its own navigation via its own event listener.
          break;

        case 'registered':
          if (mounted) setState(() {});
          break;

        case 'registrationFailed':
          if (mounted) setState(() {});
          _showConnectionError('registration_failed');
          break;

        case 'connectionLost':
          if (mounted) setState(() {});
          break;

        case 'connectionRestored':
          if (mounted) setState(() {});
          break;

        default:
          if (mounted) setState(() {});
    }
  }

  void _showConnectionError(String reason) {
    final isRegistrationFail = reason == 'registration_failed';
    final msg = isRegistrationFail
        ? 'Registration failed. Please try again.'
        : reason == 'session_expired'
            ? 'Session expired. Please login again.'
            : 'Poor connection. Please login again.';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(isRegistrationFail ? 'Registration Failed' : 'Connection Lost'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              if (isRegistrationFail) {
                _sip.disconnect();
                await _sip.connect();
              } else {
                await AuthService.logout();
                if (mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                    (route) => false,
                  );
                }
              }
            },
            child: Text(isRegistrationFail ? 'Reconnect' : 'OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _showIncomingCall(String number) async {
    if (_isShowingIncomingDialog) {
      print('[DIALPAD] _showIncomingCall skipped — already showing dialog');
      return;
    }
    if (_sip.hasPendingAnswer || _sip.callState == CallState.onCall || _sip.callState == CallState.dialing) {
      print('[DIALPAD] _showIncomingCall skipped — call already being handled or dialing');
      return;
    }
    print('[DIALPAD] _showIncomingCall for $number');
    _isShowingIncomingDialog = true;
    _callHandled = false;
    _recentlyHandled.add(number);
    // Stop native Kotlin ringtone first to avoid double ringing
    RingtoneService().cleanupForegroundService();
    await Future.delayed(const Duration(milliseconds: 200));
    RingtoneService().startRinging();
    RingtoneService().clearNotification();
    
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

    // result is Map{'answer': true, 'video': bool} or false/null
    final answered = result is Map && result['answer'] == true;
    final videoAnswer = result is Map ? (result['video'] as bool? ?? false) : false;

    if (answered) {
      if (!_sip.isRegistered) {
        print('[DIALPAD] Waiting for SIP registration before answering...');
        int waitCount = 0;
        while (!_sip.isRegistered && mounted) {
          await Future.delayed(const Duration(milliseconds: 100));
          waitCount++;
          if (waitCount > 50) {
            print('[DIALPAD] Timeout waiting for SIP registration');
            break;
          }
        }
      }
      if (!mounted) return;

      RingtoneService().clearNotification();
      _navigatedToCallScreen = true;
      await _sip.answerCall(video: videoAnswer);
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => videoAnswer
                ? VideoCallScreen(phoneNumber: number)
                : OutgoingCallScreen(phoneNumber: number),
          ),
        ).then((_) {
          _navigatedToCallScreen = false;
        });
      }
    } else {
      RingtoneService().clearNotification();
    }
  }

  void _onDigitPressed(String digit) {
    HapticFeedback.lightImpact();
    if (_dialedNumber.length < 16) {
      setState(() => _dialedNumber += digit);
    }
  }

  void _onBackspace() {
    if (_dialedNumber.isNotEmpty) {
      setState(
        () => _dialedNumber = _dialedNumber.substring(
          0,
          _dialedNumber.length - 1,
        ),
      );
    }
  }

  String get _connectionStatus {
    if (_sip.isRegistered) return 'Ready';
    if (_sip.isConnected) return 'Registering…';
    return 'Connecting…';
  }

  bool get _isConnected => _sip.isRegistered;

  Widget _buildStatusBadge() {
    final status = _connectionStatus;
    final connected = _isConnected;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: connected ? Colors.greenAccent : Colors.orangeAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            status,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onCall({bool video = false}) async {
    if (_dialedNumber.isEmpty) return;
    if (!_sip.isRegistered) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected. Please wait...')),
      );
      return;
    }
    print('[DIALPAD] _onCall(video=$video) for: $_dialedNumber');
    final number = _dialedNumber;
    _isOutgoingCall = true;
    setState(() => _dialedNumber = '');
    _sip.makeCall(number, video: video);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => video
            ? VideoCallScreen(phoneNumber: number)
            : OutgoingCallScreen(phoneNumber: number),
      ),
    );
    _isOutgoingCall = false;
  }

  @override
  Widget build(BuildContext context) {
    final isReady = _sip.isRegistered;
    final isDark  = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0F1115) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF1a1a1a);
    final secTextColor = isDark ? const Color(0xFFB8BDC9) : const Color(0xFF6B7280);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        titleSpacing: 20,
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            // Connection status dot
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                color: isReady ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              isReady ? 'Samvaad' : 'Connecting…',
              style: TextStyle(
                color: textColor,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
        actions: [
          Builder(
            builder: (ctx) => GestureDetector(
              onTap: () => Scaffold.of(ctx).openDrawer(),
              child: Container(
                margin: const EdgeInsets.only(right: 16),
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    widget.userName.isNotEmpty ? widget.userName[0].toUpperCase() : 'U',
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),

            // ── Number display ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      _dialedNumber.isEmpty ? '' : _formatNumber(_dialedNumber),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: _dialedNumber.length > 10 ? 28 : 36,
                        fontWeight: FontWeight.w300,
                        color: textColor,
                        letterSpacing: 2.5,
                      ),
                    ),
                  ),
                  // Backspace
                  GestureDetector(
                    onTap: _onBackspace,
                    onLongPress: () { HapticFeedback.heavyImpact(); setState(() => _dialedNumber = ''); },
                    child: AnimatedOpacity(
                      opacity: _dialedNumber.isNotEmpty ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(Icons.backspace_rounded, color: secTextColor, size: 22),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // ── Dialpad grid ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                children: [
                  _buildDialRow(['1', '2', '3']),
                  const SizedBox(height: 18),
                  _buildDialRow(['4', '5', '6']),
                  const SizedBox(height: 18),
                  _buildDialRow(['7', '8', '9']),
                  const SizedBox(height: 18),
                  _buildDialRow(['*', '0', '#']),
                ],
              ),
            ),

            const SizedBox(height: 36),

            // ── Action buttons row ────────────────────────────────────────
            SizedBox(
              height: 80,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Video call
                  _DialActionButton(
                    icon: Icons.videocam_rounded,
                    color: const Color(0xFF2563EB),
                    size: 60,
                    iconSize: 26,
                    enabled: _dialedNumber.isNotEmpty && isReady,
                    onTap: () => _onCall(video: true),
                  ),
                  const SizedBox(width: 28),
                  // Audio call — larger, primary
                  _DialActionButton(
                    icon: Icons.call_rounded,
                    color: const Color(0xFF22C55E),
                    size: 72,
                    iconSize: 32,
                    enabled: _dialedNumber.isNotEmpty && isReady,
                    onTap: () => _onCall(video: false),
                  ),
                  const SizedBox(width: 28),
                  // Placeholder spacer (mirror of video btn for symmetry)
                  const SizedBox(width: 60, height: 60),
                ],
              ),
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  String _formatNumber(String n) {
    // Simple grouping: show raw but with a space every 3-4 digits for readability
    if (n.length <= 5) return n;
    return n;
  }

  Widget _buildDialRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits
          .map((d) => DialButton(digit: d, onPressed: () => _onDigitPressed(d)))
          .toList(),
    );
  }

  Widget _buildDrawer() {
    final isReady = _sip.isRegistered;
    final isDark  = Theme.of(context).brightness == Brightness.dark;
    final drawerBg = isDark ? const Color(0xFF181A20) : Colors.white;
    final headerBg = isDark ? const Color(0xFF0F1115) : const Color(0xFFF5F9FC);
    final textColor = isDark ? Colors.white : const Color(0xFF1a1a1a);
    final secTextColor = isDark ? const Color(0xFFB8BDC9) : const Color(0xFF6B7280);
    final dividerColor = isDark ? const Color(0xFF2A2D36) : const Color(0xFFE5E8ED);

    return Drawer(
      backgroundColor: drawerBg,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(24, 60, 24, 28),
            color: headerBg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2563EB),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      widget.userName.isNotEmpty ? widget.userName[0].toUpperCase() : 'U',
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(widget.userName,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: textColor)),
                const SizedBox(height: 3),
                Text(widget.userEmail,
                    style: TextStyle(fontSize: 13, color: secTextColor)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: (isReady ? const Color(0xFF22C55E) : const Color(0xFFF59E0B)).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: (isReady ? const Color(0xFF22C55E) : const Color(0xFFF59E0B)).withValues(alpha: 0.4),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6, height: 6,
                        decoration: BoxDecoration(
                          color: isReady ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isReady ? 'Registered' : _connectionStatus,
                        style: TextStyle(
                          fontSize: 12,
                          color: isReady ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          Divider(color: dividerColor, height: 1),
          SafeArea(
            top: false,
            child: ListTile(
              leading: const Icon(Icons.logout_rounded, color: Color(0xFFEF4444)),
              title: const Text('Logout', style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.w600)),
              onTap: () async {
                _sip.disconnect();
                await AuthService.logout();
                if (!mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── Dial action button (call / video) ─────────────────────────────────────────
class _DialActionButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final bool enabled;
  final VoidCallback onTap;

  const _DialActionButton({
    required this.icon,
    required this.color,
    required this.size,
    required this.iconSize,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_DialActionButton> createState() => _DialActionButtonState();
}

class _DialActionButtonState extends State<_DialActionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 110));
    _scale = Tween<double>(begin: 1.0, end: 0.9)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.enabled ? (_) { HapticFeedback.mediumImpact(); _ctrl.forward(); } : null,
      onTapUp:   widget.enabled ? (_) { _ctrl.reverse(); widget.onTap(); } : null,
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: Opacity(
          opacity: widget.enabled ? 1.0 : 0.35,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
              boxShadow: widget.enabled ? [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.45),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ] : null,
            ),
            child: Icon(widget.icon, color: Colors.white, size: widget.iconSize),
          ),
        ),
      ),
    );
  }
}
