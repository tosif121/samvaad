package com.samvaad

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class CallForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START

        when (action) {
            ACTION_STOP -> {
                Log.d(TAG, "CallForegroundService stopping via ACTION_STOP")
                releaseLocks()
                stopForegroundSafely()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_END_CALL -> {
                Log.d(TAG, "User tapped End Call on notification")
                MainActivity.endCallFromNative()
                releaseLocks()
                stopForegroundSafely()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val rawCallerName = intent?.getStringExtra(EXTRA_CALLER_NAME) ?: "Call in progress"
                val rawCallerNumber = intent?.getStringExtra(EXTRA_CALLER_NUMBER) ?: ""
                val callerName = cleanNumber(rawCallerName)
                val callerNumber = cleanNumber(rawCallerNumber)
                Log.d(TAG, "Starting CallForegroundService for $callerName ($callerNumber)")

                startCallForeground(callerName, callerNumber)
                acquireLocks()
                return START_STICKY
            }
        }
    }

    private fun cleanNumber(number: String): String {
        var n = number.trim()
        if (n.startsWith("+91")) n = n.substring(3)
        if (n.startsWith("0091")) n = n.substring(4)
        if (n.startsWith("91") && n.length == 12 && n.all { it.isDigit() }) n = n.substring(2)
        if (n.startsWith("+")) n = n.substring(1)
        return n.trim()
    }

    private fun startCallForeground(callerName: String, callerNumber: String) {
        val channelId = "samvaad_active_call_channel"
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Active Call",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps the call connected when app is minimized"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

        // Tap notification to bring Samvaad to foreground
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            )
        }
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            101,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // "End Call" action button
        val endCallIntent = Intent(this, CallForegroundService::class.java).apply {
            action = ACTION_END_CALL
        }
        val endCallPendingIntent = PendingIntent.getService(
            this,
            102,
            endCallIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val displayText = if (callerNumber.isNotEmpty() && callerNumber != callerName) {
            "$callerNumber • Tap to return to call"
        } else {
            "Call in progress • Tap to return to call"
        }

        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle(callerName.ifEmpty { "Active Call" })
            .setContentText(displayText)
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setUsesChronometer(true)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "End Call", endCallPendingIntent)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var serviceType = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
            val hasMicPermission = ActivityCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO
            ) == PackageManager.PERMISSION_GRANTED

            if (hasMicPermission) {
                serviceType = serviceType or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }

            try {
                startForeground(NOTIFICATION_ID, notification, serviceType)
            } catch (e: Exception) {
                Log.e(TAG, "Error starting foreground with types: $e, falling back to basic startForeground")
                startForeground(NOTIFICATION_ID, notification)
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireLocks() {
        try {
            if (wakeLock == null) {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "Samvaad:ActiveCallWakeLock"
                ).apply {
                    setReferenceCounted(false)
                    acquire(60 * 60 * 1000L) // 1 hour max safeguard
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error acquiring wake lock: $e")
        }

        try {
            if (wifiLock == null) {
                val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                @Suppress("DEPRECATION")
                wifiLock = wifiManager.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "Samvaad:ActiveCallWifiLock"
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error acquiring wifi lock: $e")
        }
    }

    private fun releaseLocks() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
            wakeLock = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wake lock: $e")
        }

        try {
            wifiLock?.let {
                if (it.isHeld) it.release()
            }
            wifiLock = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wifi lock: $e")
        }
    }

    private fun stopForegroundSafely() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping foreground: $e")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        releaseLocks()
        stopForegroundSafely()
        Log.d(TAG, "CallForegroundService destroyed")
    }

    companion object {
        private const val TAG = "CallForegroundService"
        private const val NOTIFICATION_ID = 2001

        const val ACTION_START = "com.samvaad.action.START_CALL_FOREGROUND"
        const val ACTION_STOP = "com.samvaad.action.STOP_CALL_FOREGROUND"
        const val ACTION_END_CALL = "com.samvaad.action.END_CALL"

        const val EXTRA_CALLER_NAME = "caller_name"
        const val EXTRA_CALLER_NUMBER = "caller_number"

        fun start(context: Context, callerName: String, callerNumber: String) {
            try {
                val intent = Intent(context, CallForegroundService::class.java).apply {
                    action = ACTION_START
                    putExtra(EXTRA_CALLER_NAME, callerName)
                    putExtra(EXTRA_CALLER_NUMBER, callerNumber)
                }
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                Log.e(TAG, "Error starting CallForegroundService: $e")
            }
        }

        fun stop(context: Context) {
            try {
                val intent = Intent(context, CallForegroundService::class.java).apply {
                    action = ACTION_STOP
                }
                context.startService(intent)
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping CallForegroundService: $e")
            }
        }
    }
}
