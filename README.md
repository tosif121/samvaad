# Samvaad

Samvaad is a robust Flutter SIP client application that supports both audio and video calls. It is designed to work seamlessly with SIP servers like Asterisk, providing native calling experiences on Android and iOS devices.

## Features

### Calling Core
- **SIP Audio & Video Calling**: Built on top of `dart-sip-ua`, optimized for WebRTC with strict H.264 codec constraints for robust compatibility with Asterisk.
- **Native Incoming Call UI**: Integrates with `flutter_callkit_incoming` and custom native Android bridging to display standard incoming call screens even when the app is in the background or closed.
- **Permissions Management**: Auto-handles essential permissions (Microphone and Camera) natively upon login or call initiation to avoid interruptions.
- **Background Support**: Includes Android native foreground services for maintaining WebRTC sockets and receiving incoming push notifications consistently.
- **Rich Call Controls**: Mute/Unmute microphone, toggle camera on/off, and switch between front and rear cameras seamlessly during an active call.

### Agent Dashboard
- **Dialer**: Call any number via the backend (`/dialnumber` autodial with SIP auto-answer); lead calls include the `leadId`/`autoLeadDial` payload so the server updates the lead's `lastDialedStatus`.
- **Leads Tab**: Lead queue from `/leadswithdaterange` with date filters (Today / 7 / 30 days / All Time), search by name or number, and a summary row (Total Leads, Not Dialed, Dialed Not Picked, Answered). Status and Dial Status are derived from `lastDialedStatus` exactly like the webphone (`Pending/Contacted/Completed` and `Not Dialed/Dialed Not Picked/Answered`).
- **Auto-Dial Mode**: Toggle Active/Paused from the Leads badge or Settings. When Active, after each call the next un-dialed lead is dialed after a configurable countdown (3–30s), the app returns to the Leads tab, and each lead is dialed at most once per session (server status + local skip set). Defaults to Paused.
- **Recent Calls**: Server-backed call history from `/reports/calls/byAgent` (last 30 days) merged with locally-logged calls, grouped by day with swipe-to-delete and clear-all; times shown in 12-hour format using the API timestamp when present, plus a stats row (Total / Incoming / Outgoing / Avg Duration).
- **Missed Calls**: Polled every 30s from `/userMissedCalls/{username}`, grouped by caller with one-tap call-back (`/dialmissedcall`); 12-hour timestamps from the API when available.
- **Follow-up Calls**: Scheduled callbacks parsed from `followUpDispoes` (`/userconnection`), with call-back that marks them complete (`/callback/update-status`).
- **Take Break**: Break options loaded from the login token (`userData.breakoptions`) with contextual icons and a live elapsed timer; set/remove via the `/user/breakuser:{username}` and `/user/removebreakuser:{username}` endpoints.
- **Call Disposition**: Post-call disposition sheet with auto-dispose fallback (`Auto Disposed`); when webforms are enabled a mandatory contact form (dynamic form, or a static UserCall-style form) is shown first.
- **Call Source / Contact Info**: Dial-source modal and contact info surfaced from the call context API.

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

### Building a Release APK

```bash
flutter build apk --release
```

The APK is produced at `build/app/outputs/flutter-apk/app-release.apk`.

## Important Notes

- **Video Codecs**: This application specifically munges the SDP to enforce the **H.264** video codec, as VP8 is currently unsupported in the target Asterisk environments.
- **Permissions**: Make sure you have granted the required `Microphone` and `Camera` access when prompted, otherwise calls will fail to connect.
