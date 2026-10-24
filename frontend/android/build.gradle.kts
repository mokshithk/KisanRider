allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// 1. Add this block to force all plugins to use SDK 34
subprojects {
    afterEvaluate {
        if (project.plugins.hasPlugin("com.android.library") || project.plugins.hasPlugin("com.android.application")) {
            project.extensions.configure<com.android.build.gradle.BaseExtension>("android") {
                compileSdkVersion(36)
            }
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

// 2. Keep this line as it was
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}