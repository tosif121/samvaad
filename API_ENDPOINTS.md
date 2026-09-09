# Samvaad API Endpoints Documentation

## Base URL
```
https://app.samvaad.io
```
> **Note:** The Flutter app uses `https://app.samvaad.io` (see `lib/services/sip_socket_service.dart`).

## Authentication
All authenticated endpoints require:
```
Headers:
  Authorization: Bearer {token}
  Content-Type: application/json
```

---

## 1. Authentication APIs

### Login
```http
POST /userlogin/{username}
```
**Body:**
```json
{
  "username": "string",
  "password": "string"
}
```
**Response:**
```json
{
  "token": "string",
  "userData": {
    "Name": "string",
    "Email": "string",
    "username": "string",
    "ExpiryDate": "ISO date string",
    "campaign": "string",
    "uiPreferences": {},
    "breakoptions": [
      { "value": "Lunch Break", "label": "Lunch Break", "type": "string", "name": "string", "id": "string" },
      { "value": "General Break", "label": "Break" }
    ]
  },
  "message": "success" | "wrong login info" | "User already login somewhere else"
}
```
> `breakoptions` drives the Take Break UI. Each option supplies a break **type** (`value`/`type`/`name`/`id`) and a display **label** (`label`/`name`/`title`/`value`/`type`). Falls back to `General Break` when absent.

### Logout
```http
DELETE /deleteFirebaseToken
Headers: Authorization: Bearer {token}
```

---

## 2. Agent Status APIs

### User Ready (Set Agent as Ready)
```http
POST /userready/{username}/Web
Headers: Authorization: Bearer {token}
Body: {}
```
**Response:**
```json
{
  "message": "success"
}
```
**Purpose:** Sets agent as ready to receive calls. Should be called:
- After login
- After SIP registration
- Periodically to maintain ready state

### User Connection (Check Connection Status)
```http
POST /userconnection
Headers: Authorization: Bearer {token}
Body: { "user": "username" }
```
**Response:**
```json
{
  "message": "ok connection for user" | "poor connection problem ,please login again",
  "isUserLogin": true,
  "status": "NOT_INUSE" | "INUSE" | "Disposition" | "UNAVAILABLE",
  "followUpDispoes": [],
  "currentCallqueue": [
    {
      "Caller": "phone_number",
      "campaign": "string",
      "queueDetail": {},
      "queueTransfered": boolean
    }
  ],
  "conferenceCalls": []
}
```
**Purpose:** 
- Check agent connection status
- Get queue information
- Get follow-up dispositions
- Should be called every 5-10 seconds

### Remove Break
```http
POST /user/removebreakuser:{username}
Headers: Authorization: Bearer {token}
Body: {}
```

### Set Break
```http
POST /user/breakuser:{username}
Headers: Authorization: Bearer {token}
Body: {
  "breakType": "Lunch Break"
}
```
> The route receives the user id with a leading `@` and strips it server-side — keep the colon form above. `breakType` values come from `userData.breakoptions`.

---

## 2.5 Missed Calls & Follow-ups

### Fetch Missed Calls
```http
POST /userMissedCalls/{username}
Headers: Authorization: Bearer {token}
Body: {}
```
**Response:**
```json
{
  "result": [
    {
      "Caller": "phone_number",
      "startTime": "1712500000000",
      "campaign": "string",
      "anstime": "string",
      "hanguptime": "string",
      "Type": "string"
    }
  ]
}
```
> `startTime` is an epoch-milliseconds string. The app polls this every 30 seconds and shows a badge for the current count.

### Dial Back a Missed Call
```http
POST /dialmissedcall
Headers: Authorization: Bearer {token}
Body: {
  "receiver": "phone_number"
}
```
**Response:**
```json
{
  "success": true,
  "CallID": "bridgeID"
}
```
**Purpose:** Calls back a missed caller. Server sends a SIP INVITE back to the agent (autodial); the app auto-answers and stores `CallID` as the bridge id.

