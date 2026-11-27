package com.example.securemesh_client;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.hardware.biometrics.BiometricManager;
import android.os.Bundle;
import android.util.Log;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

/** Runs inside the installed release app's UID on a disposable API 35 device. */
public final class BiometricFallbackInstrumentation extends Instrumentation {
    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override public void onStart() {
        Bundle report = new Bundle();
        try {
            Context context = getTargetContext();
            FutureTask<Void> task = new FutureTask<>(() -> {
                verify(context);
                return null;
            });
            context.getMainExecutor().execute(task);
            task.get(20, TimeUnit.SECONDS);
            report.putString("fallback", "verified");
            finish(Activity.RESULT_OK, report);
        } catch (Throwable error) {
            report.putString("stream", Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED, report);
        }
    }

    private static void verify(Context context) throws Exception {
        int status = context.getSystemService(BiometricManager.class)
                .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG);
        require(status != BiometricManager.BIOMETRIC_SUCCESS, "expected no enrolled biometric");
        ProfileBiometrics bridge = new ProfileBiometrics(context);
        File a = File.createTempFile("alice", ".db", context.getFilesDir());
        File b = File.createTempFile("bob", ".db", context.getFilesDir());
        File first = envelope(context, a);
        File second = envelope(context, b);
        try {
            expect(bridge, a, "status", "unavailable");
            expect(bridge, a, "enable", "error:unavailable");
            require(!first.exists(), "failed enrollment wrote a profile envelope");
            writeDummy(first);
            writeDummy(second);
            expect(bridge, a, "status", "enrolled");
            expect(bridge, a, "unlock", "error:unavailable");
            expect(bridge, a, "forget", null);
            require(!first.exists() && second.exists(), "forget crossed profile boundaries");
            expect(bridge, b, "unlock", "error:unavailable");
            require(a.exists() && b.exists(), "manual profile recovery files disappeared");
        } finally {
            first.delete();
            second.delete();
            a.delete();
            b.delete();
        }
    }

    private static void writeDummy(File file) throws Exception {
        try (FileOutputStream stream = new FileOutputStream(file)) {
            stream.write(new byte[64]);
        }
    }

    private static File envelope(Context context, File profile) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest(profile.getCanonicalPath().getBytes(StandardCharsets.UTF_8));
        StringBuilder name = new StringBuilder("unlock-v1-");
        for (byte value : digest) name.append(String.format(Locale.ROOT, "%02x", value));
        return new File(context.getNoBackupFilesDir(), name.toString());
    }

    private static void expect(ProfileBiometrics bridge, File profile, String operation, Object expected) {
        Map<String, Object> args = new HashMap<>();
        args.put("path", profile.getPath());
        args.put("deviceId", "00000000-0000-4000-8000-000000000001");
        args.put("passphrase", "synthetic test value");
        Object[] result = {"no reply"};
        bridge.handle(new MethodCall(operation, args), new MethodChannel.Result() {
            @Override public void success(Object value) { result[0] = value; }
            @Override public void error(String code, String message, Object details) { result[0] = "error:" + code; }
            @Override public void notImplemented() { result[0] = "not implemented"; }
        });
        require(Objects.equals(expected, result[0]), "unexpected result for " + operation);
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
