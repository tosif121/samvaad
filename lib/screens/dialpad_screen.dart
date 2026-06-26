import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'outgoing_call_screen.dart';
import 'incoming_call_screen.dart';
import 'login_screen.dart';
import '../widgets/dial_button.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
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

  @override
  void initState() {
    print('[SCREEN] DialpadScreen ACTIVE');
    super.initState();
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
        if (_sip.callState == CallState.ringing &&
            !_isShowingIncomingDialog &&
            !_callHandled) {
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
    await FcmService().clearPendingFcmCall();
    print('[DIALPAD] Pending FCM call found for: $number | callState=${_sip.callState.name} | callHandled=$_callHandled');
    if (_sip.callState != CallState.idle) {
      print('[DIALPAD] Skipping pending FCM — SIP not idle');
      return;
    }

    // Validate FCM against server — if no active call, the FCM is stale
    try {
      final ctx = await ApiService.userOnCall();
      final bridgeID = ctx['data']?['currentcalldata']?['bridgeID'] ?? '';
      if (bridgeID.isEmpty) {
        print('[DIALPAD] Server says no active call — FCM stale, ignoring');
        await FlutterCallkitIncoming.endAllCalls();
        return;
      }
    } catch (e) {
      print('[DIALPAD] userOnCall check failed — proceeding anyway: $e');
    }

    // Answer SIP call first, wait for connect, then navigate
    _callHandled = true; // Prevent incoming call dialog from showing while we wait
    RingtoneService().stopRinging();
    await RingtoneService().clearNotification();
    await RingtoneService().cleanupForegroundService();
    await FlutterCallkitIncoming.endAllCalls();

    _sip.answerCall();
    print('[DIALPAD] FCM answer: SIP answerCall sent — waiting for callAnswered...');

    final connected = await _waitForCallAnswered();
    if (!connected || !mounted) {
      print('[DIALPAD] FCM answer: call not connected — aborting');
      return;
    }

    print('[DIALPAD] FCM answer: call connected — navigating to call screen');
    _navigatedToCallScreen = true;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutgoingCallScreen(phoneNumber: number),
      ),
    );
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
    print('[DIALPAD] CallKit pending action: ANSWER for $number — connecting SIP first');
    _callHandled = true; // Prevent incoming call dialog from showing while we wait
    RingtoneService().stopRinging();
    await RingtoneService().clearNotification();
    await RingtoneService().cleanupForegroundService();
    await FcmService().clearPendingFcmCall();
    await FlutterCallkitIncoming.endAllCalls();

    _sip.answerCall();
    print('[DIALPAD] CallKit answer: SIP answerCall sent — waiting for callAnswered...');

    final connected = await _waitForCallAnswered();
    if (!connected || !mounted) {
      print('[DIALPAD] CallKit answer: call not connected — aborting');
      return;
    }

    print('[DIALPAD] CallKit answer: call connected — navigating to call screen');
    _navigatedToCallScreen = true;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OutgoingCallScreen(phoneNumber: number),
      ),
    );
  }

  /// Wait for SIP callAnswered event (up to 15 seconds)
  Future<bool> _waitForCallAnswered() async {
    int waitCount = 0;
    while (mounted) {
      if (_sip.callState == CallState.onCall) {
        print('[DIALPAD] _waitForCallAnswered: callState already onCall');
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 200));
      waitCount++;
      if (waitCount > 75) {
        print('[DIALPAD] _waitForCallAnswered: timeout after 15s');
        return false;
      }
    }
    return false;
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
    // Permission is handled by flutter_webrtc at call time.
    // No pre-fetch needed - avoids Android audio resource conflicts.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sipSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initSip() async {
    // Listen for SIP events before connecting
    _sipSubscription = _sip.events.listen((event) async {
      if (!mounted) return;
      final type = event['event'] as String;
      print('[DIALPAD] Received SIP Event: $type | Data: $event');

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
          _isShowingIncomingDialog = false; // dialog is stale — OutgoingCallScreen pushed above
          _recentlyHandled.clear();
          RingtoneService().stopRinging();
          if (_sip.incomingNumber.isNotEmpty && !_isOutgoingCall && !_navigatedToCallScreen) {
            _navigatedToCallScreen = true;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => OutgoingCallScreen(phoneNumber: _sip.incomingNumber),
              ),
            );
          }
          break;

        case 'callEnded':
        case 'callFailed':
          print('[DIALPAD] $type — clearing state');
          _callHandled = false;
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
    });

    // Connect SIP WebSocket + register
    await _sip.connect();
    if (mounted) setState(() {});
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
    
    final result = await showGeneralDialog<bool>(
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

    if (result == true) {
      // INSTANT TRANSITION - but ensure SIP is ready first
      if (!_sip.isRegistered) {
        print('[DIALPAD] Waiting for SIP registration before answering...');
        int waitCount = 0;
        while (!_sip.isRegistered && mounted) {
          await Future.delayed(const Duration(milliseconds: 100));
          waitCount++;
          if (waitCount > 50) { // 5 second timeout
            print('[DIALPAD] Timeout waiting for SIP registration');
            break;
          }
        }
      }
      if (!mounted) return;

      // Clear notification when call is answered
      RingtoneService().clearNotification();

      // INSTANT TRANSITION
      _navigatedToCallScreen = true;
      _sip.answerCall();
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => OutgoingCallScreen(
              phoneNumber: number,
            ),
          ),
        ).then((_) {
          _navigatedToCallScreen = false;
        });
      }
    } else {
      // Call was declined - clear notification
      RingtoneService().clearNotification();
    }
  }

  void _onDigitPressed(String digit) {
    if (_dialedNumber.length < 10) {
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
    final data = _sip.connectionData;
    if (data == null) return 'Connecting…';
    final msg = data['status']?.toString() ?? data['message']?.toString();
    if (msg != null && msg.isNotEmpty) return msg;
    return 'Online';
  }

  bool get _isConnected =>
      _sip.connectionData?['status'] != 'poor connection' &&
      _sip.connectionData?['isUserLogin'] != false;

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

  Future<void> _onCall() async {
    if (_dialedNumber.isEmpty) return;
    print('[DIALPAD] _onCall() initiated for number: $_dialedNumber');

    _sip.setDialedNumber(_dialedNumber);
    _isOutgoingCall = true;
    print('[DIALPAD] Calling ApiService.agentAvailable()');
    final agentResult = await ApiService.agentAvailable();
    print('[DIALPAD] agentAvailable result: $agentResult');
    print('[DIALPAD] Calling ApiService.dialNumber($_dialedNumber)');
    final result = await ApiService.dialNumber(_dialedNumber);
    print('[DIALPAD] dialNumber result: $result');
    if (!mounted) return;

    if (result['success'] == true) {
      print('[DIALPAD] dialNumber SUCCESS, navigating to OutgoingCallScreen');
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OutgoingCallScreen(phoneNumber: _dialedNumber),
        ),
      );
      setState(() => _dialedNumber = '');
    } else {
      print('[DIALPAD] dialNumber FAILED: ${result['message']}');
      _isOutgoingCall = false;
      _sip.setDialedNumber('');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Samvaad'),
        titleSpacing: 16,
        automaticallyImplyLeading: false,
        actions: [
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: SafeArea(

        child: Column(

          children: [
            const Spacer(),
            const SizedBox(height: 40),
            // Number display row with backspace
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Center(
                      child: Text(
                        _dialedNumber.isEmpty ? 'Enter number' : _dialedNumber,
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w500,
                          color: _dialedNumber.isEmpty
                              ? Colors.grey[400]
                              : const Color(0xFF1a1a1a),
                          letterSpacing: 2,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                  if (_dialedNumber.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.backspace_outlined),
                      onPressed: _onBackspace,
                      color: Colors.grey[600],
                    ),
                ],
              ),
            ),
            const SizedBox(height:  40),
            // Dialpad
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  _buildDialRow(['1', '2', '3']),
                  const SizedBox(height: 16),
                  _buildDialRow(['4', '5', '6']),
                  const SizedBox(height: 16),
                  _buildDialRow(['7', '8', '9']),
                  const SizedBox(height: 16),
                  _buildDialRow(['*', '0', '#']),
                ],
              ),
            ),
            const SizedBox(height: 32),
            // Call button
            Container(
              width: 72,
              height: 72,
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
              child: IconButton(
                icon: const Icon(Icons.call, size: 32),
                color: Colors.white,
                onPressed: _onCall,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
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
    return Drawer(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(24, 60, 24, 32),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF4299EB),
                  const Color(0xFF4299EB).withValues(alpha: 0.8),
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      widget.userName.isNotEmpty
                          ? widget.userName[0].toUpperCase()
                          : 'U',
                      style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF4299EB),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.userName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.userEmail,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
                const SizedBox(height: 8),
                _buildStatusBadge(),
              ],
            ),
          ),
          const Spacer(),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.all(16),
              child: ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text(
                  'Logout',
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
          ),
        ],
      ),
    );
  }
}
