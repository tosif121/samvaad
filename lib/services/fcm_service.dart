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
import 'ringtone_service.dart';
import 'user_data.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  log('[FCM_SERVICE] Background message received: ${message.messageId}, data: ${message.data}');

  final type = message.data['type'];
  final callerName = message.data['callerName'] ?? message.data['title'] ?? 'Incoming Call';
  final callerNumber = message.data['callerNumber'] ?? message.data['body'] ?? '';

  if (type == 'incomingCall' || type == 'incoming_call' || type == 'call') {
    log('[FCM_SERVICE] Displaying incoming call notification for $callerName...');
    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
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
    const notificationDetails = NotificationDetails(android: androidDetails);
    await flutterLocalNotificationsPlugin.show(
      0,
      callerName,
      callerNumber.isNotEmpty ? 'Incoming call from $callerNumber' : 'Incoming call',
      notificationDetails,
      payload: jsonEncode(message.data),
    );
  }
}

class FcmService with WidgetsBindingObserver {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  Future<Map<String, String>> _getDeviceInfo() async {
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        return {
          "deviceId": androidInfo.id,
          "deviceName": "${androidInfo.brand} ${androidInfo.model}",
        };
      } else if (Platform.isIOS) {
        final IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        return {
          "deviceId": iosInfo.identifierForVendor ?? "unknown_ios_device",
          "deviceName": iosInfo.name,
        };
      }
    } catch (e) {
      log('[FCM_SERVICE] Error getting device info: $e');
    }
    return {"deviceId": "unknown_device", "deviceName": "Unknown Device"};
  }

  Future<void> sendTokenToBackend(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final credsStr = prefs.getString('sip_credentials');
      if (credsStr == null) {
        log(
          "[FCM_SERVICE] No SIP credentials found, skipping token registration.",
        );
        return;
      }

      final creds = jsonDecode(credsStr);
      // Mirror the webphone: register under `userid` (e.g. demo@surya) so the
      // backend finds the token when it sends a push for an incoming call.
      final username = UserData.userId().isNotEmpty
          ? UserData.userId()
          : UserData.username().isNotEmpty
          ? UserData.username()
          : (creds['extension'] ?? creds['username'] ?? '');

      String adminuser = UserData.adminUser();
      if (adminuser.isEmpty) {
        await UserData.init();
        adminuser = UserData.adminUser();
      }
      if (adminuser.isEmpty) {
        adminuser = "devapp";
      }
      if (username.isEmpty) return;

      final deviceInfo = await _getDeviceInfo();

      final payload = {
        "username": username,
        "adminuser": adminuser,
        "token": token,
        "platform": Platform.isAndroid ? "android" : "ios",
        "deviceId": deviceInfo["deviceId"],
        "deviceName": deviceInfo["deviceName"],
        "appSecret": "samvaad_mobile_secret_123",
      };

      log("[FCM_SERVICE] Sending payload to backend: ${jsonEncode(payload)}");

      final url = Uri.parse(
        'https://devapp.iotcom.io/storeFirebaseTokenMobile',
      );
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
      // Mirror the webphone: register under `userid` (e.g. demo@surya).
      final username = UserData.userId().isNotEmpty
          ? UserData.userId()
          : UserData.username().isNotEmpty
          ? UserData.username()
          : (creds['extension'] ?? creds['username'] ?? '');

      String adminuser = UserData.adminUser();
      if (adminuser.isEmpty) {
        await UserData.init();
        adminuser = UserData.adminUser();
      }
      if (adminuser.isEmpty) {
        adminuser = "devapp";
      }
      if (username.isEmpty) return;

      String? token = await _messaging.getToken();
      if (token == null) return;

      final payload = {
        "username": username,
        "adminuser": adminuser,
        "token": token,
        "appSecret": "samvaad_mobile_secret_123",
      };

      final url = Uri.parse(
        'https://devapp.iotcom.io/removeFirebaseTokenMobile',
      );
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
    const DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings();
    const InitializationSettings initializationSettings =
        InitializationSettings(
          android: initializationSettingsAndroid,
          iOS: initializationSettingsIOS,
        );

    await _localNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (details) {
        log('[FCM_SERVICE] Local notification tapped: ${details.payload}');
        _localNotificationsPlugin.cancelAll();
      },
    );

    // Register high priority Android Notification Channel
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'incoming_calls_channel',
      'Incoming Calls',
      description: 'Notifications for incoming call alerts',
      importance: Importance.max,
      playSound: true,
    );

    final androidPlugin = _localNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(channel);
    }

    // Clear notifications on startup
    await _localNotificationsPlugin.cancelAll();

    // Request permissions ONLY ONCE on initial launch/login
    final prefs = await SharedPreferences.getInstance();
    final hasRequestedAll =
        prefs.getBool('has_requested_all_permissions') ?? false;

    if (!hasRequestedAll) {
      await prefs.setBool('has_requested_all_permissions', true);

      // Request Firebase Messaging notification permission
      NotificationSettings settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      log(
        '[FCM_SERVICE] Notification permission status: ${settings.authorizationStatus}',
      );

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

    // Fetch and send FCM token immediately on init
    try {
      String? token = await _messaging.getToken();
      if (token != null) {
        log('[FCM_SERVICE] FCM Token retrieved: $token');
        sendTokenToBackend(token);
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
      log(
        '[FCM_SERVICE] Foreground message received: ${message.messageId}, data: ${message.data}',
      );
      final type = message.data['type'];
      if (type == 'incomingCall' || type == 'incoming_call' || type == 'call') {
        log('[FCM_SERVICE] Ringing on foreground notification...');
        RingtoneService().startRinging();

        final callerName =
            message.data['callerName'] ?? message.data['title'] ?? 'Incoming Call';
        final callerNumber =
            message.data['callerNumber'] ?? message.data['body'] ?? '';

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
        const notificationDetails =
            NotificationDetails(android: androidDetails);

        _localNotificationsPlugin.show(
          0,
          callerName,
          callerNumber.isNotEmpty
              ? 'Incoming call from $callerNumber'
              : 'Incoming call',
          notificationDetails,
          payload: jsonEncode(message.data),
        );
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
