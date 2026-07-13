package com.samwad

import android.content.Intent
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class MyFirebaseMessagingService : FirebaseMessagingService() {

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        Log.d(TAG, "Message received: ${message.messageId}")

        val type = message.data["type"]
        if (type == "incomingCall" || type == "incoming_call") {
            if (MainActivity.isInForeground) {
                Log.d(TAG, "App is in foreground, skipping native handling")
                return
            }
            Log.d(TAG, "App is not in foreground, handling incoming call natively")
            handleIncomingCall(message)
        }
    }

    private fun handleIncomingCall(message: RemoteMessage) {
        val callerName = message.data["callerName"] ?: message.data["title"] ?: "Unknown Caller"
        val callerNumber = message.data["callerNumber"] ?: message.data["body"] ?: ""

        // Start foreground service (works on stricter OEMs with persistent state)
        IncomingCallService.start(this, callerName, callerNumber)

        // Also try direct activity start (fastest path, uses FCM whitelist)
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                )
                putExtra("fcm_number", callerNumber)
                putExtra("caller_name", callerName)
            }
            startActivity(intent)
            Log.d(TAG, "Direct activity start from FCM service")
        } catch (e: Exception) {
            Log.d(TAG, "Direct start deferred to foreground service: $e")
        }
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        Log.d(TAG, "New FCM Token: $token")
    }

    companion object {
        private const val TAG = "MyFCMService"
    }
}
