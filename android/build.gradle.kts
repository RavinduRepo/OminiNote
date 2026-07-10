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

    // Some older plugins (e.g. receive_sharing_intent 1.8.x) set Java
    // compatibility to 1.8 while their Kotlin compile defaults to a newer JVM
    // target, causing "Inconsistent JVM Target Compatibility" build failures.
    // Force every plugin module to Java + Kotlin 17, matching the app. Register
    // this BEFORE evaluationDependsOn below (which triggers evaluation).
    afterEvaluate {
        (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)
            ?.compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java)
            .configureEach {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
    }

    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
