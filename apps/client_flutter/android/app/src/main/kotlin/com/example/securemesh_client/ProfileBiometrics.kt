package com.example.securemesh_client

import android.app.Activity
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

/** UI-thread operations. Only authenticated Cipher operations touch the SQLCipher passphrase. */
internal class ProfileBiometrics(private val activity: Activity) {
    private val store by lazy { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } }
    private var cancelPending: (() -> Unit)? = null

    fun cancel() { cancelPending?.invoke() }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 30) {
            if (call.method == "status") result.success("unavailable")
            else result.error("unavailable", null, null)
            return
        }
        if (cancelPending != null) {
            result.error("busy", null, null)
            return
        }
        try {
            val path = File(requireNotNull(call.argument<String>("path"))).canonicalFile
            require(path.isFile && path.name.endsWith(".db"))
            require(path.toPath().startsWith(activity.applicationInfo.dataDir.let { File(it).canonicalFile.toPath() }))
            val id = MessageDigest.getInstance("SHA-256").digest(path.path.toByteArray())
                .joinToString("") { "%02x".format(it) }
            val alias = "securemesh.profile.biometric.v1.$id"
            val file = AtomicFile(File(activity.noBackupFilesDir, "unlock-v1-$id"))
            val enrolled = file.baseFile.exists()
            if (call.method == "forget") {
                if (store.containsAlias(alias)) store.deleteEntry(alias)
                file.delete()
                result.success(null)
                return
            }
            val strong = BiometricManager.Authenticators.BIOMETRIC_STRONG
            val available = activity.getSystemService(BiometricManager::class.java).canAuthenticate(strong) ==
                BiometricManager.BIOMETRIC_SUCCESS
            if (call.method == "status") {
                result.success(if (enrolled) "enrolled" else if (available) "available" else "unavailable")
                return
            }
            val enabling = call.method == "enable"
            require(enabling || call.method == "unlock")
            require(available && (enabling != enrolled))
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val input = if (enabling) {
                val secret = requireNotNull(call.argument<String>("passphrase"))
                require(secret.length in 1..1024)
                val device = requireNotNull(call.argument<String>("deviceId"))
                require(java.util.UUID.fromString(device).toString() == device)
                // An interrupted enrollment can leave an alias without an envelope.
                if (store.containsAlias(alias)) store.deleteEntry(alias)
                val key = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
                    init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                        .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setUserAuthenticationRequired(true)
                        .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                        .setInvalidatedByBiometricEnrollment(true).build())
                    generateKey()
                }
                val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
                    .getKeySpec(key, KeyInfo::class.java) as KeyInfo
                @Suppress("DEPRECATION")
                if (!info.isInsideSecureHardware || !info.isUserAuthenticationRequirementEnforcedBySecureHardware) {
                    store.deleteEntry(alias)
                    throw IllegalStateException("hardware unavailable")
                }
                cipher.init(Cipher.ENCRYPT_MODE, key)
                require(cipher.iv.size == 12)
                val encodedSecret = secret.toByteArray(Charsets.UTF_8)
                try {
                    device.toByteArray(Charsets.US_ASCII) + encodedSecret
                } finally { encodedSecret.fill(0) }
            } else {
                val key = store.getKey(alias, null) as? SecretKey ?: throw IllegalStateException()
                val encrypted = file.openRead().use { stream ->
                    require(stream.channel.size() in 29L..8192L)
                    stream.readBytes()
                }
                cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, encrypted, 0, 12))
                encrypted.copyOfRange(12, encrypted.size)
            }
            val stop = CancellationSignal()
            var finished = false
            fun finish(action: () -> Unit) {
                if (finished) return
                finished = true
                cancelPending = null
                try {
                    action()
                } finally {
                    input.fill(0)
                    if (enabling && !file.baseFile.exists()) {
                        // An unsuccessful prompt must never enroll this profile.
                        try { store.deleteEntry(alias) } catch (_: Exception) {
                            // No envelope exists. A retry discards any orphan alias.
                        }
                    }
                }
            }
            fun cancelled() = finish { result.error("cancelled", null, null) }
            cancelPending = { stop.cancel(); cancelled() }
            val ru = call.argument<Boolean>("russian") == true
            try {
                BiometricPrompt.Builder(activity)
                    .setTitle(if (ru) "Биометрия SecureMesh" else "SecureMesh biometric unlock")
                    .setAllowedAuthenticators(strong)
                    .setNegativeButton(if (ru) "Отмена" else "Cancel", activity.mainExecutor) { _, _ -> cancelled() }
                    .build().authenticate(BiometricPrompt.CryptoObject(cipher), stop, activity.mainExecutor,
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationError(code: Int, message: CharSequence) = cancelled()

                            override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                                finish {
                                    try {
                                        val granted = requireNotNull(auth.cryptoObject?.cipher)
                                        require(granted === cipher)
                                        granted.updateAAD(alias.toByteArray(Charsets.UTF_8))
                                        val output = granted.doFinal(input)
                                        try {
                                            if (enabling) {
                                                val out = file.startWrite()
                                                try {
                                                    out.write(granted.iv)
                                                    out.write(output)
                                                    file.finishWrite(out)
                                                } catch (error: Exception) {
                                                    file.failWrite(out)
                                                    throw error
                                                }
                                                result.success(null)
                                            } else {
                                                require(output.size > 36)
                                                result.success(mapOf(
                                                    "deviceId" to String(output, 0, 36, Charsets.US_ASCII),
                                                    "passphrase" to String(output, 36, output.size - 36, Charsets.UTF_8)
                                                ))
                                            }
                                        } finally { output.fill(0) }
                                    } catch (_: Exception) { result.error("unavailable", null, null) }
                                }
                            }
                        })
            } catch (_: Exception) {
                finish { result.error("unavailable", null, null) }
            }
        } catch (_: Exception) {
            if (call.method == "status") result.success("unavailable")
            else result.error("unavailable", null, null)
        }
    }
}