### Update Callback Status
```http
POST /callback/update-status
Headers: Authorization: Bearer {token}
Body: {
  "callbackId": "string",
  "status": "completed"
}
```
**Purpose:** Marks a scheduled follow-up callback as completed (the callback `_id` from `followUpDispoes` in `/userconnection`).

### Recent Call History
```http
POST /reports/calls/byAgent
Headers: Authorization: Bearer {token}
Body: {
  "startDate": "YYYY-MM-DD",
  "endDate": "YYYY-MM-DD",
  "agentName": "username"
}
```
**Response:**
```json
{
  "result": [
    {
      "Caller": "phone_number",
      "Type": "incoming" | "manualoutgoing",
      "startTime": "epoch ms string",
      "anstime": "string",
      "hanguptime": "string",
      "duration": "seconds",
      "Disposition": "string",
      "bridgeID": "string",
      "campaign": "string",
      "agent": "username",
      "dialNumber": "string",
      "contactNumber": "string",
      "_id": "string",
      "status": "string"
    }
  ],
  "summary": {
    "incomingCalls": 0,
    "outgoingCalls": 0,
    "totalCalls": 0,
    "connectedCalls": 0,
    "avgDurationSeconds": 0
  }
}
```
**Purpose:** Backs the Recent tab "Call History". The app requests the last 30 days, maps records to local log entries, and merges them with locally-logged calls (deduped by `bridgeID`, else number + minute). Refreshed on SIP registration and every 30s alongside missed calls. No server-side paging.

---

## 3. Call Management APIs

### Dial Number (Initiate Outgoing Call)
```http
POST /dialnumber
Headers: 
  Authorization: Bearer {token}
  Content-Type: application/json
  X-User-ID: {username}
Body: {
  "receiver": "phone_number",
  "leadLockToken": "optional_token",
  "leadId": "optional_lead_id"
}
```
**Response:**
```json
{
  "success": true,
  "message": "Call initiated"
}
```
**Error Responses:**
```json
{
  "success": false,
  "message": "Agent is not in a ready state" | "Please Login again"
}
```
**Purpose:** Initiates outgoing call. Server will send SIP INVITE back to agent (autodial).

### User On Call (Get Call Context)
```http
POST /useroncall/{username}
Headers: Authorization: Bearer {token}
Body: { "leadLockToken": "optional" }
```
**Response:**
```json
{
  "currentcalldata": {
    "bridgeID": "string",
    "stickyAgent": "username",
    "isSticky": boolean
  },
  "contactData": {
    "Name": "string",
    "Phone": "string",
    "stickyAgent": "username",
    "isSticky": boolean
  }
}
```
**Purpose:** Called when call is connected to get call context and contact information.

### Call Ended
```http
POST /user/callended{username}
Headers: Authorization: Bearer {token}
Body: { "leadLockToken": "optional" }
```
**Purpose:** Notifies server that call has ended. Triggers post-call workflow.

### Disposition (Submit Call Disposition)
```http
POST /user/disposition{username}
Headers: Authorization: Bearer {token}
Body: {
  "bridgeID": "string",
  "Disposition": "string",
  "autoDialDisabled": false
}
```
**Purpose:** Submits call disposition after call ends.
**Mobile:** Auto-dispose with "Auto Disposed"

---

## 4. Conference Call APIs

### Request Conference
```http
POST /reqConf/{username}
Headers: Content-Type: application/json
Body: {
  "confNumber": "phone_number"
}
```
**Response:**
```json
{
  "message": "conferance call dialed" | "conference call dialed",
  "result": "bridgeID"
}
```

### Request Hold
```http
POST /reqHold/{username}
Headers: Content-Type: application/json
Body: {}
```

### Request Unhold
```http
POST /reqUnHold/{username}
Headers: Content-Type: application/json
Body: {}
```

---

## 5. Call Flow Diagrams

### Outgoing Call Flow:
```
1. User enters number and presses call
2. POST /dialnumber → Server initiates call
3. JsSIP receives SIP INVITE (autodial from server)
4. Auto-answer SIP call
5. When confirmed → POST /useroncall/{username}
6. Show call screen with timer
7. When call ends → POST /user/callended{username}
8. Mobile: POST /user/disposition{username} with "Auto Disposed"
9. Return to dialpad
```

