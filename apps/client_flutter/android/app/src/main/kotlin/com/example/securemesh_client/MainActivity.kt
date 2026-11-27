package com.example.securemesh_client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val biometrics by lazy { ProfileBiometrics(this) }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "securemesh/profile_biometrics")
            .setMethodCallHandler(biometrics::handle)
    }

    override fun onStop() {
        biometrics.cancel()
        super.onStop()
    }

    override fun cleanUpFlutterEngine(engine: FlutterEngine) {
        biometrics.cancel()
        MethodChannel(engine.dartExecutor.binaryMessenger, "securemesh/profile_biometrics")
            .setMethodCallHandler(null)
        super.cleanUpFlutterEngine(engine)
    }
}
