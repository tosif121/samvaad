package com.samwad

import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.PhoneAccountHandle
import android.util.Log

class SipConnectionService : ConnectionService() {
    companion object {
        private const val TAG = "SipConnectionService"

        private val activeConnections = mutableMapOf<String, SipConnection>()

        fun notifyCallActive(callId: String) {
            activeConnections[callId]?.setCallActive()
        }

        fun notifyCallEnded(callId: String) {
            Log.d(TAG, "notifyCallEnded: $callId")
            activeConnections.remove(callId)?.setCallEnded()
        }

        fun bindIncomingCall(callId: String) {
            Log.d(TAG, "bindIncomingCall (no-op, already bound): $callId")
        }
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection {
        val extras = request.extras ?: Bundle()
        val callId = extras.getString("call_id") ?: "unknown"
        val callerNumber = extras.getString("caller_number") ?: "Unknown"

        Log.d(TAG, "Creating incoming connection: $callerNumber (callId=$callId)")

        val connection = SipConnection(callId, callerNumber) { method, args ->
            SipBridge.sendCommand(method, args)
        }

        activeConnections[callId] = connection
        return connection
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ): Connection? {
        Log.d(TAG, "Outgoing connection requested (not supported)")
        return null
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle,
        request: ConnectionRequest
    ) {
        Log.d(TAG, "Outgoing connection failed (not supported)")
    }
}
