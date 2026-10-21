package com.anyhack.app

import android.content.Context
import android.hardware.ConsumerIrManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.anyhack.app/ir"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val irManager = getSystemService(Context.CONSUMER_IR_SERVICE) as? ConsumerIrManager
                when (call.method) {
                    "hasIrEmitter" -> {
                        result.success(irManager != null && irManager.hasIrEmitter())
                    }

                    "transmit" -> {
                        if (irManager == null || !irManager.hasIrEmitter()) {
                            result.error("NO_IR", "IR emitter not available", null)
                            return@setMethodCallHandler
                        }
                        val frequency = call.argument<Int>("frequency") ?: 38000
                        val pattern = call.argument<List<Int>>("pattern")
                        if (pattern == null || pattern.size < 2) {
                            result.error("BAD_PATTERN", "Empty or too short pattern", null)
                            return@setMethodCallHandler
                        }
                        try {
                            irManager.transmit(frequency, pattern.toIntArray())
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("TRANSMIT_FAILED", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
