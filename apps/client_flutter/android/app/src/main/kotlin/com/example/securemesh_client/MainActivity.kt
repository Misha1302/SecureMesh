package com.example.securemesh_client

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val biometrics by lazy { ProfileBiometrics(this) }
    private val notifications by lazy { MessageNotifications(this) }
    private val exportRequest = 47291
    private var pending: Pair<ByteArray, MethodChannel.Result>? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "securemesh/message_notifications").setMethodCallHandler(notifications::handle)
        MethodChannel(engine.dartExecutor.binaryMessenger, "securemesh/profile_biometrics")
            .setMethodCallHandler(biometrics::handle)
        MethodChannel(engine.dartExecutor.binaryMessenger, "securemesh/attachment-export")
            .setMethodCallHandler { call, result ->
                if (call.method != "save") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val bytes = call.argument<ByteArray>("bytes")
                val name = call.argument<String>("name")
                if (bytes == null || bytes.size !in 1..(4 * 1024 * 1024) || name.isNullOrBlank() || pending != null) {
                    result.error("EXPORT_UNAVAILABLE", null, null)
                    return@setMethodCallHandler
                }
                pending = Pair(bytes, result)
                try {
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }, exportRequest)
                } catch (_: Exception) {
                    pending = null
                    bytes.fill(0)
                    result.error("EXPORT_UNAVAILABLE", null, null)
                }
            }
    }

    @Deprecated("FlutterActivity uses the activity-result compatibility API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != exportRequest) return
        val (bytes, result) = pending ?: return
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            bytes.fill(0)
            result.success(false)
            return
        }
        Thread {
            try {
                require(uri.scheme == "content")
                val output = contentResolver.openOutputStream(uri, "wt") ?: error("No output")
                output.use { it.write(bytes) }
                runOnUiThread { result.success(true) }
            } catch (_: Exception) {
                runOnUiThread { result.error("EXPORT_FAILED", null, null) }
            } finally {
                bytes.fill(0)
            }
        }.start()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MessageNotifications.permissionRequest) notifications.permissionReturned()
    }

    override fun onDestroy() {
        pending?.let { (bytes, result) ->
            bytes.fill(0)
            result.success(false)
        }
        pending = null
        super.onDestroy()
    }

    override fun onStop() {
        biometrics.cancel()
        super.onStop()
    }

    override fun cleanUpFlutterEngine(engine: FlutterEngine) {
        biometrics.cancel()
        MethodChannel(engine.dartExecutor.binaryMessenger, "securemesh/profile_biometrics")
            .setMethodCallHandler(null)
        MethodChannel(engine.dartExecutor.binaryMessenger, "securemesh/attachment-export")
            .setMethodCallHandler(null)
        notifications.detach()
        MethodChannel(engine.dartExecutor.binaryMessenger, "securemesh/message_notifications").setMethodCallHandler(null)
        super.cleanUpFlutterEngine(engine)
    }
}
