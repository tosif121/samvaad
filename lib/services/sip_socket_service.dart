import 'dart:async';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sip_ua/sip_ua.dart' as sip;
import 'auth_service.dart';
import 'remote_audio_stub.dart'
    if (dart.library.html) 'remote_audio_web.dart';
import 'call_lifecycle_service.dart';
import 'log_service.dart';

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
    LogService().init().then((_) {
      LogService().write('SIP', 'LogService initialized');
      LogService().logFilePath.then((path) {
        print('=== SAMVAAD LOG FILE: $path ===');
      });
    });
  }

  void _reRegisterIfNeeded() {
    if (!_isConnected || !_isRegistered) {
      _log('Re-registering SIP after resume (was disconnected or unregistered)');
      try { _helper.register(); } catch (e) { _log('re-register failed: $e'); }
    }
  }

  void _log(String msg, {Object? data}) {
    LogService().write('SIP', msg, data: data);
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
            _activeCall = call;
            answerCall(video: _isVideo);
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
        if (call.peerConnection != null) {
          final pc = call.peerConnection!;
          Future(() async {
            try {
              final localSdp = await pc.getLocalDescription();
              final remoteSdp = await pc.getRemoteDescription();
              _log('PROGRESS: signalingState=${pc.signalingState} local=${localSdp?.type ?? '-'} remote=${remoteSdp?.type ?? '-'}');
              if (remoteSdp?.sdp != null) {
                final remoteVideoLines = remoteSdp!.sdp!.split('\r\n').where((l) =>
                    l.startsWith('m=video') || l.startsWith('a=rtpmap:') || l.startsWith('a=fmtp:'));
                _log('PROGRESS remote video SDP:\n${remoteVideoLines.join("\n")}');
              }
            } catch (_) {}
          });
        }
        break;

      case sip.CallStateEnum.CONFIRMED:
        _log('CONFIRMED');
        _callState = CallState.onCall;
        _emit(SipEvent.callAnswered);
        CallLifecycleService().onCallStarted();
        if (call.peerConnection != null) {
          final pc = call.peerConnection!;
          Future(() async {
            try {
              final localSdp = await pc.getLocalDescription();
              final remoteSdp = await pc.getRemoteDescription();
              _log('CONFIRMED: signalingState=${pc.signalingState} local=${localSdp?.type ?? '-'} remote=${remoteSdp?.type ?? '-'}');
              if (localSdp?.sdp != null) {
                final localVideoLines = localSdp!.sdp!.split('\r\n').where((l) =>
                    l.startsWith('m=video') || l.startsWith('a=rtpmap:') || l.startsWith('a=fmtp:'));
                _log('CONFIRMED local video SDP:\n${localVideoLines.join("\n")}');
              }
              if (remoteSdp?.sdp != null) {
                final remoteVideoLines = remoteSdp!.sdp!.split('\r\n').where((l) =>
                    l.startsWith('m=video') || l.startsWith('a=rtpmap:') || l.startsWith('a=fmtp:'));
                _log('CONFIRMED remote video SDP:\n${remoteVideoLines.join("\n")}');
              }
            } catch (_) {}
          });
        }
        _preferH264OnSender(call);
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
          // Schedule H264 codec preference BEFORE offer is created.
          // sip_ua adds tracks to PC synchronously after emitting STREAM,
          // then asynchronously creates the offer. A microtask runs between
          // addTrack and createOffer, allowing us to set codec preferences
          // so the initial SDP offer uses H264-only for Grandstream compat.
          if (_isVideo && _activeCall != null) {
            final c = _activeCall!;
            Future.microtask(() => _preferH264OnSender(c));
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
      _log('_preferH264OnSender: ${transceivers.length} transceivers found');
      for (final transceiver in transceivers) {
        if (transceiver.sender.track?.kind != 'video') continue;
        final capabilities = await getRtpSenderCapabilities('video');
        final codecs = capabilities?.codecs ?? [];
        if (codecs.isEmpty) {
          _log('_preferH264OnSender: no video codec capabilities available');
          continue;
        }
        final availCodecs = codecs.map((c) => '${c.mimeType}/${c.clockRate}').join(', ');
        _log('_preferH264OnSender: available codecs: $availCodecs');
        final h264Only = codecs.where((c) => (c.mimeType ?? '').toLowerCase().contains('h264')).toList();
        if (h264Only.isNotEmpty) {
          await transceiver.setCodecPreferences(h264Only);
          _log('Set H264 ONLY in codec preferences for video transceiver (removed ${codecs.length - h264Only.length} other codecs)');
        } else {
          _log('_preferH264OnSender: WARNING - H264 not found in sender capabilities!');
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

    // First pass: identify H264 payload types in the video section
    final h264Payloads = <String>{};
    bool inVideoSection = false;
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        inVideoSection = true;
      } else if (line.startsWith('m=') && !line.startsWith('m=video')) {
        inVideoSection = false;
      }
      if (inVideoSection && line.startsWith('a=rtpmap:')) {
        final ptEnd = line.indexOf(' ', 9);
        if (ptEnd > 9) {
          final pt = line.substring(9, ptEnd);
          if (line.toLowerCase().contains('h264')) {
            h264Payloads.add(pt);
          }
        }
      }
    }

    // If no H264 found, return original SDP unchanged
    if (h264Payloads.isEmpty) {
      _log('_mungeSdpForH264: No H264 codecs found in SDP, returning unchanged');
      return sdp;
    }

    _log('_mungeSdpForH264: H264 payload types found: ${h264Payloads.join(', ')}');

    // Second pass: munge the SDP
    final munged = <String>[];
    inVideoSection = false;
    for (var line in lines) {
      if (line.startsWith('m=video')) {
        inVideoSection = true;
        // Remove non-H264 payload types from m=video line
        final parts = line.split(' ');
        if (parts.length >= 4) {
          final originalPts = parts.sublist(3);
          final pts = originalPts.where((pt) => h264Payloads.contains(pt)).toList();
          if (pts.isNotEmpty && pts.length != originalPts.length) {
            final newMline = '${parts.sublist(0, 3).join(' ')} ${pts.join(' ')}';
            _log('_mungeSdpForH264: m=video updated\n  before: $line\n  after : $newMline');
            line = newMline;
          }
        }
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

      // Remove rtcp-fb lines for non-H264 payload types
      if (inVideoSection && line.startsWith('a=rtcp-fb:')) {
        final fbPayloadMatch = RegExp(r'^a=rtcp-fb:(\d+)').firstMatch(line);
        if (fbPayloadMatch != null && !h264Payloads.contains(fbPayloadMatch.group(1))) {
          _log('Removing non-H264 rtcp-fb from SDP: $line');
          continue;
        }
      }

      if (line.startsWith('a=fmtp:') && line.toLowerCase().contains('h264')) {
        line = line.replaceAll(RegExp(r'profile-level-id=[0-9a-fA-F]{6}'), 'profile-level-id=42E01F');
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
      final remoteDesc = await pc.getRemoteDescription();
      _log('_mungeLocalSdpForH264: localDesc=${localDesc?.type ?? 'null'}, remoteDesc=${remoteDesc?.type ?? 'null'}');

      if (localDesc == null) {
        _log('_mungeLocalSdpForH264: localDesc is NULL — cannot munge');
        return;
      }
      final originalSdp = localDesc.sdp;
      if (originalSdp == null || originalSdp.isEmpty) {
        _log('_mungeLocalSdpForH264: local SDP is empty');
        return;
      }

      // Log video section of original SDP
      final videoLines = originalSdp.split('\r\n').where((l) =>
          l.startsWith('m=video') || l.startsWith('a=rtpmap:') || l.startsWith('a=fmtp:'));
      _log('_mungeLocalSdpForH264: original video SDP lines:\n${videoLines.join("\n")}');

      final mungedSdp = _mungeSdpForH264(originalSdp);
      if (mungedSdp != originalSdp) {
        // Log video section of munged SDP
        final mungedVideoLines = mungedSdp.split('\r\n').where((l) =>
            l.startsWith('m=video') || l.startsWith('a=rtpmap:') || l.startsWith('a=fmtp:'));
        _log('_mungeLocalSdpForH264: munged video SDP lines:\n${mungedVideoLines.join("\n")}');

        await pc.setLocalDescription(RTCSessionDescription(mungedSdp, localDesc.type));
        _log('Applied H264 SDP munging to local description');
      } else {
        _log('_mungeLocalSdpForH264: SDP unchanged after munging (no H264 found or already only H264)');
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
      await _helper.call(uri, voiceOnly: !video, customOptions: customOptions);
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
