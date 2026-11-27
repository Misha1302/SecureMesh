package com.example.securemesh_client

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// The channel accepts only a language flag. Message text and sender never cross the bridge.
class MessageNotifications(private val activity: Activity) {
    private val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val channel = "private_messages"
    private val notification = 814
    private var permission: MethodChannel.Result? = null
    private fun allowed(): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
        return Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(channel)?.importance != NotificationManager.IMPORTANCE_NONE
    }
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "available" -> result.success(allowed())
                "enable" -> {
                    if (Build.VERSION.SDK_INT >= 26) {
                        manager.createNotificationChannel(NotificationChannel(channel, "SecureMesh", NotificationManager.IMPORTANCE_DEFAULT))
                    }
                    if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        if (permission != null) { result.success(false); return }
                        permission = result
                        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), permissionRequest)
                    } else result.success(allowed())
                }
                "settings" -> {
                    val intent = if (Build.VERSION.SDK_INT >= 26) {
                        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                    } else {
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:" + activity.packageName))
                    }
                    activity.startActivity(intent)
                    result.success(null)
                }
                "show" -> {
                    if (!allowed()) { result.success(false); return }
                    val launch = activity.packageManager.getLaunchIntentForPackage(activity.packageName) ?: error("No launch intent")
                    val content = PendingIntent.getActivity(activity, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                    @Suppress("DEPRECATION")
                    val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(activity, channel) else Notification.Builder(activity)
                    manager.notify(notification, builder.setSmallIcon(android.R.drawable.ic_dialog_email)
                        .setContentTitle("SecureMesh").setContentText(if (call.arguments == true) "Новое сообщение" else "New message")
                        .setVisibility(Notification.VISIBILITY_PRIVATE).setContentIntent(content).setAutoCancel(true).build())
                    result.success(true)
                }
                "clear" -> { manager.cancel(notification); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            if (permission === result) permission = null
            result.error("NOTIFICATION_UNAVAILABLE", null, null)
        }
    }
    fun permissionReturned() { permission?.success(allowed()); permission = null }
    fun detach() { permission?.success(false); permission = null }
    companion object { const val permissionRequest = 47292 }
}
