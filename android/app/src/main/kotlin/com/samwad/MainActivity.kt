package com.samwad

import android.app.NotificationChannel
import android.app.NotificationManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.samvaad/ringtone"
    private var mediaPlayer: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Pre-create notification channel with LOW importance
        // so flutter_callkit_incoming doesn't create it with higher importance.
        // Heads-up notification is suppressed; ringtone is handled by RingtoneService.
        createCallKitChannel()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "playRingtone" -> {
                    playDefaultRingtone()
                    result.success(true)
                }
                "stopRingtone" -> {
                    stopRingtone()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun createCallKitChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            // Incoming/missed: LOW importance to suppress heads-up popup
            for (channelId in listOf("callkit_incoming_channel_id_v2", "callkit_missed_channel_id", "incoming_calls_ringtone")) {
                val channel = NotificationChannel(channelId, "CallKit", NotificationManager.IMPORTANCE_LOW).apply {
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                    description = "Call notifications"
                }
                manager.createNotificationChannel(channel)
            }
            // Ongoing: HIGH importance required for Android 14+ foreground service
            val ongoing = NotificationChannel("callkit_ongoing_channel_id", "CallKit", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
                description = "Ongoing call"
            }
            manager.createNotificationChannel(ongoing)
        }
    }

    private fun playDefaultRingtone() {
        stopRingtone()
        try {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE)
            mediaPlayer = MediaPlayer().apply {
                setDataSource(this@MainActivity, uri)
                isLooping = true
                setVolume(1.0f, 1.0f)
                prepare()
                start()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopRingtone() {
        mediaPlayer?.apply {
            if (isPlaying) stop()
            release()
        }
        mediaPlayer = null
    }

    override fun onDestroy() {
        super.onDestroy()
        stopRingtone()
    }
}
