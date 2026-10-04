plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.voidrunner.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.voidrunner.app"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0-hackathon"

        vectorDrawables { useSupportLibrary = true }
    }

    // Release signing comes ONLY from the environment (CI secrets or local
    // keystore.properties). Nothing secret is ever committed — see README.
    val keystoreFile: java.io.File? =
        System.getenv("KEYSTORE_FILE")?.let { file(it) }?.takeIf { it.exists() }
    if (keystoreFile != null) {
        signingConfigs {
            create("release") {
                storeFile = keystoreFile
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS")
                keyPassword = System.getenv("KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            isDebuggable = true
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Signed only when a keystore is provided (CI tag builds). Otherwise
            // falls back to the debug key — fine for local testing, NOT for the store.
            if (keystoreFile != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging { resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" } }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.06.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.navigation:navigation-compose:2.8.5")

    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")

    // Solana Mobile Wallet Adapter (official). Provides the native connect /
    // session / sign flow against the Seeker's Seed Vault wallet.
    // Docs: https://github.com/solana-mobile/solana-mobile-docs (android-native)
    implementation("com.solanamobile:mobile-wallet-adapter-clientlib-ktx:2.0.8")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
