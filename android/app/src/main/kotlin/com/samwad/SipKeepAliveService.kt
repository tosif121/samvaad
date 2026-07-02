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
 * Persistent foreground service that keeps the SIP WebSocket and Dart VM alive 24/7.
 * 
 * This service starts immediately after successful SIP registration and runs continuously
 * to ensure the app stays registered with Asterisk even when:
 * - App is backgrounded
 * - Screen is locked
 * - User switches to other apps
 * 
 * Uses PARTIAL_WAKE_LOCK to prevent CPU from sleeping, keeping the Flutter Dart isolate
 * running so the WebSocket heartbeat fires and SIP registration stays active.
 * 
 * Without this, Android suspends the Dart VM → WebSocket drops → SIP unregisters → 
 * incoming calls fail with "404 Not Found" or "User Not Registered".
 */
class SipKeepAliveService : Service() {

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
        // START_STICKY — Android restarts the service if killed, keeping SIP registered
        return START_STICKY
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            // PARTIAL_WAKE_LOCK keeps the CPU running (screen can be off).
            // This is what WhatsApp/Telegram use to keep connection alive.
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Samvaad::SipKeepAliveWakeLock"
            ).apply {
                acquire(24 * 60 * 60 * 1000L) // 24 hours max
                Log.d(TAG, "PARTIAL_WAKE_LOCK acquired for keep-alive")
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
            .setContentTitle("Samvaad – Online")
            .setContentText("SIP registered and ready for calls")
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openPi)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIF_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIF_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            } else {
                startForeground(NOTIF_ID, notification)
            }
            Log.d(TAG, "SipKeepAliveService started with foreground notification")
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed: $e")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseWakeLock()
        Log.d(TAG, "SipKeepAliveService destroyed")
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID, "SIP Keep Alive", NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps SIP registration active in background"
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        mgr.createNotificationChannel(ch)
    }

    companion object {
        private const val TAG = "SipKeepAliveService"
        const val CHANNEL_ID = "sip_keepalive_channel"
        const val NOTIF_ID = 3001
        const val ACTION_STOP = "com.samwad.SIP_KEEPALIVE_STOP"

        fun start(context: Context) {
            val intent = Intent(context, SipKeepAliveService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                Log.d(TAG, "SipKeepAliveService start requested")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start: $e")
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, SipKeepAliveService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                context.startService(intent)
                Log.d(TAG, "SipKeepAliveService stop requested")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to stop: $e")
            }
        }
    }
}
