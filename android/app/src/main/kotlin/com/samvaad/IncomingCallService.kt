package com.samvaad

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
import android.media.AudioAttributes
import android.media.RingtoneManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class IncomingCallService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    private fun cleanNumber(number: String): String {
        var n = number.trim()
        if (n.startsWith("+91")) n = n.substring(3)
        if (n.startsWith("0091")) n = n.substring(4)
        if (n.startsWith("91") && n.length == 12 && n.all { it.isDigit() }) n = n.substring(2)
        if (n.startsWith("+")) n = n.substring(1)
        return n.trim()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val rawCallerName = intent?.getStringExtra("caller_name") ?: "Unknown Caller"
        val rawCallerNumber = intent?.getStringExtra("fcm_number") ?: ""
        val callerName = cleanNumber(rawCallerName)
        val callerNumber = cleanNumber(rawCallerNumber)

        Log.d(TAG, "IncomingCallService started for $callerName ($callerNumber)")

        // 1. MUST call startForeground() first, within the system's ~5s deadline.
        //    Without it the app crashes with ForegroundServiceDidNotStartInTimeException.
        startForeground(NOTIFICATION_ID, createForegroundNotification())

        // 2. Show high-priority heads-up incoming call notification banner
        showIncomingCallNotification(callerName, callerNumber)

        // 3. Wake device screen if locked
        wakeDevice()

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
        val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val audioAttributes = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .build()

            val channel = NotificationChannel(
                channelId,
                "Incoming Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for incoming calls"
                setSound(null, null)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 1000, 1000, 1000, 1000)
                enableLights(true)
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
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
            .setContentIntent(pendingIntent)
            .setSound(ringtoneUri)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(pendingIntent, true)
            .addAction(android.R.drawable.ic_menu_call, "Answer Call", pendingIntent)
            .setOngoing(true)
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
