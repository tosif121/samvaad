import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sip_ua/sip_ua.dart' as sip;
import 'auth_service.dart';
import 'remote_audio_stub.dart'
    if (dart.library.html) 'remote_audio_web.dart';
import 'call_lifecycle_service.dart';

enum CallState { idle, dialing, ringing, onCall }

enum SipEvent {
  registered,
  registrationFailed,
  incomingCall,
  callAnswered,
  callEnded,
  callFailed,
  connectionLost,
  connectionRestored,
}

class SipSocketService implements sip.SipUaHelperListener {
  static final SipSocketService _instance = SipSocketService._internal();
  factory SipSocketService() => _instance;

  final sip.SIPUAHelper _helper = sip.SIPUAHelper();

  static const String _origin = 'devapp.iotcom.io';

  CallState _callState = CallState.idle;
  sip.Call? _activeCall;
  String? _autoRejectedCallId;
  String? _lastCallId;
  String _incomingNumber = '';
  String _dialedNumber = '';
  bool _pendingAnswer = false;
  bool _isVideo = false;

  bool _isRegistered = false;
  bool _isConnected = false;
  bool _isMuted = false;
  bool _isHeld = false;

  dynamic _remoteStream;
  dynamic _localStream;
  bool _endingCall = false;
  sip.UaSettings? _lastSettings;  // stored for reconnect

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  CallState get callState => _callState;
  String get incomingNumber => _incomingNumber;
  bool get isRegistered => _isRegistered;
  bool get isConnected => _isConnected;
  bool get hasPendingAnswer => _pendingAnswer;
  bool get isVideo => _isVideo;
  dynamic get remoteStream => _remoteStream;
  dynamic get localStream => _localStream;
  bool get isMuted => _isMuted;
  bool get isHeld => _isHeld;

  SipSocketService._internal() {
    _helper.addSipUaHelperListener(this);
    CallLifecycleService().setReRegisterCallback(_reRegisterIfNeeded);
  }

  void _reRegisterIfNeeded() {
    if (!_isConnected || !_isRegistered) {
      _log('Re-registering SIP after resume (was disconnected or unregistered)');
      try { _helper.register(); } catch (e) { _log('re-register failed: $e'); }
    }
  }

  void _log(String msg, {Object? data}) {
    final ts = DateTime.now().toIso8601String();
    final log = data != null
        ? '[$ts] [SIP] $msg | $data'
        : '[$ts] [SIP] $msg';
    developer.log(log, name: 'Samvaad');
    print(log);
  }

  void _emit(SipEvent event, {Map<String, dynamic>? data}) {
    _log('→ ${event.name}', data: data);
    _eventController.add({'event': event.name, ...?data});
  }

  // ─── Connect & Register ───────────────────────────────────────────────────

  Future<void> connect() async {
    final username = await AuthService.getSavedUsername();
    final password = await AuthService.getSavedPassword();

    if (username == null || password == null) {
      _log('ERROR: Missing credentials');
      return;
    }

    try {
      final settings = sip.UaSettings();
      settings.webSocketUrl = 'wss://$_origin:8089/ws';
      settings.uri = 'sip:${username.replaceAll('@', '-')}@$_origin:8089';
      settings.password = password;
      settings.authorizationUser = username.replaceAll('@', '-');
      settings.transportType = sip.TransportType.WS;
      settings.sessionTimers = true;
      settings.register_expires = 600;
      settings.register = true;
      settings.userAgent = 'Samvaad-Flutter';
      
      // ICE servers — STUN required for NAT traversal so WebRTC generates
      // server-reflexive (srflx) candidates that work across different networks.
      // Without this, only host (local IP) candidates are generated and
      // video/audio won't flow between mobile and IP phone on different NATs.
      settings.iceServers = [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun.cloudflare.com:3478'},
      ];
      _lastSettings = settings;
      await _helper.start(settings);
    } catch (e) {
      _log('start() exception: $e');
    }
  }

  // ─── SIP Callbacks ────────────────────────────────────────────────────────

