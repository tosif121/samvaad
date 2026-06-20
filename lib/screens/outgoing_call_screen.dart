import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/api_service.dart';
import '../services/sip_socket_service.dart';
import '../widgets/dial_button.dart';
import '../services/ringtone_service.dart';

class OutgoingCallScreen extends StatefulWidget {
  final String phoneNumber;

  const OutgoingCallScreen({super.key, required this.phoneNumber});

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  final SipSocketService _sip = SipSocketService();

  bool _isConnected = false;
  bool _showKeypad = false;
  bool _isSpeakerOn = false;
  bool _conferenceStatus = false;
  bool _isMerged = false;
  bool _showConferenceKeypad = false;
  bool _isEndingCall = false;
  String _conferenceNumber = '';
  String? _conferenceBridgeID;
  int _seconds = 0;
  StreamSubscription? _sipSubscription;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    print('[OUTGOING] initState for number: ${widget.phoneNumber}');
    RingtoneService().stopRinging();
    Helper.setSpeakerphoneOn(false);

    if (_sip.callState == CallState.onCall) {
      print('[OUTGOING] Already onCall, loading context');
      _isConnected = true;
      _loadCallContext();
    } else {
      print('[OUTGOING] Waiting for SIP callAnswered event');
    }

    _sipSubscription = _sip.events.listen((event) {
      if (!mounted) return;
      final type = event['event'] as String;
      print('[OUTGOING] SIP event: $type');
      final data = event['data'] as Map<String, dynamic>?;

      switch (type) {
        case 'callAnswered':
          if (!_isConnected) {
            setState(() => _isConnected = true);
            _loadCallContext();
          }
          break;
        case 'callEnded':
        case 'callFailed':
          if (!_isEndingCall) Navigator.of(context).pop();
          break;
      }

      // Handle conference socket messages from ARI
      if (data != null && data['message'] is String) {
        final msg = data['message'] as String;
        if (msg.contains('customer host channel connected')) {
          setState(() {
            _conferenceStatus = true;
            _showConferenceKeypad = false;
          });
        } else if (msg.contains('customer host channel disconnected')) {
          setState(() => _conferenceStatus = false);
          if (!_isMerged) _toggleHold();
        }
      }
    });
  }

  @override
  void dispose() {
    _sipSubscription?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadCallContext() async {
    final result = await ApiService.userOnCall();
    if (result['success'] == true && mounted) {
      setState(() => _isConnected = true);
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && _isConnected) {
        setState(() => _seconds++);
      } else {
        timer.cancel();
      }
    });
  }

  String get _formattedTime {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _toggleMute() {
    _sip.toggleMute();
    setState(() {});
  }

  Future<void> _toggleHold() async {
    await _sip.toggleHold();
    setState(() {});
  }

  Future<void> _startConferenceCall() async {
    if (_conferenceNumber.isEmpty) return;
    await _sip.toggleHold();
    await Future.delayed(const Duration(seconds: 1));
    final result = await ApiService.reqConf(
      _conferenceNumber,
      bridgeID: _sip.bridgeID,
    );
    final msg = result['data']?['message'] as String? ?? '';
    final success = result['success'] == true && !msg.contains('error');
    if (success) {
      setState(() {
        _conferenceStatus = true;
        _showConferenceKeypad = false;
        _conferenceBridgeID = _sip.bridgeID;
      });
    } else {
      await _sip.toggleHold();
    }
  }

  Future<void> _mergeConference() async {
    await _sip.toggleHold();
    setState(() => _isMerged = true);
  }

  Future<void> _disconnectConference() async {
    if (_conferenceNumber.isEmpty) return;
    await ApiService.hangupConference(_conferenceNumber);
    setState(() {
      _conferenceStatus = false;
      _conferenceNumber = '';
      _conferenceBridgeID = null;
      _isMerged = false;
      _showConferenceKeypad = false;
    });
    if (!_isMerged) await _sip.toggleHold();
  }

  Future<void> _endCall() async {
    _isEndingCall = true;
    if (_conferenceStatus) {
      await _disconnectConference();
    }
    await _sip.endCall();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            // Avatar
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF4299EB).withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF4299EB).withValues(alpha: 0.4),
                  width: 3,
                ),
              ),
              child: const Icon(
                Icons.person,
                size: 42,
                color: Color(0xFF4299EB),
              ),
            ),
            const SizedBox(height: 16),
            // Phone number
            Text(
              widget.phoneNumber,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1a1a1a),
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 6),
            // Status / timer
            if (_conferenceStatus)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _isMerged ? 'Merged' : 'Conference',
                    style: const TextStyle(fontSize: 13, color: Colors.orange, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            SizedBox(height: _conferenceStatus ? 4 : 0),
            _isConnected
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.access_time, size: 16, color: Colors.green),
                        const SizedBox(width: 6),
                        Text(
                          _formattedTime,
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.green,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF4299EB)),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Calling...',
                        style: TextStyle(fontSize: 16, color: Colors.grey[600], fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
            const Spacer(),
            // Controls
            if (_showConferenceKeypad)
              _buildConferenceKeypad()
            else if (_conferenceStatus)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildControlButton(
                          icon: Icons.call_merge,
                          label: 'Merge',
                          enabled: !_isMerged,
                          onPressed: _mergeConference,
                        ),
                        _buildControlButton(
                          icon: Icons.call_end,
                          label: 'Disconnect Conf',
                          isActive: true,
                          onPressed: () {
                            _disconnectConference();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else if (!_showKeypad)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    // Primary Controls Row: Hold, Transfer, Keypad
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildControlButton(
                            icon: _sip.isHeld ? Icons.play_arrow : Icons.pause,
                            label: _sip.isHeld ? 'Resume' : 'Hold',
                            isActive: _sip.isHeld,
                            onPressed: _toggleHold,
                          ),
                          _buildControlButton(
                            icon: Icons.phone_forwarded,
                            label: 'Transfer',
                            isActive: false,
                            enabled: _sip.bridgeID.isNotEmpty,
                            onPressed: () {},
                          ),
                          _buildControlButton(
                            icon: Icons.dialpad,
                            label: 'Keypad',
                            onPressed: () => setState(() => _showKeypad = true),
                          ),
                        ],
                      ),
                    ),
                    // Secondary Controls Row: Add Call, Mute, Speaker
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildControlButton(
                          icon: Icons.person_add,
                          label: 'Add Call',
                          enabled: _isConnected,
                          onPressed: () => setState(() {
                            _showConferenceKeypad = true;
                            _conferenceNumber = '';
                          }),
                        ),
                        _buildControlButton(
                          icon: _sip.isMuted ? Icons.mic_off : Icons.mic,
                          label: _sip.isMuted ? 'Unmute' : 'Mute',
                          isActive: _sip.isMuted,
                          onPressed: _toggleMute,
                        ),
                        _buildControlButton(
                          icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                          label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                          isActive: _isSpeakerOn,
                          onPressed: () async {
                            final newVal = !_isSpeakerOn;
                            await Helper.setSpeakerphoneOn(newVal);
                            setState(() => _isSpeakerOn = newVal);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              _buildKeypad(),
            // End call button (hidden during add-to-call keypad)
            if (!_showConferenceKeypad) const SizedBox(height: 16),
            if (!_showConferenceKeypad)
              GestureDetector(
                onTap: _endCall,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.redAccent.withValues(alpha: 0.4),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.call_end, color: Colors.white, size: 32),
                ),
              ),
            if (!_showConferenceKeypad) const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    bool isActive = false,
    bool enabled = true,
    VoidCallback? onPressed,
  }) {
    return GestureDetector(
      onTap: enabled ? onPressed : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: isActive ? const Color(0xFF4299EB) : Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(
                icon,
                size: 24,
                color: isActive ? Colors.white : const Color(0xFF4299EB),
              ),
            ),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          ],
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          _buildDtmfRow(['1', '2', '3']),
          const SizedBox(height: 4),
          _buildDtmfRow(['4', '5', '6']),
          const SizedBox(height: 4),
          _buildDtmfRow(['7', '8', '9']),
          const SizedBox(height: 4),
          _buildDtmfRow(['*', '0', '#']),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => setState(() => _showKeypad = false),
            icon: const Icon(Icons.keyboard_hide, size: 18),
            label: const Text('Hide Keypad'),
          ),
        ],
      ),
    );
  }

  Widget _buildDtmfRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits
          .map((d) => DialButton(digit: d, onPressed: () => _sip.sendDTMF(d)))
          .toList(),
    );
  }

  Widget _buildConferenceKeypad() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Close button at top
          Align(
            alignment: Alignment.topRight,
            child: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _showConferenceKeypad = false),
              color: Colors.grey[600],
            ),
          ),
          // Number display row with backspace (matches dialpad screen)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Center(
                    child: Text(
                      _conferenceNumber.isEmpty ? 'Enter number' : _conferenceNumber,
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w500,
                        color: _conferenceNumber.isEmpty
                            ? Colors.grey[400]
                            : const Color(0xFF1a1a1a),
                        letterSpacing: 2,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                if (_conferenceNumber.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.backspace_outlined),
                    onPressed: () => setState(
                      () => _conferenceNumber = _conferenceNumber.substring(
                        0,
                        _conferenceNumber.length - 1,
                      ),
                    ),
                    color: Colors.grey[600],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _buildConfDialRow(['1', '2', '3']),
          const SizedBox(height: 4),
          _buildConfDialRow(['4', '5', '6']),
          const SizedBox(height: 4),
          _buildConfDialRow(['7', '8', '9']),
          const SizedBox(height: 4),
          _buildConfDialRow(['*', '0', '#']),
          const SizedBox(height: 8),
          // Green call button centered
          GestureDetector(
            onTap: _conferenceNumber.isNotEmpty ? _startConferenceCall : null,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: _conferenceNumber.isNotEmpty ? Colors.green : Colors.grey[300],
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.green.withValues(alpha: _conferenceNumber.isNotEmpty ? 0.4 : 0),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(Icons.call, color: Colors.white, size: 28),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfDialRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits
          .map((d) => DialButton(digit: d, onPressed: () {
                if (_conferenceNumber.length < 10) {
                  setState(() => _conferenceNumber += d);
                }
              }))
          .toList(),
    );
  }
}
