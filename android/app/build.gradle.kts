plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.quilldown.viewer"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.quilldown.viewer"
        minSdk = 26 // Android 8.0+ so adaptive icons work without PNG fallbacks
        targetSdk = 34
        versionCode = 1
        versionName = "1.1.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
        debug {
            isDebuggable = true
        }
    }

    // Reuse the exact same web assets shipped with the macOS build so render
    // fidelity is identical. Gradle merges this directory into the APK's
    // assets/ root — render.html references sibling scripts by relative path
    // which resolves to file:///android_asset/<name>.
    sourceSets {
        getByName("main") {
            assets.srcDirs("src/main/assets", "../../Quilldown/Resources")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        buildConfig = true
    }
}

dependencies {
    // No external deps — WebView, Activity, and JSONObject are all platform APIs.
}
