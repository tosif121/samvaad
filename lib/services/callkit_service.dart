import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fcm_service.dart';
import 'ringtone_service.dart';
import 'sip_socket_service.dart';

const _pendingActionKey = 'callkit_pending_action';
const _declinedKey = 'callkit_declined';

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

Future<void> _markCallKitDeclined(String number) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_declinedKey, jsonEncode({
    'number': number,
    'ts': DateTime.now().millisecondsSinceEpoch,
  }));
}

Future<void> showCallkitIncoming(String number, {bool isVideo = false}) async {
  if (await _isCallKitDeclined(number)) {
    print('[CALLKIT] Recently declined $number — skip');
    return;
  }
  try {
    final active = await FlutterCallkitIncoming.activeCalls();
    if (active.isNotEmpty) {
      print('[CALLKIT] Already active — skip');
      return;
    }
  } catch (_) {}

  await FlutterCallkitIncoming.endAllCalls();
  await FlutterCallkitIncoming.showCallkitIncoming(CallKitParams(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    nameCaller: number,
    handle: number,
    type: isVideo ? 1 : 0,
    appName: 'Samvaad',
    android: AndroidParams(
      isCustomNotification: true,
      isShowLogo: false,
      isShowCallID: true,
      backgroundColor: '#4299EB',
      actionColor: '#FFFFFF',
      textColor: '#FFFFFF',
      incomingCallNotificationChannelName: 'incoming_calls',
      isShowFullLockedScreen: true,
      isFullScreen: true,
      textAccept: isVideo ? 'Video' : 'Answer',
      textDecline: 'Decline',
      ringtonePath: 'system_ringtone_default',
    ),
    ios: IOSParams(
      handleType: 'number',
      supportsVideo: isVideo,
      includesCallsInRecents: true,
    ),
    callingNotification: const NotificationParams(isShowCallback: false),
    extra: {'number': number, 'isVideo': isVideo},
  ));
}

@pragma('vm:entry-point')
Future<void> callkitBackgroundHandler(CallEvent event) async {
  print('[CALLKIT_BG] ${event.runtimeType}');
  try {
    if (event is CallEventActionCallDecline) {
      final number = event.callKitParams.extra?['number'] as String? ?? '';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('callkit_stop_ringtone', true);
      await prefs.setString(_pendingActionKey, jsonEncode({
        'action': 'decline',
        'number': number,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }));
      await prefs.remove('fcm_pending_call');
      await prefs.remove('fcm_pending_call_ts');
      await _markCallKitDeclined(number);
      try {
        const ch = MethodChannel('com.samwad/ringtone');
        await ch.invokeMethod('cleanupForeground');
      } catch (_) {}
      await FlutterCallkitIncoming.endAllCalls();
    } else if (event is CallEventActionCallAccept) {
      final number = event.callKitParams.extra?['number'] as String? ?? '';
      final isVideo = event.callKitParams.extra?['isVideo'] as bool? ?? false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fcm_pending_call');
      await prefs.remove('fcm_pending_call_ts');
      await prefs.setString(_pendingActionKey, jsonEncode({
        'action': 'answer',
        'number': number,
        'isVideo': isVideo,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }));
      await prefs.setBool('callkit_stop_ringtone', true);
      await FlutterCallkitIncoming.endAllCalls();
      try {
        const ch = MethodChannel('com.samwad/ringtone');
        await ch.invokeMethod('cleanupForeground');
        await ch.invokeMethod('bringAppToForeground');
      } catch (_) {}
    }
  } catch (e) {
    print('[CALLKIT_BG] ERROR: $e');
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

  void showIncomingCall(String number, {bool isVideo = false}) {
    showCallkitIncoming(number, isVideo: isVideo);
  }

  Future<Map<String, dynamic>?> getPendingAction() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
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

  Future<void> _onEvent(CallEvent? event) async {
    if (event == null) return;
    print('[CALLKIT] Event: ${event.runtimeType}');
    switch (event) {
      case CallEventActionCallAccept():
        final number = event.callKitParams.extra?['number'] ?? '';
        final isVideo = event.callKitParams.extra?['isVideo'] as bool? ?? false;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_pendingActionKey, jsonEncode({
          'action': 'answer',
          'number': number.toString(),
          'isVideo': isVideo,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }));
        RingtoneService().stopRinging();
        RingtoneService().cleanupForegroundService();
        FlutterCallkitIncoming.endAllCalls();
        FcmService().clearPendingFcmCall();
        // If SIP already has a ringing call, answer it immediately
        if (SipSocketService().callState == CallState.ringing) {
          SipSocketService().answerCall(video: isVideo);
        }
        break;

      case CallEventActionCallDecline():
        final number = event.callKitParams.extra?['number'] ?? '';
        RingtoneService().stopRinging();
        RingtoneService().cleanupForegroundService();
        _markCallKitDeclined(number.toString());
        FcmService().clearPendingFcmCall();
        clearPendingAction();
        FlutterCallkitIncoming.endAllCalls();
        SipSocketService().rejectCall();
        break;

      case CallEventActionCallEnded():
      case CallEventActionCallTimeout():
        FlutterCallkitIncoming.endAllCalls();
        FcmService().clearPendingFcmCall();
        break;

      default:
        break;
    }
  }

  void dispose() {
    _eventSub?.cancel();
  }
}
