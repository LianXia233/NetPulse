allprojects {
    repositories {
        // Flutter engine 构件在独立 Maven 仓库；放在最前面，避免受限网络下
        // 先连接 dl.google.com 失败而中断解析。
        maven {
            val base = System.getenv("FLUTTER_STORAGE_BASE_URL")
                ?: "https://storage.googleapis.com"
            url = uri("$base/download.flutter.io")
        }
        val isCi = !System.getenv("CI").isNullOrEmpty()
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

gradle.projectsEvaluated {
    rootProject.allprojects.forEach { p ->
        p.tasks.matching { it.name.startsWith("lintVital") }.configureEach { enabled = false }
    }
}
