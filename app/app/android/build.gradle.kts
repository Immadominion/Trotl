allprojects {
    repositories {
        google()
        mavenCentral()
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

// Some plugins (e.g. solana_mobile_client) declare an old compileSdk (31) but
// pull androidx deps that require ≥ 34. Bump every Android subproject to 36
// after it evaluates (so it overrides the plugin's own value). `:app` is skipped
// — `evaluationDependsOn(":app")` above already evaluated it, so registering an
// afterEvaluate on it throws; it sets compileSdk = 36 in its own build script.
subprojects {
    if (name != "app") {
        afterEvaluate {
            (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)?.let { ext ->
                val current = ext.compileSdkVersion?.removePrefix("android-")?.toIntOrNull() ?: 0
                if (current < 34) ext.compileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
