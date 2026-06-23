import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

const _fcmPendingCallKey = 'fcm_pending_call';
const _fcmPendingCallTsKey = 'fcm_pending_call_ts';
const _fcmPendingTtlMs = 30000;

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('[FCM_BG] Background handler invoked');
  try {
    await Firebase.initializeApp();
  } catch (e) {
    print('[FCM_BG] Firebase init FAILED: $e');
    return;
  }

  final data = message.data;
  final number = data['body'] ?? data['number'] ?? data['caller'] ?? 'Unknown';

  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fcmPendingCallKey, number);
    await prefs.setInt(_fcmPendingCallTsKey, DateTime.now().millisecondsSinceEpoch);
    print('[FCM_BG] Saved pending FCM call for: $number');
  } catch (e) {
    print('[FCM_BG] SharedPreferences save failed: $e');
  }
}

class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  late final FirebaseMessaging _messaging;
  StreamSubscription? _foregroundSub;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    print('[FCM] init() called');

    try {
      await Firebase.initializeApp();
    } catch (e) {
      print('[FCM] Firebase.initializeApp() FAILED: $e');
      return;
    }

    try {
      _messaging = FirebaseMessaging.instance;
    } catch (e) {
      print('[FCM] FirebaseMessaging.instance FAILED: $e');
      return;
    }

    await _requestPermission();

    _messaging.onTokenRefresh.listen((token) {
      print('[FCM] Token refreshed');
      _sendToken(token);
    });

    try {
      final token = await _messaging.getToken();
      if (token != null) await _sendToken(token);
    } catch (e) {
      print('[FCM] getToken() FAILED: $e');
    }

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    _foregroundSub = FirebaseMessaging.onMessage.listen((message) {
      print('[FCM] Foreground message: ${message.data}');
    });

    try {
      final initialMessage = await _messaging.getInitialMessage();
      if (initialMessage != null) {
        print('[FCM] App launched from notification, waiting for SIP');
      }
    } catch (e) {
      print('[FCM] getInitialMessage() FAILED: $e');
    }

    print('[FCM] init() completed');
  }

  Future<void> _requestPermission() async {
    try {
      await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        announcement: false,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
      );
    } catch (e) {
      print('[FCM] Permission request FAILED: $e');
    }
  }

  Future<void> _sendToken(String token) async {
    print('[FCM_TOKEN] Sending token...');
    final ok = await ApiService.storeFirebaseToken(token);
    if (!ok) print('[FCM_TOKEN] Send FAILED');
  }

  Future<Map<String, dynamic>?> getPendingCallAction() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('callkit_pending_action');
    if (raw == null) return null;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final timestamp = data['timestamp'] as int;
    if (DateTime.now().millisecondsSinceEpoch - timestamp > 60000) {
      await prefs.remove('callkit_pending_action');
      return null;
    }
    print('[FCM] getPendingCallAction found: ${data['action']}');
    return data;
  }

  Future<void> clearPendingCallAction() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('callkit_pending_action');
  }

  Future<String?> getPendingFcmCall() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_fcmPendingCallTsKey);
    if (ts == null) return null;
    if (DateTime.now().millisecondsSinceEpoch - ts > _fcmPendingTtlMs) {
      await prefs.remove(_fcmPendingCallKey);
      await prefs.remove(_fcmPendingCallTsKey);
      return null;
    }
    return prefs.getString(_fcmPendingCallKey);
  }

  Future<void> clearPendingFcmCall() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_fcmPendingCallKey);
    await prefs.remove(_fcmPendingCallTsKey);
  }

  void dispose() {
    _foregroundSub?.cancel();
  }
}
