plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseStore = providers.environmentVariable("SECUREMESH_SIGNING_STORE")
val debugNativeDir = layout.buildDirectory.dir("generated/securemesh/debug/jniLibs")
val releaseNativeDir = layout.buildDirectory.dir("generated/securemesh/release/jniLibs")

android {
    testBuildType = "release"
    sourceSets.getByName("debug").jniLibs.srcDir(debugNativeDir.get().asFile)
    sourceSets.getByName("release").jniLibs.srcDir(releaseNativeDir.get().asFile)

    signingConfigs {
        if (releaseStore.isPresent) {
            create("distribution") {
                storeFile = file(releaseStore.get())
                storePassword = providers.environmentVariable("SECUREMESH_STORE_PASSWORD").get()
                keyAlias = providers.environmentVariable("SECUREMESH_KEY_ALIAS").get()
                keyPassword = providers.environmentVariable("SECUREMESH_KEY_PASSWORD").get()
            }
        }
    }

    namespace = "com.example.securemesh_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        testInstrumentationRunner = "com.example.securemesh_client.BiometricFallbackInstrumentation"
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.securemesh_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("distribution")
            testProguardFile("instrumentation-rules.pro")
            proguardFile("biometric-bridge.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}


// Build against the same Android NDK and minimum API level as Flutter.
// Keep generated binaries in Gradle's build directory, outside source control.
val supportedAbis = mapOf(
    "android-arm" to "armeabi-v7a", "android-arm64" to "arm64-v8a", "android-x64" to "x86_64"
)
val requestedAbis = providers.gradleProperty("target-platform").orNull
    ?.split(",")?.map(supportedAbis::getValue) ?: supportedAbis.values.toList()

fun registerCryptoTask(name: String, output: File, abis: List<String>) = tasks.register<Exec>(name) {
    val crate = rootProject.file("../../../src/crypto_core")
    inputs.dir(crate.resolve("src"))
    inputs.files(crate.resolve("Cargo.toml"), crate.resolve("Cargo.lock"))
    outputs.dir(output)
    // cargo-ndk and the Android NDK are external inputs. Let Cargo track its
    // own incremental state even when Gradle has retained the shared libraries.
    outputs.upToDateWhen { false }
    workingDir(crate)
    // cargo-ndk prints its child environment when reporting a panic.
    // The native compiler has no role in signing the APK.
    setEnvironment(environment.filterKeys { !it.startsWith("SECUREMESH_") })
    environment("ANDROID_NDK_HOME", androidComponents.sdkComponents.ndkDirectory.get().asFile)
    commandLine(listOf("cargo", "ndk") + abis.flatMap { listOf("-t", it) } + listOf(
        "--platform", android.defaultConfig.minSdk.toString(), "-o", output.absolutePath,
        "build", "--locked", "--release", "--lib"))
}
val buildReleaseCrypto = registerCryptoTask("buildReleaseCrypto", releaseNativeDir.get().asFile, supportedAbis.values.toList())
val buildDebugCrypto = registerCryptoTask("buildDebugCrypto", debugNativeDir.get().asFile, requestedAbis)
tasks.matching { it.name == "preDebugBuild" }.configureEach { dependsOn(buildDebugCrypto) }
tasks.matching { it.name == "preReleaseBuild" }.configureEach { dependsOn(buildReleaseCrypto) }
