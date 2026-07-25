import 'dart:developer';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:uuid/uuid.dart';

class CallKitService {
  static final CallKitService _instance = CallKitService._internal();
  factory CallKitService() => _instance;
  CallKitService._internal();

  String? _currentCallId;
  bool isCallKitAnswering = false;

  Future<void> showIncomingCall({
    required String callerName,
    required String callerNumber,
    String? callId,
  }) async {
    final String uuid = (callId != null && callId.isNotEmpty) ? callId : const Uuid().v4();
    _currentCallId = uuid;

    final CallKitParams params = CallKitParams(
      id: uuid,
      nameCaller: callerName.isNotEmpty ? callerName : 'Incoming Call',
      appName: 'Samvaad',
      avatar: 'assets/app_icon.png',
      handle: callerNumber.isNotEmpty ? callerNumber : 'Samvaad Call',
      type: 0, // 0: Audio Call, 1: Video Call
      duration: 40000,
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: false,
        subtitle: 'Missed Call',
      ),
      extra: <String, dynamic>{
        'callerName': callerName,
        'callerNumber': callerNumber,
      },
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#095D40',
        actionColor: '#4CAF50',
        textColor: '#FFFFFF',
        isShowCallID: true,
      ),
      ios: const IOSParams(
        iconName: 'AppIcon',
        handleType: 'generic',
        supportsVideo: true,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: true,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
      ),
    );

    log('[CALLKIT_SERVICE] Triggering WhatsApp-style CallKit UI for $callerName ($uuid)');
    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  Future<void> endCurrentCall() async {
    isCallKitAnswering = false;
    if (_currentCallId != null) {
      log('[CALLKIT_SERVICE] Ending CallKit UI for $_currentCallId');
      await FlutterCallkitIncoming.endCall(_currentCallId!);
      _currentCallId = null;
    }
    await FlutterCallkitIncoming.endAllCalls();
  }

  void listenCallEvents({
    required Function(String callerNumber, String callerName) onAccept,
    required Function() onDecline,
  }) {
    FlutterCallkitIncoming.onEvent.listen((CallEvent? event) {
      if (event == null) return;
      log('[CALLKIT_SERVICE] Event: ${event.eventName}');

      if (event is CallEventActionCallAccept) {
        log('[CALLKIT_SERVICE] User tapped ACCEPT');
        isCallKitAnswering = true;
        final extra = event.callKitParams.extra ?? {};
        final callerNumber = extra['callerNumber'] ?? event.callKitParams.handle ?? '';
        final callerName = extra['callerName'] ?? event.callKitParams.nameCaller ?? '';
        onAccept(callerNumber.toString(), callerName.toString());
      } else if (event is CallEventActionCallDecline) {
        log('[CALLKIT_SERVICE] User tapped DECLINE');
        isCallKitAnswering = false;
        onDecline();
        endCurrentCall();
      } else if (event is CallEventActionCallEnded || event is CallEventActionCallTimeout) {
        log('[CALLKIT_SERVICE] Call ended or timed out');
        isCallKitAnswering = false;
        endCurrentCall();
      }
    });
  }

  Future<Map<String, String>?> getAcceptedCallInfo() async {
    try {
      final List<dynamic> calls = await FlutterCallkitIncoming.activeCalls();
      if (calls.isNotEmpty) {
        final Map<String, dynamic> activeCall = Map<String, dynamic>.from(calls.first as Map);
        final extra = Map<String, dynamic>.from(activeCall['extra'] as Map? ?? {});
        final callerNumber = extra['callerNumber'] ?? activeCall['handle'] ?? '';
        final callerName = extra['callerName'] ?? activeCall['nameCaller'] ?? '';
        return {
          'callerNumber': callerNumber.toString(),
          'callerName': callerName.toString(),
        };
      }
    } catch (e) {
      log('[CALLKIT_SERVICE] Error fetching active calls: $e');
    }
    return null;
  }
}
