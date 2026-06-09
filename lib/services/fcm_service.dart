import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'ringtone_service.dart';
import 'sip_socket_service.dart';

const _notificationChannelId = 'incoming_calls_ringtone';
const _notificationChannelName = 'Incoming Calls';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('[FCM_BG] Background handler invoked');
  print('[FCM_BG] Message data: ${message.data}');
  try {
    await Firebase.initializeApp();
    print('[FCM_BG] Firebase initialized');
  } catch (e) {
    print('[FCM_BG] Firebase init FAILED: $e');
    return;
  }
  final fcm = FcmService();
  print('[FCM_BG] FcmService instance obtained');
  await fcm._setupLocalNotifications();
  await fcm._handleMessage(message, isBackground: true);
  print('[FCM_BG] Handler completed');
}

class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  final _localNotifications = FlutterLocalNotificationsPlugin();
  late final FirebaseMessaging _messaging;
  StreamSubscription? _foregroundSub;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    print('[FCM] init() called');

    try {
      await Firebase.initializeApp();
      print('[FCM] Firebase.initializeApp() done');
    } catch (e) {
      print('[FCM] Firebase.initializeApp() FAILED: $e');
      return;
    }

    try {
      _messaging = FirebaseMessaging.instance;
      print('[FCM] FirebaseMessaging.instance OK');
    } catch (e) {
      print('[FCM] FirebaseMessaging.instance FAILED: $e');
      return;
    }

    await RingtoneService().createRingtoneChannel();
    await _setupLocalNotifications();
    await _requestPermission();

    print('[FCM] Setting up onTokenRefresh listener...');
    _messaging.onTokenRefresh.listen((token) {
      print('[FCM] Token refreshed: $token');
      _sendToken(token);
    });

    print('[FCM] Fetching initial token...');
    try {
      final initialToken = await _messaging.getToken();
      print('[FCM] getToken() result: ${initialToken ?? "null"}');
      if (initialToken != null) await _sendToken(initialToken);
    } catch (e) {
      print('[FCM] getToken() FAILED: $e');
    }

    print('[FCM] Setting background message handler...');
    try {
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      print('[FCM] Background handler set');
    } catch (e) {
      print('[FCM] onBackgroundMessage FAILED: $e');
    }

    print('[FCM] Setting foreground message listener...');
    _foregroundSub = FirebaseMessaging.onMessage.listen((message) {
      print('[FCM] Foreground message received: ${message.data}');
      _handleMessage(message, isBackground: false);
    });
    print('[FCM] Foreground listener active');

    print('[FCM] Checking for initial message (killed state)...');
    try {
      final initialMessage = await _messaging.getInitialMessage();
      print('[FCM] getInitialMessage() result: ${initialMessage != null ? "has data" : "null"}');
      if (initialMessage != null) {
        // App was launched from a notification (killed state).
        // Don't show a local notification - the app is now open.
        // The SIP INVITE will follow and trigger the normal call flow.
        print('[FCM] getInitialMessage() - app launched from notification, waiting for SIP');
      }
    } catch (e) {
      print('[FCM] getInitialMessage() FAILED: $e');
    }

    print('[FCM] init() completed successfully');
  }

  Future<void> _requestPermission() async {
    print('[FCM] Requesting notification permission...');
    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        announcement: false,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
      );
      print('[FCM] Permission status: ${settings.authorizationStatus}');
    } catch (e) {
      print('[FCM] Permission request FAILED: $e');
    }
  }

  Future<void> _setupLocalNotifications() async {
    print('[FCM] Setting up local notifications...');
    try {
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _localNotifications.initialize(
        const InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        ),
        onDidReceiveNotificationResponse: onNotificationResponse,
        onDidReceiveBackgroundNotificationResponse: onNotificationResponse,
      );
      print('[FCM] Local notifications initialized');

      print('[FCM] Checking local notification launch details...');
      final launchDetails = await _localNotifications.getNotificationAppLaunchDetails();
      if (launchDetails != null && launchDetails.didNotificationLaunchApp) {
        final response = launchDetails.notificationResponse;
        if (response != null) {
          print('[FCM] Processing launch notification response');
          onNotificationResponse(response);
        }
      }
    } catch (e) {
      print('[FCM] Local notifications init FAILED: $e');
    }


  }

  Future<void> _sendToken(String token) async {
    print('[FCM_TOKEN] Token: $token');
    print('[FCM_TOKEN] Sending to /storeFirebaseToken...');
    final ok = await ApiService.storeFirebaseToken(token);
    if (ok) {
      print('[FCM_TOKEN] Token sent OK');
    } else {
      print('[FCM_TOKEN] Token send FAILED');
    }
  }



  Future<Map<String, dynamic>?> getPendingCallAction() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('pendingCallAction');
    if (raw == null) return null;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final timestamp = data['timestamp'] as int;
    if (DateTime.now().millisecondsSinceEpoch - timestamp > 60000) {
      await prefs.remove('pendingCallAction');
      return null;
    }
    return data;
  }

  Future<void> clearPendingCallAction() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pendingCallAction');
  }

  Future<void> _handleMessage(
    RemoteMessage message, {
    bool isBackground = false,
  }) async {
    print('[FCM] _handleMessage() called | isBackground=$isBackground');
    print('[FCM]   messageId: ${message.messageId}');
    print('[FCM]   data: ${message.data}');

    final data = message.data;
    final callId = data['call_id'];

    if (callId != null) {
      final prefs = await SharedPreferences.getInstance();
      final lastCallId = prefs.getString('last_fcm_call_id');
      if (lastCallId == callId) {
        print('[FCM] Duplicate call_id=$callId, skipping');
        return;
      }
      await prefs.setString('last_fcm_call_id', callId);
    }

    final number = data['body'] ?? data['number'] ?? data['caller'] ?? 'Unknown';
    print('[FCM] Parsed caller number: $number');

    if (isBackground) {
      print('[FCM] Showing notification for background message...');
      await showIncomingCallNotification(number);
      print('[FCM] Background handling done');
    } else {
      print('[FCM] Foreground message - no local notification needed');
    }
  }

  Future<void> showIncomingCallNotification(String number) async {
    await _localNotifications.cancelAll();
    final androidDetails = AndroidNotificationDetails(
      _notificationChannelId,
      _notificationChannelName,
      channelDescription: 'Incoming call notifications',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      visibility: NotificationVisibility.public,
      fullScreenIntent: true,
      actions: [
        const AndroidNotificationAction(
          'answer',
          'Answer',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        const AndroidNotificationAction(
          'decline',
          'Decline',
          showsUserInterface: true,
          cancelNotification: true,
        ),
      ],
    );

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      'Incoming Call',
      number,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode({'number': number}),
    );
  }

  Future<void> cancelAllNotifications() async {
    await _localNotifications.cancelAll();
  }

  void dispose() {
    _foregroundSub?.cancel();
  }
}

