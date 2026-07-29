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

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  log('[FCM_SERVICE] Background message received: ${message.messageId}');

  final type = message.data['type'];
  if (type == 'incomingCall' || type == 'incoming_call') {
    // Native MyFirebaseMessagingService handles notification + app opening
    // when app is killed or in background. This handler is kept as fallback
    // for logging and future non-call message types.
    log('[FCM_SERVICE] Incoming call background message (handled natively)');
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

  Future<void> saveCredentialsAndSendToken({
    required String username,
    required String adminuser,
  }) async {
    try {
      log("[FCM_SERVICE] [STEP 1] Received credentials from Webview bridge: username='$username', adminuser='$adminuser'");
      final prefs = await SharedPreferences.getInstance();
      final creds = {
        'username': username,
        'extension': username,
        'adminuser': adminuser,
      };
      await prefs.setString('sip_credentials', jsonEncode(creds));
      log("[FCM_SERVICE] [STEP 2] Saved 'sip_credentials' to SharedPreferences successfully.");

      log("[FCM_SERVICE] [STEP 3] Fetching FCM token from FirebaseMessaging...");
      String? token = await _messaging.getToken();
      if (token != null) {
        log("[FCM_SERVICE] [STEP 4] FCM token fetched: ${token.substring(0, 20)}...");
        await sendTokenToBackend(token);
      } else {
        log("[FCM_SERVICE] [STEP 4 WARNING] FirebaseMessaging.getToken() returned null!");
      }
    } catch (e, st) {
      log("[FCM_SERVICE] [ERROR] Error in saveCredentialsAndSendToken: $e\n$st");
    }
  }

  Future<void> sendTokenToBackend(String token) async {
    try {
      log("[FCM_SERVICE] [POST 1] Starting sendTokenToBackend...");
      final prefs = await SharedPreferences.getInstance();
      final credsStr = prefs.getString('sip_credentials');
      if (credsStr == null) {
        log("[FCM_SERVICE] [POST WARNING] No SIP credentials found in SharedPreferences, skipping token registration.");
        return;
      }
      
      final creds = jsonDecode(credsStr);
      final username = creds['extension'] ?? creds['username'] ?? '';
      
      String adminuser = "devapp"; 
      if (username.contains('-')) {
        adminuser = username.split('-').last;
      } else if (creds['sipUri'] != null && creds['sipUri'].contains('@')) {
        final domain = creds['sipUri'].split('@').last.split('.').first;
        if (domain != 'devapp') adminuser = domain;
      } else if (creds['adminuser'] != null && creds['adminuser'].toString().isNotEmpty) {
        adminuser = creds['adminuser'].toString();
      }

      if (username.isEmpty) {
        log("[FCM_SERVICE] [POST WARNING] Username is empty, skipping POST request.");
        return;
      }

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

      log("[FCM_SERVICE] [POST 2] Sending FCM token payload to backend: ${jsonEncode(payload)}");

      final url = Uri.parse('https://devapp.iotcom.io/storeFirebaseTokenMobile');
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      );

      log("[FCM_SERVICE] [POST 3] Backend Response Code: ${response.statusCode}, Body: ${response.body}");

      if (response.statusCode == 200) {
        log("[FCM_SERVICE] [SUCCESS] FCM Token securely registered in MongoDB!");
      } else {
        log("[FCM_SERVICE] [FAILURE] Failed to store token: ${response.body}");
      }
    } catch (e, st) {
      log("[FCM_SERVICE] [ERROR] Error sending token to backend: $e\n$st");
    }
  }

  Future<void> removeTokenFromBackend() async {
    try {
      log("[FCM_SERVICE] [LOGOUT 1] Initiating FCM token removal on logout...");
      final prefs = await SharedPreferences.getInstance();
      final credsStr = prefs.getString('sip_credentials');
      if (credsStr == null) {
        log("[FCM_SERVICE] [LOGOUT WARNING] No sip_credentials found in SharedPreferences.");
        return;
      }
      
      final creds = jsonDecode(credsStr);
      final username = creds['extension'] ?? creds['username'] ?? '';
      
      String adminuser = creds['adminuser'] ?? "devapp"; 
      if (username.contains('-')) {
        adminuser = username.split('-').last;
      } else if (creds['sipUri'] != null && creds['sipUri'].contains('@')) {
        final domain = creds['sipUri'].split('@').last.split('.').first;
        if (domain != 'devapp') adminuser = domain;
      }

      if (username.isEmpty) {
        log("[FCM_SERVICE] [LOGOUT WARNING] Username is empty, skipping remove token payload.");
        return;
      }

      String? token = await _messaging.getToken();
      if (token == null) {
        log("[FCM_SERVICE] [LOGOUT WARNING] FCM Token is null!");
        return;
      }

      final payload = {
        "username": username,
        "adminuser": adminuser,
        "token": token,
        "appSecret": "samvaad_mobile_secret_123"
      };

      log("[FCM_SERVICE] [LOGOUT 2] Sending remove token payload to backend: ${jsonEncode(payload)}");

      final url = Uri.parse('https://devapp.iotcom.io/removeFirebaseTokenMobile');
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      );

      log("[FCM_SERVICE] [LOGOUT 3] Backend Response Code: ${response.statusCode}, Body: ${response.body}");

      if (response.statusCode == 200) {
        log("[FCM_SERVICE] [SUCCESS] Token removed from backend successfully on logout!");
        await prefs.remove('sip_credentials');
      } else {
        log("[FCM_SERVICE] [FAILURE] Failed to remove token from backend: ${response.body}");
      }
    } catch (e, st) {
      log("[FCM_SERVICE] [ERROR] Error removing token from backend: $e\n$st");
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

        // Request Display over other apps (System Alert Window) once
        if (!await Permission.systemAlertWindow.isGranted) {
          await Permission.systemAlertWindow.request();
        }
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
      log('[FCM_SERVICE] Foreground message received: ${message.messageId}');
      // Ignore foreground notifications since the app will show the SIP incoming call screen automatically.
      _localNotificationsPlugin.cancelAll();
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
