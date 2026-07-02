package com.samwad

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps the SIP WebSocket and Dart VM alive when
 * the app is backgrounded, screen is locked, or user switches tabs.
 *
 * Uses PARTIAL_WAKE_LOCK to prevent the CPU from sleeping — critical for
 * keeping the Flutter Dart isolate running so the WebSocket heartbeat fires.
 * Without this, Android suspends the Dart VM → WebSocket drops → 404/disconnect.
 *
 * Started as early as RINGING/DIALING (not just CONFIRMED) to handle the
 * case where the user switches apps during call setup.
 */
class SipForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: ${intent?.action}")
        when (intent?.action) {
            ACTION_STOP -> {
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                startForegroundCompat()
                acquireWakeLock()
            }
        }
        // START_STICKY — Android restarts the service if killed, keeping the call alive
        return START_STICKY
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            // PARTIAL_WAKE_LOCK keeps the CPU running (screen can be off).
            // This is what WhatsApp/Telegram use during calls.
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Samvaad::SipCallWakeLock"
            ).apply {
                acquire(3 * 60 * 60 * 1000L) // 3 hours max
                Log.d(TAG, "PARTIAL_WAKE_LOCK acquired")
            }
        } catch (e: Exception) {
            Log.e(TAG, "WakeLock acquire failed: $e")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
            Log.d(TAG, "WakeLock released")
        } catch (e: Exception) {
            Log.e(TAG, "WakeLock release failed: $e")
        }
    }

    private fun startForegroundCompat() {
        ensureChannel()

        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val openPi = PendingIntent.getActivity(
            this, 1, openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Samvaad – Active Call")
            .setContentText("Tap to return to the call")
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setContentIntent(openPi)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIF_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIF_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
            } else {
                startForeground(NOTIF_ID, notification)
            }
            Log.d(TAG, "SipForegroundService started with foreground notification")
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed: $e")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseWakeLock()
        Log.d(TAG, "SipForegroundService destroyed")
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID, "Active Call", NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Keeps SIP/WebRTC connection alive during calls"
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        mgr.createNotificationChannel(ch)
    }

    companion object {
        private const val TAG = "SipForegroundService"
        const val CHANNEL_ID = "sip_call_channel"
        const val NOTIF_ID = 2001
        const val ACTION_STOP = "com.samwad.SIP_STOP"

        fun start(context: Context) {
            val intent = Intent(context, SipForegroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                Log.d(TAG, "SipForegroundService start requested")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start: $e")
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, SipForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                context.startService(intent)
                Log.d(TAG, "SipForegroundService stop requested")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to stop: $e")
            }
        }
    }
}
