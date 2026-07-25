import 'package:flutter/material.dart';
import 'screens/login_screen.dart';
import 'screens/dialpad_screen.dart';
import 'screens/connecting_call_screen.dart';
import 'services/call_lifecycle_service.dart';
import 'services/sip_socket_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/fcm_service.dart';
import 'services/callkit_service.dart';

const _primaryColor = Color(0xFF4299EB);
const _secondaryColor = Color(0xFF00C853);
const _errorColor = Color(0xFFFF5252);
const _darkText = Color(0xFF1a1a1a);

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp();
  await FcmService().init();

  CallLifecycleService().init();

  final sip = SipSocketService();
  await sip.loadCredentials();

  Map<String, String>? initialCallInfo;
  try {
    initialCallInfo = await CallKitService().getAcceptedCallInfo();
    if (initialCallInfo != null) {
      sip.shouldAutoAnswerNextCall = true;
      CallKitService().isCallKitAnswering = true;
    }
  } catch (e) {
    debugPrint('[MAIN] Error checking initial CallKit call info: $e');
  }

  // Fallback: check SharedPreferences for a pending call saved by the
  // FCM background handler (catches the Android cold-start case where
  // getAcceptedCallInfo() returns null and the onAccept event is lost).
  if (initialCallInfo == null) {
    final prefs = await SharedPreferences.getInstance();
    final pendingNumber = prefs.getString('pending_call_number');
    if (pendingNumber != null && pendingNumber.isNotEmpty) {
      final pendingName = prefs.getString('pending_call_name') ?? '';
      initialCallInfo = {
        'callerNumber': pendingNumber,
        'callerName': pendingName,
      };
      sip.shouldAutoAnswerNextCall = true;
      CallKitService().isCallKitAnswering = true;
      debugPrint('[MAIN] Restored pending call from SharedPreferences: $pendingName ($pendingNumber)');
    }
    // Clear prefs after reading (also cleared on call end as a safety net).
    await prefs.remove('pending_call_number');
    await prefs.remove('pending_call_name');
    await prefs.remove('pending_call_id');
  }

  CallKitService().listenCallEvents(
    onAccept: (callerNumber, callerName) async {
      await CallKitService().endCurrentCall();
      sip.shouldAutoAnswerNextCall = true;
      CallKitService().isCallKitAnswering = true;
      if (navigatorKey.currentState != null) {
        navigatorKey.currentState!.pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => ConnectingCallScreen(
              callerName: callerName,
              callerNumber: callerNumber,
            ),
          ),
          (route) => false,
        );
      }
    },
    onDecline: () async {
      final sipService = SipSocketService();
      await sipService.endCall();
      await CallKitService().endCurrentCall();
    },
  );

  runApp(SamvaadApp(
    hasCredentials: sip.hasCredentials,
    initialCallInfo: initialCallInfo,
  ));
}

class SamvaadApp extends StatelessWidget {
  final bool hasCredentials;
  final Map<String, String>? initialCallInfo;

  const SamvaadApp({
    super.key,
    required this.hasCredentials,
    this.initialCallInfo,
  });

  @override
  Widget build(BuildContext context) {
    Widget initialHome;
    if (initialCallInfo != null) {
      initialHome = ConnectingCallScreen(
        callerName: initialCallInfo!['callerName'] ?? '',
        callerNumber: initialCallInfo!['callerNumber'] ?? '',
      );
    } else if (hasCredentials) {
      initialHome = const DialpadScreen();
    } else {
      initialHome = const LoginScreen();
    }

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Samvaad',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: initialHome,
    );
  }

  ThemeData _buildTheme() {
    final colorScheme = ColorScheme.light(
      primary: _primaryColor,
      onPrimary: Colors.white,
      secondary: _secondaryColor,
      onSecondary: Colors.white,
      error: _errorColor,
      onError: Colors.white,
      surface: Colors.white,
      onSurface: _darkText,
      outline: Colors.grey.shade300,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFFF5F6FA),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: colorScheme.primary),
        titleTextStyle: TextStyle(
          color: _darkText,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.grey.shade200, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF8F9FA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade200, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade200, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _primaryColor, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: _errorColor, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: 18,
        ),
        labelStyle: TextStyle(color: Colors.grey.shade600, fontSize: 15),
      ),
      dividerTheme: DividerThemeData(
        color: Colors.grey.shade200,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}
