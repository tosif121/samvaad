package com.samwad

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import android.util.Log

import android.os.Handler

class CallkitLifecycleTracker : Application.ActivityLifecycleCallbacks {

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        Log.d(TAG, "===== onActivityCreated: ${activity.javaClass.name} =====")
        if (activity.javaClass.name != "com.hiennv.flutter_callkit_incoming.TransparentActivity") {
            Log.d(TAG, "Not TransparentActivity — skipping")
            return
        }
        Log.d(TAG, "TransparentActivity detected — capturing pending action")
        val intent = activity.intent
        if (intent == null) {
            Log.d(TAG, "Intent is null — returning")
            return
        }
        val actionExtra = intent.getStringExtra("action")
        if (actionExtra == null) {
            Log.d(TAG, "action extra is null — returning")
            return
        }
        val callData = intent.getBundleExtra("data")
        if (callData == null) {
            Log.d(TAG, "data bundle is null — returning")
            return
        }
        val number = callData.getString("EXTRA_CALLKIT_NAME_CALLER", "") ?: ""
        Log.d(TAG, "Action: $actionExtra, Number: $number")

        val action = when {
            actionExtra.endsWith("ACTION_CALL_ACCEPT") -> "answer"
            actionExtra.endsWith("ACTION_CALL_DECLINE") -> "decline"
            else -> {
                Log.d(TAG, "Unknown action: $actionExtra — returning")
                return
            }
        }

        val prefs: SharedPreferences = activity.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE
        )
        prefs.edit()
            .putString("flutter.callkit_pending_action",
                """{"action":"$action","number":"$number"}""")
            .apply()
        Log.d(TAG, "Saved callkit_pending_action = $action")

        // Set stop ringtone flag immediately (both accept and decline)
        prefs.edit().putBoolean("flutter.callkit_stop_ringtone", true).apply()
        Log.d(TAG, "Set callkit_stop_ringtone = true for $action")

        // Send broadcast to FCM service to stop ringtone (cross-process safe)
        try {
            val stopIntent = Intent("com.samvaad.STOP_RINGTONE")
            activity.sendBroadcast(stopIntent)
            Log.d(TAG, "Sent STOP_RINGTONE broadcast for $action")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send STOP_RINGTONE broadcast: $e")
        }

        // Also cleanup foreground service after short delay (backup)
        Handler(activity.mainLooper).postDelayed({
            Log.d(TAG, "Executing cleanupForeground() for $action")
            SamvaadFcmService.cleanupForeground()
            Log.d(TAG, "cleanupForeground() done for $action")
        }, 500)

        if (action == "decline") {
            prefs.edit()
                .remove("flutter.fcm_pending_call")
                .remove("flutter.fcm_pending_call_ts")
                .apply()
            Log.d(TAG, "Decline — cleared fcm_pending_call for $number")
        }
        Log.d(TAG, "===== Captured CallKit action: $action for $number =====")
    }

    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityResumed(activity: Activity) {}
    override fun onActivityPaused(activity: Activity) {}
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}

    companion object {
        private const val TAG = "CallkitLifecycleTracker"
    }
}
