import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. The keystore + passwords come from key.properties (gitignored;
// the keystore itself lives OUT of the repo at ~/.config/sequentia/). Without it a
// checkout still configures — the release build falls back to debug signing so a
// local `flutter run --release` works, but a DISTRIBUTED build must have it.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "io.sequentia.ambra"
    compileSdk = flutter.compileSdkVersion
    // Pin to the NDK we have fully installed (and that built the jniLibs .so),
    // instead of flutter.ndkVersion, whose default NDK auto-download was
    // landing incomplete (missing source.properties -> [CXX1101]).
    ndkVersion = "29.0.14206865"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.sequentia.ambra"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = (keystoreProperties["storeFile"] as String).let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
                // v1 (JAR) + v2 both enabled so the APK installs across every supported
                // API level (minSdk 24); v3 stays default-on for future key rotation.
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            // Release-signed with the stable Ambra key when key.properties is present
            // (a distributable, UPDATABLE APK — a debug key is machine-specific and gets
            // rejected as an invalid/mismatched package on install). Falls back to debug
            // only for a local checkout without the secret.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
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