  @override
  void registrationStateChanged(sip.RegistrationState state) {
    if (state.state == null) return;

    final stateStr = state.state.toString();
    _log('REGISTRATION STATE: $stateStr');

    switch (state.state) {
      case sip.RegistrationStateEnum.REGISTERED:
        _isRegistered = true;
        _isConnected = true;
        _log('SIP REGISTERED');
        _emit(SipEvent.registered);
        // Start persistent keep-alive service to keep SIP registered in background
        _startKeepAliveService();
        break;
      case sip.RegistrationStateEnum.UNREGISTERED:
        _isRegistered = false;
        _log('SIP UNREGISTERED');
        _stopKeepAliveService();
        break;
      case sip.RegistrationStateEnum.REGISTRATION_FAILED:
        _isRegistered = false;
        _log('SIP REGISTRATION FAILED');
        _emit(SipEvent.registrationFailed, data: {'cause': state.cause?.toString()});
        _stopKeepAliveService();
        break;
      case sip.RegistrationStateEnum.NONE:
        _isRegistered = false;
        break;
      default:
        break;
    }
  }

  @override
  void transportStateChanged(sip.TransportState state) {
    switch (state.state) {
      case sip.TransportStateEnum.CONNECTED:
        _isConnected = true;
        break;
      case sip.TransportStateEnum.DISCONNECTED:
        _isConnected = false;
        _isRegistered = false;
        _log('WS DISCONNECTED');
        _emit(SipEvent.connectionLost);
        // If disconnected during an active call, attempt immediate reconnect
        // sip_ua has exponential back-off reconnect built in, but also
        // trigger our own re-connect attempt after 1 second for faster recovery
        if (_callState != CallState.idle) {
          Future.delayed(const Duration(seconds: 1), () {
            if (!_isConnected && _lastSettings != null) {
              _log('Reconnecting after disconnect during call...');
              try { _helper.start(_lastSettings!); } catch (_) {}
            }
          });
        }
        break;
      default:
        break;
    }
  }

  @override
  void callStateChanged(sip.Call call, sip.CallState state) {
    _activeCall = call;
    switch (state.state) {
      case sip.CallStateEnum.CALL_INITIATION:
        _endingCall = false;
        if (call.direction == 'INCOMING') {
          if (_lastCallId == call.id) {
            _log('Duplicate INVITE — auto-reject');
            _autoRejectedCallId = call.id;
            call.hangup();
            FlutterCallkitIncoming.endAllCalls();
            break;
          }
          _lastCallId = call.id;
          final remoteNumber = call.remote_identity ?? 'Unknown';
          final cleanRemote = remoteNumber.replaceAll(RegExp(r'\D'), '');
          final cleanDialed = _dialedNumber.replaceAll(RegExp(r'\D'), '');

          final isAutoDial = _callState == CallState.dialing ||
              (cleanDialed.isNotEmpty &&
                  (cleanRemote.contains(cleanDialed) || cleanDialed.contains(cleanRemote)));

          if (isAutoDial) {
            _log('Auto-answer autodial call');
            _dialedNumber = '';
            _callState = CallState.onCall;
            _activeCall = call;
            call.answer({'audio': true, 'video': false});
            _emit(SipEvent.callAnswered);
          } else {
            _log('INCOMING from: $remoteNumber');
            _incomingNumber = remoteNumber;
            _callState = CallState.ringing;
            // Start foreground service NOW so the Dart VM stays alive
            // even if user is on lockscreen or switches apps
            CallLifecycleService().onCallStarted();
            // Auto-detect video in incoming SDP
            try {
              final sdp = call.session.request?.body as String? ?? '';
              _isVideo = sdp.contains('m=video');
              _log('Incoming call — video detected: $_isVideo');
            } catch (_) {
              _isVideo = false;
            }
            _emit(SipEvent.incomingCall, data: {'number': _incomingNumber, 'isVideo': _isVideo});
            if (_pendingAnswer) {
              _log('Pending answer — answering immediately (video=$_isVideo)');
              _pendingAnswer = false;
              answerCall(video: _isVideo);
            }
          }
        }
        break;

      case sip.CallStateEnum.PROGRESS:
        _log('PROGRESS');
        break;

      case sip.CallStateEnum.CONFIRMED:
        _log('CONFIRMED');
        _callState = CallState.onCall;
        _emit(SipEvent.callAnswered);
        // onCallStarted is idempotent — safe to call again even if already called at RINGING
        CallLifecycleService().onCallStarted();
        // After call confirmed, prefer H264 over VP8 on sender side
        _preferH264OnSender(call);
        // Munge local SDP to force H264 Constrained Baseline profile for Grandstream
        _mungeLocalSdpForH264(call);
        break;

      case sip.CallStateEnum.STREAM:
        _log('STREAM — originator: ${state.originator}');
        if (state.originator == 'remote' && state.stream != null) {
          _remoteStream = state.stream;
          final remoteTracks = state.stream!.getTracks();
          _log('REMOTE STREAM tracks: ${remoteTracks.map((t) => "${t.kind}:${t.id}").join(", ")}');
          // Ensure remote video track is enabled
          for (final track in remoteTracks) {
            if (track.kind == 'video' && !track.enabled) {
              track.enabled = true;
              _log('Enabled remote video track: ${track.id}');
            }
          }
          // Play remote audio for both voice and video calls
          try { playRemoteAudio(state.stream!); } catch (_) {}
          _emit(SipEvent.callAnswered, data: {'stream': 'remote'});
          _eventController.add({'event': 'streamUpdated'});
        } else if (state.originator == 'local' && state.stream != null) {
          _localStream = state.stream;
          final localTracks = state.stream!.getTracks();
          _log('LOCAL STREAM tracks: ${localTracks.map((t) => "${t.kind}:${t.id}").join(", ")}');
          // Ensure local video track is enabled
          for (final track in localTracks) {
            if (track.kind == 'video' && !track.enabled) {
              track.enabled = true;
              _log('Enabled local video track: ${track.id}');
            }
          }
          _eventController.add({'event': 'streamUpdated'});
        }
        break;

      case sip.CallStateEnum.FAILED:
        _log('FAILED: ${state.cause}');
        if (_autoRejectedCallId != null && call.id == _autoRejectedCallId) {
          _autoRejectedCallId = null;
          break;
        }
        _onCallEnded();
        _emit(SipEvent.callFailed, data: {'reason': state.cause?.toString() ?? 'unknown'});
        break;

      case sip.CallStateEnum.ENDED:
        _log('ENDED');
        if (_autoRejectedCallId != null && call.id == _autoRejectedCallId) {
          _autoRejectedCallId = null;
          break;
        }
        _onCallEnded();
        break;

      default:
        break;
    }
  }

