package com.example.securemesh_client

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

/** Import encrypted bytes without loading the document or trusting its provider's filename as a path. */
class ProfileArchivePicker(private val activity: Activity) {
    companion object {
        const val requestCode = 47292
        private const val limit = 512L * 1024 * 1024
    }
    private var pending: MethodChannel.Result? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "pick") {
            result.notImplemented()
            return
        }
        if (pending != null) {
            result.error("PICK_BUSY", null, null)
            return
        }
        pending = result
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
            }, requestCode)
        } catch (_: Exception) {
            pending = null
            result.error("PICK_UNAVAILABLE", null, null)
        }
    }

    fun returned(resultCode: Int, uri: Uri?) {
        val result = pending ?: return
        if (resultCode != Activity.RESULT_OK || uri == null) {
            cancel()
            return
        }
        Thread {
            val folder = File(activity.cacheDir, "securemesh-archive-" + UUID.randomUUID())
            val snapshot = File(folder, "snapshot.db")
            try {
                require(uri.scheme == "content")
                val resolver = activity.contentResolver
                val columns = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
                val metadata = resolver.query(uri, columns, null, null, null) ?: error("No metadata")
                val expected = metadata.use { cursor ->
                    require(cursor.moveToFirst())
                    val name = cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))
                    require(name != null && name.endsWith(".db", ignoreCase = true))
                    val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (index < 0 || cursor.isNull(index)) null else cursor.getLong(index)
                }
                require(expected == null || expected in 4096L..limit)
                check(folder.mkdir())
                val input = resolver.openInputStream(uri) ?: error("No input stream")
                input.use { source ->
                    snapshot.outputStream().use { output ->
                        val buffer = ByteArray(65536)
                        var size = 0L
                        while (true) {
                            val count = source.read(buffer)
                            if (count < 0) break
                            size += count
                            require(count > 0 && size <= limit && (expected == null || size <= expected))
                            output.write(buffer, 0, count)
                        }
                        require(size >= 4096 && (expected == null || size == expected))
                    }
                }
                activity.runOnUiThread {
                    if (pending === result) {
                        pending = null
                        result.success(snapshot.path)
                    } else {
                        folder.deleteRecursively()
                    }
                }
            } catch (_: Exception) {
                folder.deleteRecursively()
                activity.runOnUiThread {
                    if (pending === result) {
                        pending = null
                        result.error("PICK_FAILED", null, null)
                    }
                }
            }
        }.start()
    }

    fun cancel() {
        pending?.success(null)
        pending = null
    }
}
