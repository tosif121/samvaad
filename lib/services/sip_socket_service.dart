import 'dart:async';
import 'dart:developer' as developer;
import 'package:sip_ua/sip_ua.dart' as sip;
import 'auth_service.dart';
import 'api_service.dart';
import 'remote_audio_stub.dart'
    if (dart.library.html) 'remote_audio_web.dart';

// Call state matching webphone lifecycle
enum CallState { idle, dialing, ringing, onCall, disposition }

// Events emitted to the UI
enum SipEvent {
  registered,
  registrationFailed,
  incomingCall,
  callAnswered,
  callEnded,
  callFailed,
  connectionLost,
  connectionRestored,
  messageReceived,
}

class SipSocketService implements sip.SipUaHelperListener {
  static final SipSocketService _instance = SipSocketService._internal();
  factory SipSocketService() => _instance;

  final sip.SIPUAHelper _helper = sip.SIPUAHelper();

  static const String _origin = 'devapp.iotcom.io';

  Timer? _connectionCheckTimer;

  CallState _callState = CallState.idle;
  String _incomingNumber = '';
  String _bridgeID = '';
  String _dialedNumber = '';
  bool _pendingAnswerForQueue = false;

  void setDialedNumber(String number) {
    _dialedNumber = number;
    if (number.isNotEmpty) {
      _callState = CallState.dialing;
    } else {
      _callState = CallState.idle;
    }
  }
  bool _isRegistered = false;
  bool _isConnected = false;
  bool _isMuted = false;
  bool _isHeld = false;
  dynamic _remoteStream;

  sip.Call? _activeCall;
  bool _endingCall = false;

  // Stream controller for UI events
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  CallState get callState => _callState;
  String get incomingNumber => _incomingNumber;
  bool get isRegistered => _isRegistered;
  bool get isConnected => _isConnected;
  String get bridgeID => _bridgeID;
  Map<String, dynamic>? connectionData;

  SipSocketService._internal() {
    _helper.addSipUaHelperListener(this);
  }

  void _log(String msg, {Object? data}) {
    final ts = DateTime.now().toIso8601String();
    final log = data != null
        ? '[$ts] [SIP_SOCKET] $msg | $data'
        : '[$ts] [SIP_SOCKET] $msg';
    developer.log(log, name: 'Samvaad');
    print(log);
  }

  void _emit(SipEvent event, {Map<String, dynamic>? data}) {
    _log('Emitting event: ${event.name}', data: data);
    _eventController.add({'event': event.name, ...?data});
  }

  // ─── Connect & Register ───────────────────────────────────────────────────

  Future<void> connect() async {
    final userData = await AuthService.getUserData();
    final username = await AuthService.getUsername();
    final password = await AuthService.getSavedPassword();

    if (username == null || password == null) {
      _log('ERROR: Missing credentials for SIP connection');
      return;
    }

    try {
      sip.UaSettings settings = sip.UaSettings();
      settings.webSocketUrl = 'wss://$_origin:8089/ws';
      settings.uri = 'sip:${username.replaceAll('@', '-')}@$_origin:8089';
      settings.password = password;
      settings.authorizationUser = username.replaceAll('@', '-');
      settings.transportType = sip.TransportType.WS;
      settings.sessionTimers = false;

      await _helper.start(settings);
    } catch (e) {
      _log('_helper.start() threw exception', data: {'error': e.toString()});
    }

    // Start periodic REST API connection check every 10 seconds
    _startConnectionCheck();
  }

  // ─── SipListener Callbacks ────────────────────────────────────────────────

  @override
  void registrationStateChanged(sip.RegistrationState state) {
    if (state.state == null) return;

    switch (state.state!) {
      case sip.RegistrationStateEnum.NONE:
        _isRegistered = false;
        break;
      case sip.RegistrationStateEnum.REGISTERED:
        _isRegistered = true;
        _log('SIP REGISTERED');
        _onRegistered();
        break;
      case sip.RegistrationStateEnum.UNREGISTERED:
        _log('SIP UNREGISTERED');
        _isRegistered = false;
        break;
      case sip.RegistrationStateEnum.REGISTRATION_FAILED:
        _log('SIP REGISTRATION FAILED');
        _isRegistered = false;
        _emit(SipEvent.registrationFailed, data: {'cause': state.cause?.toString()});
        break;
    }
  }

