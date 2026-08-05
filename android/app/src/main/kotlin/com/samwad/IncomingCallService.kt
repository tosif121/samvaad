package com.samwad

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class IncomingCallService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callerName = intent?.getStringExtra("caller_name") ?: "Unknown Caller"
        val callerNumber = intent?.getStringExtra("fcm_number") ?: ""

        Log.d(TAG, "IncomingCallService started for $callerName")

        // 1. Show persistent foreground notification (required within ~5s of service start)
        startForeground(NOTIFICATION_ID, createForegroundNotification())

        // 2. Show high-priority incoming call notification with fullScreenIntent FIRST
        // (gives background activity launch privilege on Android 10+)
        showIncomingCallNotification(callerName, callerNumber)

        // 3. Wake device (turn screen on)
        wakeDevice()

        // 4. Open the activity directly into foreground
        openApp(callerNumber, callerName)

        stopSelf()

        return START_NOT_STICKY
    }

    @Suppress("DEPRECATION")
    private fun wakeDevice() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = powerManager.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                        PowerManager.ACQUIRE_CAUSES_WAKEUP or
                        PowerManager.ON_AFTER_RELEASE,
                "Samvaad:CallServiceWakeLock"
            )
            wakeLock.acquire(10000)
            wakeLock.release()
        } catch (e: Exception) {
            Log.e(TAG, "Error waking device: $e")
        }
    }

    private fun createForegroundNotification(): Notification {
        val channelId = "incoming_call_foreground"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Call Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Required for incoming call handling"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
        return NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Samvaad")
            .setContentText("Handling incoming call...")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
    }

    private fun showIncomingCallNotification(callerName: String, callerNumber: String) {
        val channelId = "incoming_call_channel"
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Incoming Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for incoming calls"
                enableVibration(true)
                enableLights(true)
                setShowBadge(true)
            }
            notificationManager.createNotificationChannel(channel)
        }

        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            putExtra("fcm_number", callerNumber)
            putExtra("caller_name", callerName)
        }

        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                    PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Incoming Call")
            .setContentText("Call from $callerName")
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(pendingIntent, true)
            .setOngoing(false)
            .build()

        notificationManager.notify(1001, notification)
    }

    @Suppress("DEPRECATION")
    private fun openApp(callerNumber: String, callerName: String) {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                )
                putExtra("fcm_number", callerNumber)
                putExtra("caller_name", callerName)
            }
            startActivity(intent)
            Log.d(TAG, "App launched from foreground service")
        } catch (e: Exception) {
            Log.e(TAG, "Error opening app from service: $e")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "IncomingCallService destroyed")
    }

    companion object {
        private const val TAG = "IncomingCallService"
        private const val NOTIFICATION_ID = 1002

        fun start(context: Context, callerName: String, callerNumber: String) {
            try {
                val intent = Intent(context, IncomingCallService::class.java).apply {
                    putExtra("caller_name", callerName)
                    putExtra("fcm_number", callerNumber)
                }
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                Log.e(TAG, "Error starting foreground service: $e")
            }
        }
    }
}
