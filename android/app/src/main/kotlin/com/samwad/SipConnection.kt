package com.samwad

import android.telecom.Connection
import android.telecom.DisconnectCause
import android.util.Log

class SipConnection(
    private val callId: String,
    private val callerNumber: String,
    private val onCommand: (String, Map<String, String>) -> Unit
) : Connection() {
    companion object {
        private const val TAG = "SipConnection"
    }

    init {
        setInitialized()
        setRinging()
        setAudioModeIsVoip(true)
        setConnectionProperties(PROPERTY_SELF_MANAGED)
    }

    override fun onAnswer() {
        super.onAnswer()
        Log.d(TAG, "User answered call: $callId")
        setActive()
        onCommand("nativeAnswerCall", mapOf("callId" to callId))
    }

    override fun onReject() {
        super.onReject()
        Log.d(TAG, "User rejected call: $callId")
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
        onCommand("nativeRejectCall", mapOf("callId" to callId))
    }

    override fun onDisconnect() {
        super.onDisconnect()
        Log.d(TAG, "Call disconnected: $callId")
        setDisconnected(DisconnectCause(DisconnectCause.LOCAL))
        destroy()
        onCommand("nativeEndCall", mapOf("callId" to callId))
    }

    fun setCallActive() {
        setActive()
    }

    fun setCallEnded() {
        setDisconnected(DisconnectCause(DisconnectCause.REMOTE))
        destroy()
    }
}
