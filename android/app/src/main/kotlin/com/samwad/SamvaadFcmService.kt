package com.samwad

import android.app.ActivityManager
import android.app.Application
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.hiennv.flutter_callkit_incoming.CallkitIncomingBroadcastReceiver
import com.hiennv.flutter_callkit_incoming.Data

class SamvaadFcmService : FirebaseMessagingService() {

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
        ensureCallkitChannels()
        ensureTracker(this)
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

        val km = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        val pm = getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
        val isLockedOrOff = (km?.isKeyguardLocked == true) || (pm?.isInteractive == false)

        if (isLockedOrOff) {
            Log.d(TAG, "Device is locked or screen off, showing CallKit")
            showCallkitIncoming(number)
        } else {
            Log.d(TAG, "Device is unlocked, showing Heads-Up Notification to open app directly")
            showOpenAppNotification(number)
        }
    }

    private fun showCallkitIncoming(number: String) {
        try {
            Log.d(TAG, "showCallkitIncoming for $number — starting foreground service")

            if (backgroundFlutterEngine == null) {
                val appCtx = applicationContext
                val loader = io.flutter.FlutterInjector.instance().flutterLoader()
                loader.startInitialization(appCtx)
                loader.ensureInitializationComplete(appCtx, null)

                backgroundFlutterEngine = io.flutter.embedding.engine.FlutterEngine(appCtx)
                backgroundFlutterEngine!!.dartExecutor.executeDartEntrypoint(
                    io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint.createDefault()
                )
                Log.d(TAG, "Background FlutterEngine started successfully")
            }

            ensureCallkitChannels()

            val callkitNotifId = "call_${number.hashCode()}".hashCode()
            
            // Start foreground service so we can launch CallkitIncomingActivity from background
            instance = this
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
            Log.d(TAG, "Foreground service started")


            // Use the plugin's Data class to create the call data bundle properly
            val callData = Data(
                hashMapOf(
                    // Deterministic ID prevents duplicate CallKit screens for same call
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
            val intent = CallkitIncomingBroadcastReceiver.getIntentIncoming(
                applicationContext,
                bundle
            )
            applicationContext.sendBroadcast(intent)
            Log.d(TAG, "CallKit broadcast sent for: $number")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch callkit natively", e)
            cleanupForeground()
            showOpenAppNotification(number)
        }
    }

    private fun showOpenAppNotification(number: String) {
        try {
            instance = this
            val fgNotif = NotificationCompat.Builder(this, ringtoneChannelId)
                .setContentTitle("Incoming Call")
                .setContentText(number)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setOngoing(true)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(1003, fgNotif, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
            } else {
                startForeground(1003, fgNotif)
            }

            val powerManager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            val wakeLock = powerManager.newWakeLock(
                android.os.PowerManager.FULL_WAKE_LOCK or
                android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP or
                android.os.PowerManager.ON_AFTER_RELEASE,
                "Samvaad::IncomingCallWakeLock"
            )
            wakeLock.acquire(3 * 60 * 1000L) // 3 minutes max
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire wake lock", e)
        }

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        launchIntent.putExtra("fcm_number", number)
        launchIntent.action = "INCOMING_CALL_ACTION"

        try {
            startActivity(launchIntent)
            Log.d(TAG, "Force started activity from background")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start activity directly", e)
        }

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

        Handler(mainLooper).postDelayed({
            cleanupForeground()
        }, 10000)
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

    private fun playNativeRingtone() {
        try {
            stopNativeRingtone()
            val uri: Uri = RingtoneManager.getActualDefaultRingtoneUri(
                this, RingtoneManager.TYPE_RINGTONE
            )
            ringtonePlayer = MediaPlayer().apply {
                setDataSource(this@SamvaadFcmService, uri)
                isLooping = true
                setVolume(1.0f, 1.0f)
                prepare()
                start()
            }
            Log.d(TAG, "Native ringtone started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to play native ringtone", e)
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
        
        // DELETE OLD MUTED CHANNELS SO CALLKIT CAN RECREATE THEM AS HIGH IMPORTANCE!
        mgr.deleteNotificationChannel("callkit_incoming_channel_id_v2")
        mgr.deleteNotificationChannel("incoming_calls_ringtone")

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
        private const val ringtoneNotifId = 1002
        private const val fgServiceNotifId = 1003
        private var trackerRegistered = false

        @Volatile
        var instance: SamvaadFcmService? = null

        @Volatile
        var ringtonePlayer: MediaPlayer? = null
        
        @Volatile
        var backgroundFlutterEngine: io.flutter.embedding.engine.FlutterEngine? = null

        fun stopNativeRingtone() {
            Log.d(TAG, "stopNativeRingtone called")
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

        fun cleanupForeground() {
            Log.d(TAG, "cleanupForeground called")
            stopNativeRingtone()
            try {
                instance?.stopForeground(STOP_FOREGROUND_REMOVE)
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping foreground", e)
            }
            instance = null
            try {
                backgroundFlutterEngine?.destroy()
                backgroundFlutterEngine = null
            } catch (e: Exception) {
                Log.e(TAG, "Failed to destroy background engine", e)
            }
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
