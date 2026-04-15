import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Load release signing config from ~/.quilldown/keystore.properties if present.
// The file and keystore live outside the repo so secrets never enter git.
// Other machines fall through to an unsigned release build.
val keystorePropsFile = file("${System.getProperty("user.home")}/.quilldown/keystore.properties")
val keystoreProps = Properties()
if (keystorePropsFile.exists()) {
    keystorePropsFile.inputStream().use { keystoreProps.load(it) }
}

android {
    namespace = "com.quilldown.viewer"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.quilldown.viewer"
        minSdk = 26 // Android 8.0+ so adaptive icons work without PNG fallbacks
        targetSdk = 34
        versionCode = 2
        versionName = "1.1.2"
    }

    signingConfigs {
        create("release") {
            if (keystoreProps.isNotEmpty()) {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (keystoreProps.isNotEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
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
    // ComponentActivity gives us `registerForActivityResult(...)` for the
    // system file picker (Storage Access Framework).
    implementation("androidx.activity:activity-ktx:1.9.3")
}
