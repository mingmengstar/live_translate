plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.live_translate"
    compileSdk = 35
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Use new compilerOptions DSL instead of deprecated kotlinOptions
    kotlin {
        jvmToolchain(17)
    }

    defaultConfig {
        applicationId = "com.example.live_translate"
        minSdk = 29
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Use ndk abiFilters for arm64-v8a priority
        ndk {
            abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a"))
        }
    }

    // 大模型文件不压缩，供 mmap 直接加载 - use packaging instead of packagingOptions
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
        // Exclude model files from compression
        resources {
            excludes += listOf("**/*.onnx", "**/*.bin", "**/*.gguf", "**/*.model")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}