@pragma('vm:entry-point')
void onNotificationResponse(NotificationResponse response) async {
  print('[FCM] onNotificationResponse called');
  print('[FCM]   actionId: ${response.actionId}');
  print('[FCM]   payload: ${response.payload}');

  final payload = response.payload;
  if (payload == null) {
    print('[FCM]   payload is null, ignoring');
    return;
  }

  final data = jsonDecode(payload) as Map<String, dynamic>;
  final action = response.actionId;
  final number = data['number'] as String? ?? 'Unknown';

  print('[FCM] Notification response: action=$action, number=$number');

  final sip = SipSocketService();
  print('[FCM] SIP callState: ${sip.callState}');

  FlutterLocalNotificationsPlugin().cancelAll();
  RingtoneService().stopRinging();

  if (action == 'answer') {
    if (sip.callState == CallState.ringing) {
      print('[FCM] Auto-answering SIP call...');
      sip.answerCall();
    } else {
      print('[FCM] Not ringing, storing pending answer action');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'pendingCallAction',
        jsonEncode({'action': 'answer', 'number': number, 'timestamp': DateTime.now().millisecondsSinceEpoch}),
      );
    }
  } else if (action == 'decline') {
    if (sip.callState == CallState.ringing) {
      print('[FCM] Auto-declining SIP call...');
      sip.rejectCall();
    } else {
      print('[FCM] Not ringing, storing pending decline action');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'pendingCallAction',
        jsonEncode({'action': 'decline', 'number': number, 'timestamp': DateTime.now().millisecondsSinceEpoch}),
      );
    }
  }
}

