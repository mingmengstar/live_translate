pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // 官方源优先，国内镜像仅作兜底（与 android/build.gradle.kts 保持一致）。
        //
        // 历史事故（Run 45951861007）：阿里云镜像排在首位时，一次 502 就会让
        // Gradle 把该仓库标记为 disabled，导致 lint 工具依赖
        // org.glassfish.jaxb:jaxb-runtime 解析失败、构建中断。
        // CI 跑在海外，官方源命中率与速度都更好，不该让镜像站在关键路径上。
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()

        // 以下镜像只为国内开发环境加速（海外 CI 命中上面几条后不会走到这里）。
        maven("https://maven.aliyun.com/repository/gradle-plugin")
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        maven("https://repo.huaweicloud.com/repository/gradle-plugin/")
        maven("https://repo.huaweicloud.com/repository/maven/")
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")
