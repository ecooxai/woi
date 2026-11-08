plugins {
    id("com.android.application")
    id("com.chaquo.python")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.woi.woi"
    testBuildType = providers.gradleProperty("woiTestBuildType").orElse("debug").get()
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.woi.woi"
        testInstrumentationRunner = "dev.woi.woi.PythonInstrumentation"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        ndk { abiFilters.clear() }
        targetSdk = flutter.targetSdkVersion
        // Each ABI flavor preserves Flutter's previous split APK version offset.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Chaquopy packages Python native modules as assets. ABI flavors keep
    // both those assets and JNI libraries aligned without APK split conflicts.
    flavorDimensions += "abi"
    productFlavors {
        create("armv7") {
            dimension = "abi"
            ndk { abiFilters += "armeabi-v7a" }
            versionCode = flutter.versionCode + 1000
        }
        create("arm64") {
            dimension = "abi"
            ndk { abiFilters += "arm64-v8a" }
            versionCode = flutter.versionCode + 2000
        }
        create("x64") {
            dimension = "abi"
            ndk { abiFilters += "x86_64" }
            versionCode = flutter.versionCode + 4000
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles("proguard-rules.pro")
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

// Python 3.11 preserves support for the app's 32-bit and 64-bit ABIs.
// Source packaging avoids requiring this exact Python minor on the build host.
chaquopy {
    defaultConfig {
        version = "3.11"
        pyc {
            src = false
            pip = false
            stdlib = false
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
