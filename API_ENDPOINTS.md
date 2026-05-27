# Samvaad API Endpoints Documentation

## Base URL
```
https://app.samvaad.io
```

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
    "uiPreferences": {}
  },
  "message": "success" | "wrong login info" | "User already login somewhere else"
}
```

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

- [ ] Implement login API
- [ ] Call /userready after login
- [ ] Start periodic /userconnection check
- [ ] Implement /dialnumber for outgoing calls
- [ ] Handle SIP INVITE (autodial)
- [ ] Call /useroncall when connected
- [ ] Implement call timer
- [ ] Call /user/callended when call ends
- [ ] Auto-dispose with "Auto Disposed"
- [ ] Handle connection errors
- [ ] Implement SIP heartbeat
- [ ] Handle incoming calls (if needed)
- [ ] Implement hold/unhold
- [ ] Implement conference calls (optional)
