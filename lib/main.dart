import 'dart:io';
import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'screens/dialpad_screen.dart';
import 'services/call_lifecycle_service.dart';
import 'services/sip_socket_service.dart';
import 'services/user_data.dart';
import 'package:firebase_core/firebase_core.dart';
import 'services/fcm_service.dart';
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

  await _acquireSingleInstanceLock();

  await Firebase.initializeApp();
  await UserData.init();
  await FcmService().init();

  CallLifecycleService().init();

  final sip = SipSocketService();
  await sip.loadCredentials();

  await ThemeController.instance.init();

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
