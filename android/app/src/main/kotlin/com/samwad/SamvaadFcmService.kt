package com.samwad

import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class SamvaadFcmService : FirebaseMessagingService() {

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
        Log.d(TAG, "FCM received: $data")

        if (isCallEndedPayload(data)) {
            clearPendingCall()
            return
        }

        val number = data["body"] ?: data["number"] ?: data["caller"] ?: return
        if (number.isEmpty()) return

        savePendingCall(number)

        if (isAppInForeground()) {
            Log.d(TAG, "Foreground=true — Flutter handles active UI")
            return
        }

        showOpenAppNotification(number)
    }

    private fun showOpenAppNotification(number: String) {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        launchIntent.putExtra("number", number)

        val pendingIntent = PendingIntent.getActivity(
            this,
            number.hashCode(),
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, incomingChannelId)
            .setContentTitle("Incoming Call")
            .setContentText(number)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setAutoCancel(true)
            .setFullScreenIntent(pendingIntent, true)
            .setContentIntent(pendingIntent)
            .build()

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(incomingNotificationId, notification)
        Log.d(TAG, "Open-app notification shown for $number")
    }

    private fun isCallEndedPayload(data: Map<String, String>): Boolean {
        val keys = listOf("event", "type", "action", "status", "callStatus", "message")
        return keys.any { key ->
            val value = data[key]?.lowercase() ?: return@any false
            value.contains("call_ended") ||
                value.contains("callended") ||
                value.contains("ended") ||
                value.contains("hangup") ||
                value.contains("hang_up") ||
                value.contains("cancel") ||
                value.contains("rejected") ||
                value.contains("disconnected") ||
                value.contains("timeout")
        }
    }

    private fun savePendingCall(number: String) {
        try {
            val prefs: SharedPreferences = applicationContext.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE
            )
            prefs.edit()
                .putString("flutter.fcm_pending_call", number)
                .putLong("flutter.fcm_pending_call_ts", System.currentTimeMillis())
                .apply()
            Log.d(TAG, "Saved pending FCM call for: $number")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save pending FCM call", e)
        }
    }

    private fun clearPendingCall() {
        try {
            val prefs: SharedPreferences = applicationContext.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE
            )
            prefs.edit()
                .remove("flutter.fcm_pending_call")
                .remove("flutter.fcm_pending_call_ts")
                .apply()
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(incomingNotificationId)
            Log.d(TAG, "Cleared pending FCM call")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clear pending FCM call", e)
        }
    }

    private fun isAppInForeground(): Boolean {
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguard != null && keyguard.isKeyguardLocked) {
            return false
        }
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
        val processes = am.runningAppProcesses ?: return false
        return processes.any { process ->
            process.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND &&
                process.processName == packageName
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            incomingChannelId,
            "Incoming Calls",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Opens Samvaad for incoming calls"
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val TAG = "SamvaadFcmService"
        private const val incomingChannelId = "samvaad_incoming_calls"
        private const val incomingNotificationId = 1001
    }
}
