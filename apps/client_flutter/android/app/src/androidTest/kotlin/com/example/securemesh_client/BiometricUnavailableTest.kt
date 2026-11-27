package com.example.securemesh_client

import android.hardware.biometrics.BiometricManager
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest

@RunWith(AndroidJUnit4::class)
class BiometricUnavailableTest {
    // Runs on the CI API 35 emulator without enrolled strong biometrics.
    @Test fun manualFallbackAndProfileIsolation() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                assertNotEquals(BiometricManager.BIOMETRIC_SUCCESS,
                    activity.getSystemService(BiometricManager::class.java)
                        .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG))
                val channel = ProfileBiometrics(activity)
                val a = File.createTempFile("alice", ".db", activity.filesDir)
                val b = File.createTempFile("bob", ".db", activity.filesDir)
                fun envelope(profile: File): File {
                    val digest = MessageDigest.getInstance("SHA-256").digest(profile.canonicalPath.toByteArray())
                        .joinToString("") { "%02x".format(it) }
                    return File(activity.noBackupFilesDir, "unlock-v1-$digest")
                }
                fun call(method: String, file: File): Any? {
                    var answer: Any? = "NO_REPLY"
                    channel.handle(MethodCall(method, mapOf("path" to file.path,
                        "deviceId" to "00000000-0000-4000-8000-000000000001",
                        "passphrase" to "synthetic test value")), object : MethodChannel.Result {
                        override fun success(value: Any?) { answer = value }
                        override fun error(code: String, message: String?, details: Any?) { answer = "error:$code" }
                        override fun notImplemented() { answer = "NOT_IMPLEMENTED" }
                    })
                    return answer
                }
                try {
                    assertEquals("unavailable", call("status", a))
                    assertEquals("error:unavailable", call("enable", a))
                    assertFalse(envelope(a).exists())
                    // A copied or stale envelope cannot unlock either profile.
                    envelope(a).writeBytes(ByteArray(64) { 1 })
                    envelope(b).writeBytes(ByteArray(64) { 2 })
                    assertEquals("enrolled", call("status", a))
                    assertEquals("error:unavailable", call("unlock", a))
                    assertNull(call("forget", a))
                    assertFalse(envelope(a).exists())
                    assertTrue(envelope(b).exists())
                    assertEquals("error:unavailable", call("unlock", b))
                    assertTrue(a.exists())
                    assertTrue(b.exists())
                } finally {
                    a.delete(); b.delete()
                    envelope(a).delete(); envelope(b).delete()
                }
            }
        }
    }
}
