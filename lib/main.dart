import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'screens/login_screen.dart';
import 'screens/dialpad_screen.dart';
import 'services/auth_service.dart';
import 'services/call_lifecycle_service.dart';
import 'services/callkit_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterCallkitIncoming.onBackgroundMessage(callkitBackgroundHandler);
  FlutterCallkitIncoming.invokeFlutter((_) {
    print('[MAIN] invokeFlutter called — app restored from CallKit');
  });
  CallLifecycleService().init();
  runApp(const SamvaadApp());
}

class SamvaadApp extends StatelessWidget {
  const SamvaadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Samvaad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4299EB),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          iconTheme: IconThemeData(color: Color(0xFF4299EB)),
          titleTextStyle: TextStyle(
            color: Color(0xFF1a1a1a),
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF4299EB),
            foregroundColor: Colors.white,
            elevation: 2,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF5F9FC),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF4299EB), width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
        ),
      ),
      home: const _StartupScreen(),
    );
  }
}

class _StartupScreen extends StatefulWidget {
  const _StartupScreen();

  @override
  State<_StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<_StartupScreen> {
  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final isLoggedIn = await AuthService.isLoggedIn();
    if (!mounted) return;

    if (isLoggedIn) {
      final userData = await AuthService.getUserData() ?? {};
      final name = userData['Name'] ?? userData['username'] ?? 'User';
      final email = userData['Email'] ?? userData['username'] ?? '';

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DialpadScreen(userName: name, userEmail: email),
          ),
        );
      }
    } else {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