### Incoming Call Flow:
```
1. JsSIP receives SIP INVITE
2. Check if autodial (from /dialnumber)
3. If autodial: Auto-answer
4. If real incoming: Show incoming call screen
5. User accepts → Answer SIP call
6. POST /useroncall/{username}
7. Show call screen
8. Follow same end flow as outgoing
```

### Connection Check Flow:
```
1. Every 5-10 seconds: POST /userconnection
2. Check response status
3. If "poor connection": Show reconnect modal
4. If 401/not logged in: Force logout
5. Update queue information
6. Update follow-up dispositions
```

---

## 6. Agent Lifecycle States

| State | Description |
|-------|-------------|
| `idle` | Ready for calls, no active work |
| `dialing` | Outgoing call initiated, waiting for answer |
| `ringing` | Incoming call ringing |
| `on_call` | Active call in progress |
| `disposition` | Post-call wrap-up |
| `lead_locked` | Working on a lead (not ready for calls) |

---

## 7. Connection Status Values

| Status | Description |
|--------|-------------|
| `NOT_INUSE` | Agent is idle and ready |
| `INUSE` | Agent is on a call |
| `Disposition` | Agent is in post-call wrap-up |
| `UNAVAILABLE` | Agent is on break or unavailable |

---

## 8. Error Handling

### Common Error Responses:

**401 Unauthorized:**
```json
{
  "message": "Session expired. Please log in again."
}
```
Action: Force logout and redirect to login

**Poor Connection:**
```json
{
  "message": "poor connection problem ,please login again"
}
```
Action: Show reconnect modal (don't force logout)

**Agent Not Ready:**
```json
{
  "success": false,
  "message": "Agent is not in a ready state"
}
```
Action: Show modal to login again

---

## 9. Periodic Tasks

### Connection Check (Every 5-10 seconds)
```javascript
setInterval(() => {
  POST /userconnection
  // Check status, update queue, handle errors
}, 5000);
```

### SIP Heartbeat (Every 4 seconds)
```javascript
setInterval(() => {
  // Send SIP MESSAGE to keep connection alive
  ua.sendMessage('heartbeat', { body: 'webphone-heartbeat' });
}, 4000);
```

### User Ready Sync (After key events)
```javascript
// Call after:
// - SIP registration
// - Connection check failure
// - Session ended
POST /userready/{username}/Web
```

---

## 10. Mobile-Specific Behavior

### Auto-Disposition on Mobile:
```javascript
// After call ends on mobile:
POST /user/callended{username}
POST /user/disposition{username} with {
  bridgeID: "...",
  Disposition: "Auto Disposed",
  autoDialDisabled: false
}
// Return to dialpad immediately (no disposition modal)
```

### Incoming Calls on Mobile:
```javascript
// Show incoming call UI with ringtone
// User must manually accept/reject
// Desktop: Auto-answer incoming calls
```

---

## 11. WebSocket for Transcription

### WebSocket Connection:
```
wss://{origin}/socket
```
**Purpose:** Real-time speech-to-text transcription during calls

**Messages:**
- Send audio chunks as WebM/Opus
- Receive transcription results
- Send "streamClose" when call ends

---

## 12. Implementation Checklist for Flutter

- [x] Implement login API
- [x] Call /userready after login
- [x] Start periodic /userconnection check
- [x] Implement /dialnumber for outgoing calls
- [x] Handle SIP INVITE (autodial)
- [x] Call /useroncall when connected
- [x] Implement call timer
- [x] Call /user/callended when call ends
- [x] Auto-dispose with "Auto Disposed"
- [x] Handle connection errors
- [x] Implement SIP heartbeat
- [x] Handle incoming calls
- [x] Implement hold/unhold
- [ ] Implement conference calls (optional)
- [x] Implement break set/remove (dynamic options from token)
- [x] Implement missed calls polling + call-back
- [x] Implement follow-up callbacks
- [x] Fetch recent call history from `/reports/calls/byAgent` (merged with local logs)
