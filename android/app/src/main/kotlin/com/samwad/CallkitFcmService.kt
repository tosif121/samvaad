package com.samwad

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.hiennv.flutter_callkit_incoming.CallkitIncomingBroadcastReceiver
import com.hiennv.flutter_callkit_incoming.Data

class CallkitFcmService : FirebaseMessagingService() {

    private var broadcastCount = 0

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        Log.d(TAG, "New FCM token: $token")
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        val data = message.data
        broadcastCount++
        Log.d(TAG, "FCM received#$broadcastCount: $data")

        val number = data["body"] ?: data["number"] ?: data["caller"] ?: return
        if (number.isEmpty()) return

        if (isAppInForeground()) {
            Log.d(TAG, "App is in foreground — skipping native CallKit, Flutter will handle via SIP")
            return
        }

        Log.d(TAG, "App is NOT in foreground — sending CallKit broadcast for $number")
        saveNativeFcmHandled(number)

        val callData = Data(
            hashMapOf(
                "id" to System.currentTimeMillis().toString(),
                "nameCaller" to number,
                "handle" to number,
                "type" to 0,
                "appName" to "Samvaad",
                "isCustomNotification" to true,
                "isShowLogo" to false,
                "isShowCallID" to false,
                "backgroundColor" to "#4299EB",
                "actionColor" to "#FFFFFF",
                "textColor" to "#FFFFFF",
                "incomingCallNotificationChannelName" to "incoming_calls_ringtone",
                "isShowFullLockedScreen" to true,
                "isFullScreen" to true,
                "textAccept" to "Answer",
                "textDecline" to "Decline",
                "extra" to hashMapOf("number" to number)
            )
        )

        val bundle = callData.toBundle()
        val intent = CallkitIncomingBroadcastReceiver.getIntentIncoming(
            applicationContext,
            bundle
        )
        applicationContext.sendBroadcast(intent)
        Log.d(TAG, "CallKit broadcast#$broadcastCount sent for: $number")
    }

    private fun isAppInForeground(): Boolean {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
        val processes = activityManager.runningAppProcesses ?: return false
        return processes.any { process ->
            process.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND &&
            process.processName == packageName
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // Incoming/missed: LOW importance to suppress heads-up popup
        for (channelId in listOf("callkit_incoming_channel_id_v2", "callkit_missed_channel_id", "incoming_calls_ringtone")) {
            val channel = NotificationChannel(channelId, "CallKit", NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
                enableLights(false)
                description = "Call notifications"
            }
            manager.createNotificationChannel(channel)
        }
        // Ongoing: HIGH importance required for Android 14+ foreground service
        val ongoing = NotificationChannel("callkit_ongoing_channel_id", "CallKit", NotificationManager.IMPORTANCE_HIGH).apply {
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
            enableLights(false)
            description = "Ongoing call"
        }
        manager.createNotificationChannel(ongoing)
        Log.d(TAG, "CallKit notification channels created (incoming/missed=LOW, ongoing=HIGH)")
    }

    private fun saveNativeFcmHandled(number: String) {
        try {
            val prefs: SharedPreferences = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            prefs.edit().putString("fcm_native_handled", number).apply()
            Log.d(TAG, "Saved native FCM handled for: $number")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save native FCM handled", e)
        }
    }

    companion object {
        private const val TAG = "CallkitFcmService"
    }
}
