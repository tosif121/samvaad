import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audio_session/audio_session.dart';

const _kChannel = MethodChannel('com.samwad/ringtone');

class CallLifecycleService with WidgetsBindingObserver {
  static final CallLifecycleService _instance = CallLifecycleService._internal();
  factory CallLifecycleService() => _instance;

  bool _isCallActive = false;
  bool _isInitialized = false;
  bool _foregroundStarted = false;
  VoidCallback? _reRegisterCallback;

  /// Set this from SipSocketService so CallLifecycleService can trigger
  /// re-registration when the app resumes from background.
  void setReRegisterCallback(VoidCallback cb) => _reRegisterCallback = cb;

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
    _isCallActive = true;
    await WakelockPlus.enable();
    if (!_foregroundStarted) {
      _foregroundStarted = true;
      try { await _kChannel.invokeMethod('startSipForeground'); } catch (_) {}
      _log('Call started - wakelock + foreground service acquired');
    }
  }

  void onCallEnded() {
    _isCallActive = false;
    _foregroundStarted = false;
    WakelockPlus.disable();
    _kChannel.invokeMethod('stopSipForeground').catchError((_) {});
    _log('Call ended - resources released');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _log('App lifecycle: $state');
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // Always keep audio session active when backgrounded (call or not)
      // so SIP WebSocket keep-alive pings can fire
      _keepAliveInBackground();
    } else if (state == AppLifecycleState.resumed) {
      _log('Resumed — re-activating audio + triggering SIP re-register');
      _activateAudioSession();
      // Re-register SIP on resume so Asterisk updates the contact binding
      // and incoming calls reach us again after background
      Future.delayed(const Duration(milliseconds: 500), () {
        _reRegisterCallback?.call();
      });
    }
  }

  Future<void> _keepAliveInBackground() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
      _log('Audio session kept active in background');
    } catch (e) {
      _log('Background keepalive failed: $e');
    }
  }

  Future<void> _activateAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
      _log('Audio session re-activated on resume');
    } catch (e) {
      _log('Audio session re-activate failed: $e');
    }
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
