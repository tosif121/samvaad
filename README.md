# Samvaad

Samvaad is a robust Flutter SIP client application that supports both audio and video calls. It is designed to work seamlessly with SIP servers like Asterisk, providing native calling experiences on Android and iOS devices.

## Features

- **SIP Audio & Video Calling**: Built on top of `dart-sip-ua`, optimized for WebRTC with strict H.264 codec constraints for robust compatibility with Asterisk.
- **Native Incoming Call UI**: Integrates with `flutter_callkit_incoming` and custom native Android bridging to display standard incoming call screens even when the app is in the background or closed.
- **Permissions Management**: Auto-handles essential permissions (Microphone and Camera) natively upon login or call initiation to avoid interruptions.
- **Background Support**: Includes Android native foreground services for maintaining WebRTC sockets and receiving incoming push notifications consistently.
- **Rich Call Controls**: Mute/Unmute microphone, toggle camera on/off, and switch between front and rear cameras seamlessly during an active call.

## Getting Started

### Prerequisites

- Flutter SDK (latest stable version recommended)
- A configured SIP Server (e.g., Asterisk) that supports WebRTC, WSS transport, and H.264 video codec.

### Installation

1. Clone this repository.
2. Run `flutter pub get` to fetch all dependencies.
3. Configure your SIP credentials in the login flow (e.g. extension, password, WSS URL).

### Running the App

```bash
flutter run
```

## Important Notes

- **Video Codecs**: This application specifically munges the SDP to enforce the **H.264** video codec, as VP8 is currently unsupported in the target Asterisk environments.
- **Permissions**: Make sure you have granted the required `Microphone` and `Camera` access when prompted, otherwise calls will fail to connect.
