package com.samwad

import android.content.Intent
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.samvaad/ringtone"
    private var mediaPlayer: MediaPlayer? = null

    companion object {
        private const val TAG = "MainActivity"
        var isAlive = false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        isAlive = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON
        )

        // Request USE_FULL_SCREEN_INTENT permission on Android 14+
        requestFullScreenIntentPermission()
    }

    private fun requestFullScreenIntentPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val notificationManager = getSystemService(android.content.Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            if (!notificationManager.canUseFullScreenIntent()) {
                val intent = Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                    putExtra(android.provider.Settings.EXTRA_CHANNEL_ID, "samvaad_incoming_calls")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                try {
                    startActivity(intent)
                } catch (e: Exception) {
                    val settingsIntent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = android.net.Uri.parse("package:$packageName")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    try {
                        startActivity(settingsIntent)
                    } catch (_: Exception) {}
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                "bringAppToForeground" -> {
                    bringToForeground()
                    result.success(true)
                }
                "clearNotification" -> {
                    val manager = getSystemService(android.content.Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
                    manager.cancel(1001)
                    manager.cancel(1002)
                    result.success(true)
                }
                "cleanupForeground" -> {
                    SamvaadFcmService.cleanupForeground()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun bringToForeground() {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        try {
            startActivity(launchIntent)
        } catch (e: Exception) {
            e.printStackTrace()
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON
        )
        // Handle incoming call intent from notification
        handleIncomingCallIntent(intent)
    }

    private fun handleIncomingCallIntent(intent: Intent) {
        val number = intent.getStringExtra("fcm_number")
        if (number != null && number.isNotEmpty()) {
            Log.d(TAG, "Incoming call from notification for: $number")
            intent.putExtra("fcm_number", null as String?) // consume the extra
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        isAlive = false
        stopRingtone()
    }
}
