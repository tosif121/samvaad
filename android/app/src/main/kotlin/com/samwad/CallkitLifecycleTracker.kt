package com.samwad

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.util.Log

import android.os.Handler

class CallkitLifecycleTracker : Application.ActivityLifecycleCallbacks {

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        if (activity.javaClass.name != "com.hiennv.flutter_callkit_incoming.TransparentActivity") return
        Log.d(TAG, "TransparentActivity detected — capturing pending action")
        val intent = activity.intent ?: return
        val actionExtra = intent.getStringExtra("action") ?: return
        val callData = intent.getBundleExtra("data") ?: return
        val number = callData.getString("EXTRA_CALLKIT_NAME_CALLER", "") ?: ""

        val action = when {
            actionExtra.endsWith("ACTION_CALL_ACCEPT") -> "answer"
            actionExtra.endsWith("ACTION_CALL_DECLINE") -> "decline"
            else -> return
        }

        val prefs: SharedPreferences = activity.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE
        )
        prefs.edit()
            .putString("flutter.callkit_pending_action",
                """{"action":"$action","number":"$number"}""")
            .apply()
            
        Handler(activity.mainLooper).removeCallbacksAndMessages(null)

        if (action == "decline") {
            prefs.edit()
                .remove("flutter.fcm_pending_call")
                .remove("flutter.fcm_pending_call_ts")
                .apply()
            Log.d(TAG, "Decline — cleared FCM pending call for $number")
        }
        Log.d(TAG, "Captured CallKit action: $action for $number")
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
