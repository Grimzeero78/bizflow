import org.jetbrains.kotlin.gradle.tasks.KotlinCompile
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

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

    tasks.withType<KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(
                JvmTarget.JVM_17
            )
        }
    }

    configurations.all {
        resolutionStrategy {
            // Force resolution of core libraries to avoid the 'lStar' resource error.
            // Ensures all plugins use a consistent version of androidx.core.
            force("androidx.core:core:1.13.1")
            force("androidx.core:core-ktx:1.13.1")
        }
    }

    // FIX FOR ISAR & AGP 8+: add namespace if library forgot it
    plugins.withId("com.android.library") {
        extensions.getByType<com.android.build.gradle.LibraryExtension>().apply {
            if (namespace == null) {
                namespace = "com.bizflow.generated.${project.name.replace("-", "_").replace(".", "_")}"
            }
        }
    }

    // Globally force a compatible SDK version for all Android subprojects.
    // This resolves issues where plugins like tflite_flutter require API 30+ 
    // to compile Java 9+ source code.
    afterEvaluate {
        extensions.findByType<com.android.build.gradle.BaseExtension>()?.apply {
            compileSdkVersion(36)
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
