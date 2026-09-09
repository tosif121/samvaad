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
    private var currentMode = MODE_NONE
    private var lastUsername = "Agent"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START_ONLINE

        when (action) {
            ACTION_STOP, ACTION_END_CALL_BACK_TO_ONLINE -> {
                Log.d(TAG, "CallForegroundService stopping and removing notification via $action")
                currentMode = MODE_NONE
                releaseLocks()
                stopForegroundSafely()
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_END_CALL_FROM_NOTIFICATION -> {
                Log.d(TAG, "User tapped End Call on notification - ending call and clearing notification")
                MainActivity.endCallFromNative()
                currentMode = MODE_NONE
                releaseLocks()
                stopForegroundSafely()
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_START_CALL -> {
                val rawCallerName = intent?.getStringExtra(EXTRA_CALLER_NAME) ?: "Call in progress"
                val rawCallerNumber = intent?.getStringExtra(EXTRA_CALLER_NUMBER) ?: ""
                val callerName = cleanNumber(rawCallerName)
                val callerNumber = cleanNumber(rawCallerNumber)
                Log.d(TAG, "Starting CallForegroundService [CALL MODE] for $callerName ($callerNumber)")

                showCallNotification(callerName, callerNumber)
                acquireLocks()
                return START_STICKY
            }

            ACTION_START_ONLINE -> {
                val username = intent?.getStringExtra(EXTRA_USERNAME) ?: lastUsername
                lastUsername = username
                Log.d(TAG, "Starting CallForegroundService [ONLINE MODE] for $username")

                showOnlineNotification(username)
                acquireLocks()
                return START_STICKY
            }

            else -> {
                showOnlineNotification(lastUsername)
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

    private fun showOnlineNotification(username: String) {
        currentMode = MODE_ONLINE
        val channelId = "samvaad_online_channel"
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Online Status",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps Samvaad connected for incoming calls"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

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
            100,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Samvaad • Online")
            .setContentText("Connected as $username — Ready for calls")
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } catch (e: Exception) {
                Log.e(TAG, "Error starting online foreground service with DATA_SYNC: $e")
                startForeground(NOTIFICATION_ID, notification)
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun showCallNotification(callerName: String, callerNumber: String) {
        currentMode = MODE_CALL
        val channelId = "samvaad_active_call_channel"
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Active Call",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps call connected when app is minimized"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

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

        val endCallIntent = Intent(this, CallForegroundService::class.java).apply {
            action = ACTION_END_CALL_FROM_NOTIFICATION
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
                Log.e(TAG, "Error starting call foreground with types: $e, falling back to basic startForeground")
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
                    "Samvaad:ForegroundWakeLock"
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.d(TAG, "Acquired partial wake lock")
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
                    "Samvaad:ForegroundWifiLock"
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.d(TAG, "Acquired high-perf wifi lock")
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
            Log.d(TAG, "Released wake lock")
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wake lock: $e")
        }

        try {
            wifiLock?.let {
                if (it.isHeld) it.release()
            }
            wifiLock = null
            Log.d(TAG, "Released wifi lock")
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
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(NOTIFICATION_ID)
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

        const val MODE_NONE = 0
        const val MODE_ONLINE = 1
        const val MODE_CALL = 2

        const val ACTION_START_ONLINE = "com.samvaad.action.START_ONLINE"
        const val ACTION_START_CALL = "com.samvaad.action.START_CALL"
        const val ACTION_END_CALL_BACK_TO_ONLINE = "com.samvaad.action.END_CALL_BACK_TO_ONLINE"
        const val ACTION_STOP = "com.samvaad.action.STOP"
        const val ACTION_END_CALL_FROM_NOTIFICATION = "com.samvaad.action.END_CALL_FROM_NOTIFICATION"

        const val EXTRA_USERNAME = "username"
        const val EXTRA_CALLER_NAME = "caller_name"
        const val EXTRA_CALLER_NUMBER = "caller_number"

        fun startOnline(context: Context, username: String) {
            try {
                val intent = Intent(context, CallForegroundService::class.java).apply {
                    action = ACTION_START_ONLINE
                    putExtra(EXTRA_USERNAME, username)
                }
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                Log.e(TAG, "Error starting CallForegroundService [ONLINE]: $e")
            }
        }

        fun startCall(context: Context, callerName: String, callerNumber: String) {
            try {
                val intent = Intent(context, CallForegroundService::class.java).apply {
                    action = ACTION_START_CALL
                    putExtra(EXTRA_CALLER_NAME, callerName)
                    putExtra(EXTRA_CALLER_NUMBER, callerNumber)
                }
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                Log.e(TAG, "Error starting CallForegroundService [CALL]: $e")
            }
        }

        fun endCall(context: Context) {
            try {
                stop(context)
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping CallForegroundService on endCall: $e")
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
