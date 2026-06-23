package com.samwad

import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.hiennv.flutter_callkit_incoming.CallkitIncomingBroadcastReceiver
import com.hiennv.flutter_callkit_incoming.Data

class CallkitFcmService : FirebaseMessagingService() {

    private var broadcastCount = 0
    private val ringtoneChannelId = "callkit_ringtone_channel"
    private val ringtoneNotifId = 1001

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
            Log.d(TAG, "Foreground=true — skip native CallKit, Flutter handles via SIP")
            return
        }

        Log.d(TAG, "Foreground=false — native CallKit broadcast + ringtone for $number")
        saveNativeFcmHandled(number)
        instance = this

        // Start foreground service so process stays alive long enough for ringtone
        val notif = NotificationCompat.Builder(this, ringtoneChannelId)
            .setContentTitle("Incoming Call")
            .setContentText(number)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(ringtoneNotifId, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
        } else {
            startForeground(ringtoneNotifId, notif)
        }
        Log.d(TAG, "Started foreground service for ringtone")

        playNativeRingtone()

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

    private fun playNativeRingtone() {
        try {
            stopNativeRingtone()
            val uri: Uri = RingtoneManager.getActualDefaultRingtoneUri(
                this, RingtoneManager.TYPE_RINGTONE
            )
            ringtonePlayer = MediaPlayer().apply {
                setDataSource(this@CallkitFcmService, uri)
                isLooping = true
                setVolume(1.0f, 1.0f)
                prepare()
                start()
            }
            Log.d(TAG, "Native MediaPlayer ringtone started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to play native ringtone", e)
        }
    }

    private fun isAppInForeground(): Boolean {
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguard != null && keyguard.isKeyguardLocked) {
            Log.d(TAG, "isAppInForeground: Device locked → background")
            return false
        }
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
        val processes = am.runningAppProcesses ?: return false
        return processes.any { p ->
            p.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND &&
            p.processName == packageName
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        // Ringtone foreground service — MIN importance, no sound, no popup
        val ringtoneCh = NotificationChannel(
            ringtoneChannelId, "Call Ringtone", NotificationManager.IMPORTANCE_MIN
        ).apply {
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
            enableLights(false)
            description = "Foreground service for incoming call ringtone"
        }
        mgr.createNotificationChannel(ringtoneCh)
        Log.d(TAG, "Ringtone foreground channel created (MIN)")
        // Incoming/missed — LOW, no sound (ringtone comes from MediaPlayer, not notification)
        for (id in listOf(
            "callkit_incoming_channel_id_v2",
            "callkit_missed_channel_id",
            "incoming_calls_ringtone"
        )) {
            val ch = NotificationChannel(id, "CallKit", NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
                enableLights(false)
                description = "Call notifications (no ringtone)"
            }
            mgr.createNotificationChannel(ch)
        }
        // Ongoing — HIGH, required for Android 14+ foreground service
        val ongoing = NotificationChannel(
            "callkit_ongoing_channel_id", "CallKit", NotificationManager.IMPORTANCE_HIGH
        ).apply {
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
            enableLights(false)
            description = "Ongoing call"
        }
        mgr.createNotificationChannel(ongoing)
        Log.d(TAG, "All CallKit notification channels created (incoming/missed=LOW, ongoing=HIGH, ringtone=MIN)")
    }

    private fun saveNativeFcmHandled(number: String) {
        try {
            val prefs: SharedPreferences = applicationContext.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE
            )
            prefs.edit().putString("fcm_native_handled", number).apply()
            Log.d(TAG, "Saved native FCM handled for: $number")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save native FCM handled", e)
        }
    }

    companion object {
        private const val TAG = "CallkitFcmService"
        @Volatile
        var ringtonePlayer: MediaPlayer? = null
        @Volatile
        var instance: CallkitFcmService? = null

        fun stopNativeRingtone() {
            Log.d(TAG, "stopNativeRingtone called")
            try {
                ringtonePlayer?.apply {
                    if (isPlaying) {
                        stop()
                        Log.d(TAG, "Native ringtone stopped")
                    }
                    release()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping ringtone", e)
            }
            ringtonePlayer = null
        }

        fun stopForegroundAndRingtone() {
            Log.d(TAG, "stopForegroundAndRingtone called")
            stopNativeRingtone()
            try {
                instance?.apply {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    Log.d(TAG, "Foreground service stopped")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping foreground", e)
            }
            instance = null
        }
    }
}
