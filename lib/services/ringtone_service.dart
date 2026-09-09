import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class RingtoneService {
  static final RingtoneService _instance = RingtoneService._internal();
  factory RingtoneService() => _instance;
  RingtoneService._internal() {
    _initMethodCallHandler();
  }

  static const _channel = MethodChannel('com.example.samvaad/ringtone');
  Timer? _fallbackTimer;
  static bool _channelCreated = false;
  VoidCallback? onNativeEndCall;

  void _initMethodCallHandler() {
    if (!kIsWeb && Platform.isAndroid) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'nativeEndCall') {
          debugPrint('[RingtoneService] Received nativeEndCall from notification');
          onNativeEndCall?.call();
        }
        return null;
      });
    }
  }

  Future<void> createRingtoneChannel() async {
    if (_channelCreated) return;
    _channelCreated = true;
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('createRingtoneChannel');
      } catch (_) {}
    }
  }

  Future<void> startRinging() async {
    await stopRinging();
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('playRingtone');
        return;
      } catch (_) {}
    }
    _fallbackTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    });
  }

  Future<void> bringAppToForeground() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('bringAppToForeground');
      } catch (e) {
        debugPrint('Error bringing app to foreground: $e');
      }
    }
  }

  Future<void> clearNotification() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('clearNotification');
      } catch (e) {
        debugPrint('Error clearing notification: $e');
      }
    }
  }

  Future<void> stopRinging() async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('stopRingtone');
      } catch (_) {}
    }
  }

  Future<void> startCallForeground({
    String callerName = 'Active Call',
    String callerNumber = '',
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('startCallForeground', {
          'callerName': callerName,
          'callerNumber': callerNumber,
        });
      } catch (e) {
        debugPrint('Error starting CallForegroundService: $e');
      }
    }
  }

  Future<void> stopCallForeground() async {
    if (!kIsWebPlatform() && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('stopCallForeground');
      } catch (e) {
        debugPrint('Error stopping CallForegroundService: $e');
      }
    }
  }

  bool kIsWebPlatform() => kIsWeb;

  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
      } catch (e) {
        debugPrint('Error requesting ignore battery optimizations: $e');
      }
    }
  }

  Future<void> cleanupForegroundService() async {
    await stopCallForeground();
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('cleanupForeground');
      } catch (e) {
        debugPrint('Error cleaning up foreground service: $e');
      }
    }
  }
}