  @override
  void onNewMessage(sip.SIPMessageRequest request) {}

  @override
  void onNewNotify(sip.Notify notify) {}

  @override
  void onNewReinvite(sip.ReInvite reinvite) {
    // Re-INVITE handling - codec preference already set in CONFIRMED
  }

  // ─── H264 codec preference ────────────────────────────────────────────────

  /// After CONFIRMED, reorder video codec so H264 is preferred over VP8.
  /// This affects the re-INVITE / subsequent negotiation so the IP phone
  /// (which only has H264) can receive our video stream.
  Future<void> _preferH264OnSender(sip.Call call) async {
    try {
      final pc = call.peerConnection;
      if (pc == null) return;
      final transceivers = await pc.getTransceivers();
      for (final transceiver in transceivers) {
        if (transceiver.sender.track?.kind != 'video') continue;
        // Get available codecs and keep ONLY H264
        final capabilities = await getRtpSenderCapabilities('video');
        final codecs = capabilities?.codecs ?? [];
        if (codecs.isEmpty) continue;
        // Filter: H264 ONLY, remove all other codecs (VP8, VP9, AV1, etc.)
        final h264Only = codecs.where((c) => (c.mimeType ?? '').toLowerCase().contains('h264')).toList();
        if (h264Only.isNotEmpty) {
          await transceiver.setCodecPreferences(h264Only);
          _log('Set H264 ONLY in codec preferences for video transceiver (removed ${codecs.length - h264Only.length} other codecs)');
        }
      }
    } catch (e) {
      _log('_preferH264OnSender failed (non-fatal): $e');
    }
  }

  /// Munge SDP to force H264 Constrained Baseline profile (42E01F) and packetization-mode=1
  /// Grandstream phones cannot decode High/Main profiles (640C1F, 640032, etc.)
  /// Also removes all non-H264 video codecs from SDP
  String _mungeSdpForH264(String sdp) {
    final lines = sdp.split('\r\n');
    final munged = <String>[];
    bool inVideoSection = false;
    for (var line in lines) {
      // Track video section
      if (line.startsWith('m=video')) {
        inVideoSection = true;
      } else if (line.startsWith('m=')) {
        inVideoSection = false;
      }

      // Remove non-H264 video codec lines from SDP
      if (inVideoSection && line.startsWith('a=rtpmap:') && !line.toLowerCase().contains('h264')) {
        _log('Removing non-H264 video codec from SDP: $line');
        continue;
      }

      // Remove non-H264 fmtp lines
      if (inVideoSection && line.startsWith('a=fmtp:') && !line.toLowerCase().contains('h264')) {
        _log('Removing non-H264 fmtp from SDP: $line');
        continue;
      }

      if (line.startsWith('a=fmtp:') && line.toLowerCase().contains('h264')) {
        // Replace profile-level-id with Constrained Baseline (42E01F)
        line = line.replaceAll(RegExp(r'profile-level-id=[0-9a-fA-F]{6}'), 'profile-level-id=42E01F');
        // Ensure packetization-mode=1
        if (!line.contains('packetization-mode')) {
          line = '$line;packetization-mode=1';
        } else {
          line = line.replaceAll(RegExp(r'packetization-mode=\d'), 'packetization-mode=1');
        }
        _log('Munged H264 fmtp: $line');
      }
      munged.add(line);
    }
    return munged.join('\r\n');
  }

