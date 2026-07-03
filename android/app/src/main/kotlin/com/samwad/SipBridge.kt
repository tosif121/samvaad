package com.samwad

import android.util.Log
import io.flutter.plugin.common.MethodChannel

object SipBridge {
    private const val TAG = "SipBridge"

    var methodChannel: MethodChannel? = null
        set(value) {
            field = value
            Log.d(TAG, "MethodChannel set: ${value != null}")
        }

    fun sendCommand(method: String, args: Map<String, Any?>) {
        val ch = methodChannel
        if (ch == null) {
            Log.w(TAG, "No MethodChannel set, dropping: $method")
            return
        }
        try {
            ch.invokeMethod(method, args)
        } catch (e: Exception) {
            Log.e(TAG, "sendCommand failed: $method", e)
        }
    }
}
