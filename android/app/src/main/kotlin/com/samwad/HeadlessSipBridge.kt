package com.samwad

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

object HeadlessSipBridge {
    private const val TAG = "HeadlessSipBridge"
    private const val ENGINE_ID = "headless_sip_bridge"
    private const val CHANNEL = "sip_native_bridge"

    fun start(context: Context, callId: String, callerNumber: String?) {
        val engine = getOrCreateEngine(context)

        SipBridge.methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)

        SipBridge.sendCommand(
            "handleIncomingPush",
            mapOf(
                "call_id" to callId,
                "caller_number" to (callerNumber ?: "")
            )
        )
        Log.d(TAG, "Headless engine started, handleIncomingPush sent")
    }

    private fun getOrCreateEngine(context: Context): FlutterEngine {
        val cached = FlutterEngineCache.getInstance().get(ENGINE_ID)
        if (cached != null) return cached

        val engine = FlutterEngine(context)
        val defaultEntrypoint = DartExecutor.DartEntrypoint.createDefault()
        val entrypoint = DartExecutor.DartEntrypoint(
            defaultEntrypoint.pathToBundle,
            "backgroundMain"
        )
        engine.dartExecutor.executeDartEntrypoint(entrypoint)
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        Log.d(TAG, "Headless FlutterEngine created and cached")
        return engine
    }
}
