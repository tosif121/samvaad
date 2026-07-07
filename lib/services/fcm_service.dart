import 'dart:developer';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:uuid/uuid.dart';
import 'dart:io' show Platform;
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  log('[FCM_SERVICE] Background message received: ${message.messageId}');
  
  // Example of processing an incoming call payload
  // In a real app, you parse the message.data and trigger CallKit
  final type = message.data['type'];
  if (type == 'incomingCall' || type == 'incoming_call') {
    final callerName = message.data['callerName'] ?? message.data['title'] ?? 'Unknown Caller';
    final callerNumber = message.data['callerNumber'] ?? message.data['body'] ?? 'Unknown Number';
    
    final callKitParams = CallKitParams(
      id: const Uuid().v4(),
      nameCaller: callerName,
      appName: 'Samvaad',
      handle: callerNumber,
      type: 0,
      duration: 30000,
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: true,
        subtitle: 'Missed call',
        callbackText: 'Call back',
      ),
      extra: <String, dynamic>{'userId': '1a2b3c4d'},
      headers: <String, dynamic>{'apiKey': 'v1.0', 'platform': 'flutter'},
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0955fa',
        actionColor: '#4CAF50',
        textColor: '#ffffff',
        textAccept: 'Answer',
        textDecline: 'Decline',
      ),
      ios: const IOSParams(
        iconName: 'CallKitLogo',
        handleType: 'generic',
        supportsVideo: true,
        maximumCallGroups: 2,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: true,
        supportsHolding: true,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );

    await FlutterCallkitIncoming.showCallkitIncoming(callKitParams);
  }
}

class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

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
      
      // Extract tenant from sipUri or username if possible, default to devapp
      String adminuser = "devapp"; 
      if (username.contains('-')) {
        adminuser = username.split('-').last;
      } else if (creds['sipUri'] != null && creds['sipUri'].contains('@')) {
        // e.g. sip:3006@surya.iotcom.io -> might extract surya
        final domain = creds['sipUri'].split('@').last.split('.').first;
        if (domain != 'devapp') adminuser = domain;
      }

      if (username.isEmpty) return;

      final payload = {
        "username": username,
        "adminuser": adminuser,
        "token": token,
        "platform": Platform.isAndroid ? "android" : "ios",
        "deviceId": "flutter_device", 
        "appSecret": "samvaad_mobile_secret_123"
      };

      final url = Uri.parse('https://devapp.iotcom.io/storeFirebaseTokenMobile');
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
      
      String adminuser = "devapp"; 
      if (username.contains('-')) {
        adminuser = username.split('-').last;
      } else if (creds['sipUri'] != null && creds['sipUri'].contains('@')) {
        final domain = creds['sipUri'].split('@').last.split('.').first;
        if (domain != 'devapp') adminuser = domain;
      }

      if (username.isEmpty) return;

      String? token = await _messaging.getToken();
      if (token == null) return;

      final payload = {
        "username": username,
        "adminuser": adminuser,
        "token": token,
        "appSecret": "samvaad_mobile_secret_123"
      };

      final url = Uri.parse('https://devapp.iotcom.io/removeFirebaseTokenMobile');
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
    // Request permissions (primarily for iOS, but good practice)
    NotificationSettings settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    log('[FCM_SERVICE] User granted permission: ${settings.authorizationStatus}');

    // Get FCM Token
    try {
      String? token = await _messaging.getToken();
      if (token != null) {
        log('[FCM_SERVICE] FCM Token: $token');
        await sendTokenToBackend(token);
      }
    } catch (e) {
      log('[FCM_SERVICE] Error getting FCM token: $e');
    }

    // Listen to token refreshes
    _messaging.onTokenRefresh.listen((newToken) {
      log('[FCM_SERVICE] FCM Token refreshed: $newToken');
      sendTokenToBackend(newToken);
    });

    // Foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      log('[FCM_SERVICE] Foreground message received: ${message.messageId}');
      // Handle foreground message (e.g. trigger CallKit if not already on call)
    });

    // Listen to CallKit events
    FlutterCallkitIncoming.onEvent.listen((event) {
      if (event == null) return;
      switch (event) {
        case CallEventActionCallAccept():
          log('[FCM_SERVICE] CallKit Action: Accept');
          // Fast reconnect and answer using native handle incoming push args
          // In a real app, you would pass the caller ID from the event body
          break;
        case CallEventActionCallDecline():
          log('[FCM_SERVICE] CallKit Action: Decline');
          break;
        default:
          break;
      }
    });

    // Background messages are handled by the top-level handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }
}
