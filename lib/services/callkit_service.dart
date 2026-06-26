import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
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
      isFullScreen: true,
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
  print('[CALLKIT_BG] ==================== BACKGROUND HANDLER FIRED ====================');
  print('[CALLKIT_BG] Event type: ${event.runtimeType}');
  try {
    if (event is CallEventActionCallDecline) {
      final number = event.callKitParams.extra?['number'] as String? ?? '';
      print('[CALLKIT_BG] ===== DECLINE (background isolate) =====');
      print('[CALLKIT_BG] Number: $number');
      
      // STEP 1: Set stop ringtone flag IMMEDIATELY
      print('[CALLKIT_BG] Step 1: Setting callkit_stop_ringtone flag...');
      try {
        final bgPrefs = await SharedPreferences.getInstance();
        await bgPrefs.setBool('callkit_stop_ringtone', true);
        print('[CALLKIT_BG] Step 1 OK: callkit_stop_ringtone = true');
      } catch (e) {
        print('[CALLKIT_BG] Step 1 FAILED: $e');
      }
      
      // STEP 2: Save pending action
      print('[CALLKIT_BG] Step 2: Saving pending action...');
      try {
        final bgPrefs = await SharedPreferences.getInstance();
        await bgPrefs.setString(_pendingActionKey, jsonEncode({
          'action': 'decline',
          'number': number,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }));
        await bgPrefs.remove('fcm_pending_call');
        await bgPrefs.remove('fcm_pending_call_ts');
        print('[CALLKIT_BG] Step 2 OK: pending action saved, FCM cleared');
      } catch (e) {
        print('[CALLKIT_BG] Step 2 FAILED: $e');
      }
      
      // STEP 3: Mark as declined
      print('[CALLKIT_BG] Step 3: Marking call as declined...');
      await _markCallKitDeclined(number);
      print('[CALLKIT_BG] Step 3 OK: call marked declined');
      
      // STEP 4: Cleanup foreground service (stop native ringtone)
      print('[CALLKIT_BG] Step 4: Invoking cleanupForeground...');
      try {
        const platform = MethodChannel('com.example.samvaad/ringtone');
        await platform.invokeMethod('cleanupForeground');
        print('[CALLKIT_BG] Step 4 OK: cleanupForeground succeeded');
      } catch (e) {
        print('[CALLKIT_BG] Step 4 FAILED (expected in bg isolate): $e');
      }
      
      // STEP 5: Dismiss CallKit UI
      print('[CALLKIT_BG] Step 5: Calling endAllCalls...');
      try {
        await FlutterCallkitIncoming.endAllCalls();
        print('[CALLKIT_BG] Step 5 OK: endAllCalls succeeded');
      } catch (e) {
        print('[CALLKIT_BG] Step 5 FAILED: $e');
      }
      
      print('[CALLKIT_BG] ===== DECLINE ESSENTIALS DONE =====');
      
      // STEP 6: API calls (awaited to ensure they complete before isolate dies)
      print('[CALLKIT_BG] Step 6: Running decline API calls...');
      try {
        await _handleDeclineApis(number);
        print('[CALLKIT_BG] Step 6 OK: Decline APIs completed');
      } catch (e) {
        print('[CALLKIT_BG] Step 6 FAILED: $e');
      }
      
    } else if (event is CallEventActionCallAccept) {
      final number = event.callKitParams.extra?['number'] as String? ?? '';
      print('[CALLKIT_BG] ===== ACCEPT (background isolate) =====');
      print('[CALLKIT_BG] Number: $number');
      
      // STEP 1: Save pending action
      print('[CALLKIT_BG] Step 1: Saving pending action...');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fcm_pending_call');
      await prefs.remove('fcm_pending_call_ts');
      await prefs.setString(_pendingActionKey, jsonEncode({
        'action': 'answer',
        'number': number,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }));
      print('[CALLKIT_BG] Step 1 OK: pending action saved');
      
      // STEP 2: Set stop ringtone flag
      print('[CALLKIT_BG] Step 2: Setting callkit_stop_ringtone flag...');
      await prefs.setBool('callkit_stop_ringtone', true);
      print('[CALLKIT_BG] Step 2 OK: callkit_stop_ringtone = true');
      
      // STEP 3: Dismiss CallKit UI
      print('[CALLKIT_BG] Step 3: Calling endAllCalls...');
      try {
        await FlutterCallkitIncoming.endAllCalls();
        print('[CALLKIT_BG] Step 3 OK: endAllCalls succeeded');
      } catch (e) {
        print('[CALLKIT_BG] Step 3 FAILED: $e');
      }
      
      // STEP 4: Cleanup foreground service
      print('[CALLKIT_BG] Step 4: Invoking cleanupForeground...');
      try {
        const platform = MethodChannel('com.example.samvaad/ringtone');
        await platform.invokeMethod('cleanupForeground');
        print('[CALLKIT_BG] Step 4 OK: cleanupForeground succeeded');
      } catch (e) {
        print('[CALLKIT_BG] Step 4 FAILED (expected in bg isolate): $e');
      }
      
      // STEP 5: Bring app to foreground
      print('[CALLKIT_BG] Step 5: Invoking bringAppToForeground...');
      try {
        const platform = MethodChannel('com.example.samvaad/ringtone');
        await platform.invokeMethod('bringAppToForeground');
        print('[CALLKIT_BG] Step 5 OK: bringAppToForeground succeeded');
      } catch (e) {
        print('[CALLKIT_BG] Step 5 FAILED: $e');
      }
      
      print('[CALLKIT_BG] ===== ACCEPT DONE =====');
    }
  } catch (e) {
    print('[CALLKIT_BG] ===== ERROR: $e =====');
    print('[CALLKIT_BG] Stacktrace: ${StackTrace.current}');
  }
}