  /// Apply SDP munging to the local description after CONFIRMED
  Future<void> _mungeLocalSdpForH264(sip.Call call) async {
    try {
      final pc = call.peerConnection;
      if (pc == null) return;
      final localDesc = await pc.getLocalDescription();
      if (localDesc == null) return;
      final originalSdp = localDesc.sdp;
      if (originalSdp == null) return;
      // Always attempt munging even if H264 not present (might be VP8 that needs removal)
      final mungedSdp = _mungeSdpForH264(originalSdp);
      if (mungedSdp != originalSdp) {
        await pc.setLocalDescription(RTCSessionDescription(mungedSdp, localDesc.type));
        _log('Applied H264 SDP munging to local description');
      }
    } catch (e) {
      _log('_mungeLocalSdpForH264 failed (non-fatal): $e');
    }
  }

  // ─── Call Ended (pure SIP — no agent APIs) ────────────────────────────────

  void _onCallEnded() {
    if (_endingCall) return;
    _endingCall = true;
    _callState = CallState.idle;
    _emit(SipEvent.callEnded);
    CallLifecycleService().onCallEnded();

    _incomingNumber = '';
    _dialedNumber = '';
    _isMuted = false;
    _isHeld = false;
    _remoteStream = null;
    _localStream = null;
    _activeCall = null;
    _pendingAnswer = false;
    _isVideo = false;

    try { removeRemoteAudio(); } catch (_) {}
    _endingCall = false;
  }

  // ─── Outgoing Call ────────────────────────────────────────────────────────

  void setDialedNumber(String number, {bool video = false}) {
    _dialedNumber = number;
    _isVideo = video;
    _callState = number.isNotEmpty ? CallState.dialing : CallState.idle;
  }

