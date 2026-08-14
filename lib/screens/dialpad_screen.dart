import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'incoming_call_screen.dart';
import '../services/fcm_service.dart';
import 'login_screen.dart';
import '../models/call_log_entry.dart';
import '../services/call_log_service.dart';
import '../services/sip_socket_service.dart';
import '../services/ringtone_service.dart';
import '../services/user_data.dart';
import '../ui/theme.dart';
import '../ui/tokens.dart';
import '../ui/widgets/avatar.dart';
import '../ui/widgets/buttons.dart';
import '../ui/widgets/call_history_tile.dart';
import '../ui/widgets/chips.dart';
import '../ui/widgets/common.dart';
import '../ui/widgets/follow_up_tile.dart';
import '../ui/widgets/dynamic_form_sheet.dart';
import '../ui/widgets/user_call_form_sheet.dart';
import '../ui/widgets/schedule_callback_sheet.dart';

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
  bool _isBreaksEnabled = true;
  int _autoDialGeneration = 0;
  bool _autoDialRunning = false;
  final Set<String> _autoDialedPhones = {};

  bool _conferenceStatus = false;
  bool _conferenceConnected = false;
  bool _isMerged = false;
  bool _showConferenceKeypad = false;
  String _conferenceNumber = '';
  String _dtmfNumber = '';

  String? _lastHandledNumber;
  DateTime? _lastHandledAt;
  final Map<String, DateTime> _recentlyRejected = {};

  CallLogDirection? _lastCallDirection;

  final Set<String> _callBackingCallers = {};
  final Set<String> _completingCallbacks = {};
  final Set<String> _activeCallbackIds = {};

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  @override
  void initState() {
    super.initState();
    _initRenderers();
    WidgetsBinding.instance.addObserver(this);
    _initSip();
    _callLog.load();
    _loadUsername();
    _restoreBreakState();
    _loadUserConfig();
    _phoneFocusNode.addListener(() {
      if (_phoneFocusNode.hasFocus) {
        _phoneFocusNode.unfocus();
      }
    });
  }

  Future<void> _loadUserConfig() async {
    await UserData.init();
    if (!mounted) return;
    setState(() {
      _isBreaksEnabled = UserData.isBreaksEnabled();
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

      if (!_sip.isRegistered) {
        _sip.connect();
      }

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

  Future<bool> _requestPermissions({bool isVideo = false}) async {
    if (isVideo) {
      final statuses = await [
        Permission.microphone,
        Permission.camera,
      ].request();
      return (statuses[Permission.microphone]?.isGranted ?? false) &&
          (statuses[Permission.camera]?.isGranted ?? false);
    }
    final status = await Permission.microphone.request();
    return status.isGranted;
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

      switch (type) {
        case 'incomingCall':
          final number = event['number'] as String? ?? 'Unknown';

          if (_sip.shouldAutoAnswerNextCall) {
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
            break;
          }

          if (_isOnCall) break;
          if (_isShowingIncomingDialog) break;

          final isQueueFallback = event['fromQueue'] == true;

          // Never surface the incoming call screen while on break: reject any
          // real SIP session (so it stops ringing), but ignore queue fallbacks
          // so the caller stays in the queue (rejecting would hang it up).
          if (_currentBreak != null) {
            if (!isQueueFallback) {
              await _sip.rejectCall();
            }
            break;
          }

          // Only the synthetic queue-fallback ring (fired by the 5s poll before
          // the real INVITE lands) is suppressed for a recently declined caller.
          // A real SIP INVITE is a genuine (re)call attempt and must always ring.
          if (isQueueFallback) {
            final recentlyHandledSameNumber =
                _lastHandledNumber == number &&
                _lastHandledAt != null &&
                DateTime.now().difference(_lastHandledAt!) <
                    const Duration(seconds: 3);
            final recentlyRejected = _recentlyRejected.entries.any(
              (e) =>
                  (e.key == number || e.key == number.replaceAll('+', '')) &&
                  DateTime.now().difference(e.value) <
                      const Duration(seconds: 15),
            );
            if (recentlyHandledSameNumber || recentlyRejected) {
              await _sip.rejectCall();
              break;
            }
          }

          _callWasAnswered = false;
          _activeLogEntry = _createLogEntry(
            number: number,
            direction: CallLogDirection.incoming,
            source: event['fromQueue'] == true ? 'Queue' : 'Incoming',
          );

          if (_appLifecycleState != AppLifecycleState.resumed) {
            log(
              '[DIALPAD] Incoming call received while app is backgrounded/minimized for $number',
            );
            RingtoneService().startRinging();
            RingtoneService().bringAppToForeground();

            const androidDetails = AndroidNotificationDetails(
              'incoming_calls_channel',
              'Incoming Calls',
              channelDescription: 'Notifications for incoming call alerts',
              importance: Importance.max,
              priority: Priority.high,
              fullScreenIntent: true,
              category: AndroidNotificationCategory.call,
              playSound: true,
            );
            const notificationDetails = NotificationDetails(
              android: androidDetails,
            );
            FlutterLocalNotificationsPlugin().show(
              0,
              'Incoming Call',
              'Incoming call from $number',
              notificationDetails,
              payload: jsonEncode({'number': number}),
            );
          } else {
            RingtoneService().stopRinging();
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
          if (_isShowingIncomingDialog && mounted) {
            try {
              final nav = Navigator.of(context, rootNavigator: true);
              if (nav.canPop()) {
                nav.pop('call_cancelled');
              }
            } catch (_) {}
            _isShowingIncomingDialog = false;
          }
          final wasAnswered = _callWasAnswered;
          final endedNumber = _activeCallNumber.isNotEmpty
              ? _activeCallNumber
              : _sip.incomingNumber;
          final endedBridge = _callBridgeId;
          try {
            await _finalizeActiveCall(failed: type == 'callFailed');
          } catch (e, st) {
            log('[DIALPAD] _finalizeActiveCall error: $e');
            log('$st');
          }
          _isOnCall = false;
          _isShowingKeypad = false;
          _conferenceStatus = false;
          _conferenceConnected = false;
          _isMerged = false;
          _showConferenceKeypad = false;
          _conferenceNumber = '';
          _dtmfNumber = '';
          _lastHandledNumber = endedNumber.isNotEmpty
              ? endedNumber
              : _activeCallNumber;
          _lastHandledAt = DateTime.now();
          _activeCallNumber = '';
          _callBridgeId = '';
          _callTimer?.cancel();
          _callSeconds = 0;
          RingtoneService().stopRinging();
          try {
            FlutterLocalNotificationsPlugin().cancelAll();
          } catch (_) {}
          if (mounted) setState(() {});
          if (type == 'callEnded' && wasAnswered && mounted) {
            unawaited(
              _runPostCallFlow(
                bridgeId: endedBridge,
                number: endedNumber,
              ).whenComplete(() {
                if (mounted) {
                  if (UserData.isAutoDialActive()) {
                    setState(() => _tabIndex = 2);
                  }
                  unawaited(_autoDialNextLead());
                }
              }),
            );
          }
          break;

        case 'messageReceived':
          final message = event['message'] as String? ?? '';
          if (message.contains('customer host channel connected')) {
            setState(() {
              _conferenceStatus = true;
              _conferenceConnected = true;
              _showConferenceKeypad = false;
            });
          } else if (message.contains('customer host channel diconnected') ||
              message.contains('customer host channel disconnected')) {
            final wasMerged = _isMerged;
            setState(() {
              _conferenceStatus = false;
              _conferenceConnected = false;
              _isMerged = false;
            });
            if (!wasMerged) {
              unawaited(_sip.requestUnhold());
            }
          }
          if (mounted) setState(() {});
          break;

        case 'registered':
          if (mounted) setState(() {});
          break;

        case 'missedCallsUpdated':
          if (mounted) setState(() {});
          break;

        case 'followUpsUpdated':
          log('[FOLLOW_UPS] UI refreshed with ${event['count']} callbacks');
          if (mounted) setState(() {});
          break;

        case 'recentCallsUpdated':
          if (mounted) setState(() {});
          break;

        case 'queueUpdated':
          if (mounted) setState(() {});
          break;

        case 'registrationFailed':
          final regCause = (event['cause'] ?? '').toString();
          final authFailed = regCause.contains('401') ||
              regCause.toLowerCase().contains('unauthorized');
          if (authFailed) {
            log('[DIALPAD] SIP registration failed with 401, clearing session...');
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('token');
            await prefs.remove('savedUsername');
            await prefs.remove('savedPassword');
            _sip.disconnect();
            await _sip.clearCredentials();
            if (mounted) {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                (route) => false,
              );
            }
          } else if (mounted) {
            setState(() {});
          }
          break;

        case 'connectionLost':
          final reason = (event['reason'] ?? '').toString();
          if (reason == 'force_login' || reason == '401_unauthorized') {
            log(
              '[DIALPAD] Unauthenticated session ($reason), attempting auto-login...',
            );
            await _handleSessionLoss();
          }
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
    if (_isShowingIncomingDialog) {
      return;
    }
    if (_isOnCall) {
      return;
    }
    if (_currentBreak != null) {
      await _sip.rejectCall();
      return;
    }
    _isShowingIncomingDialog = true;
    RingtoneService().cleanupForegroundService();
    await Future.delayed(const Duration(milliseconds: 200));
    RingtoneService().startRinging();
    RingtoneService().clearNotification();

    if (!mounted) return;
    final dynamic result;
    try {
      result = await showGeneralDialog<dynamic>(
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
    } catch (e, st) {
      log('[DIALPAD] Incoming dialog error: $e');
      log('$st');
      _isShowingIncomingDialog = false;
      RingtoneService().stopRinging();
      RingtoneService().clearNotification();
      return;
    }

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
      // Declined/dismissed: remember the caller so the queue fallback ring
      // and SIP retries for the same caller are auto-rejected for 15s.
      _recentlyRejected[number] = DateTime.now();
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

  Future<void> _onCallPressed({
    String? leadId,
    String? dialSource,
    bool? autoLeadDial,
  }) async {
    _autoDialGeneration++;
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

    final ok = await _sip.dialNumber(
      number,
      leadId: leadId,
      dialSource: dialSource,
      autoLeadDial: autoLeadDial,
    );
    if (ok && _callBridgeId.isEmpty) {
      _callBridgeId = _sip.bridgeID;
    }
    if (!ok) {
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
    _lastCallDirection = entry.direction;
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
    if (_activeCallbackIds.isNotEmpty) {
      for (final id in _activeCallbackIds.toList()) {
        unawaited(_sip.updateCallbackStatus(id, 'completed'));
      }
      if (mounted) setState(() => _activeCallbackIds.clear());
    }
    if (!mounted || _dispositionShowing) return;

    final callType = _lastCallDirection == CallLogDirection.incoming
        ? 'incoming'
        : 'outgoing';
    final formResult = await _sip.fetchDynamicFormConfig(callType: callType);
    if (formResult.webformEnabled && mounted) {
      final formConfig = formResult.config;
      if (formConfig != null) {
        // Dynamic form is mandatory and cannot be dismissed: keep showing it
        // until the user submits a valid form.
        bool submitted = false;
        while (mounted && !submitted) {
          submitted = await showDynamicFormSheet(
            context,
            formConfig: formConfig,
            callType: callType,
            contactNumber: number,
            onSubmit: (payload) => _sip.addModifyContact(payload),
          );
        }
      } else {
        // Webforms enabled but no dynamic form resolved: show the static
        // UserCall contact form (webphone UserCall.jsx fallback). Also
        // mandatory — keep showing until submitted.
        bool submitted = false;
        while (mounted && !submitted) {
          submitted = await showUserCallFormSheet(
            context,
            callType: callType,
            contactNumber: number,
            onSubmit: (payload) => _sip.addModifyContact(payload),
          );
        }
      }
      if (!mounted) return;
    }

    if (!UserData.isDispositionEnabled()) {
      await _sip.submitDisposition(
        bridgeId: bridgeId,
        disposition: 'Auto Disposed',
        contactNumber: number,
      );
      return;
    }
    await _showDispositionSheet(bridgeId: bridgeId, number: number);
  }

  /// Starts a call for [phone] by populating the keypad and reusing the
  /// regular dial flow (permissions, log entry, dialNumber/makeCall). When
  /// dialing a lead, [leadId] is sent so the server can update the lead's
  /// `lastDialedStatus`, and [autoLeadDial] marks the auto-dial flow — the
  /// same payload the webphone sends to `/dialnumber`.
  Future<void> _startCallForNumber(
    String phone, {
    String? leadId,
    bool? autoLeadDial,
  }) async {
    if (phone.isEmpty) return;
    _phoneController.text = phone;
    if (mounted) setState(() => _tabIndex = 0);
    await _onCallPressed(
      leadId: leadId,
      dialSource: autoLeadDial == true
          ? 'auto_lead_preview'
          : leadId != null
          ? 'manual_lead_preview'
          : null,
      autoLeadDial: autoLeadDial,
    );
  }

  /// Dials the next lead that hasn't been dialed yet when Auto-Dial is active.
  /// A monotonically increasing generation counter invalidates the countdown
  /// when the user toggles auto-dial off or starts a manual call.
  Future<void> _autoDialNextLead() async {
    if (!UserData.isAutoDialActive()) return;
    if (_isOnCall || _activeCallNumber.isNotEmpty) return;
    if (_autoDialRunning) return;
    _autoDialRunning = true;
    try {
      await _fetchLeadsForSelectedFilter();

      Map<String, dynamic>? next;
      String? nextPhone;
      for (final lead in _sip.leads) {
        final phone = _leadDisplayPhone(lead);
        if (phone.isEmpty) continue;
        if (_autoDialedPhones.contains(_stripCountryCode(phone))) continue;
        final status = lead['lastDialedStatus'];
        final alreadyDialed =
            status == 1 ||
            status == '1' ||
            status == 2 ||
            status == '2' ||
            (status is String &&
                (status.toLowerCase().contains('dial') ||
                    status.toLowerCase().contains('answered') ||
                    status.toLowerCase().contains('completed')));
        if (alreadyDialed) continue;
        next = lead;
        nextPhone = phone;
        break;
      }
      log(
        '[AUTO-DIAL] leads=${_sip.leads.length} '
        'dialedThisSession=${_autoDialedPhones.length} '
        'next=${nextPhone ?? 'none'}',
      );
      if (next == null || nextPhone == null) return;

      final cleanPhone = _stripCountryCode(nextPhone);
      _autoDialedPhones.add(cleanPhone);

      if (mounted) setState(() => _tabIndex = 2);

      final gen = ++_autoDialGeneration;
      final secs = UserData.autoDialCountdownSeconds();
      if (mounted && secs > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Auto-dialing $cleanPhone in ${secs}s...'),
            duration: Duration(seconds: secs),
          ),
        );
      }
      for (var i = 0; i < secs; i++) {
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted ||
            gen != _autoDialGeneration ||
            !UserData.isAutoDialActive()) {
          return;
        }
        if (_isOnCall || _activeCallNumber.isNotEmpty) return;
      }
      if (!mounted || gen != _autoDialGeneration) return;
      if (_isOnCall || _activeCallNumber.isNotEmpty) return;
      final leadId = (next['leadId'] ?? next['_id'] ?? '').toString();
      await _startCallForNumber(
        cleanPhone,
        leadId: leadId.isEmpty ? null : leadId,
        autoLeadDial: true,
      );
    } finally {
      _autoDialRunning = false;
    }
  }

  Future<void> _showDispositionSheet({
    required String bridgeId,
    required String number,
  }) async {
    if (!mounted) return;
    _dispositionShowing = true;
    try {
      final options = await _loadDispositionOptions();
      if (!mounted) return;
      // Webphone behaviour: when disposition is enabled the agent MUST
      // submit one — the sheet cannot be dismissed (swipe/back/tap-outside)
      // and is re-shown until a disposition is saved.
      while (mounted) {
        final result = await showModalBottomSheet<_DispositionResult>(
          context: context,
          backgroundColor: Colors.transparent,
          isScrollControlled: true,
          isDismissible: false,
          enableDrag: false,
          builder: (context) => PopScope(
            canPop: false,
            child: _DispositionSheet(
              bridgeId: bridgeId,
              number: number,
              options: options,
            ),
          ),
        );
        if (result != null) {
          await _sip.submitDisposition(
            bridgeId: bridgeId,
            disposition: result.disposition,
            contactNumber: number,
            followUpDisposition: result.followUpDisposition,
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Disposition saved: ${result.disposition}'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      }
    } finally {
      _dispositionShowing = false;
    }
  }

  Future<List<String>> _loadDispositionOptions() async {
    final prefs = await SharedPreferences.getInstance();
    final tokenStr = prefs.getString('token');
    if (tokenStr != null && tokenStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(tokenStr);
        if (decoded is Map) {
          final userData = decoded['userData'];
          if (userData is Map) {
            final opts = userData['dispostionOptions'];
            if (opts is List && opts.isNotEmpty) {
              final list = opts
                  .map((o) {
                    if (o is Map) {
                      return (o['label'] ?? o['value']).toString();
                    }
                    return o.toString();
                  })
                  .where((s) => s.isNotEmpty)
                  .toList();
              if (list.isNotEmpty) return list;
            }
          }
        }
      } catch (_) {}
    }
    return _dispositionOptions;
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
    if (_conferenceStatus) {
      await _disconnectConference();
      return;
    }
    await _sip.endCall();
  }

  Future<void> _startConferenceCall() async {
    if (_conferenceNumber.isEmpty) return;
    final ok = await _sip.requestConference(
      _conferenceNumber,
      bridgeID: _callBridgeId.isEmpty ? _sip.bridgeID : _callBridgeId,
    );
    if (mounted) {
      if (ok) {
        setState(() {
          _conferenceStatus = true;
          _conferenceConnected = false;
          _showConferenceKeypad = false;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Conference request failed')),
        );
      }
    }
  }

  Future<void> _mergeConference() async {
    final ok = await _sip.requestUnhold();
    if (mounted && !ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Merge failed: could not unhold the call'),
        ),
      );
      return;
    }
    if (mounted) {
      setState(() => _isMerged = true);
    }
  }

  Future<void> _disconnectConference() async {
    final number = _conferenceNumber;
    if (number.isEmpty) return;
    final wasMerged = _isMerged;
    await _sip.hangupConference(number);
    if (mounted) {
      setState(() {
        _conferenceStatus = false;
        _conferenceConnected = false;
        _isMerged = false;
        _showConferenceKeypad = false;
      });
    }
    if (!wasMerged) {
      await _sip.requestUnhold();
    }
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onBreak && _breakStartedAt != null)
                BreakTimerChip(
                  startedAt: _breakStartedAt!,
                  breakLabel: _currentBreak!,
                  onTap: _removeBreak,
                )
              else if (_isBreaksEnabled)
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
              if (_sip.queueCount > 0) ...[
                const SizedBox(height: 4),
                _buildQueueBadge(),
              ],
            ],
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

  int _callsFilterIndex = 0;
  String _leadSearchQuery = '';

  Widget _buildTabs() {
    return IndexedStack(
      index: _tabIndex,
      children: [
        _buildDialerTab(),
        _buildCallsTab(),
        _buildLeadsTab(),
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
        final leadsCount = _sip.leads.length;
        final followUpCount = _sip.followUps.length;
        return NavigationBar(
          selectedIndex: _tabIndex,
          height: 68,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (index) {
            final tabChanged = index != _tabIndex;
            setState(() {
              _tabIndex = index;
              if (tabChanged) {
                _phoneController.clear();
              }
              if (index == 3 && _followUpTabIndex != 0) {
                _followUpTabIndex = 0;
              }
            });
            if (index == 1) {
              _callLog.markMissedSeen();
            } else if (index == 2) {
              if (_leadDateFilterIndex != 0) {
                setState(() => _leadDateFilterIndex = 0);
              }
              unawaited(_fetchLeadsForSelectedFilter(0));
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
                count: missedCount,
                isLabelVisible: missedCount > 0,
                child: const Icon(Icons.call_outlined),
              ),
              selectedIcon: Badge.count(
                count: missedCount,
                isLabelVisible: missedCount > 0,
                child: const Icon(Icons.call_rounded),
              ),
              label: 'Calls',
            ),
            NavigationDestination(
              icon: Badge.count(
                count: leadsCount,
                isLabelVisible: leadsCount > 0,
                child: const Icon(Icons.assignment_ind_outlined),
              ),
              selectedIcon: Badge.count(
                count: leadsCount,
                isLabelVisible: leadsCount > 0,
                child: const Icon(Icons.assignment_ind_rounded),
              ),
              label: 'Leads',
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

  /// Re-authenticates with the saved username/password after a forced logout
  /// or 401. Reconnects SIP on success, otherwise falls back to [LoginScreen].
  Future<void> _handleSessionLoss() async {
    final ok = await autoLoginWithSavedCredentials();
    if (!mounted) return;
    if (ok) {
      log('[DIALPAD] Auto-login succeeded, reconnecting SIP...');
      _sip.disconnect();
      await _sip.loadCredentials();
      await _sip.connect();
      if (mounted) setState(() {});
    } else {
      log('[DIALPAD] Auto-login failed, clearing session and falling back to logout...');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('token');
      await prefs.remove('savedUsername');
      await prefs.remove('savedPassword');
      _logout();
    }
  }

  Widget _buildQueueBadge() {
    final count = _sip.queueCount;
    if (count <= 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: _showQueueSheet,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: InfoChip(
          icon: Icons.queue_rounded,
          label: 'Queue: $count',
          color: cs.primary,
        ),
      ),
    );
  }

  Future<void> _showQueueSheet() async {
    final cs = Theme.of(context).colorScheme;
    final queue = List<dynamic>.from(_sip.currentCallqueue);
    log(
      '[CALL_QUEUE] Opened Call Queue Sheet (${queue.length} callers): ${jsonEncode(queue)}',
    );
    if (queue.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadii.xl),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.md,
          ),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Icon(Icons.queue_rounded, size: 20, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Call Queue (${queue.length})',
                    style: TextStyle(
                      fontSize: AppType.heading,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Divider(color: cs.outlineVariant),
              const SizedBox(height: AppSpacing.xs),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  itemCount: queue.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: cs.outlineVariant),
                  itemBuilder: (context, index) {
                    final call = queue[index] is Map
                        ? queue[index] as Map
                        : null;
                    final caller = (call?['Caller'] ?? 'Unknown').toString();
                    final stickyAgent = (call?['stickyAgent'] ?? '').toString();
                    final isSticky = call?['isSticky'] == true;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          AvatarBubble(
                            name: _stripCountryCode(caller),
                            size: AppSizes.avatarMd,
                            iconColor: cs.primary,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _stripCountryCode(caller),
                                  style: TextStyle(
                                    fontSize: AppType.body,
                                    fontWeight: FontWeight.w700,
                                    color: cs.onSurface,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isSticky && stickyAgent.isNotEmpty)
                            InfoChip(
                              icon: Icons.push_pin_rounded,
                              label: stickyAgent,
                              color: cs.tertiary,
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
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

  Widget _buildDialpadGrid({required void Function(String) onDigit}) {
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDialRow(['1', '2', '3'], onDigit: onDigit),
            _buildDialRow(['4', '5', '6'], onDigit: onDigit),
            _buildDialRow(['7', '8', '9'], onDigit: onDigit),
            _buildDialRow(['*', '0', '#'], onDigit: onDigit),
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

  Widget _buildDialpadKey(
    String key, {
    required void Function(String) onDigit,
  }) {
    final cs = Theme.of(context).colorScheme;
    final letters = _dialLetters[key] ?? '';
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: PressableScale(
          onTap: () => onDigit(key),
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
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                      height: 1,
                    ),
                  ),
                  if (letters.isNotEmpty)
                    Text(
                      letters,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: cs.onSurface.withValues(alpha: 0.4),
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

  Widget _buildDialRow(
    List<String> keys, {
    required void Function(String) onDigit,
  }) {
    return Row(
      children: keys
          .map((key) => _buildDialpadKey(key, onDigit: onDigit))
          .toList(),
    );
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
                    child: _buildDialpadGrid(onDigit: _onDialPadTap),
                  ),
                ),
              ),
            ],
          );
        }

        return Column(
          children: [

            _buildNumberDisplay(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: _buildDialpadGrid(onDigit: _onDialPadTap),
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
  // Combined Calls tab (Recent + Missed)
  // ---------------------------------------------------------------------

  CallLogEntry _rawMissedCallToEntry(dynamic raw, int index) {
    if (raw is Map) {
      final caller =
          (raw['Caller'] ?? raw['caller'] ?? raw['number'] ?? 'Unknown')
              .toString();
      final startTimeRaw = raw['startTime'] ?? raw['time'] ?? raw['timestamp'];
      DateTime time = DateTime.now();
      if (startTimeRaw != null) {
        final ms = int.tryParse(startTimeRaw.toString());
        if (ms != null) {
          time = DateTime.fromMillisecondsSinceEpoch(ms);
        } else {
          time = DateTime.tryParse(startTimeRaw.toString()) ?? DateTime.now();
        }
      }
      return CallLogEntry(
        id: 'missed_${index}_${time.millisecondsSinceEpoch}',
        number: caller,
        startedAt: time,
        durationSec: 0,
        direction: CallLogDirection.incoming,
        type: CallLogType.audio,
        source: (raw['campaign'] ?? raw['source'] ?? '').toString(),
      );
    }
    return CallLogEntry(
      id: 'missed_$index',
      number: raw.toString(),
      startedAt: DateTime.now(),
      durationSec: 0,
      direction: CallLogDirection.incoming,
      type: CallLogType.audio,
    );
  }

  Widget _buildCallsTab() {
    final cs = Theme.of(context).colorScheme;
    final allCalls = _sip.recentCalls;
    final rawMissed = _sip.missedCalls;
    final missedCalls = rawMissed
        .asMap()
        .entries
        .map((e) => _rawMissedCallToEntry(e.value, e.key))
        .toList();
    final displayList = _callsFilterIndex == 0 ? allCalls : missedCalls;

    final totalCalls = displayList.length;
    final incomingCount = displayList
        .where((e) => e.direction == CallLogDirection.incoming)
        .length;
    final outgoingCount = displayList
        .where((e) => e.direction == CallLogDirection.outgoing)
        .length;
    final withDuration = displayList.where((e) => e.durationSec > 0).toList();
    final avgSec = withDuration.isEmpty
        ? 0
        : withDuration.fold<int>(0, (sum, e) => sum + e.durationSec) ~/
              withDuration.length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Calls',
                  style: TextStyle(
                    fontSize: AppType.heading,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: cs.onSurface,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => unawaited(
                  Future.wait([
                    _sip.fetchRecentCalls(),
                    _sip.fetchMissedCalls(),
                  ]),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 20),
                tooltip: 'Refresh Calls',
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            2,
            AppSpacing.md,
            4,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadii.lg),
              border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                _statTile(cs: cs, value: '$totalCalls', label: 'Total Calls'),
                _statTile(
                  cs: cs,
                  value: '$incomingCount',
                  label: 'Incoming Calls',
                ),
                _statTile(
                  cs: cs,
                  value: '$outgoingCount',
                  label: 'Outgoing Calls',
                ),
                _statTile(
                  cs: cs,
                  value: CallHistoryTile.formatDuration(avgSec),
                  label: 'Avg Duration',
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 4,
          ),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<int>(
                  segments: [
                    ButtonSegment<int>(
                      value: 0,
                      label: Text('All Calls (${allCalls.length})'),
                      icon: const Icon(Icons.call_rounded, size: 16),
                    ),
                    ButtonSegment<int>(
                      value: 1,
                      label: Text('Missed (${missedCalls.length})'),
                      icon: const Icon(Icons.phone_missed_rounded, size: 16),
                    ),
                  ],
                  selected: {_callsFilterIndex},
                  onSelectionChanged: (val) {
                    setState(() => _callsFilterIndex = val.first);
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              await Future.wait([
                _sip.fetchRecentCalls(),
                _sip.fetchMissedCalls(),
              ]);
            },
            child: displayList.isEmpty
                ? SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 64),
                      child: EmptyState(
                        icon: _callsFilterIndex == 0
                            ? Icons.history_rounded
                            : Icons.phone_missed_rounded,
                        title: _callsFilterIndex == 0
                            ? 'No recent calls'
                            : 'No missed calls',
                        subtitle: _callsFilterIndex == 0
                            ? 'Incoming, outgoing and missed calls will appear here.'
                            : 'Missed calls will show up here while you are away.',
                      ),
                    ),
                  )
                : CustomScrollView(
                    slivers: [
                      for (final group in _groupEntriesByDay(displayList))
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
                                );
                              },
                            ),
                          ],
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Leads tab
  // ---------------------------------------------------------------------

  int _leadDateFilterIndex =
      0; // Default: Today (0: Today, 1: 7 Days, 2: 30 Days, 3: All Time)

  Future<void> _fetchLeadsForSelectedFilter([int? filterIdx]) async {
    final idx = filterIdx ?? _leadDateFilterIndex;
    final now = DateTime.now();
    DateTime startDate;
    switch (idx) {
      case 0:
        startDate = now;
        break;
      case 1:
        startDate = now.subtract(const Duration(days: 7));
        break;
      case 2:
        startDate = now.subtract(const Duration(days: 30));
        break;
      case 3:
      default:
        startDate = DateTime(2000, 1, 1);
        break;
    }
    await _sip.fetchLeads(startDate, now);
  }

  Widget _statTile({
    required ColorScheme cs,
    required String value,
    required String label,
  }) {
    return Expanded(
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontSize: AppType.heading,
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeadsTab() {
    final cs = Theme.of(context).colorScheme;
    final allLeads = _sip.leads;
    final hasLeads = allLeads.isNotEmpty;
    final query = _leadSearchQuery.trim().toLowerCase();
    final leads = query.isEmpty
        ? allLeads
        : allLeads.where((lead) {
            final name =
                (lead['name'] ?? lead['leadName'] ?? lead['customerName'] ?? '')
                    .toString()
                    .toLowerCase();
            final phone =
                (lead['phone'] ??
                        lead['contactNumber'] ??
                        lead['mobileNumber'] ??
                        lead['dialNumber'] ??
                        '')
                    .toString()
                    .toLowerCase();
            return name.contains(query) || phone.contains(query);
          }).toList();

    final isAutoActive = UserData.isAutoDialActive();
    final badgeColor = !hasLeads
        ? cs.onSurface.withValues(alpha: 0.38)
        : isAutoActive
        ? Colors.green
        : Colors.orange;

    var notDialedCount = 0;
    var dialedNotPickedCount = 0;
    var answeredCount = 0;
    for (final lead in allLeads) {
      final v = lead['lastDialedStatus'];
      final n = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
      switch (n) {
        case 1:
          dialedNotPickedCount++;
          break;
        case 2:
          answeredCount++;
          break;
        default:
          notDialedCount++;
      }
    }

    return RefreshIndicator(
      onRefresh: () async => await _fetchLeadsForSelectedFilter(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Leads (${allLeads.length})',
                    style: TextStyle(
                      fontSize: AppType.heading,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: !hasLeads
                      ? null
                      : () async {
                          final active = UserData.isAutoDialActive();
                          if (active) _autoDialGeneration++;
                          await UserData.setAutoDialActive(!active);
                          if (mounted) {
                            setState(() {});
                            if (!active) unawaited(_autoDialNextLead());
                          }
                        },
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: hasLeads ? 1.0 : 0.5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: badgeColor.withValues(alpha: 0.5),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            !hasLeads
                                ? Icons.block_rounded
                                : isAutoActive
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            size: 14,
                            color: badgeColor,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            !hasLeads
                                ? 'Disabled'
                                : isAutoActive
                                ? 'Auto Active'
                                : 'Paused',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: badgeColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: () => unawaited(_fetchLeadsForSelectedFilter()),
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  tooltip: 'Refresh Leads',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              2,
              AppSpacing.md,
              4,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadii.lg),
                border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  _statTile(
                    cs: cs,
                    value: '${allLeads.length}',
                    label: 'Total Leads',
                  ),
                  _statTile(
                    cs: cs,
                    value: '$notDialedCount',
                    label: 'Not Dialed',
                  ),
                  _statTile(
                    cs: cs,
                    value: '$dialedNotPickedCount',
                    label: 'Dialed Not Picked',
                  ),
                  _statTile(cs: cs, value: '$answeredCount', label: 'Answered'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 4,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('Today'),
                    selected: _leadDateFilterIndex == 0,
                    onSelected: (sel) {
                      if (sel) {
                        setState(() => _leadDateFilterIndex = 0);
                        _fetchLeadsForSelectedFilter(0);
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Last 7 Days'),
                    selected: _leadDateFilterIndex == 1,
                    onSelected: (sel) {
                      if (sel) {
                        setState(() => _leadDateFilterIndex = 1);
                        _fetchLeadsForSelectedFilter(1);
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Last 30 Days'),
                    selected: _leadDateFilterIndex == 2,
                    onSelected: (sel) {
                      if (sel) {
                        setState(() => _leadDateFilterIndex = 2);
                        _fetchLeadsForSelectedFilter(2);
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('All Time'),
                    selected: _leadDateFilterIndex == 3,
                    onSelected: (sel) {
                      if (sel) {
                        setState(() => _leadDateFilterIndex = 3);
                        _fetchLeadsForSelectedFilter(3);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 4,
            ),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search leads by name or number...',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: cs.outline.withValues(alpha: 0.3),
                  ),
                ),
                filled: true,
                fillColor: cs.surfaceContainerLow,
              ),
              onChanged: (val) => setState(() => _leadSearchQuery = val),
            ),
          ),
          Expanded(
            child: leads.isEmpty
                ? SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 64),
                      child: EmptyState(
                        icon: Icons.assignment_ind_outlined,
                        title: allLeads.isEmpty
                            ? 'No leads found'
                            : 'No matching leads',
                        subtitle: allLeads.isEmpty
                            ? 'Pull down to refresh or check your assigned campaign.'
                            : 'Try searching with a different name or number.',
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: leads.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final item = leads[i];
                      final name = _leadDisplayName(
                        item,
                        fallback: 'Lead #${i + 1}',
                      );
                      final phone = _leadDisplayPhone(item);
                      final status = _leadStatusLabel(item);
                      final dialStatus = _leadDialStatusLabel(item);
                      final leadIdValue = (item['leadId'] ?? item['_id'] ?? '')
                          .toString();
                      final leadId = leadIdValue.isEmpty ? null : leadIdValue;
                      final lastUpdated =
                          (item['updatedAt'] ??
                          item['lastUpdated'] ??
                          item['uploadDate'] ??
                          item['created_at'] ??
                          item['Last Updated']);

                      final isDialed = dialStatus != 'Not Dialed';

                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: cs.outline.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor: cs.primaryContainer,
                                  child: Icon(
                                    Icons.person_rounded,
                                    size: 20,
                                    color: cs.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.phone_rounded,
                                            size: 13,
                                            color: cs.onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            phone.isNotEmpty
                                                ? UserData.maskNumber(phone)
                                                : 'No mobile number',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: cs.onSurfaceVariant,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.phone_forwarded_rounded,
                                    color: Colors.green,
                                    size: 22,
                                  ),
                                  onPressed: phone.isEmpty
                                      ? null
                                      : () => unawaited(
                                          _startCallForNumber(
                                            _stripCountryCode(phone),
                                            leadId: leadId,
                                          ),
                                        ),
                                  tooltip: 'Dial Lead',
                                ),
                              ],
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Divider(height: 1),
                            ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cs.primary.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Status: ',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                      Text(
                                        status,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: cs.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isDialed
                                        ? Colors.green.withValues(alpha: 0.12)
                                        : Colors.orange.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Dial Status: ',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                      Text(
                                        dialStatus,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isDialed
                                              ? Colors.green
                                              : Colors.orange,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(
                                  Icons.access_time_rounded,
                                  size: 12,
                                  color: cs.onSurfaceVariant.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Last Updated: ${_formatLeadDate(lastUpdated)}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant.withValues(
                                      alpha: 0.7,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Follow-ups tab
  // ---------------------------------------------------------------------

  int _followUpTabIndex = 0;
  static const _followUpTabs = ['Pending', 'Active'];

  Widget _buildFollowUpsTab() {
    final cs = Theme.of(context).colorScheme;
    final followUps = _sip.followUps;
    log(
      '[FOLLOW_UPS_SCREEN] rendering tab $_followUpTabIndex '
      'followUps=${followUps.length}',
    );
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

    final now = DateTime.now();
    final buckets = _bucketFollowUps(followUps, now);
    log(
      '[FOLLOW_UPS_SCREEN] buckets -> '
      'Pending=${buckets['Pending']?.length ?? 0} '
      'Active=${buckets['Active']?.length ?? 0}',
    );
    final counts = {
      for (final tab in _followUpTabs) tab: buckets[tab]?.length ?? 0,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Follow-up Calls',
                style: TextStyle(
                  fontSize: AppType.heading,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: cs.onSurface,
                ),
              ),
              IconButton(
                tooltip: 'Fetch Recent Callbacks',
                onPressed: () => unawaited(_sip.fetchAgentCallbacks()),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: _FollowUpTabBar(
            tabs: _followUpTabs,
            selectedIndex: _followUpTabIndex,
            counts: counts,
            onSelected: (i) => setState(() => _followUpTabIndex = i),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: AnimatedSwitcher(
            duration: AppMotion.normal,
            child: ListView(
              key: ValueKey('followups-${buckets.length}-$_followUpTabIndex'),
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              children: [
                for (final entry
                    in buckets[_followUpTabs[_followUpTabIndex]] ??
                        const <_FollowUpEntry>[])
                  _followUpTile(entry, now),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Map<String, List<_FollowUpEntry>> _bucketFollowUps(
    List<dynamic> followUps,
    DateTime now,
  ) {
    final startOfToday = DateTime(now.year, now.month, now.day);
    final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59);

    final buckets = <String, List<_FollowUpEntry>>{
      for (final tab in _followUpTabs) tab: <_FollowUpEntry>[],
    };

    for (final item in followUps) {
      if (item is! Map) continue;
      final map = Map<dynamic, dynamic>.from(item);
      String field(String key) {
        final v = map[key];
        return v?.toString() ?? '';
      }

      final phone = field('phoneNumber').isNotEmpty
          ? field('phoneNumber')
          : field('contactNumber');
      final comment = field('comment').isNotEmpty
          ? field('comment')
          : field('reason').isNotEmpty
          ? field('reason')
          : field('notes');
      final user = field('user').isNotEmpty
          ? field('user')
          : field('agentName');
      final status = field('status').toLowerCase();
      final callbackId = field('_id').isNotEmpty ? field('_id') : field('id');

      if (status.contains('complete')) continue;

      final scheduled = _resolveFollowUpTime(item) ?? now;

      final isActive = (callbackId.isNotEmpty &&
              _activeCallbackIds.contains(callbackId)) ||
          _callBackingCallers.any(
            (c) => c.replaceAll(RegExp(r'[^0-9]'), '') ==
                phone.replaceAll(RegExp(r'[^0-9]'), ''),
          );
      if (!isActive && scheduled.isBefore(startOfToday)) continue;
      if (!isActive && scheduled.isAfter(endOfToday)) continue;

      final tab = isActive ? 'Active' : 'Pending';

      final isAlert =
          !isActive &&
          now.isAfter(scheduled.subtract(const Duration(minutes: 10))) &&
          !now.isAfter(scheduled);

      buckets[tab]!.add(
        _FollowUpEntry(
          item: item,
          phone: phone,
          comment: comment,
          user: user,
          status: field('status'),
          callbackId: callbackId,
          scheduledAt: scheduled,
          isAlert: isAlert,
          isActive: isActive,
        ),
      );
    }

    for (final tab in _followUpTabs) {
      buckets[tab]!.sort((a, b) {
        final at = a.scheduledAt;
        final bt = b.scheduledAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return at.compareTo(bt);
      });
    }

    return buckets;
  }

  DateTime? _resolveFollowUpTime(dynamic item) {
    if (item is! Map) return null;
    final raw = item['scheduledAt'] ?? item['scheduledtime'];
    final ms = int.tryParse(raw?.toString() ?? '');
    if (ms != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        ms.toString().length <= 10 ? ms * 1000 : ms,
      );
    }
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    if (parsed != null) return parsed;

    final date = item['date']?.toString() ?? '';
    final time = item['time']?.toString() ?? '';
    if (date.isNotEmpty && time.isNotEmpty) {
      final parsedTime = _parseFollowUpTime(date, time);
      if (parsedTime != null) return parsedTime;
    }
    return null;
  }

  DateTime? _parseFollowUpTime(String date, String time) {
    final dateParts = date.split('-');
    if (dateParts.length != 3) return null;
    final y = int.tryParse(dateParts[0]);
    final m = int.tryParse(dateParts[1]);
    final d = int.tryParse(dateParts[2]);
    if (y == null || m == null || d == null) return null;

    final lower = time.toLowerCase().trim();
    final isPm = lower.contains('pm');
    final digits = lower.replaceAll(RegExp(r'[^0-9:]'), '');
    final parts = digits.split(':');
    if (parts.length < 2) return null;
    var h = int.tryParse(parts[0]);
    final min = int.tryParse(parts[1]);
    if (h == null || min == null) return null;
    if (isPm && h < 12) h += 12;
    if (!isPm && h == 12) h = 0;
    return DateTime(y, m, d, h, min);
  }

  String _formatLeadDate(dynamic raw) {
    if (raw == null || raw.toString().isEmpty) return 'N/A';
    try {
      final dt =
          DateTime.tryParse(raw.toString()) ??
          (raw is int ? DateTime.fromMillisecondsSinceEpoch(raw) : null);
      if (dt != null) {
        final months = [
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
        final hour = dt.hour.toString().padLeft(2, '0');
        final min = dt.minute.toString().padLeft(2, '0');
        return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $hour:$min';
      }
    } catch (_) {}
    return raw.toString();
  }

  Widget _followUpTile(_FollowUpEntry entry, DateTime now) {
    final overdue =
        entry.scheduledAt != null &&
        entry.scheduledAt!.isBefore(now) &&
        !entry.isActive;

    return FollowUpTile(
      phone: entry.phone,
      scheduledAt: entry.scheduledAt,
      comment: entry.comment,
      user: entry.user,
      status: entry.status,
      callbackId: entry.callbackId,
      overdue: overdue,
      isAlert: entry.isAlert,
      isActive: entry.isActive,
      completing:
          entry.callbackId.isNotEmpty &&
          _completingCallbacks.contains(entry.callbackId),
      onDone: entry.callbackId.isEmpty
          ? null
          : () => _markCallbackComplete(entry),
      onCallBack: entry.phone.isEmpty
          ? null
          : () => _callBackNumber(entry.phone, callbackId: entry.callbackId),
    );
  }

  Future<void> _markCallbackComplete(_FollowUpEntry entry) async {
    if (_completingCallbacks.contains(entry.callbackId)) return;
    setState(() => _completingCallbacks.add(entry.callbackId));
    await _sip.updateCallbackStatus(entry.callbackId, 'completed');
    if (mounted) setState(() => _completingCallbacks.remove(entry.callbackId));
  }

  Future<void> _callBackNumber(String number, {String? callbackId}) async {
    log(
      '[CALLBACK] Dialing back $number'
      '${callbackId != null ? ' (callbackId=$callbackId)' : ''}',
    );
    if (!mounted) return;
    final caller = number.trim();
    if (caller.isNotEmpty) setState(() => _callBackingCallers.add(caller));
    if (callbackId != null && callbackId.isNotEmpty) {
      setState(() => _activeCallbackIds.add(callbackId));
    }
    final ok = await _sip.dialMissedCall(number);
    if (!mounted) return;
    if (caller.isNotEmpty) setState(() => _callBackingCallers.remove(caller));
    if (!ok) {
      if (callbackId != null && callbackId.isNotEmpty) {
        setState(() => _activeCallbackIds.remove(callbackId));
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not call back the number')),
      );
      return;
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
      _phoneController.text = _stripCountryCode(entry.number);
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
        const SectionHeader('Auto-Dial Settings'),
        _buildAutoDialCard(cs),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('Account'),
        _buildAccountCard(cs),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('Appearance'),
        _buildAppearanceCard(cs),
        const SizedBox(height: AppSpacing.lg),
        const SectionHeader('Agent Status'),
        _buildAgentStatusCard(cs),
        if (_isBreaksEnabled) ...[
          const SizedBox(height: AppSpacing.lg),
          const SectionHeader('Break'),
          _buildBreakCard(cs),
        ],
        const SizedBox(height: AppSpacing.xl),
        _buildLogoutCard(cs),
        const SizedBox(height: AppSpacing.md),
      ],
    );
  }

  Widget _buildAutoDialCard(ColorScheme cs) {
    final hasLeads = _sip.leads.isNotEmpty;
    final isActive = UserData.isAutoDialActive() && hasLeads;
    final countdownSec = UserData.autoDialCountdownSeconds();

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          SwitchListTile(
            title: const Text(
              'Auto-Dial Mode',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              !hasLeads
                  ? 'No leads available to auto-dial'
                  : isActive
                  ? 'Auto Active — Automatically dials next lead'
                  : 'Paused — Manual dialing required',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            secondary: Icon(
              !hasLeads
                  ? Icons.block_rounded
                  : isActive
                  ? Icons.play_circle_fill_rounded
                  : Icons.pause_circle_filled_rounded,
              color: !hasLeads
                  ? cs.onSurface.withValues(alpha: 0.38)
                  : isActive
                  ? Colors.green
                  : Colors.orange,
            ),
            value: isActive,
            onChanged: !hasLeads
                ? null
                : (val) async {
                    if (!val) _autoDialGeneration++;
                    await UserData.setAutoDialActive(val);
                    if (mounted) {
                      setState(() {});
                      if (val) unawaited(_autoDialNextLead());
                    }
                  },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text(
              'Auto-Dial Countdown',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Countdown before dialing: ${countdownSec}s',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${countdownSec}s',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: cs.onPrimaryContainer,
                ),
              ),
            ),
            onTap: _showCountdownDurationDialog,
          ),
        ],
      ),
    );
  }

  Future<void> _showCountdownDurationDialog() async {
    final cs = Theme.of(context).colorScheme;
    final current = UserData.autoDialCountdownSeconds();
    final options = [3, 5, 10, 15, 30];

    final selected = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Auto-Dial Countdown Duration'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((sec) {
            final isSelected = sec == current;
            return ListTile(
              title: Text('$sec Seconds ${sec == 3 ? '(Default)' : ''}'),
              leading: Icon(
                isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: isSelected
                    ? cs.primary
                    : cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
              onTap: () => Navigator.of(context).pop(sec),
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (selected != null) {
      await UserData.setAutoDialCountdownSeconds(selected);
      if (mounted) setState(() {});
    }
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

  Widget _buildAccountCard(ColorScheme cs) {
    final campaign = UserData.campaignName();
    final campaignId = UserData.campaign();
    final userId = UserData.userId();
    final admin = UserData.adminUser();
    final expiry = UserData.expiryDate();
    final masking = UserData.isNumberMasking();
    return SettingsCard(
      children: [
        if (userId.isNotEmpty)
          SettingsRow(
            icon: Icons.badge_outlined,
            iconColor: cs.primary,
            title: 'User ID',
            value: userId,
          ),
        if (campaign.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          SettingsRow(
            icon: Icons.campaign_outlined,
            iconColor: cs.primary,
            title: 'Campaign',
            value: campaignId.isNotEmpty && campaignId != campaign
                ? '$campaign ($campaignId)'
                : campaign,
          ),
        ],
        if (admin.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          SettingsRow(
            icon: Icons.admin_panel_settings_outlined,
            iconColor: cs.primary,
            title: 'Admin',
            value: admin,
          ),
        ],
        if (expiry != null && expiry.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          SettingsRow(
            icon: Icons.event_outlined,
            iconColor: cs.primary,
            title: 'Plan Expiry',
            value: expiry,
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        SettingsRow(
          icon: Icons.security_rounded,
          iconColor: cs.primary,
          title: 'Number Masking',
          value: masking ? 'On' : 'Off',
        ),
      ],
    );
  }

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
    final keypadOpen = _showConferenceKeypad || _isShowingKeypad;
    return Column(
      children: [
        if (keypadOpen) const SizedBox(height: 24) else const Spacer(flex: 2),
        Container(
          width: keypadOpen ? 84 : 120,
          height: keypadOpen ? 84 : 120,
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
            size: keypadOpen ? 44 : 60,
            color: cs.primary,
          ),
        ),
        const SizedBox(height: 16),
        Builder(
          builder: (context) {
            final merged =
                _isMerged &&
                _activeCallNumber.isNotEmpty &&
                _conferenceNumber.isNotEmpty;
            String headerText;
            if (merged) {
              headerText =
                  '${UserData.maskNumber(_stripCountryCode(_activeCallNumber))} '
                  'Conference with '
                  '${UserData.maskNumber(_stripCountryCode(_conferenceNumber))}';
            } else {
              final headerNumber = _headerCallNumber(
                _activeCallNumber,
                _conferenceNumber,
                conferenceActive: _conferenceStatus,
                merged: false,
              );
              headerText = headerNumber.isEmpty
                  ? 'Unknown'
                  : UserData.maskNumber(_stripCountryCode(headerNumber));
            }
            return Text(
              headerText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
                letterSpacing: 1,
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: cs.secondary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.access_time_rounded, size: 16, color: cs.secondary),
              const SizedBox(width: 8),
              Text(
                _sip.isHeld ? 'On Hold' : _formattedTime,
                style: TextStyle(
                  fontSize: 16,
                  color: cs.secondary,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
        if (_conferenceStatus) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _isMerged ? 'Merged' : 'Conference',
              style: TextStyle(
                fontSize: 13,
                color: Colors.orange,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        if (keypadOpen) ...[
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isWide ? 120 : 32),
              child: _showConferenceKeypad
                  ? _buildConferenceKeypad(isWide: isWide)
                  : _buildDtmfKeypad(),
            ),
          ),
        ] else ...[
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
            height: 340,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isWide ? 120 : 32),
              child: _buildDtmfKeypad(),
            ),
          ),
          const Spacer(),
        ] else
          const Spacer(),
        if (!_isShowingKeypad)
          Center(
            child: _buildCallControls(
              isVideo: true,
              cs: cs,
              isLandscape: isLandscape,
            ),
          ),
        const SizedBox(height: 16),
        if (!_isShowingKeypad)
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
    final hSpacing = isLandscape ? 10.0 : 8.0;
    final vSpacing = isLandscape ? 16.0 : 22.0;

    Widget mute() => _CallControlButton(
      icon: _sip.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
      label: _sip.isMuted ? 'Unmute' : 'Mute',
      isActive: _sip.isMuted,
      isOnDark: isVideo,
      onPressed: () {
        setState(() {
          _sip.mute(!_sip.isMuted);
        });
      },
    );

    Widget transfer({bool disabled = false}) => _CallControlButton(
      icon: Icons.call_made_rounded,
      label: 'Transfer',
      disabled: disabled || _sip.bridgeID.isEmpty,
      isOnDark: isVideo,
      onPressed: () async {
        final ok = await _sip.requestTransfer();
        if (mounted && !ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Transfer request failed')),
          );
        }
      },
    );

    Widget speaker() => _CallControlButton(
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
    );

    Widget hold({bool disabled = false}) => _CallControlButton(
      icon: _sip.isHeld ? Icons.play_arrow_rounded : Icons.pause_rounded,
      label: _sip.isHeld ? 'Resume' : 'Hold',
      isActive: _sip.isHeld,
      disabled: disabled,
      isOnDark: isVideo,
      onPressed: () {
        setState(() {
          _sip.toggleHold(!_sip.isHeld);
        });
      },
    );

    Widget keypad() => _CallControlButton(
      icon: _isShowingKeypad ? Icons.grid_view_rounded : Icons.dialpad_rounded,
      label: _isShowingKeypad ? 'Close' : 'Keypad',
      isActive: _isShowingKeypad,
      isOnDark: isVideo,
      onPressed: () {
        setState(() {
          _isShowingKeypad = !_isShowingKeypad;
        });
      },
    );

    Widget addCall({bool disabled = false}) => _CallControlButton(
      icon: Icons.person_add_alt_1_rounded,
      label: 'Add Call',
      disabled: disabled,
      isOnDark: isVideo,
      onPressed: () {
        setState(() {
          _showConferenceKeypad = true;
          _conferenceNumber = '';
          _isShowingKeypad = false;
        });
      },
    );

    final List<Widget> row1;
    final List<Widget> row2;
    if (isVideo) {
      row1 = [
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
        mute(),
        speaker(),
      ];
      row2 = [hold(), keypad(), transfer(disabled: !_isMerged), addCall()];
    } else if (_conferenceStatus) {
      // Match webphone conference controls: Hold is disabled, Transfer is
      // enabled only once merged, Merge is hidden after merging.
      row1 = [hold(disabled: true), transfer(disabled: !_isMerged), keypad()];
      row2 = [
        if (!_isMerged)
          _CallControlButton(
            icon: Icons.call_merge_rounded,
            label: 'Merge',
            disabled: !_conferenceConnected,
            isOnDark: isVideo,
            onPressed: _mergeConference,
          ),
        mute(),
        speaker(),
      ];
    } else {
      row1 = [hold(), transfer(disabled: !_isMerged), keypad()];
      row2 = [addCall(disabled: !_sip.isConnected), mute(), speaker()];
    }

    Widget row(List<Widget> items) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) SizedBox(width: hSpacing),
            Expanded(child: items[i]),
          ],
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row(row1),
          SizedBox(height: vSpacing),
          row(row2),
        ],
      ),
    );
  }

  Widget _buildDtmfKeypad() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            iconSize: 26,
            icon: const Icon(Icons.close_rounded),
            onPressed: () {
              setState(() {
                _isShowingKeypad = false;
                _dtmfNumber = '';
              });
            },
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadii.xl),
            border: Border.all(color: cs.outline.withValues(alpha: 0.5)),
          ),
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Center(
                  child: Text(
                    _dtmfNumber.isEmpty ? 'Enter number' : _dtmfNumber,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3,
                      color: _dtmfNumber.isEmpty
                          ? cs.onSurface.withValues(alpha: 0.25)
                          : cs.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              if (_dtmfNumber.isNotEmpty)
                IconButton(
                  iconSize: 24,
                  icon: const Icon(Icons.backspace_outlined),
                  onPressed: () => setState(
                    () => _dtmfNumber = _dtmfNumber.substring(
                      0,
                      _dtmfNumber.length - 1,
                    ),
                  ),
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
            ],
          ),
        ),
        Expanded(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDialRow(['1', '2', '3'], onDigit: _onDtmfKey),
                  _buildDialRow(['4', '5', '6'], onDigit: _onDtmfKey),
                  _buildDialRow(['7', '8', '9'], onDigit: _onDtmfKey),
                  _buildDialRow(['*', '0', '#'], onDigit: _onDtmfKey),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _onDtmfKey(String key) {
    _sip.sendDTMF(key);
    setState(() {
      if (_dtmfNumber.length < 15) _dtmfNumber += key;
    });
  }

  Widget _buildConferenceKeypad({required bool isWide}) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () {
              setState(() => _showConferenceKeypad = false);
            },
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadii.xl),
            border: Border.all(color: cs.outline.withValues(alpha: 0.5)),
          ),
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Center(
                  child: Text(
                    _conferenceNumber.isEmpty
                        ? 'Enter number'
                        : _conferenceNumber,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3,
                      color: _conferenceNumber.isEmpty
                          ? cs.onSurface.withValues(alpha: 0.25)
                          : cs.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              if (_conferenceNumber.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.backspace_outlined),
                  onPressed: () => setState(
                    () => _conferenceNumber = _conferenceNumber.substring(
                      0,
                      _conferenceNumber.length - 1,
                    ),
                  ),
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
            ],
          ),
        ),
        Expanded(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildDialRow(['1', '2', '3'], onDigit: _onConferenceKey),
                  _buildDialRow(['4', '5', '6'], onDigit: _onConferenceKey),
                  _buildDialRow(['7', '8', '9'], onDigit: _onConferenceKey),
                  _buildDialRow(['*', '0', '#'], onDigit: _onConferenceKey),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: _conferenceNumber.isNotEmpty ? _startConferenceCall : null,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: _conferenceNumber.isNotEmpty
                  ? Colors.green
                  : cs.onSurface.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.green.withValues(
                    alpha: _conferenceNumber.isNotEmpty ? 0.4 : 0,
                  ),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Icon(
              Icons.call_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      ],
    );
  }

  void _onConferenceKey(String d) {
    if (_conferenceNumber.length < 15) {
      setState(() => _conferenceNumber += d);
    }
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
        : cs.surfaceContainerHighest;
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
              width: 58,
              height: 58,
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
                  : Icon(widget.icon, size: 28, color: fgColor),
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

String _stripCountryCode(String number) {
  var n = number.trim();
  if (n.startsWith('+91')) n = n.substring(3);
  if (n.startsWith('0091')) n = n.substring(4);
  return n;
}

/// Extracts a lead's phone number. Prefers the explicit number keys the
/// webphone's `mapLeadRow` dials from (`number || phone || phone_number ||
/// contactNumber`), then falls back to the `mapLeadData` scan: the first value
/// that is exactly 10 digits.
String _leadDisplayPhone(Map<String, dynamic> item) {
  const keys = [
    'number',
    'phone',
    'phone_number',
    'contactNumber',
    'mobileNumber',
    'dialNumber',
    'leadNumber',
    'mobile',
    'Lead Number',
    'contact',
  ];
  for (final key in keys) {
    final v = item[key];
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isNotEmpty && s != '0') return s;
  }
  for (final value in item.values) {
    if (value == null || value is bool) continue;
    if (value is num && value == 0) continue;
    final v = value.toString().trim();
    if (v.isEmpty || v == '0') continue;
    if (RegExp(r'^\d{10}$').hasMatch(v)) return v;
  }
  return '';
}

/// Extracts a lead's display name. Prefers the explicit contact-name keys the
/// webphone uses (`patientName || fullName || customerName ...`), keeping
/// generic `name`/`Name` last because `/leadswithdaterange` can put the LIST
/// name in a bare `name` key. Falls back to the `mapLeadData` heuristic: the
/// first value whose key contains "name" (excluding file/user/agent/list/
/// campaign/queue keys) that isn't a 10-digit number or email.
String _leadDisplayName(Map<String, dynamic> item, {required String fallback}) {
  const keys = [
    'patientName',
    'PatientName',
    'fullName',
    'FullName',
    'customerName',
    'CustomerName',
    'leadName',
    'LeadName',
    'contactName',
    'ContactName',
    'Lead Name',
    'firstName',
    'firstname',
    'first_name',
    'name',
    'Name',
  ];
  for (final key in keys) {
    final v = item[key];
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isNotEmpty) return s;
  }
  for (final entry in item.entries) {
    if (entry.value == null) continue;
    final v = entry.value.toString().trim();
    if (v.isEmpty) continue;
    if (v.contains('@') && v.contains('.')) continue;
    if (RegExp(r'^\d{10}$').hasMatch(v)) continue;
    final k = entry.key.toLowerCase();
    if (k.contains('name') &&
        !k.contains('file') &&
        !k.contains('user') &&
        !k.contains('agent') &&
        !k.contains('list') &&
        !k.contains('campaign') &&
        !k.contains('queue')) {
      return v;
    }
  }
  return fallback;
}

/// Mirrors the webphone lead queue (`mapLeadRow`): Dial Status is derived
/// from `lastDialedStatus` (0 = Not Dialed, 1 = Dialed Not Picked,
/// 2 = Answered).
String _leadDialStatusLabel(Map<String, dynamic> item) {
  final v = item['lastDialedStatus'];
  final n = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
  switch (n) {
    case 1:
      return 'Dialed Not Picked';
    case 2:
      return 'Answered';
    default:
      return 'Not Dialed';
  }
}

/// Mirrors the webphone lead queue (`mapLeadRow`): Status is derived from
/// `lastDialedStatus` (2 = Completed, >0 = Contacted, else Pending).
String _leadStatusLabel(Map<String, dynamic> item) {
  final v = item['lastDialedStatus'];
  final n = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
  if (n == null || n <= 0) return 'Pending';
  return n >= 2 ? 'Completed' : 'Contacted';
}

/// Number shown in the call header. Matches the webphone: once a conference
/// is dialled/in progress the conference number takes over the header, and
/// when merged the label becomes "main Conference with conference".
String _headerCallNumber(
  String main,
  String conference, {
  required bool conferenceActive,
  required bool merged,
}) {
  if (merged && main.isNotEmpty && conference.isNotEmpty) {
    return '$main Conference with $conference';
  }
  if (conferenceActive && conference.isNotEmpty) return conference;
  return main;
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

class _DispositionResult {
  const _DispositionResult({
    required this.disposition,
    this.followUpDisposition,
  });

  final String disposition;
  final Map<String, dynamic>? followUpDisposition;
}

class _DispositionSheet extends StatefulWidget {
  const _DispositionSheet({
    required this.bridgeId,
    required this.number,
    required this.options,
  });

  final String bridgeId;
  final String number;
  final List<String> options;

  @override
  State<_DispositionSheet> createState() => _DispositionSheetState();
}

class _DispositionSheetState extends State<_DispositionSheet> {
  late String _selected;

  static final RegExp _followUpPattern = RegExp(
    r'follow.?up|callback|call.?back',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    _selected = widget.options.isNotEmpty
        ? widget.options.first
        : 'Auto Disposed';
  }

  bool _isFollowUpAction(String action) => _followUpPattern.hasMatch(action);

  Future<void> _save() async {
    if (!_isFollowUpAction(_selected)) {
      Navigator.of(context).pop(_DispositionResult(disposition: _selected));
      return;
    }

    final callback = await showScheduleCallbackSheet(
      context,
      number: widget.number,
    );
    if (callback == null) return;
    if (!mounted) return;

    final username = UserData.username();
    final campaign = UserData.campaign();
    log(
      '[SCHEDULE_CALLBACK] Disposition "$_selected" confirmed → follow-up '
      '${callback['date']} ${callback['time']} | ${callback['details']} '
      '| number=${widget.number} user=$username campaign=$campaign',
    );
    Navigator.of(context).pop(
      _DispositionResult(
        disposition: _selected,
        followUpDisposition: {
          'date': callback['date'],
          'time': callback['time'],
          'comment': callback['details'],
          'user': username,
          'campaignID': campaign,
          'phoneNumber': widget.number,
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final followUpSelected = _isFollowUpAction(_selected);
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
            if (followUpSelected) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.schedule_rounded, size: 16, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'A callback will be scheduled with this disposition.',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                    for (final option in widget.options)
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
                onPressed: _save,
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

class _FollowUpEntry {
  const _FollowUpEntry({
    required this.item,
    required this.phone,
    required this.comment,
    required this.user,
    required this.status,
    required this.callbackId,
    required this.scheduledAt,
    required this.isAlert,
    required this.isActive,
  });

  final dynamic item;
  final String phone;
  final String comment;
  final String user;
  final String status;
  final String callbackId;
  final DateTime? scheduledAt;
  final bool isAlert;
  final bool isActive;
}

class _FollowUpTabBar extends StatelessWidget {
  const _FollowUpTabBar({
    required this.tabs,
    required this.selectedIndex,
    required this.counts,
    required this.onSelected,
  });

  final List<String> tabs;
  final int selectedIndex;
  final Map<String, int> counts;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => onSelected(i),
                borderRadius: BorderRadius.circular(AppRadii.md),
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: i == selectedIndex ? cs.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        tabs[i],
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: i == selectedIndex
                              ? cs.onPrimary
                              : cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      if ((counts[tabs[i]] ?? 0) > 0) ...[
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: i == selectedIndex
                                ? cs.onPrimary.withValues(alpha: 0.2)
                                : cs.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${counts[tabs[i]]}',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: i == selectedIndex
                                  ? cs.onPrimary
                                  : cs.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
