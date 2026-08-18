import 'dart:io';
import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'screens/dialpad_screen.dart';
import 'services/call_lifecycle_service.dart';
import 'services/sip_socket_service.dart';
import 'services/user_data.dart';
import 'package:firebase_core/firebase_core.dart';
import 'services/fcm_service.dart';
import 'services/permission_service.dart';
import 'services/toast_service.dart';
import 'ui/theme.dart';

const _singleInstancePort = 56321;
ServerSocket? _instanceLock;

Future<void> _acquireSingleInstanceLock() async {
  if (Platform.isAndroid || Platform.isIOS) return;
  try {
    _instanceLock = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      _singleInstancePort,
    );
    _instanceLock?.listen((_) {});
  } on SocketException {
    exit(0);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('[FlutterError] ${details.exceptionAsString()}');
  };

  try {
    await _acquireSingleInstanceLock();
  } catch (e) {
    debugPrint('[SingleInstanceLock] Error: $e');
  }

  try {
    await UserData.init();
  } catch (e) {
    debugPrint('[UserData] Init error: $e');
  }

  try {
    await PermissionService().requestAppPermissions();
  } catch (e) {
    debugPrint('[PermissionService] Request error: $e');
  }

  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('[Firebase] Init skipped/error: $e');
  }

  try {
    await FcmService().init();
  } catch (e) {
    debugPrint('[FcmService] Init skipped/error: $e');
  }

  try {
    await CallLifecycleService().init();
  } catch (e) {
    debugPrint('[CallLifecycleService] Init error: $e');
  }

  final sip = SipSocketService();
  try {
    await sip.loadCredentials();
  } catch (e) {
    debugPrint('[SipSocketService] Load credentials error: $e');
  }

  try {
    await ThemeController.instance.init();
  } catch (e) {
    debugPrint('[ThemeController] Init error: $e');
  }

  runApp(SamvaadApp(hasCredentials: sip.hasCredentials));
}

class SamvaadApp extends StatelessWidget {
  final bool hasCredentials;

  const SamvaadApp({super.key, required this.hasCredentials});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance.mode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Samvaad',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: ToastService.messengerKey,
          theme: SamvaadTheme.light(),
          darkTheme: SamvaadTheme.dark(),
          themeMode: mode,
          home: hasCredentials ? const DialpadScreen() : const LoginScreen(),
        );
      },
    );
  }
}
