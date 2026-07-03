package com.samwad

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.telecom.TelecomManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class CallFirebaseMessagingService : FirebaseMessagingService() {
    companion object {
        private const val TAG = "CallFCMService"
        private const val NOTIFICATION_CHANNEL_ID = "fcm_incoming_call"
        private const val NOTIFICATION_ID = 1002
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        Log.d(TAG, "New FCM token: $token")
        getSharedPreferences("fcm_prefs", Context.MODE_PRIVATE)
            .edit()
            .putString("fcm_token", token)
            .apply()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        val data = message.data
        Log.d(TAG, "FCM message received: $data")

        val type = data["type"] ?: return
        if (type != "incoming_call") return

        // When the app is in the foreground, the flutter UI handles
        // incoming calls via the SIP UA callback alone — the push is
        // redundant. Skip to avoid conflicting with the in-app call UI.
        // In background or killed state we always show the native call UI.
        if (MainActivity.isAlive && MainActivity.isInForeground) {
            Log.d(TAG, "App in foreground — SIP UA handles the call, ignoring push")
            return
        }

        val callId = data["call_id"] ?: return
        val callerNumber = data["body"] ?: data["caller_number"] ?: "Unknown"
        val title = data["title"] ?: "Incoming Call"
        val body = callerNumber

        createNotificationChannel()
        showHeadsUpNotification(title, body, callId, callerNumber)
        showNativeCallUi(callId, callerNumber)

        // If the app process is alive (backgrounded), the main Flutter
        // engine's SIP UA is already registered — no need for a headless
        // engine.  Commands from SipConnectionService reach the main
        // engine via SipBridge.methodChannel (set by MainActivity).
        // Only start a headless engine when the app was killed.
        if (!MainActivity.isAlive) {
            HeadlessSipBridge.start(this, callId, callerNumber)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Incoming Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for incoming calls"
                setShowBadge(false)
            }
            val notificationManager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun showHeadsUpNotification(
        title: String,
        body: String,
        callId: String,
        callerNumber: String
    ) {
        val intent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            putExtra("fcm_number", callerNumber)
            putExtra("call_id", callId)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(pendingIntent, true)
            .setOngoing(true)
            .setAutoCancel(false)
            .build()

        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    private fun showNativeCallUi(callId: String, callerNumber: String) {
        try {
            val telecomManager =
                getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            PhoneAccountHelper.registerPhoneAccount(this)

            val extras = Bundle().apply {
                putString("call_id", callId)
                putString("caller_number", callerNumber)
                putInt(TelecomManager.EXTRA_START_CALL_WITH_SPEAKERPHONE, 0)
                putBoolean(TelecomManager.EXTRA_START_CALL_WITH_VIDEO_STATE, false)
            }

            telecomManager.addNewIncomingCall(PhoneAccountHelper.getHandle(this), extras)
            Log.d(TAG, "Native call UI shown for $callerNumber")
        } catch (e: SecurityException) {
            Log.e(TAG, "Missing MANAGE_OWN_CALLS permission", e)
        }
    }
}
