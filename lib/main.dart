import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/fcm_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  await FcmService().init();
  await AndroidWebViewController.enableDebugging(true);

  await [
    Permission.microphone,
    Permission.camera,
  ].request();

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
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _controller.runJavaScript(notificationJs);
          },
          onPageFinished: (_) => setState(() {}),
        ),
      )
      ..loadRequest(Uri.parse('https://devapp.iotcom.io/webphone/v1/'));

    _configureAndroidSettings();
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
