package com.example.securemesh_client

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.CancellationSignal
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/** Read only on a user gesture. Never coerce clipboard text, intents or URLs. */
internal class ClipboardPhoto(private val activity: Activity) {
    private var current: CancellationSignal? = null

    fun cancel() { current?.cancel() }

    fun read(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "read") { result.notImplemented(); return }
        if (current != null || !activity.hasWindowFocus()) {
            result.error("unavailable", null, null); return
        }
        try {
            val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = clipboard.primaryClip
            val uri = if (clip?.itemCount == 1) clip.getItemAt(0).uri else null
            if (uri == null || uri.scheme != "content" || uri.authority.isNullOrEmpty()) {
                result.success(null); return
            }
            val signal = CancellationSignal()
            current = signal
            Thread {
                try {
                    val resolver = activity.contentResolver
                    val type = resolver.getType(uri)
                    val bytes = if (type == "image/png" || type == "image/jpeg") {
                        resolver.openAssetFileDescriptor(uri, "r", signal)?.use { asset ->
                            require(asset.length <= LIMIT)
                            asset.createInputStream().use { input ->
                                val out = ByteArrayOutputStream()
                                val buffer = ByteArray(16384)
                                while (true) {
                                    signal.throwIfCanceled()
                                    val n = input.read(buffer)
                                    if (n < 0) break
                                    require(n > 0 && n <= LIMIT - out.size())
                                    out.write(buffer, 0, n)
                                }
                                out.toByteArray()
                            }
                        }
                    } else null
                    activity.runOnUiThread {
                        current = null
                        if (signal.isCanceled) result.success(null) else result.success(bytes)
                    }
                } catch (_: Exception) {
                    activity.runOnUiThread { current = null; result.error("unavailable", null, null) }
                }
            }.start()
        } catch (_: Exception) { result.error("unavailable", null, null) }
    }

    companion object { private const val LIMIT = 4 * 1024 * 1024 }
}
