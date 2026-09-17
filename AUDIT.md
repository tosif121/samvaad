# Samvaad — Full Bug Audit

Date: 2026-09-15 · Branch: `audio-call` · Analyzer: clean
30 issues, ordered most-critical first. No code changed for this audit.

## CRITICAL

1. `lib/services/sip_socket_service.dart:417-425,488-493` — REGISTRATION_FAILED stops the heartbeat but never schedules a reconnect; the app sits unregistered forever while the socket stays connected (wrong password / 401) until manual restart.
2. `lib/services/sip_socket_service.dart:2516` — `shouldAutoAnswerNextCall` is latched true on dial and only cleared on failure; if the INVITE never arrives, the next unrelated incoming call auto-answers without user consent.
3. `lib/screens/dialpad_screen.dart:1499-1507` — logout keeps `token` plus plaintext `savedUsername`/`savedPassword` in prefs; a later auto-login can silently resurrect the "logged out" session.
4. `lib/services/sip_socket_service.dart:448-458` — WebSocket DISCONNECT does not stop the 10s REST poll, so the backend still sees the agent as ready though no INVITE can arrive.
5. `lib/screens/dialpad_screen.dart:789-812` — `_onCallPressed` sets `_isOnCall = true` before the network calls with no timeout/failure reset; if `/dialnumber` succeeds but the INVITE never arrives, the UI is stuck on the in-call screen.

## HIGH

6. `lib/services/sip_socket_service.dart:912-921` — `makeCall` checks `_isRegistered` synchronously right after `connect()`; registration completes async, so first-tap calls almost always fail with `not_registered` (user must tap twice).
7. `lib/screens/dialpad_screen.dart:721-731` — denying mic permission when answering leaves the ringtone running and the SIP session un-rejected; the phone rings forever with no UI.
8. `lib/services/sip_socket_service.dart:1830-1864` — queue-fallback ring never sets `_incomingNumber`; reject uses a stale/empty number, so the backend queue entry is never cleared and the same caller re-rings in a loop.
9. `lib/services/sip_socket_service.dart:848-905` — `answerCall` clears `_isAnswering` right after sync `answer()`, so double-tap answers twice; the catch path emits `callFailed` but never finishes, leaving the UI stuck on the incoming screen.
10. `lib/services/sip_socket_service.dart:1529-1554` — `_handleAuthFailure` only emits `connectionLost`; polling continues with the dead token and re-emits logout UI roughly every 10s, with no token refresh anywhere.
11. `lib/services/fcm_service.dart:227`, `lib/screens/login_screen.dart:103`, `lib/main.dart:36` — `FcmService.init()` runs at startup AND on every login with no guard; listeners duplicate, causing double ringing and duplicate notifications per push.
12. `android/.../MyFirebaseMessagingService.kt:18-24` + `lib/services/fcm_service.dart:19-66` — the same FCM is handled natively AND by the Dart background handler, producing two banners and overlapping ringtones; dismissing one leaves the other.
13. `lib/services/fcm_service.dart:241-248`, `lib/screens/dialpad_screen.dart:405-411`, `android/.../MainActivity.kt:232-238` — notification-tap payload is written but never read (no `getInitialMessage` / `onMessageOpenedApp`); tapping from background/killed opens the app but never shows the incoming-call screen.
14. `lib/screens/dialpad_screen.dart:2434-2437` — Leads "Today" filter sets `startDate = now` (not midnight), so the list is ~empty and default-filter auto-dial dials nothing.
15. `lib/screens/dialpad_screen.dart:799,3313` — `setState` after `await` in `_onCallPressed` / `_callBackNumber` with no `mounted` check → setState-after-dispose crash.
16. `lib/screens/dialpad_screen.dart:741-746` — a caller hanging up while the incoming dialog rings blacklists them for 15s; legitimate immediate retries are auto-rejected.
17. `lib/screens/login_screen.dart:51-64` + `lib/screens/dialpad_screen.dart:1520-1526` — an "already login" response during recovery permanently deletes the saved username/password, forcing manual re-entry though the credentials were correct.
18. `lib/services/fcm_service.dart:127-135,186-194` — empty `adminuser` silently falls back to `"devapp"` while endpoints target `app.samvaad.io`; the token registers under the wrong tenant and call pushes never arrive.
19. `lib/services/sip_socket_service.dart:1451-1469` — the heartbeat calls `fetchRecentCalls()` (~every 30s), which replaces the list with page 1; a user on page 2/3 is yanked back, and one malformed response wipes the list.
20. `lib/services/fcm_service.dart:334` vs `:35-38` — the foreground handler ignores `video_call` pushes that the background handler rings for; a video push while the app is open stays silent.

## MEDIUM

21. `lib/services/sip_socket_service.dart:1600-1607` — duration math records calls under ~100s as hours (`diff = 30000` treated as seconds).
22. `lib/services/sip_socket_service.dart:465-486` — backoff reconnect and the CONNECTING watchdog share one timer and cancel each other during flapping.
23. `lib/services/sip_socket_service.dart:189-212` — headless push with null args throws `TypeError` over the channel; foreground binds send an empty `callId`.
24. `lib/services/sip_socket_service.dart:2728-2740` — `disconnect()` leaves `_bridgeID`, `_pendingPushCallId`, and `_incomingNumber` stale; the next session can reuse the old call's bridgeID.
25. `lib/services/callkit_service.dart:83-112` — `listenCallEvents` never stores/cancels its subscription (duplicate handlers per wiring); `endCurrentCall` calls `endAllCalls()`.
26. `lib/services/sip_socket_service.dart:2421-2434` — the 10s heartbeat callback is `async` with no re-entrancy guard; `sendUserReady` alone can take ~16s, producing overlapping POST storms.
27. SIP heartbeat always reports success — `sendMessage` constructs synchronously while async 4xx/delivery failure is never checked.
28. `lib/screens/dialpad_screen.dart:1051-1052` — `_autoDialedPhones` is never cleared; a failed auto-dial number is never retried for the rest of the session.
29. `lib/screens/dialpad_screen.dart:773-775` — tapping Call with empty input bumps `_autoDialGeneration`, silently killing a pending auto-dial countdown.
30. `lib/screens/dialpad_screen.dart:736-740` — a call answered elsewhere sets `_isOnCall` with no `_activeCallNumber`, log entry, or notification, unlike the normal answer path.

## Smaller (confirmed, lower impact)

- Missed-call stats row uses the ungrouped list while rows are grouped (counts disagree).
- String-format missed calls are dropped by `_missedMatchesCampaign`.
- Lead search misses `number` / `phone_number` keys that display/auto-dial read.
- Incoming calls suppressed while busy/on break/in disposition leave no local missed-call record.
- Overdue (pre-today, non-active) callbacks vanish instead of rendering overdue.
- Cancelling the disposition follow-up scheduler traps the agent with no feedback.
- Permissions flag is persisted before the request runs, so denials are never re-prompted.
- `cancelAll()` on resume kills the ongoing-call and disposition-reminder notifications.
- Cold start trusts stale `sip_credentials` and never attempts silent re-login.
- Empty-username FCM path returns silently with zero diagnostics.
- iOS/macOS still use `com.example.samvaad`; MethodChannel still `com.example.samvaad/ringtone`.
- `jsonDecode(response.body)` runs before status/body validation in login.
