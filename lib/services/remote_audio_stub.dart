// Stub implementation for native platforms (Android/iOS).
// On native, flutter_webrtc automatically routes remote audio through the device audio system.

void playRemoteAudio(dynamic stream) {
  // No-op: native WebRTC handles audio output automatically
}

void removeRemoteAudio() {
  // No-op
}
