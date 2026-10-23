package com.anyhack.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.hardware.ConsumerIrManager
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val irChannelName = "com.anyhack.app/ir"
    private val filesChannelName = "com.anyhack.app/files"

    private val requestCodePick = 4101
    private var pickPending: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ir канал
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, irChannelName)
            .setMethodCallHandler { call, result ->
                val irManager =
                    getSystemService(Context.CONSUMER_IR_SERVICE) as? ConsumerIrManager
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

        // saf пикер для импорта .ir файлов
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, filesChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickIr" -> {
                        if (pickPending != null) {
                            result.error("BUSY", "Picker already open", null)
                            return@setMethodCallHandler
                        }
                        pickPending = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        }
                        try {
                            startActivityForResult(intent, requestCodePick)
                        } catch (e: Exception) {
                            pickPending = null
                            result.error("LAUNCH", e.message, null)
                        }
                    }

                    "readIr" -> {
                        val uriStr = call.argument<String>("uri")
                        if (uriStr.isNullOrEmpty()) {
                            result.error("BAD_URI", "uri is empty", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val stream = contentResolver.openInputStream(Uri.parse(uriStr))
                            if (stream == null) {
                                result.error("OPEN", "Cannot open uri", null)
                                return@setMethodCallHandler
                            }
                            val bytes = stream.use { it.readBytes() }
                            result.success(bytes)
                        } catch (e: Exception) {
                            result.error("READ", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == requestCodePick) {
            val pending = pickPending
            pickPending = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                val uris = ArrayList<Uri>()
                val clip = data.clipData
                if (clip != null && clip.itemCount > 0) {
                    for (i in 0 until clip.itemCount) {
                        clip.getItemAt(i).uri?.let { uris.add(it) }
                    }
                } else {
                    data.data?.let { uris.add(it) }
                }
                val out = uris.map { u ->
                    mapOf("uri" to u.toString(), "name" to displayNameOf(u))
                }
                pending?.success(out)
            } else {
                pending?.success(emptyList<Map<String, String>>())
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun displayNameOf(uri: Uri): String {
        try {
            contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
            )?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        return c.getString(idx) ?: uri.lastPathSegment ?: "file"
                    }
                }
            }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment ?: "file"
    }
}
