// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

void playRemoteAudio(dynamic stream) {
  final tracks = stream.getAudioTracks();
  if (tracks.isEmpty) return;

  // Remove previous audio element if any
  final existing = html.document.getElementById('sip_remote_audio');
  existing?.remove();

  final audio = html.AudioElement()
    ..autoplay = true
    ..id = 'sip_remote_audio';
  html.document.body?.append(audio);

  // Access the underlying JS MediaStream from the dart_webrtc MediaStreamWeb
  final jsStream = (stream as dynamic).jsStream;
  (audio as dynamic).srcObject = jsStream;
}

void removeRemoteAudio() {
  final audio = html.document.getElementById('sip_remote_audio');
  audio?.remove();
}