  @override
  void transportStateChanged(sip.TransportState state) {
    switch (state.state) {
      case sip.TransportStateEnum.NONE:
      case sip.TransportStateEnum.CONNECTING:
        break;
      case sip.TransportStateEnum.CONNECTED:
        _isConnected = true;
        break;
      case sip.TransportStateEnum.DISCONNECTED:
        _log('WebSocket DISCONNECTED');
        _isConnected = false;
        _isRegistered = false;
        break;
    }
  }

  @override
  void callStateChanged(sip.Call call, sip.CallState state) {
    _activeCall = call;
    
    switch (state.state) {
      case sip.CallStateEnum.CALL_INITIATION:
        _endingCall = false;
        _log('CALL_INITIATION', data: {
          'direction': call.direction,
          'remote_identity': call.remote_identity,
          'callState': _callState.name,
          'dialedNumber': _dialedNumber,
        });
        if (call.direction == 'INCOMING') {
          final remoteNumber = call.remote_identity ?? 'Unknown';

          final cleanRemote = remoteNumber.replaceAll(RegExp(r'\D'), '');
          final cleanDialed = _dialedNumber.replaceAll(RegExp(r'\D'), '');

          final isActuallyOutgoing = _callState == CallState.dialing ||
              (cleanDialed.isNotEmpty && (cleanRemote.contains(cleanDialed) || cleanDialed.contains(cleanRemote)));
          _log('CALL_INITIATION check', data: {
            'isActuallyOutgoing': isActuallyOutgoing,
            'callState': _callState.name,
            'cleanRemote': cleanRemote,
            'cleanDialed': cleanDialed,
          });

          if (isActuallyOutgoing) {
            _log('Auto-answering outgoing call');
            _dialedNumber = '';
            _callState = CallState.onCall;
            _activeCall = call;
            call.answer({'audio': true, 'video': false});
            _emit(SipEvent.callAnswered);
            _loadCallContext();
          } else {
            _log('INCOMING CALL from: $remoteNumber');
            _incomingNumber = remoteNumber;
            _callState = CallState.ringing;
            _emit(SipEvent.incomingCall, data: {'number': _incomingNumber});
            // If user already tapped Accept (pendingAnswerForQueue),
            // answer immediately when the INVITE arrives.
            if (_pendingAnswerForQueue) {
              _log('Auto-answering after pendingAnswerForQueue');
              _pendingAnswerForQueue = false;
              _callState = CallState.onCall;
              call.answer({'audio': true, 'video': false});
              _emit(SipEvent.callAnswered);
              _loadCallContext();
            }
          }
        } else {
          _log('OUTGOING call direction', data: {
            'remote_identity': call.remote_identity,
          });
        }
        break;

      case sip.CallStateEnum.PROGRESS:
        _log('CALL PROGRESS', data: {'cause': state.cause?.toString()});
        break;

      case sip.CallStateEnum.CONFIRMED:
        _log('Call CONFIRMED');
        _callState = CallState.onCall;
        _emit(SipEvent.callAnswered);
        break;
      case sip.CallStateEnum.STREAM:
        if (state.originator == 'remote' && state.stream != null) {
          _remoteStream = state.stream;
          _playRemoteAudio(state.stream!);
        }
        break;
      case sip.CallStateEnum.FAILED:
        _log('Call FAILED', data: {
          'cause': state.cause?.toString(),
          'originator': state.originator?.toString(),
        });
        _onCallEnded();
        _emit(SipEvent.callFailed, data: {'reason': state.cause?.toString() ?? 'unknown'});
        break;
      case sip.CallStateEnum.ENDED:
        _log('Call ENDED');
        _onCallEnded();
        break;
      default:
        break;
    }
  }

  @override
  void onNewMessage(sip.SIPMessageRequest request) {
    // Matches Next.js newMessage/MESSAGE sip handler
    final body = request.request.body ?? '';
    _log('Received SIP MESSAGE: $body');
    _handleAriMessage(body);
  }

