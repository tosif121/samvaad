import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:sip_ua/sip_ua.dart' as sip;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/sip_credentials.dart';
import '../models/call_log_entry.dart';
import 'remote_audio_stub.dart' if (dart.library.html) 'remote_audio_web.dart';
import 'call_lifecycle_service.dart';
import 'fcm_service.dart';
import 'toast_service.dart';
import 'user_data.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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
  streamAdded,
  queueUpdated,
  agentStatusChanged,
  missedCallsUpdated,
  followUpsUpdated,
  recentCallsUpdated,
  messageReceived,
}

class SipSocketService implements sip.SipUaHelperListener {
  static final SipSocketService _instance = SipSocketService._internal();
  factory SipSocketService() => _instance;
  static SipSocketService get instance => _instance;

  final sip.SIPUAHelper _helper = sip.SIPUAHelper();

  // Native <-> Dart bridge used by ConnectionService (Android) / CallKit
  // (iOS) so a push-triggered native call UI can be shown before SIP
  // registration completes, then bound to the real SIP call once it lands.
  static const MethodChannel _platform = MethodChannel('sip_native_bridge');

  CallState _callState = CallState.idle;
  sip.Call? _activeCall;
  String _incomingNumber = '';
  bool _isRegistered = false;
  bool _isConnected = false;
  bool _isMuted = false;
  bool isVideoCall = false;
  bool _isLocalVideoMuted = false;
  bool _isSpeakerOn = false;
  bool _isHeld = false;
  dynamic _localStream;
  dynamic _remoteStream;

  int _queueCount = 0;
  List<dynamic> _currentCallqueue = [];
  String _agentStatus = '';
  String _lastQueueCallers = '';
  String _lastFollowUpsJson = '';
  String _bridgeID = '';
  String _incomingChannelId = '';

  bool _agentAvailableInFlight = false;
  DateTime _agentAvailableLastCalled = DateTime.fromMillisecondsSinceEpoch(0);

  List<dynamic> _missedCalls = [];
  List<dynamic> _followUps = [];
  List<dynamic> _breakOptions = [];
  List<CallLogEntry> _recentCalls = [];

  int get queueCount => _queueCount;
  List<dynamic> get currentCallqueue => _currentCallqueue;
  String get agentStatus => _agentStatus;
  String get bridgeID => _bridgeID;
  String get incomingChannelId => _incomingChannelId;
  List<dynamic> get missedCalls => _missedCalls;
  List<dynamic> get followUps => _followUps;
  List<dynamic> get breakOptions => _breakOptions;
  List<CallLogEntry> get recentCalls => _recentCalls;

  bool _connecting = false;
  bool _wasStarted = false;

  // Auto-reconnect state: re-registers when the SIP WebSocket drops or gets
  // stuck in CONNECTING, unless the disconnect was intentional (logout/401).
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _intentionalDisconnect = false;
  bool _reconnectEnabled = true;

  // Guards _finishCall against being invoked twice for the same call
  // (e.g. once from callStateChanged's ENDED/FAILED branch and once from
  // an explicit endCall()/rejectCall() racing with it).
  bool _callEndedHandled = false;
  bool _isAnswering = false;
  bool shouldAutoAnswerNextCall = false;

  // Set when a call arrives via FCM/VoIP push before the real SIP INVITE
  // has been received. Used to bind the native call UI (already showing)
  // to the SIP call once it confirms, and to route native answer/reject/
  // end actions back into the SIP session.
  String? _pendingPushCallId;

  SipCredentials? _credentials;

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  SipCredentials? get credentials => _credentials;
  bool get hasCredentials => _credentials != null;

  CallState get callState => _callState;
  String get incomingNumber => _incomingNumber;
  bool get isRegistered => _isRegistered;
  bool get isConnected => _isConnected;
  // bool get isVideoCall => _isVideoCall;
  bool get isLocalVideoMuted => _isLocalVideoMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isHeld => _isHeld;
  dynamic get localStream => _localStream;
  String? get activeCallId => _activeCall?.id;

  SipSocketService._internal() {
    _helper.addSipUaHelperListener(this);
    _platform.setMethodCallHandler(_handleNativeMethodCall);
  }

  void _log(String msg, {Object? data}) {
    final ts = DateTime.now().toIso8601String();
    final log = data != null
        ? '[$ts] [SIP_SOCKET] $msg | $data'
        : '[$ts] [SIP_SOCKET] $msg';
    developer.log(log, name: 'Samvaad');
    debugPrint(log);
  }

  void _emit(SipEvent event, {Map<String, dynamic>? data}) {
    if (_eventController.isClosed) {
      _log('Dropped event (controller closed): ${event.name}', data: data);
      return;
    }
    _log('Emitting event: ${event.name}', data: data);
    _eventController.add({'event': event.name, ...?data});
  }

  // ---------------------------------------------------------------------
  // Native bridge (ConnectionService / CallKit)
  // ---------------------------------------------------------------------

  /// Invokes a method on the native side. Failures are logged, never
  /// thrown, since native call-UI sync is best-effort and must not break
  /// SIP call flow if the channel isn't attached (e.g. on web/desktop).
  Future<void> _notifyNative(String method, Map<String, dynamic> args) async {
    try {
      await _platform.invokeMethod(method, args);
    } catch (e) {
      _log('Native bridge call failed: $method', data: e.toString());
    }
  }

  /// Handles calls initiated FROM native (user tapped Answer/Reject/End on
  /// the OS-level incoming call UI, or a headless push handler).
  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    _log('Native method call received: ${call.method}', data: call.arguments);
    switch (call.method) {
      case 'nativeAnswerCall':
        await answerCall();
        break;
      case 'nativeEndCall':
        await endCall();
        break;
      case 'nativeRejectCall':
        await rejectCall();
        break;
      case 'handleIncomingPush':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        await fastReconnectAndRegister(
          callId: args['call_id'] as String? ?? '',
          callerNumber: args['caller_number'] as String?,
        );
        break;
      default:
        _log('Unhandled native method: ${call.method}');
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Connection lifecycle
  // ---------------------------------------------------------------------

  Future<void> connect([SipCredentials? creds]) async {
    // Guard against duplicate connect() calls racing each other — e.g. a
    // normal app-start connect() overlapping with an FCM-triggered
    // fastReconnectAndRegister(). Without the _isRegistered check here,
    // a second call would call _helper.stop() on an already-registered
    // UA and tear the transport down seconds after it registered.
    if (_isRegistered) {
      _log(
        'connect() ignored — already registered',
        data: StackTrace.current.toString(),
      );
      return;
    }
    if (_connecting) {
      _log(
        'connect() ignored — already connecting',
        data: StackTrace.current.toString(),
      );
      return;
    }

    // A manual connect (fresh login / fastReconnect) re-enables auto-reconnect
    // and cancels any pending reconnect timer.
    _intentionalDisconnect = false;
    _reconnectEnabled = true;
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();

    creds ??= _credentials;
    if (creds == null) {
      _log('No credentials provided');
      return;
    }
    _credentials = creds;

    _connecting = true;

    if (_wasStarted) {
      _log('Stopping previous UA before reconnect');
      _helper.stop();
      _isConnected = false;
      _isRegistered = false;
      _callState = CallState.idle;
      _activeCall = null;
      await Future.delayed(const Duration(milliseconds: 2600));
    }

    _log('connect() called', data: StackTrace.current.toString());

    try {
      sip.UaSettings settings = sip.UaSettings();

      settings.webSocketUrl = creds.serverUrl;
      settings.uri = creds.sipUri;
      settings.authorizationUser = creds.username;
      settings.password = creds.password;
      settings.displayName = creds.displayName;
      settings.transportType = sip.TransportType.WS;
      settings.register = true;
      settings.sessionTimers = false;

      if (_wasStarted) {
        try {
          _helper.stop();
        } catch (_) {}
      }

      await _helper.start(settings);
      _wasStarted = true;

      _log("Connecting to SIP...");
    } catch (e) {
      _log("SIP Start Error", data: e);
    } finally {
      _connecting = false;
    }
  }

  /// Lightweight reconnect path used when the app is woken by an FCM/VoIP
  /// push for an incoming call. Skips anything not required to get
  /// registered and receive the pending INVITE as fast as possible.
  ///
  /// [callId] correlates this push to the native call UI already shown by
  /// ConnectionService/CallKit, so the SIP call can be bound to it once
  /// CALL_INITIATION fires, and native answer/reject/end actions can be
  /// routed to the right SIP session.
  Future<void> fastReconnectAndRegister({
    required String callId,
    String? callerNumber,
  }) async {
    _pendingPushCallId = callId.isNotEmpty ? callId : null;

    if (_isRegistered) {
      _log('fastReconnectAndRegister: already registered, nothing to do');
      return;
    }

    if (_credentials == null) {
      await loadCredentials();
    }
    if (_credentials == null) {
      _log('fastReconnectAndRegister: no credentials, cannot register');
      return;
    }

    await connect(_credentials);
  }

  void setCredentials(SipCredentials creds) {
    _credentials = creds;
  }

  Future<void> loadCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('sip_credentials');
    if (json != null) {
      try {
        _credentials = SipCredentials.fromJson(
          Map<String, dynamic>.from(const JsonDecoder().convert(json) as Map),
        );
      } catch (_) {}
    }
    await _loadBreakOptions();
  }

