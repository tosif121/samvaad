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
import 'ringtone_service.dart';
import 'sip_socket_service.dart';
import 'toast_service.dart';
import 'user_data.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  log('[FCM_SERVICE] Background message received: ${message.messageId}, data: ${message.data}');

  final type = message.data['type'];
  final callerName = message.data['callerName'] ?? message.data['title'] ?? 'Incoming Call';
  final callerNumber = message.data['callerNumber'] ?? message.data['body'] ?? '';

  final isVideo = message.data['isVideo'] == 'true' ||
      message.data['mediaType'] == 'video' ||
      type == 'video_call';
  final titleText = isVideo ? 'Incoming Video Call' : callerName;
  final bodyText = callerNumber.isNotEmpty
      ? '${isVideo ? "Video call" : "Call"} from $callerNumber'
      : (isVideo ? 'Incoming video call' : 'Incoming call');

  if (type == 'incomingCall' ||
      type == 'incoming_call' ||
      type == 'call' ||
      type == 'video_call') {
    log('[FCM_SERVICE] Displaying incoming call notification ($titleText)...');

    try {
      SipSocketService().connect();
    } catch (e) {
      log('[FCM_SERVICE] Error connecting SIP socket in background: $e');
    }

    try {
      CallKitService().showIncomingCall(
        callerName: callerName,
        callerNumber: callerNumber,
      );
    } catch (e) {
      log('[FCM_SERVICE] Error showing CallKit in background: $e');
    }

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
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    const notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
    );
    await flutterLocalNotificationsPlugin.show(
      0,
      titleText,
      bodyText,
      notificationDetails,
      payload: jsonEncode(message.data),
    );
  }
}

class FcmService with WidgetsBindingObserver {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  FirebaseMessaging? get _messaging {
    try {
      if (Firebase.apps.isNotEmpty) {
        return FirebaseMessaging.instance;
      }
    } catch (e) {
      log('[FCM_SERVICE] Error accessing FirebaseMessaging: $e');
    }
    return null;
  }

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

  Future<void> sendTokenToBackend([String? token]) async {
    try {
      final messaging = _messaging;
      if (token == null || token.isEmpty) {
        token = await messaging?.getToken();
      }
      if (token == null || token.isEmpty) {
        log("[FCM_SERVICE] FCM token is null, cannot send to backend.");
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final credsStr = prefs.getString('sip_credentials');
      if (credsStr == null) {
        log(
          "[FCM_SERVICE] No SIP credentials found, skipping token registration.",
        );
        return;
      }

      final creds = jsonDecode(credsStr);
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
        log("[FCM_SERVICE] Token securely stored in MongoDB! Response: ${response.body}");
      } else {
        log("[FCM_SERVICE] Failed to store token: ${response.statusCode} - ${response.body}");
        ToastService.show('Failed to register push token');
      }
    } catch (e) {
      log("[FCM_SERVICE] Error sending token to backend: $e");
      ToastService.show('Failed to register push token');
    }
  }

  Future<void> removeTokenFromBackend() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final credsStr = prefs.getString('sip_credentials');
      if (credsStr == null) return;

      final creds = jsonDecode(credsStr);
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

      final messaging = _messaging;
      String? token = await messaging?.getToken();
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
        ToastService.show('Failed to remove push token');
      }
    } catch (e) {
      log("[FCM_SERVICE] Error removing token from backend: $e");
      ToastService.show('Failed to remove push token');
    }
  }

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);

    try {
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
          RingtoneService().bringAppToForeground();
          try {
            SipSocketService().connect();
          } catch (e) {
            log('[FCM_SERVICE] Error connecting SIP on notification tap: $e');
          }
          _localNotificationsPlugin.cancelAll();
        },
      );

      // Check if app was opened via notification tap from terminated state
      final launchDetails =
          await _localNotificationsPlugin.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp ?? false) {
        log('[FCM_SERVICE] App launched from notification: ${launchDetails?.notificationResponse?.payload}');
        try {
          SipSocketService().connect();
        } catch (e) {
          log('[FCM_SERVICE] Error connecting SIP on launch notification: $e');
        }
      }

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
    } catch (e) {
      log('[FCM_SERVICE] Error initializing local notifications: $e');
    }

    final messaging = _messaging;
    if (messaging == null) {
      log('[FCM_SERVICE] Firebase Messaging not available, skipping push setup.');
      return;
    }

    // Request permissions ONLY ONCE on initial launch/login
    final prefs = await SharedPreferences.getInstance();
    final hasRequestedAll =
        prefs.getBool('has_requested_all_permissions') ?? false;

    if (!hasRequestedAll) {
      await prefs.setBool('has_requested_all_permissions', true);

      try {
        NotificationSettings settings = await messaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );
        log(
          '[FCM_SERVICE] Notification permission status: ${settings.authorizationStatus}',
        );
      } catch (e) {
        log('[FCM_SERVICE] Error requesting permission: $e');
      }

      if (Platform.isAndroid) {
        try {
          await [
            Permission.microphone,
            Permission.notification,
          ].request();

          if (!await Permission.systemAlertWindow.isGranted) {
            await Permission.systemAlertWindow.request();
          }
        } catch (e) {
          log('[FCM_SERVICE] Error requesting Android permissions: $e');
        }
      }
    }

    // Fetch and send FCM token immediately on init
    try {
      String? token = await messaging.getToken();
      if (token != null) {
        log('[FCM_SERVICE] FCM Token retrieved: $token');
        sendTokenToBackend(token);
      }
    } catch (e) {
      log('[FCM_SERVICE] Error getting FCM token: $e');
    }

    try {
      messaging.onTokenRefresh.listen((newToken) {
        log('[FCM_SERVICE] FCM Token refreshed: $newToken');
        sendTokenToBackend(newToken);
      });
    } catch (e) {
      log('[FCM_SERVICE] Error setting token refresh listener: $e');
    }

    // Foreground messages (app is already open)
    try {
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
          const darwinDetails = DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          );
          const notificationDetails = NotificationDetails(
            android: androidDetails,
            iOS: darwinDetails,
          );

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
    } catch (e) {
      log('[FCM_SERVICE] Error listening to onMessage: $e');
    }

    try {
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    } catch (e) {
      log('[FCM_SERVICE] Error registering background message handler: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Clear notifications when app opens
      _localNotificationsPlugin.cancelAll();
    }
  }
}
