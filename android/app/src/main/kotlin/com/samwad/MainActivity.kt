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
        var isInForeground = false
        var pendingIncomingCallData: Map<String, String?>? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        isAlive = true
        isInForeground = true
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

        // Handle incoming call intent for cold start (app was killed)
        handleIncomingCallIntent(intent)

    }

    override fun onResume() {
        super.onResume()
        isInForeground = true
    }

    override fun onPause() {
        super.onPause()
        isInForeground = false
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        io.flutter.plugins.GeneratedPluginRegistrant.registerWith(flutterEngine)

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
                    manager.cancelAll()
                    result.success(true)
                }
                "cleanupForeground" -> {
                    result.success(true)
                }
                "getPendingIncomingCall" -> {
                    val data = pendingIncomingCallData
                    pendingIncomingCallData = null
                    result.success(data)
                }
                "setSpeakerphone" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    setSpeakerphone(on)
                    result.success(true)
                }
                "setCallMode" -> {
                    // Called when a call starts — pre-set earpiece BEFORE WebRTC audio begins
                    setSpeakerphone(false)
                    result.success(true)
                }
                "resetCallMode" -> {
                    // Called when a call ends — reset audio mode to normal
                    audioRouteRunnable?.let { audioRouteEnforcer?.removeCallbacks(it) }
                    try {
                        val audioManager = getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            audioManager.clearCommunicationDevice()
                        }
                        audioManager.mode = android.media.AudioManager.MODE_NORMAL
                    } catch (_: Exception) {}
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private var audioRouteEnforcer: android.os.Handler? = null
    private var audioRouteRunnable: Runnable? = null
    private var desiredSpeakerOn: Boolean = false

    private fun setSpeakerphone(on: Boolean) {
        desiredSpeakerOn = on
        applyAudioRoute(on)

        // Stop any existing enforcer
        audioRouteRunnable?.let { audioRouteEnforcer?.removeCallbacks(it) }

        // Re-apply the audio route several times over 3 seconds to defeat
        // WebRTC's internal audio routing resets in WebView
        if (!on) {
            audioRouteEnforcer = audioRouteEnforcer ?: android.os.Handler(mainLooper)
            var count = 0
            audioRouteRunnable = object : Runnable {
                override fun run() {
                    if (count < 6 && !desiredSpeakerOn) {
                        applyAudioRoute(false)
                        count++
                        audioRouteEnforcer?.postDelayed(this, 500)
                    }
                }
            }
            audioRouteEnforcer?.postDelayed(audioRouteRunnable!!, 500)
        }
    }

    private fun applyAudioRoute(speakerOn: Boolean) {
        try {
            val audioManager =
                getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager

            // Always set communication mode first
            audioManager.mode = android.media.AudioManager.MODE_IN_COMMUNICATION

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+ : use setCommunicationDevice for reliable routing
                val devices = audioManager.availableCommunicationDevices
                val targetType = if (speakerOn) {
                    android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                } else {
                    android.media.AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                }
                val device = devices.firstOrNull { it.type == targetType }
                if (device != null) {
                    val success = audioManager.setCommunicationDevice(device)
                    Log.d(TAG, "setCommunicationDevice(${if (speakerOn) "SPEAKER" else "EARPIECE"}): success=$success")
                } else {
                    // Fallback if device not found
                    @Suppress("DEPRECATION")
                    audioManager.isSpeakerphoneOn = speakerOn
                    Log.d(TAG, "setCommunicationDevice: target device not found, fallback isSpeakerphoneOn=$speakerOn")
                }
            } else {
                // Legacy path for Android < 12
                @Suppress("DEPRECATION")
                audioManager.requestAudioFocus(
                    null,
                    android.media.AudioManager.STREAM_VOICE_CALL,
                    android.media.AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                )
                @Suppress("DEPRECATION")
                audioManager.isSpeakerphoneOn = speakerOn
                Log.d(TAG, "setSpeakerphone(legacy): on=$speakerOn, mode=${audioManager.mode}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error applying audio route", e)
        }
    }

    private fun bringToForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
            Intent.FLAG_ACTIVITY_CLEAR_TOP or
            Intent.FLAG_ACTIVITY_SINGLE_TOP
        )
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
            pendingIncomingCallData = mapOf(
                "number" to number,
                "name" to (intent.getStringExtra("caller_name") ?: "Unknown"),
            )
            intent.putExtra("fcm_number", null as String?)
            intent.putExtra("caller_name", null as String?)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        isAlive = false
        stopRingtone()
    }
}
