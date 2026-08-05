package com.samwad

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.media.AudioDeviceInfo
import android.media.AudioManager
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

        /**
         * Store the incoming call so it can be injected into the WebView on the
         * next resume. Called directly from the FCM service so we don't depend
         * on the OS delivering a background startActivity to this activity
         * (which OEMs often defer/drop).
         */
        fun storePendingIncomingCall(number: String, name: String) {
            pendingIncomingCallData = mapOf("number" to number, "name" to name)
        }
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
                "clearPendingCall" -> {
                    pendingIncomingCallData = null
                    result.success(true)
                }
                "getOverlayPermissionStatus" -> {
                    result.success(Settings.canDrawOverlays(this))
                }
                "openOverlayPermission" -> {
                    openOverlayPermission()
                    result.success(Settings.canDrawOverlays(this))
                }
                "openFullScreenPermission" -> {
                    result.success(openFullScreenPermission())
                }
                "setCallMode" -> {
                    // Called when a call starts — pre-set earpiece/headset BEFORE WebRTC audio begins
                    setSpeakerphone(false)
                    result.success(true)
                }
                "resetCallMode" -> {
                    // Called when a call ends — reset audio mode to normal
                    audioRouteRunnable?.let { audioRouteEnforcer?.removeCallbacks(it) }
                    unregisterCommunicationDeviceListener()
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

    // Device types that count as "a headset is connected" for routing purposes
    private val headsetTypes = setOf(
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_USB_HEADSET,
    )

    // Fires whenever Android's active communication device changes — including
    // when WebRTC/Chromium grabs the route for itself after the call actually
    // connects (which happens later than our initial setCallMode call, and
    // later than the old fixed 3-second reinforcement window covered).
    private var commDeviceListener: AudioManager.OnCommunicationDeviceChangedListener? = null

    private fun setSpeakerphone(on: Boolean) {
        desiredSpeakerOn = on
        applyAudioRoute(on)

        // Stop any existing short-burst enforcer
        audioRouteRunnable?.let { audioRouteEnforcer?.removeCallbacks(it) }

        if (!on) {
            // Re-apply the audio route several times over 3 seconds to defeat
            // WebRTC's *initial* audio routing resets in WebView
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

            // Also keep watching for the rest of the call, in case WebRTC
            // claims the route again later (e.g. once the callee answers and
            // the actual media track starts, which can happen well after the
            // initial burst above has finished).
            registerCommunicationDeviceListener()
        } else {
            unregisterCommunicationDeviceListener()
        }
    }

    /**
     * When not on speaker, prefer a connected headset (wired, USB, or
     * Bluetooth) over the phone's built-in earpiece. Falls back to the
     * built-in earpiece only if no headset is connected.
     */
    private fun preferredNonSpeakerDevice(devices: List<AudioDeviceInfo>): AudioDeviceInfo? {
        return devices.firstOrNull { it.type in headsetTypes }
            ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE }
    }

    private fun registerCommunicationDeviceListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        if (commDeviceListener != null) return // already registered
        try {
            val audioManager =
                getSystemService(android.content.Context.AUDIO_SERVICE) as AudioManager
            val listener = AudioManager.OnCommunicationDeviceChangedListener { device ->
                val isOnDesiredRoute =
                    device != null &&
                        (device.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE || device.type in headsetTypes)
                if (!desiredSpeakerOn && !isOnDesiredRoute) {
                    Log.d(TAG, "Communication device changed unexpectedly to type=${device?.type}; re-applying earpiece/headset route")
                    applyAudioRoute(false)
                }
            }
            audioManager.addOnCommunicationDeviceChangedListener(mainExecutor, listener)
            commDeviceListener = listener
        } catch (e: Exception) {
            Log.e(TAG, "Error registering communication device listener", e)
        }
    }

    private fun unregisterCommunicationDeviceListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val listener = commDeviceListener ?: return
        try {
            val audioManager =
                getSystemService(android.content.Context.AUDIO_SERVICE) as AudioManager
            audioManager.removeOnCommunicationDeviceChangedListener(listener)
        } catch (e: Exception) {
            Log.e(TAG, "Error unregistering communication device listener", e)
        } finally {
            commDeviceListener = null
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
                val device = if (speakerOn) {
                    devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                } else {
                    // Prefer a connected headset over the built-in earpiece
                    preferredNonSpeakerDevice(devices)
                }
                if (device != null) {
                    val success = audioManager.setCommunicationDevice(device)
                    Log.d(TAG, "setCommunicationDevice(type=${device.type}, speakerOn=$speakerOn): success=$success")
                } else {
                    // Fallback if device not found
                    @Suppress("DEPRECATION")
                    audioManager.isSpeakerphoneOn = speakerOn
                    Log.d(TAG, "setCommunicationDevice: target device not found, fallback isSpeakerphoneOn=$speakerOn")
                }
            } else {
                // Legacy path for Android < 12.
                // Note: the platform audio framework automatically routes to a
                // connected wired/Bluetooth headset over the earpiece whenever
                // isSpeakerphoneOn is false, so no extra device selection is
                // needed here.
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

    /**
     * Opens the "Display over other apps / Appear on top" settings screen for
     * the current device's OEM. Falls back to the stock Android overlay
     * permission screen, then to general app settings.
     */
    private fun openOverlayPermission() {
        if (Settings.canDrawOverlays(this)) return

        val manufacturer = Build.MANUFACTURER?.lowercase() ?: ""
        val oemIntent = buildOemOverlayIntent(manufacturer)
        if (oemIntent != null && resolveActivitySafe(oemIntent)) {
            try {
                startActivity(oemIntent)
                return
            } catch (e: Exception) {
                Log.w(TAG, "OEM overlay intent failed, falling back", e)
            }
        }

        try {
            val stockIntent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (resolveActivitySafe(stockIntent)) {
                startActivity(stockIntent)
                return
            }
        } catch (e: Exception) {
            Log.w(TAG, "Stock overlay intent failed, falling back", e)
        }

        openAppSettings()
    }

    private fun buildOemOverlayIntent(manufacturer: String): Intent? {
        return when {
            manufacturer.contains("xiaomi") ||
                manufacturer.contains("redmi") ||
                manufacturer.contains("poco") -> Intent().apply {
                component = ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.permissions.AppPermissionsEditorActivity"
                )
                putExtra("extra_pkgname", packageName)
            }

            manufacturer.contains("oppo") ||
                manufacturer.contains("realme") ||
                manufacturer.contains("oneplus") -> Intent().apply {
                component = ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.permission.floatwindow.FloatWindowListActivity"
                )
            }

            manufacturer.contains("vivo") ||
                manufacturer.contains("iqoo") -> Intent().apply {
                component = ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.AppPermissionActivity"
                )
            }

            manufacturer.contains("huawei") ||
                manufacturer.contains("honor") -> Intent().apply {
                component = ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.permissionmanager.ui.MainActivity"
                )
            }

            else -> null
        }
    }

    private fun resolveActivitySafe(intent: Intent): Boolean {
        return intent.resolveActivity(packageManager) != null
    }

    /**
     * Opens the "Full screen" (allow full-screen notifications / show while
     * locked) settings screen for this device. Prefers the Android 14+ per-app
     * full-screen toggle, then falls back to the per-app notification settings.
     */
    private fun openFullScreenPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                Uri.parse("package:$packageName")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (resolveActivitySafe(intent)) {
                try {
                    startActivity(intent)
                    return true
                } catch (e: Exception) {
                    Log.w(TAG, "Full screen intent failed, falling back", e)
                }
            }
        }

        try {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (resolveActivitySafe(intent)) {
                startActivity(intent)
                return true
            }
        } catch (e: Exception) {
            Log.w(TAG, "Notification settings intent failed", e)
        }

        return false
    }

    private fun openAppSettings() {
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null)
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Error opening app settings", e)
        }
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
        audioRouteRunnable?.let { audioRouteEnforcer?.removeCallbacks(it) }
        unregisterCommunicationDeviceListener()
    }
}