  @override
  void onNewNotify(sip.Notify notify) {}

  @override
  void onNewReinvite(sip.ReInvite reinvite) {}



  // ─── ARI Message Handler (matches webphone newMessage handler) ────────────

  void _handleAriMessage(String body) {
    if (body.contains('customer channel answered') ||
        body.contains('agent channel answered')) {
      _log('Customer/Agent channel ANSWERED');
      if (_callState != CallState.onCall) {
        _callState = CallState.onCall;
        _emit(SipEvent.callAnswered, data: {'message': body});
      }
      _loadCallContext();
    } else if (body.contains('customer channel disconnected')) {
      _log('Customer channel DISCONNECTED');
      _onCallEnded();
    } else if (body.contains('force_login_request') ||
        body.contains('Force Login Request')) {
      _log('Force login request received');
      _emit(SipEvent.connectionLost, data: {'reason': 'force_login'});
    }
  }

  // ─── After Registration ───────────────────────────────────────────────────

  Future<void> _onRegistered() async {
    // Skip userReady/userConnection during an active call
    // to avoid server-side state interference with the call.
    if (_callState == CallState.onCall) {
      _emit(SipEvent.registered);
      return;
    }

    await ApiService.userReady();

    final connResult = await ApiService.userConnection();
    connectionData = connResult['data'] as Map<String, dynamic>?;
    if (connResult['success'] == true) {
      final msg = connResult['data']['message'];
      if (msg == 'poor connection problem ,please login again') {
        _isConnected = false;
        _isRegistered = false;
        return;
      }
    }

    _emit(SipEvent.registered);
  }

  // ─── Load Call Context ────────────────────────────────────────────────────

  Future<void> _loadCallContext() async {
    final result = await ApiService.userOnCall();
    if (result['success'] == true) {
      _bridgeID = result['data']?['currentcalldata']?['bridgeID'] ?? '';
    }
  }

  // ─── Call Ended ───────────────────────────────────────────────────────────

  Future<void> _onCallEnded() async {
    if (_endingCall) return;
    _endingCall = true;
    _callState = CallState.disposition;
    _emit(SipEvent.callEnded, data: {'bridgeID': _bridgeID});

    // Call ended API
    await ApiService.callEnded();

    // Ensure bridgeID is loaded before submitting disposition
    var bridgeID = _bridgeID;
    if (bridgeID.isEmpty) {
      _log('bridgeID empty, fetching from userOnCall...');
      final ctx = await ApiService.userOnCall();
      bridgeID = ctx['data']?['currentcalldata']?['bridgeID'] ?? '';
    }

    if (bridgeID.isEmpty) {
      _log('No bridgeID found, using fallback');
      bridgeID = 'deadCallId';
    }
    await ApiService.submitDisposition(bridgeID, 'Auto Disposed');

    _callState = CallState.idle;
    _bridgeID = '';
    _incomingNumber = '';
    _isMuted = false;
    _isHeld = false;
    _remoteStream = null;
    _activeCall = null;
    _pendingAnswerForQueue = false;

    removeRemoteAudio();
    _endingCall = false;
  }

  // ─── Connection Check (matches webphone CONNECTION_CHECK_SCHEDULER_MS = 5000) ─

  void _handlePoorConnection({
    bool tryRestore = false,
  }) {
    _isConnected = false;
    _isRegistered = false;
    if (tryRestore) {
      _restoreUserSession();
    }
  }

  Future<void> _restoreUserSession() async {
    if (_callState == CallState.onCall) return;
    final readyResult = await ApiService.userReady();
    if (readyResult['success'] == true) {
      final retryResult = await ApiService.userConnection();
      connectionData = retryResult['data'] as Map<String, dynamic>?;
      if (retryResult['success'] == true &&
          retryResult['data']['isUserLogin'] == true &&
          retryResult['data']['status'] != 'poor connection') {
        _isConnected = true;
        _emit(SipEvent.connectionRestored);
        return;
      }
    }
    // Restore failed — keep disconnected, try again next cycle
  }