Future<void> _handleDeclineApis(String number) async {
  print('[CALLKIT_BG_API] ===== Starting decline API calls for $number =====');
  try {
    print('[CALLKIT_BG_API] Step 1: userOnCall()...');
    final onCallRes = await ApiService.userOnCall();
    print('[CALLKIT_BG_API] Step 1 Result: $onCallRes');
    String? bridgeID;
    if (onCallRes['success'] == true) {
      bridgeID = onCallRes['data']?['currentcalldata']?['bridgeID']?.toString();
    }
    print('[CALLKIT_BG_API] bridgeID from userOnCall: $bridgeID');
    
    if (bridgeID == null || bridgeID.isEmpty) {
      print('[CALLKIT_BG_API] Step 2: userConnection() (no bridgeID from userOnCall)...');
      final uctx = await ApiService.userConnection();
      print('[CALLKIT_BG_API] Step 2 Result: $uctx');
      final queues = uctx['data']?['currentCallqueue'] as List<dynamic>? ?? [];
      if (queues.isNotEmpty) {
        bridgeID = queues.first['channelID']?.toString();
      } else {
        final followUps = uctx['data']?['followUpDispoes'] as List<dynamic>? ?? [];
        if (followUps.isNotEmpty) {
          bridgeID = followUps.first['bridgeID']?.toString();
        }
      }
    }
    print('[CALLKIT_BG_API] Final bridgeID: $bridgeID');
    
    print('[CALLKIT_BG_API] Step 3: clearRejectedCallFromAgent($number)...');
    await ApiService.clearRejectedCallFromAgent(number);
    print('[CALLKIT_BG_API] Step 3 OK');
    
    print('[CALLKIT_BG_API] Step 4: callEnded()...');
    await ApiService.callEnded();
    print('[CALLKIT_BG_API] Step 4 OK');
    
    final finalBridgeID = (bridgeID != null && bridgeID.isNotEmpty) ? bridgeID : 'deadCallId';
    print('[CALLKIT_BG_API] Step 5: submitDisposition($finalBridgeID, Auto Disposed)...');
    await ApiService.submitDisposition(finalBridgeID, 'Auto Disposed');
    print('[CALLKIT_BG_API] Step 5 OK');
    
    print('[CALLKIT_BG_API] ===== All decline APIs completed successfully =====');
  } catch (e) {
    print('[CALLKIT_BG_API] ===== FAILED: $e =====');
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
    print('[CALLKIT_EVENT] ==================== ON EVENT FIRED ====================');
    print('[CALLKIT_EVENT] Event type: ${event?.runtimeType}');
    if (event == null) {
      print('[CALLKIT_EVENT] Event is null — returning');
      return;
    }
    switch (event) {
      case CallEventActionCallAccept():
        final number = event.callKitParams.extra?['number'] ?? '';
        print('[CALLKIT_EVENT] ===== ACCEPT (app alive) =====');
        print('[CALLKIT_EVENT] Number: $number');
        
        // Save pending action so DialpadScreen picks it up on resume
        print('[CALLKIT_EVENT] Saving pending action for DialpadScreen...');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_pendingActionKey, jsonEncode({
          'action': 'answer',
          'number': number.toString(),
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }));
        print('[CALLKIT_EVENT] Pending action saved');
        
        print('[CALLKIT_EVENT] Stopping ringtone...');
        RingtoneService().stopRinging();
        print('[CALLKIT_EVENT] Cleaning up foreground service...');
        RingtoneService().cleanupForegroundService();
        print('[CALLKIT_EVENT] Dismissing CallKit UI...');
        _dismissCallKit();
        print('[CALLKIT_EVENT] Clearing CallKit active flag...');
        _clearCallKitActive();
        print('[CALLKIT_EVENT] Clearing FCM pending call...');
        FcmService().clearPendingFcmCall();
        // Do NOT answer SIP here — DialpadScreen._checkPendingCallkitAction will handle it
        print('[CALLKIT_EVENT] ===== ACCEPT DONE (app alive) — pending action set =====');
        
      case CallEventActionCallDecline():
        final number = event.callKitParams.extra?['number'] ?? '';
        print('[CALLKIT_EVENT] ===== DECLINE (app alive) =====');
        print('[CALLKIT_EVENT] Number: $number');
        print('[CALLKIT_EVENT] Stopping ringtone...');
        RingtoneService().stopRinging();
        print('[CALLKIT_EVENT] Cleaning up foreground service...');
        RingtoneService().cleanupForegroundService();
        print('[CALLKIT_EVENT] Dismissing CallKit UI...');
        _dismissCallKit();
        print('[CALLKIT_EVENT] Marking call as declined...');
        _markCallKitDeclined(number.toString());
        print('[CALLKIT_EVENT] Clearing FCM pending call...');
        FcmService().clearPendingFcmCall();
        print('[CALLKIT_EVENT] Clearing pending action...');
        clearPendingAction();
        
        print('[CALLKIT_EVENT] Running decline APIs...');
        _handleDeclineApis(number.toString());
        
        print('[CALLKIT_EVENT] Rejecting SIP call...');
        ApiService.clearRejectedCallFromAgent(number.toString()).then((_) {
          print('[CALLKIT_EVENT] clearRejectedCallFromAgent OK — calling rejectCall');
          SipSocketService().rejectCall();
          print('[CALLKIT_EVENT] rejectCall OK');
        }).catchError((e) {
          print('[CALLKIT_EVENT] clearRejectedCallFromAgent FAILED: $e');
        });
        print('[CALLKIT_EVENT] ===== DECLINE DONE (app alive) =====');
        
      case CallEventActionCallEnded():
        print('[CALLKIT_EVENT] ===== ENDED =====');
        print('[CALLKIT_EVENT] Dismissing CallKit UI...');
        _dismissCallKit();
        print('[CALLKIT_EVENT] Clearing CallKit active flag...');
        _clearCallKitActive();
        print('[CALLKIT_EVENT] Clearing FCM pending call...');
        FcmService().clearPendingFcmCall();
        print('[CALLKIT_EVENT] ===== ENDED DONE =====');
        
      case CallEventActionCallTimeout():
        print('[CALLKIT_EVENT] ===== TIMEOUT =====');
        print('[CALLKIT_EVENT] Dismissing CallKit UI...');
        _dismissCallKit();
        print('[CALLKIT_EVENT] Clearing CallKit active flag...');
        _clearCallKitActive();
        print('[CALLKIT_EVENT] Clearing FCM pending call...');
        FcmService().clearPendingFcmCall();
        print('[CALLKIT_EVENT] ===== TIMEOUT DONE =====');
        
      default:
        print('[CALLKIT_EVENT] Unknown event: ${event.runtimeType}');
        break;
    }
  }

  void dispose() {
    _eventSub?.cancel();
  }
}