  /// Acquire a MediaStream with the correct codec preference.
  /// We request H264 explicitly so the SDP offer/answer includes H264,
  /// matching what Asterisk+IP phones expect (they have H264, not VP8).
  Future<MediaStream?> _acquireVideoStream() async {
    try {
      await Permission.microphone.request();
      await Permission.camera.request();
      // Request with H264 codec preference — on Android WebRTC this makes
      // H264 appear first in the SDP m=video line, beating VP8.
      // Use Constrained Baseline profile (42E01F) for Grandstream compatibility.
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
          'frameRate': {'ideal': 30},
          'facingMode': 'user',
          'optional': [
            {'googCpuOveruseDetection': false},
            // Force H264 with Constrained Baseline profile for Grandstream compatibility
            {'googLeakyBucket': true},
            {'googTemporalLayeredScreencast': false},
          ],
        },
      });
      // Ensure all video tracks are enabled
      for (final track in stream.getVideoTracks()) {
        track.enabled = true;
      }
      _log('MediaStream acquired: tracks=${stream.getTracks().map((t) => t.kind).join(",")} (video tracks enabled)');
      return stream;
    } catch (e) {
      _log('_acquireVideoStream failed: $e');
      return null;
    }
  }

  Map<String, dynamic> get _pcConfig => {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  Future<void> makeCall(String number, {bool video = false}) async {
    _dialedNumber = number;
    _isVideo = video;
    _callState = CallState.dialing;
    // Start foreground service immediately so WS stays alive if user
    // switches app before the call is answered
    CallLifecycleService().onCallStarted();
    final uri = 'sip:$number@$_origin:8089';
    _log('makeCall → $uri (video=$video)');
    try {
      Map<String, dynamic>? customOptions;
      if (video) {
        final stream = await _acquireVideoStream();
        customOptions = {
          'pcConfig': _pcConfig,
          if (stream != null) 'mediaStream': stream,
          if (stream == null) 'mediaConstraints': {
            'audio': true,
            'video': {'facingMode': 'user'},
          },
        };
      } else {
        customOptions = {'pcConfig': _pcConfig};
      }
      final call = await _helper.call(uri, voiceOnly: !video, customOptions: customOptions);
      // Immediately apply H264 preference and SDP munging to the call before SDP is sent
      if (video && call != null) {
        _log('Applying H264 preference to outgoing call before SDP exchange');
        await _preferH264OnSender(call);
        // Also munge the offer SDP to remove VP8
        await Future.delayed(const Duration(milliseconds: 100));
        await _mungeLocalSdpForH264(call);
      }
    } catch (e) {
      _log('makeCall failed: $e');
      _callState = CallState.idle;
    }
  }

  // ─── Answer Incoming ──────────────────────────────────────────────────────

  Future<void> answerCall({bool video = false}) async {
    _isVideo = video;
    final call = _activeCall;
    if (call != null) {
      if (_callState == CallState.onCall) {
        _log('Already on call — skip duplicate answer');
        return;
      }
      _log('Answering SIP call (video=$video)');
      // Request permissions first — getUserMedia fails with 480 if denied
      try {
        await Permission.microphone.request();
        if (video) await Permission.camera.request();
      } catch (_) {}
      try {
        Map<String, dynamic> options;
        if (video) {
          // Pre-acquire H264 stream so SDP answer advertises H264 (not VP8).
          // IP phones (3006) only speak H264 — Asterisk cannot transcode video.
          final stream = await _acquireVideoStream();
          options = {
            'pcConfig': _pcConfig,
            if (stream != null) 'mediaStream': stream,
            if (stream == null) 'mediaConstraints': {'audio': true, 'video': true},
          };
        } else {
          options = {
            'pcConfig': _pcConfig,
            'mediaConstraints': {'audio': true, 'video': false},
          };
        }
        _log('answer options keys: ${options.keys.toList()}');
        call.answer(options);
        // Apply H264-only codec preference and SDP munging immediately after answering
        _preferH264OnSender(call);
        await Future.delayed(const Duration(milliseconds: 500));
        _mungeLocalSdpForH264(call);
      } catch (e) {
        _log('answerCall failed: $e');
        return;
      }
      _callState = CallState.onCall;
      CallLifecycleService().onCallStarted();
    } else {
      _log('No active call yet — queuing answer (video=$video)');
      _pendingAnswer = true;
    }
  }

  Future<void> rejectCall() async {
    final call = _activeCall;
    if (call != null) {
      try { call.session.terminate(); } catch (e) { _log('reject failed: $e'); }
    }
    _onCallEnded();
    _emit(SipEvent.callFailed, data: {'reason': 'rejected'});
  }

  Future<void> endCall() async {
    final call = _activeCall;
    if (call != null) {
      try { call.session.terminate(); } catch (e) { _log('terminate failed: $e'); }
    }
    _onCallEnded();
  }

  // ─── Call Controls ────────────────────────────────────────────────────────

  void mute(bool muted) {
    if (muted == _isMuted) return;
    final call = _activeCall;
    if (call == null) return;
    try {
      muted ? call.mute(true, false) : call.unmute(true, false);
      _isMuted = muted;
    } catch (e) {
      _log('mute failed: $e');
    }
  }

  void toggleHold() {
    final call = _activeCall;
    if (call == null) return;
    try {
      if (_isHeld) {
        call.unhold();
      } else {
        call.hold();
      }
      _isHeld = !_isHeld;
    } catch (e) {
      _log('hold failed: $e');
    }
  }

  void sendDTMF(String tone) {
    try { _activeCall?.sendDTMF(tone); } catch (e) { _log('DTMF failed: $e'); }
  }

  // ─── Disconnect ───────────────────────────────────────────────────────────

  void disconnect() {
    _helper.stop();
    _isConnected = false;
    _isRegistered = false;
    _callState = CallState.idle;
    _stopKeepAliveService();
  }

  // ─── Keep-Alive Service ─────────────────────────────────────────────────────

  void _startKeepAliveService() {
    // Keep-Alive disabled to save battery. Relying on FCM/PushKit to wake up instead.
    _log('SIP Keep-Alive disabled (battery optimization)');
  }

  void _stopKeepAliveService() {
    // Keep-Alive disabled to save battery.
  }

  void dispose() {
    disconnect();
    _eventController.close();
  }
}
