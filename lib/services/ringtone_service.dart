import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';

class RingtoneService {
  static final RingtoneService _instance = RingtoneService._internal();
  factory RingtoneService() => _instance;
  RingtoneService._internal();

  static const _channel = MethodChannel('com.example.samvaad/ringtone');
  Timer? _fallbackTimer;

  Future<void> startRinging() async {
    await stopRinging();
    if (Platform.isAndroid) {
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

  Future<void> stopRinging() async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('stopRingtone');
      } catch (_) {}
    }
  }
}
