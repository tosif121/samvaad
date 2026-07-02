import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sip_ua/sip_ua.dart' as sip;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/sip_credentials.dart';
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
  static SipSocketService get instance => _instance;

  final sip.SIPUAHelper _helper = sip.SIPUAHelper();

  // Native <-> Dart bridge used by ConnectionService (Android) / CallKit
  // (iOS) so a push-triggered native call UI can be shown before SIP
  // registration completes, then bound to the real SIP call once it lands.
  static const MethodChannel _platform =
      MethodChannel('sip_native_bridge');

  CallState _callState = CallState.idle;
  sip.Call? _activeCall;
  String _incomingNumber = '';
  bool _isRegistered = false;
  bool _isConnected = false;
  bool _isMuted = false;
  dynamic _remoteStream;

  bool _connecting = false;
  bool _wasStarted = false;

  // Guards _finishCall against being invoked twice for the same call
  // (e.g. once from callStateChanged's ENDED/FAILED branch and once from
  // an explicit endCall()/rejectCall() racing with it).
  bool _callEndedHandled = false;

  // Set when a call arrives via FCM/VoIP push before the real SIP INVITE
  // has been received. Used to bind the native call UI (already showing)
  // to the SIP call once it confirms, and to route native answer/reject/
  // end actions back into the SIP session.
  String? _pendingPushCallId;
  String? _pendingPushCallerNumber;

  SipCredentials? _credentials;

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  SipCredentials? get credentials => _credentials;
  bool get hasCredentials => _credentials != null;

  CallState get callState => _callState;
  String get incomingNumber => _incomingNumber;
  bool get isRegistered => _isRegistered;
  bool get isConnected => _isConnected;

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
        answerCall();
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
      _log('connect() ignored — already registered',
          data: StackTrace.current.toString());
      return;
    }
    if (_connecting) {
      _log('connect() ignored — already connecting',
          data: StackTrace.current.toString());
      return;
    }

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
    _pendingPushCallerNumber = callerNumber;

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
          Map<String, dynamic>.from(
            const JsonDecoder().convert(json) as Map,
          ),
        );
      } catch (_) {}
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
        break;
      case sip.RegistrationStateEnum.UNREGISTERED:
        _log('SIP UNREGISTERED');
        _isRegistered = false;
        break;
      case sip.RegistrationStateEnum.REGISTRATION_FAILED:
        _log('SIP REGISTRATION FAILED');
        _isRegistered = false;
        _emit(SipEvent.registrationFailed,
            data: {'cause': state.cause?.toString()});
        break;
    }
  }

  @override
  void transportStateChanged(sip.TransportState state) {
    _log("Transport State : ${state.state}");
    switch (state.state) {
      case sip.TransportStateEnum.NONE:
      case sip.TransportStateEnum.CONNECTING:
        break;
      case sip.TransportStateEnum.CONNECTED:
        final wasDisconnected = !_isConnected;
        _isConnected = true;
        if (wasDisconnected) {
          _emit(SipEvent.connectionRestored);
        }
        break;
      case sip.TransportStateEnum.DISCONNECTED:
        _log('WebSocket DISCONNECTED', data: StackTrace.current.toString());
        final wasConnected = _isConnected;
        _isConnected = false;
        _isRegistered = false;
        if (wasConnected) {
          _emit(SipEvent.connectionLost);
        }
        break;
    }
  }

  @override
  void callStateChanged(sip.Call call, sip.CallState state) {
    _activeCall = call;

    switch (state.state) {
      case sip.CallStateEnum.CALL_INITIATION:
        _callEndedHandled = false;
        if (call.direction == sip.Direction.incoming) {
          final remoteNumber = call.remote_identity ?? 'Unknown';
          _log('INCOMING CALL from: $remoteNumber');
          _incomingNumber = remoteNumber;
          _callState = CallState.ringing;
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
        break;

      case sip.CallStateEnum.CONFIRMED:
        _log('Call CONFIRMED');
        _callState = CallState.onCall;
        _emit(SipEvent.callAnswered);
        CallLifecycleService().onCallStarted();
        _notifyNative('callActive', {'callId': _pendingPushCallId ?? ''});
        break;

      case sip.CallStateEnum.STREAM:
        if (state.originator == sip.Originator.remote && state.stream != null) {
          _remoteStream = state.stream;
          _playRemoteAudio(state.stream!);
        }
        break;

      case sip.CallStateEnum.FAILED:
        _log('Call FAILED', data: {
          'cause': state.cause?.toString(),
          'originator': state.originator?.toString(),
        });
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
  }

  @override
  void onNewNotify(sip.Notify notify) {
    // Re-INVITE/NOTIFY-driven features (e.g. call transfer progress) are
    // not currently supported; intentionally unhandled.
  }

  @override
  void onNewReinvite(sip.ReInvite reinvite) {
    // Re-INVITEs (e.g. hold/resume from the remote party) are not
    // currently supported; intentionally unhandled.
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

    _callState = CallState.idle;

    if (emitFailedReason != null) {
      _emit(SipEvent.callFailed, data: {'reason': emitFailedReason});
    } else {
      _emit(SipEvent.callEnded);
    }

    CallLifecycleService().onCallEnded();
    _notifyNative('callEnded', {'callId': _pendingPushCallId ?? ''});

    _incomingNumber = '';
    _isMuted = false;
    _remoteStream = null;
    _activeCall = null;
    _pendingPushCallId = null;
    _pendingPushCallerNumber = null;
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
        call.session.terminate();
      } catch (e) {
        _log('Exception during session.terminate: $e');
      }
    }
    _finishCall();
  }

  void answerCall() {
    final call = _activeCall;
    if (call == null) {
      _log('answerCall called with no active call — ignoring');
      return;
    }
    if (_callState == CallState.onCall) {
      _log('Already on call — skipping duplicate answer');
      return;
    }
    _log('Answering SIP call');
    try {
      call.answer({'audio': true, 'video': false});
    } catch (e) {
      _log('answerCall failed: $e');
      _emit(SipEvent.callFailed, data: {'reason': 'answer_failed'});
      return;
    }
    CallLifecycleService().onCallStarted();
  }

  Future<void> makeCall(String number) async {
    if (!_isRegistered) {
      _log('Cannot call — not registered');
      _emit(SipEvent.callFailed, data: {'reason': 'not_registered'});
      return;
    }
    _log('Making outgoing call to: $number');
    _callState = CallState.dialing;
    _incomingNumber = number;
    try {
      await _helper.call(number);
    } catch (e) {
      _log('makeCall failed: $e');
      _finishCall(emitFailedReason: e.toString());
    }
  }

  Future<void> rejectCall() async {
    final call = _activeCall;
    if (call != null) {
      try {
        call.session.terminate();
      } catch (e) {
        _log('Exception during reject/terminate: $e');
      }
    }
    // Rejection is reported as a single callFailed event (not callEnded).
    _finishCall(emitFailedReason: 'rejected');
  }

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

  dynamic get remoteStream => _remoteStream;
  bool get isMuted => _isMuted;

  void disconnect() {
    _log('disconnect() called', data: StackTrace.current.toString());
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