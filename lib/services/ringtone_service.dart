import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class RingtoneService {
  static final RingtoneService _instance = RingtoneService._internal();
  factory RingtoneService() => _instance;
  RingtoneService._internal();

  static const _channel = MethodChannel('com.samwad/ringtone');
  Timer? _fallbackTimer;
  static bool _channelCreated = false;

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
        print('Error bringing app to foreground: $e');
      }
    }
  }

  Future<void> clearNotification() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('clearNotification');
      } catch (e) {
        print('Error clearing notification: $e');
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

  Future<void> cleanupForegroundService() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _channel.invokeMethod('cleanupForeground');
      } catch (e) {
        print('Error cleaning up foreground service: $e');
      }
    }
  }
}
