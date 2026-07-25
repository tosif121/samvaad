import 'dart:developer';
import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:io' show Platform;
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'callkit_service.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  log('[FCM_SERVICE] Background message received: ${message.messageId}');

  final type = message.data['type'] ?? message.data['event'];
  if (type == 'incomingCall' || type == 'incoming_call' || type == 'call') {
    final callerName = message.data['callerName'] ?? message.data['title'] ?? 'Incoming Call';
    final callerNumber = message.data['callerNumber'] ?? message.data['body'] ?? '';
    final callId = message.data['call_id'] ?? '';

    // Persist call info so cold start can detect it even if
    // getAcceptedCallInfo() / onAccept event is missed on Android.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pending_call_number', callerNumber);
    await prefs.setString('pending_call_name', callerName);
    await prefs.setString('pending_call_id', callId);

    log('[FCM_SERVICE] Triggering CallKit for background call from $callerName');
    await CallKitService().showIncomingCall(
      callerName: callerName,
      callerNumber: callerNumber,
      callId: callId,
    );
  } else if (type == 'cancel' || type == 'hangup' || type == 'call_ended' || type == 'ended' || type == 'missed') {
    log('[FCM_SERVICE] Received call termination push, ending CallKit UI');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pending_call_number');
    await prefs.remove('pending_call_name');
    await prefs.remove('pending_call_id');
    await CallKitService().endCurrentCall();
  }
}

class FcmService with WidgetsBindingObserver {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotificationsPlugin = FlutterLocalNotificationsPlugin();

  Future<Map<String, String>> _getDeviceInfo() async {
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        return {
          "deviceId": androidInfo.id,
          "deviceName": "${androidInfo.brand} ${androidInfo.model}"
        };
      } else if (Platform.isIOS) {
        final IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        return {
          "deviceId": iosInfo.identifierForVendor ?? "unknown_ios_device",
          "deviceName": iosInfo.name
        };
      }
    } catch (e) {
      log('[FCM_SERVICE] Error getting device info: $e');
    }
    return {
      "deviceId": "unknown_device",
      "deviceName": "Unknown Device"
    };
  }

  Future<void> sendTokenToBackend(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final credsStr = prefs.getString('sip_credentials');
      if (credsStr == null) {
        log("[FCM_SERVICE] No SIP credentials found, skipping token registration.");
        return;
      }
      
      final creds = jsonDecode(credsStr);
      final username = creds['extension'] ?? creds['username'] ?? '';
      
      String adminuser = "v2-matrix";
      if (username.isEmpty) return;

      final deviceInfo = await _getDeviceInfo();

      final payload = {
        "username": username,
        "adminuser": adminuser,
        "token": token,
        "platform": Platform.isAndroid ? "android" : "ios",
        "deviceId": deviceInfo["deviceId"], 
        "deviceName": deviceInfo["deviceName"],
        "appSecret": "samvaad_mobile_secret_123"
      };

      log("[FCM_SERVICE] Sending payload to backend: ${jsonEncode(payload)}");

      final url = Uri.parse('https://esamwad.iotcom.io/storeFirebaseTokenMobile');
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        log("[FCM_SERVICE] Token securely stored in MongoDB!");
      } else {
        log("[FCM_SERVICE] Failed to store token: ${response.body}");
      }
    } catch (e) {
      log("[FCM_SERVICE] Error sending token to backend: $e");
    }
  }

  Future<void> removeTokenFromBackend() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final credsStr = prefs.getString('sip_credentials');
      if (credsStr == null) return;
      
      final creds = jsonDecode(credsStr);
      final username = creds['extension'] ?? creds['username'] ?? '';
      
      String adminuser = "matrix";
      if (username.isEmpty) return;

      String? token = await _messaging.getToken();
      if (token == null) return;

      final payload = {
        "username": username,
        "adminuser": adminuser,
        "token": token,
        "appSecret": "samvaad_mobile_secret_123"
      };

      final url = Uri.parse('https://esamwad.iotcom.io/removeFirebaseTokenMobile');
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        log("[FCM_SERVICE] Token removed from backend successfully!");
      } else {
        log("[FCM_SERVICE] Failed to remove token: ${response.body}");
      }
    } catch (e) {
      log("[FCM_SERVICE] Error removing token from backend: $e");
    }
  }

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);

    // Initialize local notifications
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings();
    const InitializationSettings initializationSettings = InitializationSettings(
        android: initializationSettingsAndroid, iOS: initializationSettingsIOS);
    
    await _localNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (details) {
        log('[FCM_SERVICE] Local notification tapped: ${details.payload}');
        // Simply tapping it opens the app. The SIP socket will reconnect automatically
        // and trigger the incoming call screen if the call is still active.
        _localNotificationsPlugin.cancelAll();
      },
    );
    
    // Clear notifications on startup
    await _localNotificationsPlugin.cancelAll();

    // Request permissions ONLY ONCE on initial launch/login
    final prefs = await SharedPreferences.getInstance();
    final hasRequestedAll = prefs.getBool('has_requested_all_permissions') ?? false;

    if (!hasRequestedAll) {
      await prefs.setBool('has_requested_all_permissions', true);

      // Request Firebase Messaging notification permission
      NotificationSettings settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      log('[FCM_SERVICE] Notification permission status: ${settings.authorizationStatus}');

      if (Platform.isAndroid) {
        // Request Microphone, Camera & Notification permissions in one prompt batch
        await [
          Permission.microphone,
          Permission.camera,
          Permission.notification,
        ].request();
      }
    }

    try {
      String? token = await _messaging.getToken();
      if (token != null) {
        log('[FCM_SERVICE] FCM Token: $token');
        await sendTokenToBackend(token);
      }
    } catch (e) {
      log('[FCM_SERVICE] Error getting FCM token: $e');
    }

    _messaging.onTokenRefresh.listen((newToken) {
      log('[FCM_SERVICE] FCM Token refreshed: $newToken');
      sendTokenToBackend(newToken);
    });

    // Foreground messages (app is already open)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      log('[FCM_SERVICE] Foreground message received: ${message.messageId}, data: ${message.data}');
      final type = message.data['type'] ?? message.data['event'];
      if (type == 'incomingCall' || type == 'incoming_call' || type == 'call') {
        log('[FCM_SERVICE] Triggering CallKit on foreground notification...');
        final callerName = message.data['callerName'] ?? message.data['title'] ?? 'Incoming Call';
        final callerNumber = message.data['callerNumber'] ?? message.data['body'] ?? '';
        final callId = message.data['call_id'] ?? '';

        CallKitService().showIncomingCall(
          callerName: callerName,
          callerNumber: callerNumber,
          callId: callId,
        );
      } else if (type == 'cancel' || type == 'hangup' || type == 'call_ended' || type == 'ended' || type == 'missed') {
        log('[FCM_SERVICE] Received call termination push in foreground, ending CallKit UI');
        CallKitService().endCurrentCall();
      }
    });

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Clear notifications when app opens
      _localNotificationsPlugin.cancelAll();
    }
  }
}
