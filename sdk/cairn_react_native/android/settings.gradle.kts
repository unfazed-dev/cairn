// =============================================================================
// @cairn/react-native Android library — gradle settings.
// Mirrors sdk/cairn_kotlin/android/settings.gradle.kts shape: AGP + Kotlin
// resolve from the standard plugin portals; no RN codegen gradle plugin is
// applied here (the Spec class is hand-mirrored in NativeCairnSpec.kt, so the
// library builds without a host RN app driving @react-native/codegen).
// =============================================================================
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "cairn-react-native"
