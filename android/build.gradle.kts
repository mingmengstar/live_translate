allprojects {
    repositories {
        // 官方源优先，国内镜像仅作兜底。
        //
        // 历史事故（Run 45951861007，tag v0.7.0-ci-test-17）：
        // 此前阿里云镜像排在最前，它返回 502 后 Gradle 会把整个仓库标记为
        // disabled，连带 org.glassfish.jaxb:jaxb-runtime 解析失败，构建中断。
        // 单点故障不应排在关键路径上 —— CI 跑在海外，官方源才是最快最稳的。
        google()
        mavenCentral()

        // 以下镜像只为国内开发环境加速（海外 CI 命中上面两条就不会走到这里）。
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/central")
        maven("https://maven.aliyun.com/repository/public")
        maven("https://repo.huaweicloud.com/repository/maven/")
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 统一抬高 Flutter 插件模块（library 模块）的 compileSdk。
//
// 原因：quick_settings_with_flutter_plugins 1.3.1（已是 pub.dev 最新版）自身
// compileSdk 仍为 33，而它依赖的 androidx.window 1.2.0 / fragment 1.7.1 /
// activity 1.8.1 / lifecycle 2.7.0 均要求 compileSdk >= 34；
// AGP 9.3 的 checkReleaseAarMetadata 会因此直接判构建失败（共 15 项）。
//
// 说明：
// - 必须在 afterEvaluate 里覆盖：插件会在自己的 build.gradle 中写
//   android { compileSdk 33 }，若在此前设置会被插件配置重新覆盖。
// - 用反射按方法名匹配 setCompileSdk，不依赖具体 Extension 类型名
//   （AGP 版本间 LibraryExtension / CommonExtension 会变），
//   也不依赖 Kotlin 属性的 Int / Integer 装箱细节。
// - 只作用于非 app 模块，app 的 compileSdk 仍由 flutter.compileSdkVersion 决定。
subprojects {
    if (name == "app") return@subprojects

    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate

        // 只挑参数为 int / Integer 的 setCompileSdk，避免误匹配 setCompileSdk(String)
        val setter = androidExt.javaClass.methods.firstOrNull { m ->
            m.name == "setCompileSdk" && m.parameterTypes.size == 1 &&
                (m.parameterTypes[0] == Integer::class.java || m.parameterTypes[0] == Int::class.javaPrimitiveType)
        }
        if (setter == null) {
            logger.warn("[compileSdk-override] ${project.name}: setCompileSdk(int) not found, skipped")
            return@afterEvaluate
        }

        val before = runCatching {
            androidExt.javaClass.methods.firstOrNull {
                it.name == "getCompileSdk" || it.name == "getCompileSdkVersion"
            }?.invoke(androidExt)?.toString()
        }.getOrNull()

        runCatching { setter.invoke(androidExt, 36) }
            .onSuccess {
                val after = runCatching {
                    androidExt.javaClass.methods.firstOrNull {
                        it.name == "getCompileSdk" || it.name == "getCompileSdkVersion"
                    }?.invoke(androidExt)?.toString()
                }.getOrNull()
                logger.lifecycle("[compileSdk-override] ${project.name}: $before -> $after")
            }
            .onFailure { logger.warn("[compileSdk-override] ${project.name}: ${it.message}") }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
