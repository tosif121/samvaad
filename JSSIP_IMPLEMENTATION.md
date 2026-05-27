# JsSIP Implementation Analysis for Flutter

## Overview
The webphone uses JsSIP (JavaScript SIP library) for WebRTC-based calling. For Flutter mobile app, we need to use a native SIP library.

## Key API Endpoints:

### 1. **User Ready API**
```
POST https://app.samvaad.io/userready/{username}/Web
Headers: Authorization: Bearer {token}
Body: {}
Response: { message: "success" }
```
- Called after login to sync agent state
- Sets agent as ready to receive calls
- Should be called periodically to maintain ready state

### 2. **Dial Number API**
```
POST https://app.samvaad.io/dialnumber
Headers: 
  - Authorization: Bearer {token}
  - Content-Type: application/json
  - X-User-ID: {username}
Body: {
  receiver: "phone_number",
  leadLockToken: "optional_token",
  leadId: "optional_lead_id"
}
Response: { success: true/false, message: "..." }
```
- Initiates outgoing call
- Returns success/failure status
- May return "Agent is not in a ready state" error

### 3. **User Connection API**
```
POST https://app.samvaad.io/userconnection
Headers: Authorization: Bearer {token}
Body: { user: "username" }
Response: {
  message: "ok connection for user",
  isUserLogin: true,
  status: "NOT_INUSE" | "INUSE" | "Disposition" | "UNAVAILABLE",
  followUpDispoes: [],
  currentCallqueue: [],
  conferenceCalls: []
}
```
- Checks connection status
- Returns agent status and queue information
- Should be called periodically (every 5-10 seconds)

### 4. **User On Call API**
```
POST https://app.samvaad.io/useroncall/{username}
Headers: Authorization: Bearer {token}
Body: { leadLockToken: "optional" }
Response: {
  currentcalldata: { bridgeID: "...", ... },
  contactData: { ... }
}
```
- Called when call is connected
- Returns call context and contact information
- Provides bridgeID for call tracking

### 5. **Call Ended API**
```
POST https://app.samvaad.io/user/callended{username}
Headers: Authorization: Bearer {token}
Body: { leadLockToken: "optional" }
```
- Called when call ends
- Triggers post-call workflow

### 6. **Disposition API**
```
POST https://app.samvaad.io/user/disposition{username}
Headers: Authorization: Bearer {token}
Body: {
  bridgeID: "call_bridge_id",
  Disposition: "disposition_value",
  autoDialDisabled: false
}
```
- Submits call disposition
- Required after call ends

## Call Flow:

### Outgoing Call:
1. User enters number and presses call
2. Call `POST /dialnumber` with phone number
3. If successful, JsSIP receives incoming SIP call (autodial)
4. Answer the SIP call automatically
5. When confirmed, call `POST /useroncall/{username}`
6. Show call screen with timer
7. When call ends, call `POST /user/callended{username}`
8. On mobile: Auto-dispose with "Auto Disposed"
9. Return to dialpad

### Incoming Call:
1. JsSIP receives SIP INVITE
2. Check if it's autodial (from dialnumber API)
3. If autodial: Auto-answer
4. If real incoming: Show incoming call screen
5. User accepts → Answer SIP call
6. Call `POST /useroncall/{username}`
7. Show call screen
8. Follow same end flow as outgoing

## Agent Lifecycle States:
- `idle` - Ready for calls
- `dialing` - Outgoing call initiated
- `ringing` - Incoming call ringing
- `on_call` - Active call
- `disposition` - Post-call wrap-up
- `lead_locked` - Working on a lead

## Flutter Implementation Plan:

### Required Package
```yaml
dependencies:
  sip_ua: ^0.5.7  # Flutter SIP library
  permission_handler: ^11.3.0  # Microphone permissions
```

### Implementation Steps:

1. **After Login**:
   - Call `/userready/{username}/Web` to set agent as ready
   - Start periodic connection check (every 5-10 seconds)

2. **Dialpad Screen**:
   - User enters number
   - Press call button
   - Call `/dialnumber` API
   - Wait for SIP INVITE (autodial)
   - Auto-answer and show call screen

3. **Call Screen**:
   - Show timer, mute, speaker controls
   - When connected, call `/useroncall/{username}`
   - Store bridgeID for disposition

4. **Call End**:
   - Call `/user/callended{username}`
   - Auto-dispose with "Auto Disposed"
   - Return to dialpad

5. **Background Tasks**:
   - Periodic `/userconnection` check
   - SIP heartbeat messages
   - Handle connection loss

### Next Steps:
1. Implement auth service to get SIP credentials
2. Create SIP service for call handling
3. Implement call manager for state management
4. Add periodic connection checks
5. Handle call lifecycle events
