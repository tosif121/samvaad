import 'dart:async';
import 'dart:convert';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'fcm_service.dart';
import 'ringtone_service.dart';
import 'sip_socket_service.dart';

const _activeKey = 'callkit_active';
const _declinedKey = 'callkit_declined';
const _pendingActionKey = 'callkit_pending_action';

Future<bool> _isCallKitAlreadyActive(String number) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_activeKey);
  if (raw == null) return false;
  try {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final age = DateTime.now().millisecondsSinceEpoch - (data['ts'] as int);
    if (age > 15000) return false;
    return data['number'] == number;
  } catch (_) {
    return false;
  }
}

Future<bool> _isCallKitDeclined(String number) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_declinedKey);
  if (raw == null) return false;
  try {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final age = DateTime.now().millisecondsSinceEpoch - (data['ts'] as int);
    if (age > 30000) return false;
    return data['number'] == number;
  } catch (_) {
    return false;
  }
}

Future<void> _markCallKitActive(String number) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_activeKey, jsonEncode({
    'number': number,
    'ts': DateTime.now().millisecondsSinceEpoch,
  }));
}

Future<void> _clearCallKitActive() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_activeKey);
}

Future<void> _dismissCallKit() async {
  await FlutterCallkitIncoming.endAllCalls();
}

Future<void> _markCallKitDeclined(String number) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_declinedKey, jsonEncode({
    'number': number,
    'ts': DateTime.now().millisecondsSinceEpoch,
  }));
  await prefs.remove(_activeKey);
}

Future<void> showCallkitIncoming(String number) async {
  if (await _isCallKitDeclined(number)) {
    print('[CALLKIT] Declined recently for $number — skipping');
    return;
  }
  if (await _isCallKitAlreadyActive(number)) {
    print('[CALLKIT] Already active for $number — skipping');
    return;
  }
  try {
    final active = await FlutterCallkitIncoming.activeCalls();
    if (active.isNotEmpty) {
      print('[CALLKIT] Active CallKit call exists — not showing duplicate');
      return;
    }
  } catch (_) {}

  await FlutterCallkitIncoming.endAllCalls();
  await _markCallKitActive(number);
  await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    nameCaller: number,
    handle: number,
    type: 0,
    appName: 'Samvaad',
    android: AndroidParams(
      isCustomNotification: true,
      isShowLogo: false,
      isShowCallID: false,
      backgroundColor: '#4299EB',
      actionColor: '#FFFFFF',
      textColor: '#FFFFFF',
      incomingCallNotificationChannelName: 'incoming_calls_ringtone_v2',
      isShowFullLockedScreen: true,
      isFullScreen: false,
      textAccept: 'Answer',
      textDecline: 'Decline',
      ringtonePath: 'system_ringtone_default',
    ),
    ios: IOSParams(
      handleType: 'number',
      supportsVideo: false,
      includesCallsInRecents: false,
    ),
    callingNotification: const NotificationParams(
      isShowCallback: false,
    ),
    extra: {'number': number},
  ));
}

@pragma('vm:entry-point')
Future<void> callkitBackgroundHandler(CallEvent event) async {
  try {
    if (event is CallEventActionCallDecline) {
      final number = event.callKitParams.extra?['number'] as String? ?? '';
      await _markCallKitDeclined(number);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingActionKey, jsonEncode({
        'action': 'decline',
        'number': number,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }));
      try {
        await ApiService.callEnded();
      } catch (_) {}
      await FlutterCallkitIncoming.endAllCalls();
    } else if (event is CallEventActionCallAccept) {
      final number = event.callKitParams.extra?['number'] as String? ?? '';
      final prefs = await SharedPreferences.getInstance();
      // Clear FCM pending call to prevent Flutter dialog conflict
      await prefs.remove('fcm_pending_call');
      await prefs.remove('fcm_pending_call_ts');
      await prefs.setString(_pendingActionKey, jsonEncode({
        'action': 'answer',
        'number': number,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }));
      await FlutterCallkitIncoming.endAllCalls();
    }
  } catch (e) {
    print('[CALLKIT_BG] Error: $e');
  }
}

class CallKitService {
  static final CallKitService _instance = CallKitService._internal();
  factory CallKitService() => _instance;
  CallKitService._internal();

  StreamSubscription? _eventSub;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _eventSub = FlutterCallkitIncoming.onEvent.listen(_onEvent);
    // Register background handler for when app is killed
    try {
      await FlutterCallkitIncoming.onBackgroundMessage(callkitBackgroundHandler);
    } catch (e) {
      print('[CALLKIT] Failed to register background handler: $e');
    }
    print('[CALLKIT] Service initialized');
  }

  void showIncomingCall(String number) {
    showCallkitIncoming(number);
  }

  static Future<bool> isRecentlyDeclined(String number) {
    return _isCallKitDeclined(number);
  }

  Future<Map<String, dynamic>?> getPendingAction() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingActionKey);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearPendingAction() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingActionKey);
  }

  void _onEvent(CallEvent? event) {
    if (event == null) return;
    switch (event) {
      case CallEventActionCallAccept():
        print('[CALLKIT] _onEvent: ACCEPT extra=${event.callKitParams.extra}');
        RingtoneService().stopRinging();
        SipSocketService().answerCall();
        _dismissCallKit();
        _clearCallKitActive();
        FcmService().clearPendingFcmCall();
        clearPendingAction();
      case CallEventActionCallDecline():
        final number = event.callKitParams.extra?['number'] ?? '';
        print('[CALLKIT] _onEvent: DECLINE number=$number');
        RingtoneService().stopRinging();
        _dismissCallKit();
        _markCallKitDeclined(number);
        FcmService().clearPendingFcmCall();
        clearPendingAction();
        SipSocketService().rejectCall();
      case CallEventActionCallEnded():
        print('[CALLKIT] _onEvent: ENDED');
        _dismissCallKit();
        _clearCallKitActive();
        FcmService().clearPendingFcmCall();
      case CallEventActionCallTimeout():
        print('[CALLKIT] _onEvent: TIMEOUT');
        _dismissCallKit();
        _clearCallKitActive();
        FcmService().clearPendingFcmCall();
      default:
        print('[CALLKIT] _onEvent: ${event.runtimeType}');
        break;
    }
  }

  void dispose() {
    _eventSub?.cancel();
  }
}