  /// Loads the agent's configurable break options from the login token
  /// payload (`userData.breakoptions`) like the webphone does.
  Future<void> _loadBreakOptions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tokenStr = prefs.getString('token');
      if (tokenStr != null && tokenStr.isNotEmpty) {
        final decoded = jsonDecode(tokenStr);
        if (decoded is Map) {
          final userData = decoded['userData'];
          if (userData is Map) {
            final options = userData['breakoptions'];
            if (options is List && options.isNotEmpty) {
              _breakOptions = options;
            }
          }
        }
      }
    } catch (e) {
      _log('Error loading break options: $e');
    }
  }

  Future<void> saveCredentials(SipCredentials creds) async {
    _credentials = creds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'sip_credentials',
      const JsonEncoder().convert(creds.toJson()),
    );
  }

  Future<void> clearCredentials() async {
    _credentials = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('sip_credentials');
  }

  // ---------------------------------------------------------------------
  // sip_ua listener callbacks
  // ---------------------------------------------------------------------

  @override
  void registrationStateChanged(sip.RegistrationState state) {
    _log("Registration State : ${state.state}");
    _log("Cause : ${state.cause}");
    if (state.state == null) return;
    switch (state.state!) {
      case sip.RegistrationStateEnum.NONE:
        _isRegistered = false;
        break;
      case sip.RegistrationStateEnum.REGISTERED:
        _isRegistered = true;
        _log('SIP REGISTERED');
        _emit(SipEvent.registered);
        unawaited(sendUserReady());
        unawaited(FcmService().sendTokenToBackend());
        _startHeartbeatTimer();
        unawaited(fetchMissedCalls());
        unawaited(fetchRecentCalls());
        break;
      case sip.RegistrationStateEnum.UNREGISTERED:
        _log('SIP UNREGISTERED');
        _isRegistered = false;
        _stopHeartbeatTimer();
        break;
      case sip.RegistrationStateEnum.REGISTRATION_FAILED:
        _log('SIP REGISTRATION FAILED');
        _isRegistered = false;
        _stopHeartbeatTimer();
        _emit(
          SipEvent.registrationFailed,
          data: {'cause': state.cause?.toString()},
        );
        break;
    }
  }

  @override
  void transportStateChanged(sip.TransportState state) {
    _log("Transport State : ${state.state}");
    switch (state.state) {
      case sip.TransportStateEnum.NONE:
        break;
      case sip.TransportStateEnum.CONNECTING:
        // If the socket spends too long stuck mid-connect, force a retry.
        _scheduleConnectingWatchdog();
        break;
      case sip.TransportStateEnum.CONNECTED:
        _reconnectTimer?.cancel();
        _reconnectAttempt = 0;
        final wasDisconnected = !_isConnected;
        _isConnected = true;
        if (wasDisconnected) {
          _emit(SipEvent.connectionRestored);
        }
        break;
      case sip.TransportStateEnum.DISCONNECTED:
        _log('WebSocket DISCONNECTED', data: StackTrace.current.toString());
        _reconnectTimer?.cancel();
        final wasConnected = _isConnected;
        _isConnected = false;
        _isRegistered = false;
        if (wasConnected) {
          _emit(SipEvent.connectionLost);
        }
        _scheduleReconnect();
        break;
    }
  }

  /// Schedules an automatic re-registration after a SIP disconnection, with
  /// exponential-ish backoff so flapping sockets don't hammer the server.
  /// Skipped when the disconnect was intentional (logout / 401 / shutdown).
  void _scheduleReconnect() {
    if (_intentionalDisconnect || !_reconnectEnabled) {
      _log('Auto-reconnect skipped (intentional disconnect)');
      return;
    }
    _reconnectTimer?.cancel();
    const backoffs = [3, 5, 10, 15, 30];
    final idx = _reconnectAttempt > 4 ? 4 : _reconnectAttempt;
    _reconnectAttempt++;
    _log('Scheduling auto-reconnect in ${backoffs[idx]}s (attempt $_reconnectAttempt)...');
    _reconnectTimer = Timer(
      Duration(seconds: backoffs[idx]),
      _performReconnect,
    );
  }

  /// Flips the transport back on when it stays in CONNECTING for 15s.
  void _scheduleConnectingWatchdog() {
    if (_intentionalDisconnect || !_reconnectEnabled) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 15), _performReconnect);
  }

  Future<void> _performReconnect() async {
    if (_intentionalDisconnect || !_reconnectEnabled) return;
    if (_isRegistered || _isConnected) {
      _reconnectAttempt = 0;
      return;
    }
    final creds = _credentials;
    if (creds == null) return;
    _log('Performing auto-reconnect...');
    await connect(creds);
  }

  @override
  void callStateChanged(sip.Call call, sip.CallState state) {
    _log(
      'callStateChanged: ${state.state} for call ID: ${call.id}'
      ' | direction=${call.direction} | sessionState=${call.session.state}',
    );
    if (state.state == sip.CallStateEnum.CALL_INITIATION ||
        _activeCall == null) {
      _activeCall = call;
    }

    if (_activeCall != null && _activeCall!.id != call.id) {
      _log('Ignoring state ${state.state} for non-active call ${call.id}');
      return;
    }

    switch (state.state) {
      case sip.CallStateEnum.CALL_INITIATION:
        _callEndedHandled = false;
        if (call.direction == sip.Direction.incoming) {
          final remoteNumber = call.remote_identity ?? 'Unknown';
          _log('INCOMING CALL from: $remoteNumber');
          _incomingNumber = remoteNumber;
          _callState = CallState.ringing;
          isVideoCall = call.remote_has_video;
          try {
            final sdp = call.session.request?.body as String? ?? '';
            if (sdp.contains('m=video')) {
              isVideoCall = true;
            }
          } catch (_) {}
          _log('Incoming call — video detected: $isVideoCall');
          _emit(SipEvent.incomingCall, data: {'number': _incomingNumber});

          // If this call arrived after a push already showed a native
          // call UI, bind to it instead of leaving it unmatched. If no
          // push preceded this (foreground call), _pendingPushCallId is
          // null and this is a no-op on the native side.
          _notifyNative('bindIncomingCall', {
            'callId': _pendingPushCallId ?? '',
            'number': remoteNumber,
          });
        }
        break;

      case sip.CallStateEnum.PROGRESS:
        _log('Call PROGRESS');
        if (call.peerConnection != null) {
          Future(() async {
            try {
              final remoteSdp = await call.peerConnection!
                  .getRemoteDescription();
              if (remoteSdp?.sdp != null) {
                final mediaLines = remoteSdp!.sdp!
                    .split('\r\n')
                    .where(
                      (l) =>
                          l.startsWith('m=') ||
                          l.startsWith('a=rtpmap:') ||
                          l.startsWith('a=fmtp:'),
                    );
                _log('PROGRESS REMOTE CODECS:\n${mediaLines.join("\n")}');
              }
            } catch (_) {}
          });
        }
        break;

      case sip.CallStateEnum.CONFIRMED:
        _log('Call CONFIRMED');
        _callState = CallState.onCall;
        _emit(SipEvent.callAnswered);
        CallLifecycleService().onCallStarted();
        _notifyNative('callActive', {'callId': _pendingPushCallId ?? ''});
        unawaited(
          Helper.setSpeakerphoneOn(isVideoCall)
              .then((_) {
                _isSpeakerOn = isVideoCall;
              })
              .catchError((_) {}),
        );

        if (call.peerConnection != null) {
          Future(() async {
            try {
              final remoteSdp = await call.peerConnection!
                  .getRemoteDescription();
              if (remoteSdp?.sdp != null) {
                final mediaLines = remoteSdp!.sdp!
                    .split('\r\n')
                    .where(
                      (l) =>
                          l.startsWith('m=') ||
                          l.startsWith('a=rtpmap:') ||
                          l.startsWith('a=fmtp:'),
                    );
                _log('CONFIRMED REMOTE CODECS:\n${mediaLines.join("\n")}');
              }
            } catch (_) {}
          });
        }
        if (isVideoCall &&
            _activeCall != null &&
            _activeCall!.direction == sip.Direction.outgoing) {
          _log('Adding video via re-INVITE');
          try {
            final videoOptions = _helper.buildCallOptions(false);
            videoOptions['mediaConstraints'] = <String, dynamic>{
              'audio': true,
              'video': <String, dynamic>{
                'mandatory': <String, dynamic>{
                  'minWidth': '640',
                  'minHeight': '480',
                  'minFrameRate': '30',
                },
                'facingMode': 'user',
                'optional': <dynamic>[],
              },
            };
            if (videoOptions['rtcOfferConstraints'] is Map) {
              (videoOptions['rtcOfferConstraints'] as Map)['offerModifiers'] = [
                _makeH264Modifier(),
              ];
            }
            if (videoOptions['rtcAnswerConstraints'] is Map) {
              (videoOptions['rtcAnswerConstraints'] as Map)['offerModifiers'] =
                  [_makeH264Modifier()];
            }
            _activeCall!.renegotiate(options: videoOptions, useUpdate: false);
            _log('re-INVITE sent for video');
          } catch (e) {
            _log('re-INVITE failed: $e');
          }
        }
        break;

      case sip.CallStateEnum.STREAM:
        if (state.originator == sip.Originator.local && state.stream != null) {
          _localStream = state.stream;
        }
        if (state.originator == sip.Originator.remote && state.stream != null) {
          _remoteStream = state.stream;
          _playRemoteAudio(state.stream!);
        }
        _emit(SipEvent.streamAdded);
        break;

      case sip.CallStateEnum.FAILED:
        _log(
          'Call FAILED',
          data: {
            'cause': state.cause?.toString(),
            'originator': state.originator?.toString(),
          },
        );
        // Single source of truth: a FAILED call is reported as callFailed,
        // never as callEnded too.
        _finishCall(emitFailedReason: state.cause?.toString() ?? 'unknown');
        break;

      case sip.CallStateEnum.ENDED:
        _log('Call ENDED');
        _finishCall();
        break;

      default:
        break;
    }
  }

  @override
  void onNewMessage(sip.SIPMessageRequest request) {
    final body = request.request.body ?? '';
    _log('Received SIP MESSAGE: $body');
    _handleAriMessage(body);
  }

  /// Parses ARI MESSAGE events from Asterisk, matching the webphone's
  /// newMessage handler. Conference/merge events are surfaced to the UI
  /// via [SipEvent.messageReceived].
  void _handleAriMessage(String body) {
    if (body.contains('customer channel answered') ||
        body.contains('agent channel answered')) {
      _log('Customer/Agent channel ANSWERED');
      if (_callState != CallState.onCall) {
        _callState = CallState.onCall;
        _emit(SipEvent.callAnswered, data: {'message': body});
      }
    } else if (body.contains('customer channel disconnected')) {
      _log('Customer channel DISCONNECTED');
      _finishCall();
    } else if (body.contains('force_login_request') ||
        body.contains('Force Login Request')) {
      _log('Force login request received');
      _emit(SipEvent.connectionLost, data: {'reason': 'force_login'});
    } else if (body.contains('customer host channel connected')) {
      _log('Conference participant CONNECTED');
      _emit(SipEvent.messageReceived, data: {'message': body});
    } else if (body.contains('customer host channel diconnected') ||
        body.contains('customer host channel disconnected')) {
      _log('Conference participant DISCONNECTED');
      _emit(SipEvent.messageReceived, data: {'message': body});
    }
  }

  @override
  void onNewNotify(sip.Notify notify) {
    // Re-INVITE/NOTIFY-driven features (e.g. call transfer progress) are
    // not currently supported; intentionally unhandled.
  }

  @override
  void onNewReinvite(sip.ReInvite reinvite) {
    _log('Re-INVITE received — auto-handled by sip_ua');
  }

  // ---------------------------------------------------------------------
  // Call teardown
  // ---------------------------------------------------------------------

  /// Cleans up local state after a call ends, exactly once per call.
  ///
  /// If [emitFailedReason] is provided, a single SipEvent.callFailed is
  /// emitted with that reason. Otherwise a single SipEvent.callEnded is
  /// emitted. Callers should never emit their own callEnded/callFailed
  /// event after calling this — this is the only place that does so, to
  /// avoid emitting both events for the same call.
  void _finishCall({String? emitFailedReason}) {
    if (_callEndedHandled) return;
    _callEndedHandled = true;
    _isAnswering = false;

    _callState = CallState.idle;

    if (emitFailedReason != null) {
      _emit(SipEvent.callFailed, data: {'reason': emitFailedReason});
    } else {
      _emit(SipEvent.callEnded);
    }

    CallLifecycleService().onCallEnded();
    _notifyNative('callEnded', {'callId': _pendingPushCallId ?? ''});

    _incomingNumber = '';
    _incomingChannelId = '';
    _isMuted = false;
    _isLocalVideoMuted = false;
    _isSpeakerOn = false;
    _isHeld = false;
    _bridgeID = '';
    _remoteStream = null;
    _activeCall = null;
    _pendingPushCallId = null;
    removeRemoteAudio();
  }

  void _playRemoteAudio(dynamic stream) {
    try {
      playRemoteAudio(stream);
    } catch (e) {
      _log('Failed to play remote audio', data: {'error': e.toString()});
    }
  }

  // ---------------------------------------------------------------------
  // Public call controls
  // ---------------------------------------------------------------------

  Future<void> endCall() async {
    final call = _activeCall;
    if (call != null) {
      try {
        if (call.state != sip.CallStateEnum.ENDED) {
          call.session.terminate();
        }
      } catch (e) {
        _log('Exception during session.terminate: $e');
      }
    }
    _finishCall();
  }

  // set isVideoCall(bool value) => _isVideoCall = value;

  Future<void> answerCall({bool? isVideo}) async {
    final call = _activeCall;
    if (call == null) {
      _log('answerCall called with no active call — ignoring');
      return;
    }
    if (_isAnswering ||
        _callState == CallState.onCall ||
        call.state == sip.CallStateEnum.CONFIRMED) {
      _log(
        'Already answering or on call — skipping duplicate answer. state: ${call.state}',
      );
      return;
    }

    if (isVideo != null) isVideoCall = isVideo;

    _isAnswering = true;
    _log('Answering SIP call (Attempt started) - Call ID: ${call.id}');

    // [H264 MUNGING - INCOMING CALL]
    // Android WebRTC often rejects Grandstream's H264 profile (e.g. 42801F).
    // If it rejects it, Flutter's Answer SDP drops the video stream (m=video 0).
    // We rewrite the incoming Remote SDP string to 42e01f BEFORE dart-sip-ua parses it.
    try {
      if (call.session.request?.body != null) {
        String remoteSdp = call.session.request!.body as String;
        if (remoteSdp.contains('m=video') && remoteSdp.contains('H264')) {
          String newSdp = remoteSdp.replaceAllMapped(
            RegExp(r'profile-level-id=[0-9a-fA-F]+'),
            (_) => 'profile-level-id=42e01f',
          );
          if (newSdp != remoteSdp) {
            call.session.request!.body = newSdp;
            _log(
              'Munged incoming REMOTE SDP: changed profile-level-id to 42e01f so WebRTC accepts it',
            );
          }
        }
      }
    } catch (e) {
      _log('Failed to munge incoming SDP: $e');
    }

    try {
      final options = _helper.buildCallOptions(!isVideoCall);
      if (options['rtcOfferConstraints'] is Map) {
        (options['rtcOfferConstraints'] as Map)['offerModifiers'] = [
          _makeH264Modifier(),
        ];
      }
      _log('Before call.answer() - options: $options');
      call.answer(options);
      _log(
        'After call.answer() - success'
        ' | sessionState=${call.session.state} | call.state=${call.state}',
      );
      _isAnswering = false;
    } catch (e) {
      _log('answerCall failed: $e');
      _emit(SipEvent.callFailed, data: {'reason': 'answer_failed'});
      _isAnswering = false;
      return;
    }
    CallLifecycleService().onCallStarted();
  }

  Future<void> makeCall(String number) async {
    if (!_isRegistered) {
      _log('SIP not registered — attempting to connect before makeCall...');
      await connect();
      if (!_isRegistered) {
        _log('Cannot call — SIP registration failed');
        _emit(SipEvent.callFailed, data: {'reason': 'not_registered'});
        return;
      }
    }
    _log('Making outgoing call to: $number');
    _callState = CallState.dialing;
    _incomingNumber = number;
    isVideoCall = false;
    try {
      await _helper.call(number, voiceOnly: true);
    } catch (e) {
      _log('makeCall failed: $e');
      _finishCall(emitFailedReason: e.toString());
    }
  }

  Future<void> makeVideoCall(String number) async {
    if (!_isRegistered) {
      _log('Cannot call — not registered');
      _emit(SipEvent.callFailed, data: {'reason': 'not_registered'});
      return;
    }
    _log('Making outgoing video call to: $number');
    _callState = CallState.dialing;
    _incomingNumber = number;
    isVideoCall = true;
    try {
      await _helper.call(
        number,
        voiceOnly: false,
        customOptions: <String, dynamic>{
          'rtcOfferConstraints': <String, dynamic>{
            'mandatory': <String, dynamic>{
              'OfferToReceiveAudio': true,
              'OfferToReceiveVideo': true,
            },
            'offerModifiers': [_makeH264Modifier()],
          },
        },
      );
    } catch (e) {
      _log('makeVideoCall failed: $e');
      _finishCall(emitFailedReason: e.toString());
    }
  }

  void toggleVideo(bool hide) {
    if (_activeCall == null) return;
    try {
      if (hide) {
        _activeCall!.mute(false, true);
      } else {
        _activeCall!.unmute(false, true);
      }
      _isLocalVideoMuted = hide;
    } catch (e) {
      _log('Exception during video toggle: $e');
    }
  }

  Future<void> switchCamera() async {
    final stream = _localStream as MediaStream?;
    if (stream == null) return;

    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isNotEmpty) {
      final track = videoTracks.first;
      try {
        await Helper.switchCamera(track);
      } catch (e) {
        _log('Failed to switch camera: $e');
      }
    }
  }

  int _randomSsrc() => DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFF;

  String _mungeSdpForH264(String sdp) {
    if (!sdp.contains('m=video')) return sdp;

    // Safely split by lines handling both \r\n and \n to avoid truncation issues
    final lines = sdp.replaceAll('\r\n', '\n').split('\n');
    final videoStart = lines.indexWhere((l) => l.startsWith('m=video'));
    if (videoStart == -1) return sdp;

    final videoLine = lines[videoStart];
    final parts = videoLine.split(' ');
    if (parts.length < 4) return sdp;

    final allPts = parts.skip(3).toList();

    // Collect rtpmap info to identify codec types
    final Map<String, String> ptCodec = {};
    for (int i = videoStart; i < lines.length; i++) {
      final l = lines[i];
      if (l.startsWith('m=') && i > videoStart) break;
      final m = RegExp(r'^a=rtpmap:(\d+) (\S+)').firstMatch(l);
      if (m != null) ptCodec[m.group(1)!] = m.group(2)!;
    }

    final h264Pts = ptCodec.entries
        .where((e) => e.value.toLowerCase().startsWith('h264'))
        .map((e) => e.key)
        .toSet();
    final rtxForH264 = ptCodec.entries
        .where((e) => e.value.toLowerCase().startsWith('rtx'))
        .where((e) {
          final aptM = RegExp(r'^a=fmtp:(\d+) apt=(\d+)');
          for (int i = videoStart; i < lines.length; i++) {
            final l = lines[i];
            if (l.startsWith('m=') && i > videoStart) break;
            final m = aptM.firstMatch(l);
            if (m != null &&
                m.group(1) == e.key &&
                h264Pts.contains(m.group(2))) {
              return true;
            }
          }
          return false;
        })
        .map((e) => e.key)
        .toSet();

    final keepPts = {...h264Pts, ...rtxForH264};
    final newPts = allPts.where((pt) => keepPts.contains(pt)).toList();

    // Fallback if no H264 codecs found rather than stripping video completely
    if (newPts.isEmpty) {
      _log(
        'WARNING: No H264 codecs found in SDP. Falling back to original SDP.',
      );
      return sdp;
    }

    lines[videoStart] =
        '${parts[0]} ${parts[1]} ${parts[2]} ${newPts.join(" ")}';

    // Find the end of the video section first to bound the backwards loop safely
    int videoEnd = lines.length;
    for (int i = videoStart + 1; i < lines.length; i++) {
      if (lines[i].startsWith('m=')) {
        videoEnd = i;
        break;
      }
    }

    // Process only within the bounds of the m=video section
    for (int i = videoEnd - 1; i > videoStart; i--) {
      final l = lines[i];
      if (l.startsWith('a=rtpmap:') ||
          l.startsWith('a=fmtp:') ||
          l.startsWith('a=rtcp-fb:')) {
        final m = RegExp(r'^a=[a-zA-Z0-9-]+:(\d+)').firstMatch(l);
        if (m != null) {
          final pt = m.group(1)!;
          if (!keepPts.contains(pt)) {
            lines.removeAt(i);
          } else if (l.startsWith('a=fmtp:') && h264Pts.contains(pt)) {
            String updated = l.replaceAllMapped(
              RegExp(r'profile-level-id=[0-9a-fA-F]+'),
              (_) => 'profile-level-id=42e01f',
            );
            if (!updated.contains('packetization-mode')) {
              updated = '$updated;packetization-mode=1';
            } else {
              updated = updated.replaceAll(
                RegExp(r'packetization-mode=\d'),
                'packetization-mode=1',
              );
            }
            lines[i] = updated;
          }
        }
      }
    }

    return lines.join('\r\n');
  }

  String _injectVideoToSdp(String sdp) {
    final lines = sdp.replaceAll('\r\n', '\n').split('\n');
    final audioIdx = lines.indexWhere((l) => l.startsWith('m=audio'));
    if (audioIdx == -1) return sdp;

    int audioEnd = lines.length;
    for (int i = audioIdx + 1; i < lines.length; i++) {
      if (lines[i].startsWith('m=')) {
        audioEnd = i;
        break;
      }
    }

    final videoLines = <String>[
      'm=video 9 UDP/TLS/RTP/SAVPF 103 104',
      'c=IN IP4 0.0.0.0',
      'b=AS:128',
      'a=sendrecv',
      'a=rtpmap:103 H264/90000',
      'a=rtpmap:104 rtx/90000',
      'a=fmtp:103 profile-level-id=42e01f;packetization-mode=1',
      'a=fmtp:104 apt=103',
      'a=ssrc-group:FID ${_randomSsrc()} ${_randomSsrc()}',
      'a=ssrc:${_randomSsrc()} cname:samvaad',
      'a=ssrc:${_randomSsrc()} msid:samvaad_video samvaad_video',
      'a=ssrc:${_randomSsrc()} mslabel:samvaad_video',
      'a=ssrc:${_randomSsrc()} label:samvaad_video',
      'a=ssrc:${_randomSsrc()} cname:samvaad',
      'a=ssrc:${_randomSsrc()} msid:samvaad_video samvaad_video',
      'a=ssrc:${_randomSsrc()} mslabel:samvaad_video',
      'a=ssrc:${_randomSsrc()} label:samvaad_video',
    ];

    lines.insertAll(audioEnd, videoLines);
    return lines.join('\r\n');
  }

  Future<RTCSessionDescription> Function(RTCSessionDescription)
  _makeH264Modifier() {
    return (desc) async {
      var sdp = desc.sdp;
      var type = desc.type ?? 'offer'; // Ensure type is never null!

      if (sdp == null || sdp.isEmpty) {
        _log('ERROR: Modifier received null/empty SDP. Returning unmodified.');
        return RTCSessionDescription(sdp, type);
      }

      if (type == 'answer' && !sdp.contains('m=video')) {
        _log('Injected m=video into answer (Asterisk stripped it)');
        sdp = _injectVideoToSdp(sdp);
      }

      final munged = _mungeSdpForH264(sdp);

      // Strict Verification Check!
      if (munged.isEmpty || !munged.contains('m=video')) {
        _log(
          'ERROR: Munged SDP is empty or lost m=video! Falling back to original SDP.',
        );
        return RTCSessionDescription(sdp, type);
      }

      _log(
        'H264 munge (before setLocalDescription): orig(${sdp.length})→munged(${munged.length}) '
        'has_m=video=${munged.contains("m=video")} has_H264=${munged.contains("H264")} type=$type',
      );

      // Properly reconstruct the RTCSessionDescription using the validated 'type'
      return RTCSessionDescription(munged, type);
    };
  }

  dynamic get remoteStream => _remoteStream;
  bool get isMuted => _isMuted;

  void mute(bool muted) {
    if (muted == _isMuted) return;
    final call = _activeCall;
    if (call == null) {
      _log('mute called with no active call — ignoring');
      return;
    }
    try {
      if (muted) {
        call.mute(true, false);
      } else {
        call.unmute(true, false);
      }
      _isMuted = muted;
    } catch (e) {
      _log('Exception during local mute: $e');
    }
  }

  void toggleHold(bool hold) {
    if (_activeCall == null) return;
    try {
      if (hold) {
        _activeCall!.hold();
      } else {
        _activeCall!.unhold();
      }
      _isHeld = hold;
    } catch (e) {
      _log('Exception during toggleHold: $e');
    }
  }

  Future<void> toggleSpeaker(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
      _isSpeakerOn = on;
    } catch (e) {
      _log('Exception during toggleSpeaker: $e');
    }
  }

  void sendDTMF(String tone) {
    final call = _activeCall;
    if (call == null) {
      _log('sendDTMF called with no active call — ignoring');
      return;
    }
    try {
      call.sendDTMF(tone);
    } catch (e) {
      _log('Exception during sendDTMF: $e');
    }
  }

  Future<Map<String, String>> _getAuthHeaders({
    bool includeXUserId = false,
  }) async {
    String token = '';
    String savedUser = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      savedUser = prefs.getString('savedUsername') ?? '';
      final tokenStr = prefs.getString('token');
      if (tokenStr != null && tokenStr.isNotEmpty) {
        try {
          final decoded = jsonDecode(tokenStr);
          if (decoded is Map) {
            token = (decoded['token'] ?? decoded['userData']?['token'] ?? '')
                .toString();
            if (savedUser.isEmpty) {
              savedUser =
                  (decoded['userData']?['username'] ??
                          decoded['username'] ??
                          '')
                      .toString();
            }
          } else if (tokenStr.startsWith('eyJ')) {
            token = tokenStr;
          }
        } catch (_) {
          if (tokenStr.startsWith('eyJ')) {
            token = tokenStr;
          }
        }
      }
    } catch (_) {}

    final username = savedUser.isNotEmpty
        ? savedUser
        : (_credentials?.displayName ?? _credentials?.username ?? '');
    return {
      'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (includeXUserId && username.isNotEmpty) 'X-User-ID': username,
    };
  }

  /// Resolves the canonical `user@admin` username used by the REST APIs.
  /// The SIP/WebSocket layer uses the dash form (`demo-surya`) while every
  /// backend API keyed on `user.split("@")` needs the `demo@surya` form, so
  /// we must not trust what was typed at login time.
  String _normalizeToApiFormat(String s) {
    if (s.isEmpty || s.contains('@')) return s;
    final idx = s.indexOf('-');
    if (idx > 0) return '${s.substring(0, idx)}@${s.substring(idx + 1)}';
    return s;
  }

  Future<String> _resolveApiUsername() async {
    final prefs = await SharedPreferences.getInstance();
    final tokenStr = prefs.getString('token');
    if (tokenStr != null && tokenStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(tokenStr);
        if (decoded is Map) {
          final userData = decoded['userData'];
          if (userData is Map) {
            final u = userData['username']?.toString() ?? '';
            if (u.isNotEmpty && (u.contains('@') || u.contains('-'))) {
              return _normalizeToApiFormat(u);
            }
          }
          final u = decoded['username']?.toString() ?? '';
          if (u.isNotEmpty && (u.contains('@') || u.contains('-'))) {
            return _normalizeToApiFormat(u);
          }
        }
      } catch (_) {}
    }

    final saved = prefs.getString('savedUsername') ?? '';
    if (saved.isNotEmpty && (saved.contains('@') || saved.contains('-'))) {
      return _normalizeToApiFormat(saved);
    }

    final cred = _credentials?.displayName ?? _credentials?.username ?? '';
    if (cred.isNotEmpty && (cred.contains('@') || cred.contains('-'))) {
      return _normalizeToApiFormat(cred);
    }

    if (saved.isNotEmpty) return _normalizeToApiFormat(saved);
    if (cred.isNotEmpty) return _normalizeToApiFormat(cred);
    return '';
  }

  Future<void> clearRejectedCallFromAgent(String callerNumber) async {
    try {
      // Mirror the webphone: try every number variant because the backend
      // matches the queue `Caller` field exactly (raw, +91, or with +91).
      final rawNumber = callerNumber
          .replaceAll(RegExp(r'^\+91'), '')
          .replaceAll(RegExp(r'^\+'), '')
          .trim();
      if (rawNumber.isEmpty) return;
      final variants = <String>{
        callerNumber,
        rawNumber,
        '+91$rawNumber',
      }.toList();

      var cleared = false;
      for (final num in variants) {
        _log('Requesting clearRejectedCallFromAgent for $num...');
        final headers = await _getAuthHeaders();
        final response = await http
            .post(
              Uri.parse('https://app.samvaad.io/clearRejectedCallFromAgent'),
              headers: headers,
              body: jsonEncode({'caller': num}),
            )
            .timeout(const Duration(seconds: 5));
        _log('clearRejectedCallFromAgent response: ${response.body}');
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map && data['success'] == true) {
            cleared = true;
            break;
          }
        }
      }
      if (!cleared) {
        _log('clearRejectedCallFromAgent: no variant cleared for $callerNumber');
      }
    } catch (e) {
      _log('Error calling clearRejectedCallFromAgent: $e');
    }
  }

  /// Fetches the server-side missed/dropped calls list for this agent
  /// (`POST /userMissedCalls/{username}`), like the webphone does.
  Future<List<dynamic>> fetchMissedCalls() async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return _missedCalls;
      _log('Fetching missed calls for $username...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/userMissedCalls/$username'),
            headers: headers,
            body: jsonEncode({}),
          )
          .timeout(const Duration(seconds: 8));
      if (_checkResponseForAuthFailure(response)) return _missedCalls;
      if (response.statusCode != 200) {
        _log(
          'fetchMissedCalls: unexpected status ${response.statusCode} ${response.body}',
        );
        return _missedCalls;
      }
      final data = jsonDecode(response.body);
      final result = data is Map ? data['result'] : null;
      if (result is List) {
        _missedCalls = result;
        _emit(SipEvent.missedCallsUpdated, data: {'count': result.length});
      }
    } catch (e) {
      _log('Error fetching missed calls: $e');
    }
    return _missedCalls;
  }

  List<Map<String, dynamic>> _leads = [];
  List<Map<String, dynamic>> get leads => _leads;

  /// Fetches the agent's recent call records from `POST /reports/calls/byAgent`
  /// (agent + optional date range, defaults to all time) and maps them into
  /// [CallLogEntry] list.
  Future<List<CallLogEntry>> fetchRecentCalls({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return _recentCalls;
      _log('Fetching recent calls for $username...');
      final headers = await _getAuthHeaders();
      final now = DateTime.now();
      final rangeStart = startDate ?? DateTime(2000, 1, 1);
      final rangeEnd = endDate ?? now;
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/reports/calls/byAgent'),
            headers: headers,
            body: jsonEncode({
              'startDate': _formatDate(rangeStart),
              'endDate': _formatDate(rangeEnd),
              'agentName': username,
            }),
          )
          .timeout(const Duration(seconds: 10));
      _log(
        'Recent calls API status: ${response.statusCode}, body: ${response.body}',
      );
      if (_checkResponseForAuthFailure(response)) return _recentCalls;
      final data = jsonDecode(response.body);
      final result = data is Map ? data['result'] : null;
      if (result is List) {
        final mapped = result.map(_callRecordToEntry).toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
        _recentCalls = mapped;
        _emit(SipEvent.recentCallsUpdated, data: {'count': mapped.length});
      }
    } catch (e) {
      _log('Error fetching recent calls: $e');
    }
    return _recentCalls;
  }

  /// Fetches agent leads from `POST /leadswithdaterange`
  Future<List<Map<String, dynamic>>> fetchLeads([
    DateTime? customStartDate,
    DateTime? customEndDate,
  ]) async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return _leads;
      final now = DateTime.now();
      final endDate = customEndDate ?? now;
      final startDate = customStartDate ?? now;
      _log(
        'Fetching leads for $username (${_formatDate(startDate)} to ${_formatDate(endDate)})...',
      );
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/leadswithdaterange'),
            headers: headers,
            body: jsonEncode({
              'startDate': _formatDate(startDate),
              'endDate': _formatDate(endDate),
              'user': username,
              'campaignID': UserData.campaign(),
            }),
          )
          .timeout(const Duration(seconds: 10));
      _log('Leads API status: ${response.statusCode}');
      if (_checkResponseForAuthFailure(response)) return _leads;
      final data = jsonDecode(response.body);
      final result = data is Map ? (data['data'] ?? data['result']) : null;
      if (result is List) {
        _leads = List<Map<String, dynamic>>.from(
          result.map(
            (x) =>
                x is Map ? Map<String, dynamic>.from(x) : <String, dynamic>{},
          ),
        );
        if (_leads.isNotEmpty) {
          _log('Leads sample keys/values: ${_leads.first.toString()}');
        }
        _emit(
          SipEvent.messageReceived,
          data: {'type': 'leadsUpdated', 'count': _leads.length},
        );
      }
    } catch (e) {
      _log('Error fetching leads: $e');
      ToastService.show('Failed to load leads');
    }
    return _leads;
  }

  bool _checkResponseForAuthFailure(http.Response response) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      _log(
        'HTTP ${response.statusCode} Unauthorized detected on ${response.request?.url}! Triggering auto-logout...',
      );
      _handleAuthFailure();
      return true;
    }
    try {
      final body = response.body.toLowerCase();
      if (body.contains('unauthorized') ||
          body.contains('invalid token') ||
          body.contains('token expired')) {
        _log(
          'Auth failure response detected on ${response.request?.url}! Triggering auto-logout...',
        );
        _handleAuthFailure();
        return true;
      }
    } catch (_) {}
    return false;
  }

  void _handleAuthFailure() {
    _emit(SipEvent.connectionLost, data: {'reason': '401_unauthorized'});
  }

  String _formatDate(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  CallLogEntry _callRecordToEntry(dynamic record) {
    final map = record is Map ? Map<dynamic, dynamic>.from(record) : {};
    String field(String key) {
      final v = map[key];
      return v?.toString() ?? '';
    }

    var number = field('Caller');
    if (number.isEmpty) number = field('contactNumber');
    if (number.isEmpty) number = field('dialNumber');
    if (number.isEmpty) number = field('DestinationNumber');

    var type = field('Type');
    if (type.isEmpty) type = field('callType');

    final direction = type.toLowerCase().contains('incoming')
        ? CallLogDirection.incoming
        : CallLogDirection.outgoing;

    final startRaw = field('startTime');
    DateTime? start;
    if (startRaw.isNotEmpty) {
      final ms = int.tryParse(startRaw);
      if (ms != null) {
        start = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
      } else {
        start = DateTime.tryParse(startRaw)?.toLocal();
      }
    }
    start ??= DateTime.now();

    var durationSec = 0;
    final durRaw = field('duration');
    final durNum = int.tryParse(durRaw);
    if (durNum != null) {
      durationSec = durNum;
    } else {
      final ansRaw = field('anstime');
      final endRaw = field('hanguptime');
      final ansMs = int.tryParse(ansRaw);
      final endMs = int.tryParse(endRaw);
      if (ansMs != null && endMs != null && endMs > ansMs) {
        durationSec = (endMs - ansMs) ~/ 1000;
      }
    }

    final bridgeId = field('bridgeID');
    return CallLogEntry(
      id: bridgeId.isNotEmpty
          ? bridgeId
          : '${start.millisecondsSinceEpoch}_$number',
      number: number,
      direction: direction,
      source: field('campaign').isEmpty ? 'Server' : field('campaign'),
      startedAt: start,
      durationSec: durationSec,
      bridgeId: bridgeId.isEmpty ? null : bridgeId,
    );
  }

  /// Calls back a missed/dropped caller via `POST /dialmissedcall`.
  Future<bool> dialMissedCall(String receiver) async {
    try {
      final cleanNum = receiver.replaceAll('+', '').trim();
      if (cleanNum.isEmpty) return false;
      _log('Calling back missed caller $cleanNum...');
      shouldAutoAnswerNextCall = true;
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/dialmissedcall'),
            headers: headers,
            body: jsonEncode({'receiver': cleanNum}),
          )
          .timeout(const Duration(seconds: 10));
      _log(
        '/dialmissedcall response (${response.statusCode}): ${response.body}',
      );
      final data = jsonDecode(response.body);
      if (data is Map && data['success'] == true) {
        final callId = data['CallID'];
        if (callId != null && callId.toString().isNotEmpty) {
          _bridgeID = callId.toString();
        }
        return true;
      }
      shouldAutoAnswerNextCall = false;
      ToastService.show('Failed to dial missed call');
    } catch (e) {
      shouldAutoAnswerNextCall = false;
      _log('Error calling /dialmissedcall: $e');
      ToastService.show('Failed to dial missed call');
    }
    return false;
  }

  /// Marks a scheduled follow-up callback as complete on the backend
  /// (`POST /callback/update-status`).
  Future<void> updateCallbackStatus(String callbackId, String status) async {
    try {
      _log('Updating callback $callbackId → $status...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/callback/update-status'),
            headers: headers,
            body: jsonEncode({'callbackId': callbackId, 'status': status}),
          )
          .timeout(const Duration(seconds: 5));
      _log(
        '[CALLBACK] update-status response: ${response.statusCode} ${response.body}',
      );
    } catch (e) {
      _log('Error updating callback status: $e');
      ToastService.show('Failed to update callback');
    }
  }

  Future<void> hangupChannel(String channelId) async {
    try {
      if (channelId.isEmpty) return;
      _log('Requesting hangupChannel for channelId: $channelId...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/hangupChannel'),
            headers: headers,
            body: jsonEncode({'channelId': channelId}),
          )
          .timeout(const Duration(seconds: 5));
      _log('hangupChannel response: ${response.body}');
    } catch (e) {
      _log('Error calling hangupChannel: $e');
      ToastService.show('Failed to hang up channel');
    }
  }

  Future<Map<String, dynamic>?> sendUserconnection() async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return null;
      _log('Sending /userconnection check for $username...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/userconnection'),
            headers: headers,
            body: jsonEncode({'user': username}),
          )
          .timeout(const Duration(seconds: 5));
      if (_checkResponseForAuthFailure(response)) return null;
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>?;
        _log(
          '[USERCONNECTION] response keys: ${body?.keys.toList()} '
          'followUpDispoes=${body?['followUpDispoes']}',
        );
        return body;
      }
      ToastService.show('Connection check failed');
    } catch (e) {
      _log('Error in userconnection check: $e');
      ToastService.show('Connection check failed');
    }
    return null;
  }

  /// Processes the /userconnection poll response the same way the webphone does:
  /// updates the queue count/badge, tracks the agent status, and rings as a
  /// fallback when a queued call for this agent's campaign is visible but the
  /// SIP INVITE/FCM path has not surfaced it yet.
  void _processUserconnection(Map<String, dynamic> data) {
    final followUps = data['followUpDispoes'];
    _log(
      '[FOLLOW_UPS] userconnection followUpDispoes=${followUps is List ? 'list(${followUps.length})' : '${followUps?.runtimeType ?? 'ABSENT'}'}',
    );
    final count = data['currentCallqueueCount'];
    if (count is int && count != _queueCount) {
      _queueCount = count;
      _emit(SipEvent.queueUpdated, data: {'count': count});
    }

    final status = data['status'];
    if (status is String && status != _agentStatus) {
      _agentStatus = status;
      _emit(SipEvent.agentStatusChanged, data: {'status': status});
    }

    if (followUps is List) {
      final followUpsJson = followUps.join();
      if (followUpsJson != _lastFollowUpsJson) {
        _lastFollowUpsJson = followUpsJson;
        _followUps = followUps;
        _log('[FOLLOW_UPS] Refreshed: ${followUps.length} scheduled callbacks');
        _emit(SipEvent.followUpsUpdated, data: {'count': followUps.length});
      }
    }

    final queue = data['currentCallqueue'];
    if (queue is List) {
      _currentCallqueue = queue;
      _log(
        '[CALL_QUEUE] Active Call Queue (${queue.length} callers): ${jsonEncode(queue)}',
      );
      final callers = queue
          .map((c) => (c is Map ? (c['Caller'] ?? '') : '').toString())
          .join(',');
      final changed = callers != _lastQueueCallers;
      _lastQueueCallers = callers;

      if (changed &&
          callers.isNotEmpty &&
          _callState == CallState.idle &&
          _activeCall == null) {
        final first = queue.first;
        final caller = first is Map ? (first['Caller'] ?? '').toString() : '';
        if (caller.isNotEmpty) {
          _incomingChannelId = first is Map
              ? (first['channelID'] ?? '').toString()
              : '';
          _log('Queue fallback ring for caller $caller');
          _emit(
            SipEvent.incomingCall,
            data: {'number': caller, 'fromQueue': true},
          );
        }
      }
    }

    checkUserAvailability();
  }

  /// Mirrors the webphone's `checkUserAvailability` in Dashboard.jsx: when the
  /// agent is genuinely available (not in a call, not on break, status
  /// NOT_INUSE) and a queued call is waiting for this agent's campaign, ask the
  /// backend to dispatch the next queued call via `/user/agentAvailable`.
  Future<void> checkUserAvailability() async {
    if (_callState != CallState.idle || _activeCall != null) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final selectedBreak = prefs.getString('selectedBreak');
    final isOnBreak =
        selectedBreak != null &&
        selectedBreak.isNotEmpty &&
        selectedBreak != 'Break';
    if (isOnBreak) {
      return;
    }

    if (_agentAvailableInFlight) return;
    final now = DateTime.now();
    if (now.difference(_agentAvailableLastCalled) <
        const Duration(seconds: 10)) {
      return;
    }

    final queue = _currentCallqueue;
    if (queue.isEmpty) return;

    final first = queue.first is Map ? queue.first as Map : null;
    if (first == null) return;

    final queueCampaign = (first['campaign'] ?? '').toString();
    final userCampaign = UserData.campaign();
    if (userCampaign.isNotEmpty &&
        queueCampaign.isNotEmpty &&
        userCampaign != queueCampaign) {
      return;
    }

    if (_agentStatus != 'NOT_INUSE') return;

    _agentAvailableInFlight = true;
    _agentAvailableLastCalled = now;
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return;
      _log('Sending /user/agentAvailable for $username...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/user/agentAvailable/$username'),
            headers: headers,
            body: jsonEncode({}),
          )
          .timeout(const Duration(seconds: 5));
      _log(
        'agentAvailable response (${response.statusCode}): ${response.body}',
      );
    } catch (e) {
      _log('Error calling agentAvailable: $e');
      ToastService.show('Failed to set agent available');
    } finally {
      _agentAvailableInFlight = false;
    }
  }

  Future<Map<String, dynamic>?> fetchUserOnCall(
    String phoneNumber, {
    String? leadLockToken,
  }) async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return null;
      _log('Sending /useroncall/$username for $phoneNumber...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/useroncall/$username'),
            headers: headers,
            body: jsonEncode({
              'user': username,
              'phoneNumber': phoneNumber,
              if (leadLockToken != null && leadLockToken.isNotEmpty)
                'leadLockToken': leadLockToken,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>?;
      }
      ToastService.show('Failed to check user on call');
    } catch (e) {
      _log('Error calling /useroncall: $e');
      ToastService.show('Failed to check user on call');
    }
    return null;
  }

  Future<void> sendCallEnded({
    String? leadLockToken,
    String callType = 'Manual',
    bool isMerged = false,
  }) async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return;
      _log('Sending /user/callended$username...');
      final headers = await _getAuthHeaders();
      await http
          .post(
            Uri.parse('https://app.samvaad.io/user/callended$username'),
            headers: headers,
            body: jsonEncode({
              'callType': callType,
              'isMerged': isMerged,
              if (leadLockToken != null && leadLockToken.isNotEmpty)
                'leadLockToken': leadLockToken,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      _log('Error in /user/callended: $e');
      ToastService.show('Failed to send call ended');
    }
  }

  Future<void> submitDisposition({
    required String bridgeId,
    required String disposition,
    String? contactNumber,
    String? leadId,
    String? leadLockToken,
    bool autoDialDisabled = false,
    Map<String, dynamic>? followUpDisposition,
  }) async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return;
      _log('Submitting /user/disposition$username...');
      final headers = await _getAuthHeaders();
      await http
          .post(
            Uri.parse('https://app.samvaad.io/user/disposition$username'),
            headers: headers,
            body: jsonEncode({
              'bridgeID': bridgeId.isNotEmpty ? bridgeId : 'deadCallId',
              'Disposition': disposition.isNotEmpty
                  ? disposition
                  : 'Auto Disposed',
              'autoDialDisabled': autoDialDisabled,
              if (contactNumber != null && contactNumber.isNotEmpty)
                'contactNumber': contactNumber,
              if (leadId != null && leadId.isNotEmpty) 'leadId': leadId,
              if (leadLockToken != null && leadLockToken.isNotEmpty)
                'leadLockToken': leadLockToken,
              if (followUpDisposition != null && followUpDisposition.isNotEmpty)
                'followUpDisposition': followUpDisposition,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      _log('Error in /user/disposition: $e');
      ToastService.show('Failed to submit disposition');
    }
  }

  /// Fetches the campaign's dynamic lead form config, mirroring the webphone's
  /// two-step fetch: form list per campaign, then full schema by form id.
  /// Returns the parsed form config map (`{formId, formTitle, formType,
  /// sections}`) or null when the campaign has no web form enabled.
  /// Result of resolving the post-call webform.
  ///
  /// Mirrors the webphone's `LeadAndCallInfoPanel` logic:
  /// - `webformEnabled: false` -> campaign webforms are off (or unresolvable);
  ///   the webphone shows the "Campaign form is disabled" notice and skips the
  ///   contact form entirely.
  /// - `webformEnabled: true, config: null` -> webforms are enabled but no
  ///   dynamic form resolved; the webphone falls back to the static UserCall
  ///   contact form.
  /// - `webformEnabled: true, config: != null` -> the dynamic form to render.
  Future<DynamicFormConfigResult> fetchDynamicFormConfig({
    required String callType, // 'outgoing' | 'incoming'
  }) async {
    try {
      final campaign = UserData.campaign();
      if (campaign.isEmpty) {
        return const DynamicFormConfigResult(
          webformEnabled: false,
          config: null,
        );
      }
      final headers = await _getAuthHeaders();

      final listRes = await http
          .get(
            Uri.parse(
              'https://app.samvaad.io/getDynamicFormDataAgent/$campaign',
            ),
            headers: headers,
          )
          .timeout(const Duration(seconds: 8));
      if (listRes.statusCode != 200) {
        return const DynamicFormConfigResult(
          webformEnabled: false,
          config: null,
        );
      }
      final listData = jsonDecode(listRes.body) as Map<String, dynamic>?;
      if (listData == null) {
        return const DynamicFormConfigResult(
          webformEnabled: false,
          config: null,
        );
      }
      if (listData['webformEnabled'] != true) {
        return const DynamicFormConfigResult(
          webformEnabled: false,
          config: null,
        );
      }

      // Webphone reads `webForm || agentWebForm` from this response.
      final forms = listData['webForm'] ?? listData['agentWebForm'];
      if (forms is! List || forms.isEmpty) {
        return const DynamicFormConfigResult(
          webformEnabled: true,
          config: null,
        );
      }

      final target = callType.toLowerCase();
      Map<String, dynamic>? match;
      for (final f in forms) {
        if (f is! Map) continue;
        final type = (f['formType'] ?? f['type'] ?? f['Type'] ?? f['form_type'])
            .toString()
            .toLowerCase();
        if (type == target) {
          match = Map<String, dynamic>.from(f);
          break;
        }
      }
      match ??= forms.first is Map
          ? Map<String, dynamic>.from(forms.first as Map)
          : null;
      if (match == null) {
        return const DynamicFormConfigResult(
          webformEnabled: true,
          config: null,
        );
      }

      final formId =
          (match['formId'] ?? match['id'] ?? match['Id'] ?? match['form_id'])
              .toString();
      if (formId.isEmpty) {
        return const DynamicFormConfigResult(
          webformEnabled: true,
          config: null,
        );
      }

      final formRes = await http
          .get(
            Uri.parse('https://app.samvaad.io/getDynamicFormData/$formId'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 8));
      if (formRes.statusCode != 200) {
        return const DynamicFormConfigResult(
          webformEnabled: true,
          config: null,
        );
      }
      final formData = jsonDecode(formRes.body) as Map<String, dynamic>?;
      final result = formData?['result'];
      if (result is! Map) {
        return const DynamicFormConfigResult(
          webformEnabled: true,
          config: null,
        );
      }
      final config = Map<String, dynamic>.from(result);
      config['formId'] = formId;
      return DynamicFormConfigResult(webformEnabled: true, config: config);
    } catch (e) {
      _log('Error fetching dynamic form config: $e');
      ToastService.show('Failed to load form config');
      return const DynamicFormConfigResult(webformEnabled: false, config: null);
    }
  }

  /// Persists a contact + conversation record from the dynamic lead form
  /// (`POST /addModifyContact`), the same endpoint the webphone's dynamic and
  /// static forms submit to.
  Future<bool> addModifyContact(Map<String, dynamic> payload) async {
    try {
      _log('Submitting /addModifyContact...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/addModifyContact'),
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 8));
      final body = response.body;
      var success = false;
      try {
        final decoded = jsonDecode(body);
        success = decoded is Map && decoded['success'] == true;
      } catch (_) {
        success = body.contains('"success"') && body.contains('true');
      }
      _log('addModifyContact response: $body');
      return success;
    } catch (e) {
      _log('Error in /addModifyContact: $e');
      return false;
    }
  }

  Future<void> setAgentBreak(String breakType) async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return;
      _log('Setting agent break $breakType for $username...');
      final headers = await _getAuthHeaders();
      await http
          .post(
            Uri.parse('https://app.samvaad.io/user/breakuser:$username'),
            headers: headers,
            body: jsonEncode({'breakType': breakType}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      _log('Error in /user/breakuser: $e');
      ToastService.show('Failed to start break');
    }
  }

  Future<void> removeAgentBreak() async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return;
      _log('Removing agent break for $username...');
      final headers = await _getAuthHeaders();
      await http
          .post(
            Uri.parse(
              'https://app.samvaad.io/user/removebreakuser:$username',
            ),
            headers: headers,
            body: jsonEncode({}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      _log('Error in /user/removebreakuser: $e');
      ToastService.show('Failed to end break');
    }
  }

  Timer? _heartbeatTimer;

  /// Fetches scheduled callbacks via `POST /agent-callbacks` (webphone parity).
  Future<void> fetchAgentCallbacks() async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return;
      _log('Sending /agent-callbacks for $username...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/agent-callbacks'),
            headers: headers,
            body: jsonEncode({'user': username}),
          )
          .timeout(const Duration(seconds: 8));
      _log('[CALLBACK_API] /agent-callbacks status=${response.statusCode}');
      if (_checkResponseForAuthFailure(response)) return;
      final data = jsonDecode(response.body);
      if (data is Map && data['success'] == true) {
        final list = data['followUpDispoes'];
        if (list is List) {
          final jsonStr = list.join();
          if (jsonStr != _lastFollowUpsJson) {
            _lastFollowUpsJson = jsonStr;
            _followUps = list;
            _log('[CALLBACK_API] updated followUps=${list.length}');
            _emit(SipEvent.followUpsUpdated, data: {'count': list.length});
          } else {
            _log('[CALLBACK_API] no change followUps=${list.length}');
          }
        }
      } else {
        _log('[CALLBACK_API] response not success: ${response.body}');
      }
    } catch (e) {
      _log('Error in /agent-callbacks: $e');
    }
  }

  void _startHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    var tick = 0;
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      tick++;
      final data = await sendUserconnection();
      if (data != null) {
        _processUserconnection(data);
      }
      fetchAgentCallbacks();
      if (tick % 6 == 0) {
        sendUserReady();
      }
      if (tick % 3 == 0) {
        fetchMissedCalls();
        fetchRecentCalls();
      }
    });
  }

  void _stopHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<bool> sendUserReady() async {
    final prefs = await SharedPreferences.getInstance();
    final selectedBreak = prefs.getString('selectedBreak');
    final isOnBreak =
        selectedBreak != null &&
        selectedBreak.isNotEmpty &&
        selectedBreak != 'Break';
    if (isOnBreak) {
      return false;
    }

    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final username = await _resolveApiUsername();
        if (username.isEmpty) return false;

        _log('Sending /userready/$username/Web...');
        final headers = await _getAuthHeaders();
        final response = await http
            .post(
              Uri.parse('https://app.samvaad.io/userready/$username/Web'),
              headers: headers,
              body: jsonEncode({}),
            )
            .timeout(const Duration(seconds: 5));
        _log('/userready response (${response.statusCode}): ${response.body}');
        if (_checkResponseForAuthFailure(response)) return false;
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map && data['message'] == 'success') {
            return true;
          }
        }
      } catch (e) {
        _log('Error sending /userready: $e');
        ToastService.show('Failed to send ready status');
      }
      if (attempt < 3) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    return false;
  }

  Future<bool> dialNumber(
    String number, {
    String? leadId,
    String? leadLockToken,
    String? dialSource,
    bool? autoLeadDial,
  }) async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) {
        _log('dialNumber error: username is empty');
        return false;
      }
      final cleanNum = number.replaceAll('+', '').trim();
      unawaited(clearRejectedCallFromAgent(cleanNum));

      // Mark auto-answer flag BEFORE hitting /dialnumber so incoming SIP INVITE is answered in 0ms
      shouldAutoAnswerNextCall = true;

      final headers = await _getAuthHeaders(includeXUserId: true);
      _log('Initiating REST /dialnumber to $cleanNum for $username...');
      final payload = <String, dynamic>{
        'receiver': cleanNum,
        if (leadId != null && leadId.isNotEmpty) 'leadId': leadId,
        if (leadLockToken != null && leadLockToken.isNotEmpty)
          'leadLockToken': leadLockToken,
        if (dialSource != null && dialSource.isNotEmpty)
          'dialSource': dialSource,
        'autoLeadDial': ?autoLeadDial,
      };

      var response = await http
          .post(
            Uri.parse('https://app.samvaad.io/dialnumber'),
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      _log('/dialnumber response (${response.statusCode}): ${response.body}');
      var data = jsonDecode(response.body);

      // If server returns "Agent is not in a ready state", auto-send userready and retry once
      if (data != null && data['success'] == false) {
        final msg = (data['message'] ?? data['cause'] ?? '').toString();
        if (msg.contains('Agent is not in a ready state') ||
            msg.contains('Please Login again')) {
          _log(
            'Agent not in ready state for dialnumber — sending /userready and retrying...',
          );
          await sendUserReady();
          await Future.delayed(const Duration(milliseconds: 500));
          response = await http
              .post(
                Uri.parse('https://app.samvaad.io/dialnumber'),
                headers: headers,
                body: jsonEncode(payload),
              )
              .timeout(const Duration(seconds: 10));
          data = jsonDecode(response.body);
          _log('Retry /dialnumber response: ${response.body}');
        }
      }

      if (data != null && data['success'] == true) {
        final callId = data['CallID'];
        if (callId != null && callId.toString().isNotEmpty) {
          _bridgeID = callId.toString();
          _log('Captured bridgeID from /dialnumber: $_bridgeID');
        }
        return true;
      } else {
        shouldAutoAnswerNextCall = false;
      }
    } catch (e) {
      shouldAutoAnswerNextCall = false;
      _log('Error calling /dialnumber: $e');
      ToastService.show('Failed to place call');
    }
    return false;
  }

  /// Requests a transfer of the current call. The bridgeID is captured from the
  /// /dialnumber response (outgoing calls); for inbound calls the backend assigns
  /// a bridge that we may not know, so callers should disable the button when
  /// [bridgeID] is empty.
  Future<bool> requestTransfer() async {
    final bridgeId = _bridgeID;
    if (bridgeId.isEmpty) {
      _log('requestTransfer skipped: no bridgeID known for current call');
      return false;
    }
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return false;
      _log('Requesting transfer for $username with bridgeID $bridgeId...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/reqTransfer/$username'),
            headers: headers,
            body: jsonEncode({'bridgeID': bridgeId}),
          )
          .timeout(const Duration(seconds: 10));
      _log('/reqTransfer response: ${response.body}');
      return response.statusCode == 200;
    } catch (e) {
      _log('Error calling /reqTransfer: $e');
      ToastService.show('Failed to request transfer');
      return false;
    }
  }

  Future<void> rejectCall([String? incomingNumber]) async {
    final call = _activeCall;
    final numToClear = (incomingNumber != null && incomingNumber.isNotEmpty)
        ? incomingNumber
        : _incomingNumber;

    if (call != null) {
      try {
        // Prefer the real Asterisk channel ID captured from the queue data;
        // the SIP session `call.id` is NOT the ARI channel ID the backend
        // /hangupChannel route expects.
        final channelId = _incomingChannelId.isNotEmpty
            ? _incomingChannelId
            : call.id;
        if (channelId != null && channelId.isNotEmpty) {
          unawaited(hangupChannel(channelId));
        }
        if (call.state != sip.CallStateEnum.ENDED) {
          call.session.terminate();
        }
      } catch (e) {
        _log('Exception during reject/terminate: $e');
      }
    }

    if (numToClear.isNotEmpty) {
      unawaited(clearRejectedCallFromAgent(numToClear));
    }

    _incomingChannelId = '';
    _finishCall(emitFailedReason: 'rejected');
  }

  // ---------------------------------------------------------------------
  // Conference / merge (mirrors the webphone's Asterisk ARI flow)
  // ---------------------------------------------------------------------

  /// Asks Asterisk to place a second call to [confNumber] and park it in the
  /// conference room while the current call stays alive. `adminuser` comes
  /// from the logged-in userData. Returns true when the request was accepted.
  Future<bool> requestConference(
    String confNumber, {
    String bridgeID = '',
  }) async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return false;
      _log('Requesting conference for $confNumber as $username...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/reqConf/$username'),
            headers: headers,
            body: jsonEncode({
              'confNumber': confNumber,
              'bridgeID': bridgeID,
              'adminuser': UserData.adminUser(),
            }),
          )
          .timeout(const Duration(seconds: 10));
      _log('/reqConf response: ${response.body}');
      return response.statusCode == 200;
    } catch (e) {
      _log('Error calling /reqConf: $e');
      ToastService.show('Failed to start conference');
      return false;
    }
  }

  /// Unholds the current call. Used when merging a conference participant
  /// into the live call (the webphone always unholds before merging).
  Future<bool> requestUnhold() async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return false;
      _log('Requesting /reqUnHold/$username...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/reqUnHold/$username'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
      _log('/reqUnHold response: ${response.body}');
      return response.statusCode == 200;
    } catch (e) {
      _log('Error calling /reqUnHold: $e');
      ToastService.show('Failed to unhold call');
      return false;
    }
  }

  /// Ends the conference room for [hostNumber] without hanging up the main
  /// call. Used by the "disconnect conference" action.
  Future<bool> hangupConference(String hostNumber) async {
    try {
      final username = await _resolveApiUsername();
      if (username.isEmpty) return false;
      _log('Requesting /hangup/hostChannel/Conf for $hostNumber...');
      final headers = await _getAuthHeaders();
      final response = await http
          .post(
            Uri.parse('https://app.samvaad.io/hangup/hostChannel/Conf'),
            headers: headers,
            body: jsonEncode({'user': username, 'hostNumber': hostNumber}),
          )
          .timeout(const Duration(seconds: 10));
      _log('/hangup/hostChannel/Conf response: ${response.body}');
      return response.statusCode == 200;
    } catch (e) {
      _log('Error calling /hangup/hostChannel/Conf: $e');
      ToastService.show('Failed to hang up conference');
      return false;
    }
  }

  void disconnect() {
    _log('disconnect() called', data: StackTrace.current.toString());
    _stopHeartbeatTimer();
    _reconnectTimer?.cancel();
    _intentionalDisconnect = true;
    _reconnectEnabled = false;
    _helper.stop();
    _isConnected = false;
    _isRegistered = false;
    _callState = CallState.idle;
    _activeCall = null;
  }

  void dispose() {
    disconnect();
    _helper.removeSipUaHelperListener(this);
    _eventController.close();
  }
}

/// Result of resolving the post-call webform, distinguishing the cases the
/// webphone's `LeadAndCallInfoPanel` treats differently:
///
/// - [webformEnabled] `false` -> campaign webforms are off (or unresolvable);
///   the webphone shows the "Campaign form is disabled" notice and skips the
///   contact form entirely.
/// - [webformEnabled] `true`, [config] `null` -> webforms enabled but no
///   dynamic form resolved; the webphone falls back to the static UserCall
///   contact form.
/// - [webformEnabled] `true`, [config] non-null -> the dynamic form to render.
class DynamicFormConfigResult {
  const DynamicFormConfigResult({
    required this.webformEnabled,
    required this.config,
  });

  final bool webformEnabled;
  final Map<String, dynamic>? config;
}
