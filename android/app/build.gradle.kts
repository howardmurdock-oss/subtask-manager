import java.io.File
import java.util.Properties

// Signing credentials live outside the repository, which is public. The file
// is read if present; without it a release build falls back to the debug key,
// so a checkout with no secrets still builds.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKeystore =
    keystoreProperties.getProperty("storeFile")?.let { path -> File(path).exists() } == true

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.subtaskmanager.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Must match the Android app registered in Firebase, or pushes are
        // accepted by FCM and silently never delivered.
        applicationId = "com.subtaskmanager.app"
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

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
            // v3 carries a signing-key lineage, which is the only way to
            // change this key later without every install having to be
            // removed and replaced. It costs nothing to enable now and cannot
            // be added retrospectively.
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    buildTypes {
        release {
            // The debug key is machine-local and can be regenerated at any
            // time; anything signed with it can only be updated for as long as
            // that particular keystore survives. A release build uses the real
            // key when key.properties points at one, and says so at build time
            // when it does not - silently shipping a debug-signed build is how
            // an app ends up unable to update itself.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("WARNING: no release keystore found (android/key.properties); signing with the debug key.")
                signingConfigs.getByName("debug")
            }

            // R8 shrinks release builds and strips the generic signatures Gson
            // relies on, which broke flutter_local_notifications' scheduled
            // alarm store at runtime. See proguard-rules.pro.
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // FileProvider, for handing the downloaded release to the installer.
    implementation("androidx.core:core-ktx:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
