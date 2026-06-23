import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audio_session/audio_session.dart';

class CallLifecycleService with WidgetsBindingObserver {
  static final CallLifecycleService _instance = CallLifecycleService._internal();
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
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionMode: AVAudioSessionMode.voiceChat,
      avAudioSessionRouteSharingPolicy:
          AVAudioSessionRouteSharingPolicy.defaultPolicy,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.voiceCommunication,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: true,
    ));
    _log('Audio session configured');
  }

  Future<void> onCallStarted() async {
    if (_isCallActive) return;
    _isCallActive = true;
    await WakelockPlus.enable();
    _log('Call started - wakelock acquired');
  }

  void onCallEnded() {
    if (!_isCallActive) return;
    _isCallActive = false;
    WakelockPlus.disable();
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
