import 'dart:async';
import 'dart:convert';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'fcm_service.dart';
import 'ringtone_service.dart';
import 'sip_socket_service.dart';

const _activeKey = 'callkit_active';
const _declinedKey = 'callkit_declined';

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
  print('[CALLKIT] DISMISS — calling endAllCalls()');
  await FlutterCallkitIncoming.endAllCalls();
  print('[CALLKIT] DISMISS — endAllCalls() returned');
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
  print('[CALLKIT] showCallkitIncoming called for $number');
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
    print('[CALLKIT] activeCalls() returned ${active.length} calls');
    if (active.isNotEmpty) {
      print('[CALLKIT] Active CallKit call exists — not showing duplicate');
      return;
    }
  } catch (e) {
    print('[CALLKIT] activeCalls() threw: $e');
  }
  print('[CALLKIT] Proceeding to show CallKit UI for $number');
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
      incomingCallNotificationChannelName: 'incoming_calls_ringtone',
      isShowFullLockedScreen: true,
      isFullScreen: true,
      textAccept: 'Answer',
      textDecline: 'Decline',
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
    print('[CALLKIT_BG] Handler invoked: ${event.runtimeType}');
    if (event is CallEventActionCallDecline) {
      final number = event.callKitParams.extra?['number'] as String? ?? '';
      print('[CALLKIT_BG] DECLINE number="$number" extra=${event.callKitParams.extra}');
      await _markCallKitDeclined(number);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('callkit_pending_action', jsonEncode({
        'action': 'decline',
        'number': number,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }));
      print('[CALLKIT_BG] Pending decline saved number=$number');
      // Direct API calls for killed/locked state
      try {
        await ApiService.callEnded();
        print('[CALLKIT_BG] callEnded API called');
      } catch (e) {
        print('[CALLKIT_BG] callEnded API failed: $e');
      }
      print('[CALLKIT_BG] endAllCalls (decline)');
      await FlutterCallkitIncoming.endAllCalls();
    } else if (event is CallEventActionCallAccept) {
      final number = event.callKitParams.extra?['number'] as String? ?? '';
      print('[CALLKIT_BG] ACCEPT number="$number" extra=${event.callKitParams.extra}');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('callkit_pending_action', jsonEncode({
        'action': 'answer',
        'number': number,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }));
      print('[CALLKIT_BG] Pending answer saved number=$number');
      print('[CALLKIT_BG] endAllCalls (accept)');
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
  }

  static Future<bool> isRecentlyDeclined(String number) {
    return _isCallKitDeclined(number);
  }

  void showIncomingCall(String number) {
    showCallkitIncoming(number);
  }

  void _onEvent(CallEvent? event) {
    if (event == null) return;
    switch (event) {
      case CallEventActionCallAccept():
        print('[CALLKIT] _onEvent: ACCEPT extra=${event.callKitParams.extra}');
        RingtoneService().stopRinging();
        // Answer SIP call first — before dismissing CallKit (which can trigger lifecycle events)
        SipSocketService().answerCall();
        _dismissCallKit();
        _clearCallKitActive();
        FcmService().clearPendingFcmCall();
      case CallEventActionCallDecline():
        final number = event.callKitParams.extra?['number'] ?? '';
        print('[CALLKIT] _onEvent: DECLINE number=$number extra=${event.callKitParams.extra}');
        RingtoneService().stopRinging();
        _dismissCallKit();
        _markCallKitDeclined(number);
        FcmService().clearPendingFcmCall();
        FcmService().clearPendingCallAction();
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