  void _startConnectionCheck() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(const Duration(seconds: 10), (
      _,
    ) async {
      // Don't run recovery logic during an active call
      if (_callState == CallState.onCall) return;

      final result = await ApiService.userConnection();
      connectionData = result['data'] as Map<String, dynamic>?;
      if (result['success'] == true) {
        final msg = result['data']['message'];

        if (msg == 'poor connection problem ,please login again') {
          _handlePoorConnection(tryRestore: true);
        } else if (result['data']['isUserLogin'] == false) {
          final readyResult = await ApiService.userReady();
          final retryResult = await ApiService.userConnection();
          if (retryResult['success'] == true &&
              retryResult['data']['isUserLogin'] == true) {
            if (!_isConnected) {
              _isConnected = true;
              _emit(SipEvent.connectionRestored);
            }
          } else {
            _connectionCheckTimer?.cancel();
            _isConnected = false;
            _isRegistered = false;
            _helper.stop();
            _emit(SipEvent.connectionLost, data: {'reason': 'session_expired'});
          }
        } else {
          if (!_isConnected) {
            _isConnected = true;
            _emit(SipEvent.connectionRestored);
          }
        }
      } else {
        _log('Connection check request failed', data: result);
      }
    });
  }

  // ─── Play Remote Audio (Web only) ──────────────────────────────────────────

  void _playRemoteAudio(dynamic stream) {
    try {
      playRemoteAudio(stream);
    } catch (e) {
      _log('Failed to play remote audio', data: {'error': e.toString()});
    }
  }

  // ─── Send SIP BYE (end call) ──────────────────────────────────────────────

  Future<void> endCall() async {
    final call = _activeCall;
    if (call != null) {
      try {
        call.session.terminate();
      } catch (e) {
        _log('Exception during session.terminate: $e');
      }
    }
    await _onCallEnded();
  }

  // ─── Answer Incoming Call ─────────────────────────────────────────────────

  void answerCall() {
    final call = _activeCall;
    if (call != null) {
      _log('Answering SIP call');
      call.answer({'audio': true, 'video': false});
      _loadCallContext();
    } else {
      _log('No active SIP call — calling agentAvailable to trigger INVITE');
      _pendingAnswerForQueue = true;
      ApiService.agentAvailable();
    }
  }

  void rejectCall() {
    final call = _activeCall;
    if (call != null) {
      try {
        call.session.terminate();
      } catch (e) {
        _log('Exception during reject/terminate: $e');
      }
    }
    _onCallEnded();
    _emit(SipEvent.callFailed, data: {'reason': 'rejected'});
  }

  // ─── Call Control ─────────────────────────────────────────────────────────

  void toggleMute() {
    final call = _activeCall;
    if (call == null) return;
    try {
      if (_isMuted) {
        call.unmute();
      } else {
        call.mute();
      }
      _isMuted = !_isMuted;
    } catch (e) {
      _log('Exception during mute/unmute: $e');
    }
  }

  Future<void> toggleHold() async {
    final call = _activeCall;
    if (call == null) return;
    try {
      if (_isHeld) {
        call.unhold();
        await ApiService.reqUnHold();
      } else {
        call.hold();
        await ApiService.reqHold();
      }
      _isHeld = !_isHeld;
    } catch (e) {
      _log('Exception during hold/unhold: $e');
    }
  }

  void sendDTMF(String tone) {
    final call = _activeCall;
    if (call == null) return;
    try {
      call.sendDTMF(tone);
    } catch (e) {
      _log('Exception during sendDTMF: $e');
    }
  }

  dynamic get remoteStream => _remoteStream;
  bool get isMuted => _isMuted;
  bool get isHeld => _isHeld;
  sip.Call? get activeCall => _activeCall;

  // ─── Disconnect ───────────────────────────────────────────────────────────

  void disconnect() {
    _connectionCheckTimer?.cancel();
    _helper.stop();
    _isConnected = false;
    _isRegistered = false;
    _callState = CallState.idle;
    _activeCall = null;
  }

  void dispose() {
    disconnect();
    _eventController.close();
  }
}
