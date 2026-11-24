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

    val isCi = !System.getenv("CI").isNullOrEmpty()
    repositories {
        if (!isCi) {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
            maven { url = uri("https://maven.aliyun.com/repository/public") }
        }
        google()
        mavenCentral()
        gradlePluginPortal()
        if (isCi) {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
            maven { url = uri("https://maven.aliyun.com/repository/public") }
        }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

dependencyResolutionManagement {
    val isCi = !System.getenv("CI").isNullOrEmpty()
    repositories {
        // Flutter engine 的 io.flutter:* 构件在独立 Maven 仓库；
        // 通过 settings 声明，避免受 Gradle 仓库模式影响。国内可用
        // FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn 覆盖。
        val flutterStorage = System.getenv("FLUTTER_STORAGE_BASE_URL")
            ?: "https://storage.googleapis.com"
        maven { url = uri("$flutterStorage/download.flutter.io") }
        if (!isCi) {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/public") }
        }
        google()
        mavenCentral()
        if (isCi) {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/public") }
        }
    }
}

include(":app")
