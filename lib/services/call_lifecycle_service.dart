import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audio_session/audio_session.dart';

class CallLifecycleService with WidgetsBindingObserver {
  static final CallLifecycleService _instance =
      CallLifecycleService._internal();
  factory CallLifecycleService() => _instance;

  bool _isCallActive = false;
  bool _isInitialized = false;

  CallLifecycleService._internal();

  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;

    WidgetsBinding.instance.addObserver(this);
    await _configureAudioSession();

    _log('Initialized');
  }

  Future<void> _configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowBluetoothA2dp |
            AVAudioSessionCategoryOptions.defaultToSpeaker,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ),
    );
    _log('Audio session configured with Bluetooth & speaker support');
  }

  Future<void> onCallStarted() async {
    if (_isCallActive) return;
    _isCallActive = true;
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (e) {
      _log('Failed to activate audio session: $e');
    }
    try {
      await WakelockPlus.enable();
    } catch (e) {
      _log('Failed to enable wakelock: $e');
    }
    _log('Call started - audio session activated and wakelock acquired');
  }

  Future<void> onCallEnded() async {
    if (!_isCallActive) return;
    _isCallActive = false;
    try {
      await WakelockPlus.disable();
    } catch (e) {
      _log('Failed to disable wakelock: $e');
    }
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (e) {
      _log('Failed to deactivate audio session: $e');
    }
    _log('Call ended - resources released');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _log('App lifecycle: $state');
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  void _log(String msg) {
    developer.log(
      '[${DateTime.now().toIso8601String()}] [CALL_LIFECYCLE] $msg',
      name: 'Samvaad',
    );
  }
}
