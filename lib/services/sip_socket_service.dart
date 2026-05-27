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

  // Stream controller for UI events
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  CallState get callState => _callState;
  String get incomingNumber => _incomingNumber;
  bool get isRegistered => _isRegistered;
  bool get isConnected => _isConnected;
  String get bridgeID => _bridgeID;

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

    _log('FULL USER DATA: $userData');
    _log('SIP USERNAME: $username');
    _log('SIP PASSWORD: $password');

    if (username == null || password == null) {
      _log('ERROR: Missing credentials for SIP connection');
      return;
    }

    _log('Connecting to WebSocket via sip_ua: wss://$_origin:8089/ws');
    _log('SIP URI: ${username.replaceAll('@', '-')}@$_origin:8089');

    try {
      sip.UaSettings settings = sip.UaSettings();
      settings.webSocketUrl = 'wss://$_origin:8089/ws';
      settings.uri = 'sip:${username.replaceAll('@', '-')}@$_origin:8089';
      settings.password = password;
      settings.authorizationUser = username.replaceAll('@', '-');
      settings.transportType = sip.TransportType.WS;
      settings.sessionTimers = false;

      _log('UA settings prepared', data: {
        'uri': settings.uri,
        'wsUrl': settings.webSocketUrl,
        'transport': settings.transportType?.name,
        'sessionTimers': settings.sessionTimers,
      });

      _log('Calling _helper.start()...');
      await _helper.start(settings);
      _log('_helper.start() completed successfully');
    } catch (e) {
      _log('_helper.start() threw exception', data: {'error': e.toString()});
    }

    // Start periodic REST API connection check every 10 seconds
    _startConnectionCheck();
  }

  // ─── SipListener Callbacks ────────────────────────────────────────────────

  @override
  void registrationStateChanged(sip.RegistrationState state) {
    _log('UA event: registrationStateChanged -> ${state.state}'
        '${state.cause != null ? ' | cause: ${state.cause}' : ''}');

    if (state.state == null) return;

    switch (state.state!) {
      case sip.RegistrationStateEnum.NONE:
        _isRegistered = false;
        break;
      case sip.RegistrationStateEnum.REGISTERED:
        _isRegistered = true;
        _log('SIP REGISTERED successfully');
        _emit(SipEvent.registered);
        _onRegistered();
        break;
      case sip.RegistrationStateEnum.UNREGISTERED:
        _log('SIP UNREGISTERED', data: {'cause': state.cause?.toString()});
        _isRegistered = false;
        break;
      case sip.RegistrationStateEnum.REGISTRATION_FAILED:
        _log('SIP REGISTRATION FAILED', data: {'cause': state.cause?.toString()});
        _isRegistered = false;
        _emit(SipEvent.registrationFailed, data: {'cause': state.cause?.toString()});
        break;
    }
  }

  @override
  void transportStateChanged(sip.TransportState state) {
    _log('UA event: transportStateChanged -> ${state.state}');

    switch (state.state) {
      case sip.TransportStateEnum.NONE:
      case sip.TransportStateEnum.CONNECTING:
        break;
      case sip.TransportStateEnum.CONNECTED:
        _log('WebSocket transport CONNECTED');
        _isConnected = true;
        break;
      case sip.TransportStateEnum.DISCONNECTED:
        _log('WebSocket transport DISCONNECTED');
        _isConnected = false;
        _isRegistered = false;
        _emit(SipEvent.connectionLost, data: {
          'reason': 'poor_connection',
          'error': 'Transport disconnected',
        });
        break;
    }
  }

  @override
  void callStateChanged(sip.Call call, sip.CallState state) {
    _log('SIP Call State: ${state.state}');
    _activeCall = call;
    
    switch (state.state) {
      case sip.CallStateEnum.CALL_INITIATION:
        if (call.direction == 'INCOMING') {
          final remoteNumber = call.remote_identity ?? 'Unknown';
          
          // Clean both numbers of any non-digit characters for a robust comparison
          final cleanRemote = remoteNumber.replaceAll(RegExp(r'\D'), '');
          final cleanDialed = _dialedNumber.replaceAll(RegExp(r'\D'), '');
          
          final isActuallyOutgoing = _callState == CallState.dialing || 
              (cleanDialed.isNotEmpty && (cleanRemote.contains(cleanDialed) || cleanDialed.contains(cleanRemote)));
          
          _log('CALL_INITIATION debug: remoteNumber=$remoteNumber, cleanRemote=$cleanRemote, _dialedNumber=$_dialedNumber, cleanDialed=$cleanDialed, isActuallyOutgoing=$isActuallyOutgoing');
          
          if (isActuallyOutgoing) {
            _log('Detected autodial leg for outgoing call to $_dialedNumber. Auto-answering...');
            _dialedNumber = ''; // Clear tracking
            _callState = CallState.onCall;
            
            // Answer call automatically (matches webphone behavior)
            _activeCall = call;
            call.answer({'audio': true, 'video': false});
            _emit(SipEvent.callAnswered);
            _loadCallContext();
          } else {
            _log('INCOMING CALL INITIATED from: $remoteNumber');
            _incomingNumber = remoteNumber;
            _callState = CallState.ringing;
            _emit(SipEvent.incomingCall, data: {'number': _incomingNumber});
          }
        }
        break;
      case sip.CallStateEnum.CONFIRMED:
        _log('Call ANSWERED / CONFIRMED');
        _callState = CallState.onCall;
        _emit(SipEvent.callAnswered);
        break;
      case sip.CallStateEnum.STREAM:
        if (state.originator == 'remote' && state.stream != null) {
          _remoteStream = state.stream;
          final tracks = state.stream!.getAudioTracks();
          _log('Remote stream received', data: {
            'audioTracks': tracks.length,
            'videoTracks': state.stream!.getVideoTracks().length,
          });
          _playRemoteAudio(state.stream!);
        }
        break;
      case sip.CallStateEnum.FAILED:
        _log('Call FAILED: ${state.cause}');
        _callState = CallState.idle;
        _emit(SipEvent.callFailed, data: {'reason': state.cause});
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
  void onNewNotify(sip.Notify notify) {
    _log('UA event: onNewNotify', data: {
      'method': notify.request?.method,
    });
  }

  @override
  void onNewReinvite(sip.ReInvite reinvite) {
    _log('UA event: onNewReinvite');
  }



  // ─── ARI Message Handler (matches webphone newMessage handler) ────────────

  void _handleAriMessage(String body) {
    if (body.contains('customer channel answered') ||
        body.contains('agent channel answered')) {
      _log('Customer/Agent channel ANSWERED');
      _callState = CallState.onCall;
      _emit(SipEvent.callAnswered, data: {'message': body});
      _loadCallContext();
    } else if (body.contains('customer channel disconnected')) {
      _log('Customer channel DISCONNECTED');
      _onCallEnded();
    } else if (body.contains('force_login_request') ||
        body.contains('Force Login Request')) {
      _log('Force login request received');
      _emit(SipEvent.connectionLost, data: {'reason': 'force_login'});
    } else {
      _log('Keepalive message received');
    }
  }

  // ─── After Registration ───────────────────────────────────────────────────

  Future<void> _onRegistered() async {
    _log('Running post-registration tasks...');
    final result = await ApiService.userReady();
    _log('userReady after registration: $result');

    final connResult = await ApiService.userConnection();
    if (connResult['success'] == true) {
      final msg = connResult['data']['message'];
      if (msg == 'poor connection problem ,please login again') {
        _log('Post-registration connection check failed');
        _handlePoorConnection();
      }
    }
  }

  // ─── Load Call Context ────────────────────────────────────────────────────

  Future<void> _loadCallContext() async {
    _log('Loading call context...');
    final result = await ApiService.userOnCall();
    if (result['success'] == true) {
      _bridgeID = result['data']?['currentcalldata']?['bridgeID'] ?? '';
      _log('Call context loaded. bridgeID: $_bridgeID');
    }
  }

  // ─── Call Ended ───────────────────────────────────────────────────────────

  Future<void> _onCallEnded() async {
    _log('Call ended. Cleaning up...');
    _callState = CallState.disposition;
    _emit(SipEvent.callEnded, data: {'bridgeID': _bridgeID});

    // Call ended API
    await ApiService.callEnded();

    if (_bridgeID.isNotEmpty) {
      await ApiService.submitDisposition(_bridgeID, 'Auto Disposed');
    }

    _callState = CallState.idle;
    _bridgeID = '';
    _incomingNumber = '';
    _isMuted = false;
    _isHeld = false;
    _remoteStream = null;
    _activeCall = null;

    removeRemoteAudio();
  }

  // ─── Connection Check (matches webphone CONNECTION_CHECK_SCHEDULER_MS = 5000) ─

  void _handlePoorConnection() {
    _connectionCheckTimer?.cancel();
    _isConnected = false;
    _isRegistered = false;
    _helper.stop();
    _emit(SipEvent.connectionLost, data: {'reason': 'poor_connection'});
  }

  void _startConnectionCheck() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(const Duration(seconds: 10), (
      _,
    ) async {
      _log('Running periodic connection check...');
      final result = await ApiService.userConnection();
      if (result['success'] == true) {
        final msg = result['data']['message'];
        final status = result['data']['status'];
        _log('Connection check: $msg | status: $status');

        if (msg == 'poor connection problem ,please login again') {
          _handlePoorConnection();
        } else if (result['data']['isUserLogin'] == false) {
          _connectionCheckTimer?.cancel();
          _isConnected = false;
          _isRegistered = false;
          _helper.stop();
          _emit(SipEvent.connectionLost, data: {'reason': 'session_expired'});
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
      _log('Remote audio element created and attached');
    } catch (e) {
      _log('Failed to play remote audio', data: {'error': e.toString()});
    }
  }

  // ─── Send SIP BYE (end call) ──────────────────────────────────────────────

  Future<void> endCall() async {
    _log('Ending call via sip_ua...');
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
    _log('Answering incoming call from $_incomingNumber');
    _activeCall?.answer({'audio': true, 'video': false});
    _callState = CallState.onCall;
    _emit(SipEvent.callAnswered, data: {'number': _incomingNumber});
    _loadCallContext();
  }

  void rejectCall() {
    _log('Rejecting incoming call from $_incomingNumber');
    final call = _activeCall;
    if (call != null) {
      try {
        call.session.terminate();
      } catch (e) {
        _log('Exception during reject/terminate: $e');
      }
    }
    _callState = CallState.idle;
    _incomingNumber = '';
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
      _log('Mute toggled: $_isMuted');
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
      _log('Hold toggled: $_isHeld');
    } catch (e) {
      _log('Exception during hold/unhold: $e');
    }
  }

  void sendDTMF(String tone) {
    final call = _activeCall;
    if (call == null) return;
    try {
      call.sendDTMF(tone);
      _log('DTMF sent: $tone');
    } catch (e) {
      _log('Exception during sendDTMF: $e');
    }
  }

  dynamic get remoteStream => _remoteStream;
  bool get isMuted => _isMuted;
  bool get isHeld => _isHeld;

  // ─── Disconnect ───────────────────────────────────────────────────────────

  void disconnect() {
    _log('Disconnecting SIP socket via sip_ua...');
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
