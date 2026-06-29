package com.samwad

import android.app.ActivityManager
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.hiennv.flutter_callkit_incoming.CallkitIncomingBroadcastReceiver
import com.hiennv.flutter_callkit_incoming.Data

import com.hiennv.flutter_callkit_incoming.CallkitEventCallback
import com.hiennv.flutter_callkit_incoming.FlutterCallkitIncomingPlugin
import android.os.Bundle

class SamvaadFcmService : FirebaseMessagingService() {

    private var wakeLock: android.os.PowerManager.WakeLock? = null
    private var actionReceiver: android.content.BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
        ensureCallkitChannels()
        ensureTracker(this)
        
        actionReceiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
                val action = intent?.action
                Log.d(TAG, "actionReceiver onReceive: $action")
                if (action?.contains("ACTION_CALL_ACCEPT") == true ||
                    action?.contains("ACTION_CALL_DECLINE") == true ||
                    action?.contains("ACTION_CALL_ENDED") == true ||
                    action == "com.samvaad.STOP_RINGTONE") {
                    Log.d(TAG, "CallKit Action received in FcmService: $action — stopping ringtone")
                    stopRingtone()
                    releaseWakeLock()
                    cleanupForeground()
                }
            }
        }
        val filter = android.content.IntentFilter().apply {
            addAction("com.hiennv.flutter_callkit_incoming.ACTION_CALL_ACCEPT")
            addAction("com.hiennv.flutter_callkit_incoming.ACTION_CALL_DECLINE")
            addAction("com.hiennv.flutter_callkit_incoming.ACTION_CALL_ENDED")
            addAction("com.samwad.com.hiennv.flutter_callkit_incoming.ACTION_CALL_ACCEPT")
            addAction("com.samwad.com.hiennv.flutter_callkit_incoming.ACTION_CALL_DECLINE")
            addAction("com.samwad.com.hiennv.flutter_callkit_incoming.ACTION_CALL_ENDED")
            addAction("com.samvaad.STOP_RINGTONE")
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(actionReceiver, filter, android.content.Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(actionReceiver, filter)
        }
        
        // Register direct callback from the plugin to catch Decline natively (statically)
        registerStaticCallkitCallback()
    }

    override fun onDestroy() {
        super.onDestroy()
        actionReceiver?.let {
            unregisterReceiver(it)
            actionReceiver = null
        }
        releaseWakeLock()
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        Log.d(TAG, "New FCM token: $token")
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        val data = message.data
        Log.d(TAG, "FCM received: $data")

        val isCallPayload = data["notification_type"] == "call" || data["type"] == "incoming_call"
        if (!isCallPayload) {
            if (isCallEndedPayload(data)) {
                Log.d(TAG, "Received call_ended or timeout payload via FCM, cleaning up")
                clearPendingCall()
                cleanupForeground()
            }
            return
        }

        if (isAppInForeground()) {
            Log.d(TAG, "App is in foreground. Skipping CallKit. Flutter will handle the call internally.")
            return
        }

        val number = data["body"] ?: data["number"] ?: data["caller"] ?: "Unknown"
        savePendingCall(number)
        showCallkitIncoming(number)
    }

    private fun acquireWakeLock() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            wakeLock = powerManager.newWakeLock(
                android.os.PowerManager.FULL_WAKE_LOCK or
                android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP or
                android.os.PowerManager.ON_AFTER_RELEASE,
                "Samvaad::CallKitWakeLock"
            ).apply {
                acquire(90 * 1000L) // 90 seconds max
                Log.d(TAG, "WakeLock acquired for CallKit UI")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire WakeLock", e)
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    Log.d(TAG, "WakeLock released")
                }
            }
            wakeLock = null
        } catch (e: Exception) {
            Log.e(TAG, "Failed to release WakeLock", e)
        }
    }

    private fun showCallkitIncoming(number: String) {
        try {
            Log.d(TAG, "showCallkitIncoming for $number")

            acquireWakeLock()
            ensureCallkitChannels()
            playRingtone()

            // Start foreground service
            instance = this
            val callkitNotifId = "call_${number.hashCode()}".hashCode()
            val fgNotif = NotificationCompat.Builder(this, ringtoneChannelId)
                .setContentTitle("Incoming Call")
                .setContentText(number)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setOngoing(true)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(callkitNotifId, fgNotif, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
            } else {
                startForeground(callkitNotifId, fgNotif)
            }

            // Also send CallKit broadcast — on some devices it shows the native CallKit UI
            try {
                val callData = Data(
                    hashMapOf(
                        "id" to "call_${number.hashCode()}",
                        "nameCaller" to number,
                        "handle" to number,
                        "type" to 0,
                        "appName" to "Samvaad",
                        "ringtonePath" to "system_ringtone_default",
                        "isCustomNotification" to true,
                        "isShowLogo" to false,
                        "isShowCallID" to false,
                        "backgroundColor" to "#4299EB",
                        "actionColor" to "#FFFFFF",
                        "textColor" to "#FFFFFF",
                        "incomingCallNotificationChannelName" to "incoming_calls_ringtone_v2",
                        "isShowFullLockedScreen" to true,
                        "isFullScreen" to true,
                        "textAccept" to "Answer",
                        "textDecline" to "Decline",
                        "extra" to hashMapOf("number" to number)
                    )
                )
                val bundle = callData.toBundle()
                val intent = CallkitIncomingBroadcastReceiver.getIntentIncoming(applicationContext, bundle)
                applicationContext.sendBroadcast(intent)
                Log.d(TAG, "CallKit broadcast sent for: $number")
            } catch (e: Exception) {
                Log.e(TAG, "CallKit broadcast failed", e)
            }

            // Poll for decline/accept flag every second, auto-cleanup after 90 seconds
            Log.d(TAG, "Starting poll handler for stop ringtone flag")
            val stopHandler = Handler(mainLooper)
            val stopRunnable = object : Runnable {
                override fun run() {
                    val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    val shouldStop = prefs.getBoolean("flutter.callkit_stop_ringtone", false)
                    if (shouldStop) {
                        Log.d(TAG, "===== callkit_stop_ringtone flag detected — stopping ringtone + cleanup =====")
                        prefs.edit().remove("flutter.callkit_stop_ringtone").apply()
                        stopRingtone()
                        releaseWakeLock()
                        cleanupForeground()
                        Log.d(TAG, "===== Poll cleanup done =====")
                        return
                    }
                    val elapsed = System.currentTimeMillis() - startTime
                    if (elapsed > 90000) {
                        Log.d(TAG, "===== 90s timeout — force cleanup =====")
                        stopRingtone()
                        releaseWakeLock()
                        cleanupForeground()
                        return
                    }
                    stopHandler.postDelayed(this, 1000)
                }
            }
            startTime = System.currentTimeMillis()
            stopHandler.postDelayed(stopRunnable, 1000)
            Log.d(TAG, "Poll handler started at $startTime")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show incoming call UI", e)
            cleanupForeground()
        }
    }

    private fun playRingtone() {
        try {
            stopRingtone()
            val uri = android.media.RingtoneManager.getActualDefaultRingtoneUri(
                this, android.media.RingtoneManager.TYPE_RINGTONE
            )
            ringtonePlayer = android.media.MediaPlayer().apply {
                setDataSource(this@SamvaadFcmService, uri)
                isLooping = true
                setVolume(1.0f, 1.0f)
                prepare()
                start()
            }
            Log.d(TAG, "Ringtone started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to play ringtone", e)
        }
    }

    private fun stopRingtone() {
        try {
            ringtonePlayer?.apply {
                if (isPlaying) stop()
                release()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping ringtone", e)
        }
        ringtonePlayer = null
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
        } finally {
            cleanupForeground()
        }
    }

    private fun isAppInForeground(): Boolean {
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

    private fun ensureCallkitChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        
        // Do NOT delete CallKit plugin channels — it needs them for notifications
        
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
        for (id in listOf(
            "callkit_missed_channel_id"
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
        Log.d(TAG, "All CallKit notification channels created")
    }

    companion object {
        private const val TAG = "SamvaadFcmService"
        private const val incomingChannelId = "samvaad_incoming_calls"
        private const val incomingNotificationId = 1001
        private const val ringtoneChannelId = "callkit_ringtone_channel"
        private var trackerRegistered = false
        private var startTime = 0L

        @Volatile
        var instance: SamvaadFcmService? = null

        @Volatile
        var ringtonePlayer: android.media.MediaPlayer? = null

        @Volatile
        var backgroundFlutterEngine: io.flutter.embedding.engine.FlutterEngine? = null

        private var staticEventCallback: CallkitEventCallback? = null

        fun registerStaticCallkitCallback() {
            if (staticEventCallback == null) {
                staticEventCallback = object : CallkitEventCallback {
                    override fun onCallEvent(event: CallkitEventCallback.CallEvent, callData: Bundle) {
                        Log.d(TAG, "===== CallkitEventCallback received natively: $event =====")
                        if (event == CallkitEventCallback.CallEvent.DECLINE || event == CallkitEventCallback.CallEvent.END) {
                            Log.d(TAG, "Stopping ringtone natively from static CallkitEventCallback!")
                            cleanupForeground()
                        }
                    }
                }
                FlutterCallkitIncomingPlugin.registerEventCallback(staticEventCallback!!)
            }
        }

        fun cleanupForeground() {
            Log.d(TAG, "===== cleanupForeground called =====")
            val savedInstance = instance
            Log.d(TAG, "instance is null: ${savedInstance == null}")
            // Clear stop ringtone flag
            try {
                instance?.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    ?.edit()?.remove("flutter.callkit_stop_ringtone")?.apply()
                Log.d(TAG, "Cleared callkit_stop_ringtone flag")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to clear flag: $e")
            }
            // Stop ringtone
            try {
                ringtonePlayer?.apply {
                    if (isPlaying) {
                        stop()
                        Log.d(TAG, "Ringtone stopped")
                    }
                    release()
                    Log.d(TAG, "Ringtone released")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to stop ringtone: $e")
            }
            ringtonePlayer = null
            // Cancel notification BEFORE nulling instance
            try {
                val mgr = savedInstance?.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                mgr?.cancel(incomingNotificationId)
                Log.d(TAG, "Notification cancelled")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to cancel notification: $e")
            }
            // Release WakeLock
            savedInstance?.releaseWakeLock()
            Log.d(TAG, "WakeLock released")
            try {
                savedInstance?.stopForeground(STOP_FOREGROUND_REMOVE)
                Log.d(TAG, "Foreground service stopped")
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping foreground: $e")
            }
            instance = null
            try {
                backgroundFlutterEngine?.destroy()
                backgroundFlutterEngine = null
                Log.d(TAG, "Background engine destroyed")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to destroy background engine: $e")
            }
            Log.d(TAG, "===== cleanupForeground DONE =====")
        }

        fun ensureTracker(context: Context) {
            if (trackerRegistered) return
            trackerRegistered = true
            try {
                val app = context.applicationContext as Application
                app.registerActivityLifecycleCallbacks(CallkitLifecycleTracker())
                Log.d(TAG, "CallkitLifecycleTracker registered")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to register lifecycle tracker", e)
            }
        }
    }
}
