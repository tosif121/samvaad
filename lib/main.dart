import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'services/fcm_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  await FcmService().init();
  await AndroidWebViewController.enableDebugging(true);

  runApp(const SamvaadApp());
}

class SamvaadApp extends StatelessWidget {
  const SamvaadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Samvaad',
      debugShowCheckedModeBanner: false,
      home: const WebViewScreen(),
    );
  }
}

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();

    const notificationJs = '''
(function() {
  var originalRequest = Notification.requestPermission;
  Notification.requestPermission = function() {
    if (originalRequest) {
      try { originalRequest.call(Notification); } catch(_) {}
    }
    return Promise.resolve('granted');
  };
  Notification.permission = 'granted';
})();
''';

    _controller = WebViewController(
      onPermissionRequest: (request) {
        request.grant();
      },
    )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FlutterFCMBridge',
        onMessageReceived: (JavaScriptMessage message) async {
          debugPrint('[FCM_BRIDGE] Received message from Webview: ${message.message}');
          try {
            final data = jsonDecode(message.message);
            final action = (data['action'] ?? '').toString();

            if (action == 'logout' || data['logout'] == true) {
              debugPrint('[FCM_BRIDGE] Logout signal received from Webview! Removing FCM token from backend...');
              await FcmService().removeTokenFromBackend();
              return;
            }

            if (action == 'speakerphone') {
              final on = data['on'] == true;
              debugPrint('[FCM_BRIDGE] Speakerphone toggle: on=$on');
              try {
                await _channel.invokeMethod('setSpeakerphone', {'on': on});
              } catch (e) {
                debugPrint('[FCM_BRIDGE] Error setting speakerphone: $e');
              }
              return;
            }

            final username = (data['username'] ?? data['user'] ?? data['extension'] ?? '').toString();
            final adminuser = (data['adminuser'] ?? data['domain'] ?? data['tenant'] ?? 'devapp').toString();
            if (username.isNotEmpty) {
              await FcmService().saveCredentialsAndSendToken(
                username: username,
                adminuser: adminuser,
              );
            } else if (action == 'logout') {
              await FcmService().removeTokenFromBackend();
            }
          } catch (e) {
            debugPrint('[FCM_BRIDGE] Error parsing credentials/logout from JS: $e');
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _controller.runJavaScript(notificationJs);
          },
          onPageFinished: (_) async {
            setState(() {});
            await _injectPendingFcmCall();
            await _injectFcmTokenAndAutoDetectUser();
          },
        ),
      )
      ..loadRequest(Uri.parse('https://devapp.iotcom.io/webphone/mobile/'));
    _configureAndroidSettings();
  }

  static const _channel = MethodChannel('com.example.samvaad/ringtone');

  Future<void> _injectPendingFcmCall() async {
    try {
      final data = await _channel.invokeMethod<Map>('getPendingIncomingCall');
      if (data == null || data.isEmpty) return;
      final number = data['number'] as String?;
      final name = data['name'] as String? ?? 'Unknown';
      if (number == null || number.isEmpty) return;
      final payload = jsonEncode({'number': number, 'name': name});
      await _controller.runJavaScript('''
(function() {
  var data = $payload;
  window.pendingIncomingCall = data;
  window.dispatchEvent(new CustomEvent('fcmIncomingCall', {detail: data}));
})();
''');
      debugPrint('[FCM_BRIDGE] Injected incoming call: $number');
    } catch (e) {
      debugPrint('[FCM_BRIDGE] Error: $e');
    }
  }

  Future<void> _injectFcmTokenAndAutoDetectUser() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        debugPrint('[FCM_BRIDGE] [STEP A] Injecting global FCM token into Webview window.fcmToken: $token');
        await _controller.runJavaScript('''
(function() {
  window.fcmToken = "$token";
  window.mobileToken = "$token";
  console.log("[FCM_WEBVIEW] [STEP A] window.fcmToken globally set: " + window.fcmToken.substring(0, 15) + "...");
  if (window.onFcmTokenReceived) {
    try { window.onFcmTokenReceived("$token"); } catch(_) {}
  }
})();
''');
      }

      const autoDetectJs = '''
(function() {
  function extractUserAndBridge() {
    try {
      var savedUsername = localStorage.getItem('savedUsername');
      var tokenStr = localStorage.getItem('token');
      var adminuser = 'devapp';
      var username = savedUsername;

      if (tokenStr) {
        try {
          var tokenObj = JSON.parse(tokenStr);
          if (tokenObj) {
            if (!username) {
              username = tokenObj.username ||
                         (tokenObj.userData && (tokenObj.userData.username || tokenObj.userData.extension || tokenObj.userData.user)) ||
                         (tokenObj.user && tokenObj.user.username);
            }
            adminuser = tokenObj.adminuser ||
                        (tokenObj.userData && (tokenObj.userData.adminuser || tokenObj.userData.tenant || tokenObj.userData.domain)) ||
                        tokenObj.tenant ||
                        'devapp';
          }
        } catch(e) {}
      }

      if (!username) {
        username = localStorage.getItem('user') ||
                   localStorage.getItem('username') ||
                   localStorage.getItem('extension') ||
                   localStorage.getItem('agent');
      }

      if (username) {
        if (!window._fcmSentUser || window._fcmSentUser !== username) {
          window._fcmSentUser = username;
          console.log('[FCM_WEBVIEW] [STEP C] Found webphone credentials: username=' + username + ', adminuser=' + adminuser);
          if (window.FlutterFCMBridge) {
            window.FlutterFCMBridge.postMessage(JSON.stringify({
              action: 'login',
              username: username,
              adminuser: adminuser
            }));
          } else {
            console.warn('[FCM_WEBVIEW] [STEP C WARNING] window.FlutterFCMBridge is undefined');
          }
        }
      } else {
        if (window._fcmSentUser) {
          console.log('[FCM_WEBVIEW] [LOGOUT DETECTED] User logged out! Sending logout signal for user: ' + window._fcmSentUser);
          if (window.FlutterFCMBridge) {
            window.FlutterFCMBridge.postMessage(JSON.stringify({
              action: 'logout',
              username: window._fcmSentUser
            }));
          }
          window._fcmSentUser = null;
        }
      }
    } catch(e) {
      console.error('[FCM_WEBVIEW] [ERROR] Exception during extractUserAndBridge:', e);
    }
  }

  if (!window._fcmLogoutHooked) {
    window._fcmLogoutHooked = true;
    var origClear = localStorage.clear;
    localStorage.clear = function() {
      if (window._fcmSentUser && window.FlutterFCMBridge) {
        console.log('[FCM_WEBVIEW] localStorage.clear() invoked - sending logout signal');
        window.FlutterFCMBridge.postMessage(JSON.stringify({ action: 'logout', username: window._fcmSentUser }));
        window._fcmSentUser = null;
      }
      return origClear.apply(this, arguments);
    };
    var origRemoveItem = localStorage.removeItem;
    localStorage.removeItem = function(key) {
      if ((key === 'token' || key === 'savedUsername' || key === 'user' || key === 'username') && window._fcmSentUser && window.FlutterFCMBridge) {
        console.log('[FCM_WEBVIEW] localStorage.removeItem(' + key + ') invoked - sending logout signal');
        window.FlutterFCMBridge.postMessage(JSON.stringify({ action: 'logout', username: window._fcmSentUser }));
        window._fcmSentUser = null;
      }
      return origRemoveItem.apply(this, arguments);
    };
  }

  extractUserAndBridge();
  if (!window._fcmBridgeInterval) {
    window._fcmBridgeInterval = setInterval(extractUserAndBridge, 2000);
  }
})();
''';

      await _controller.runJavaScript(autoDetectJs);
      debugPrint('[FCM_BRIDGE] [STEP B] Auto-detector script injected successfully into Webview.');
    } catch (e) {
      debugPrint('[FCM_BRIDGE] [ERROR] Error injecting FCM token auto-detector: $e');
    }
  }

  Future<void> _configureAndroidSettings() async {
    if (_controller.platform is AndroidWebViewController) {
      final android = _controller.platform as AndroidWebViewController;
      await android.setMediaPlaybackRequiresUserGesture(false);
      await android.setMixedContentMode(MixedContentMode.alwaysAllow);
      await android.setAllowFileAccess(true);
      await android.setUserAgent(
        'Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.6367.113 Mobile Safari/537.36',
      );
      await android.setOnConsoleMessage((message) {
        debugPrint('[WEBVIEW:${message.level.name}] ${message.message}');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: WebViewWidget(controller: _controller)),
    );
  }
}
