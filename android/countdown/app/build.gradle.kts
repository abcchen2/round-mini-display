// Public source build: original signing keys are deliberately excluded.
import java.util.Properties
import java.io.File
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val signingDir = providers.gradleProperty("localSigningDir").orNull?.let { File(it) } ?: rootProject.file("keystore")
val ksProps = Properties().apply {
    val f = File(signingDir,"keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

// Generate a new development key on the recipient's machine, including when
// building directly in Android Studio. It is excluded from the source archive.
val localDebugKey = rootProject.file(".local/debug.keystore")
val identityFile = rootProject.file("personal.properties")
val identity = Properties().apply {
    if (identityFile.exists()) identityFile.inputStream().use { load(it) }
}
val personalId = identity.getProperty("personalApplicationId")
    ?: throw GradleException("Initialize this source folder first: python personal_identity.py (or use Build-Countdown.ps1).")
require(personalId.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")) && personalId.length <= 21) {
    "Invalid personalApplicationId; countdown native paths allow at most 21 ASCII characters."
}
require(personalId !in listOf("com.autonavi.amapauto", "com.autonavi.minimap")) { "Official AMap package names are not allowed." }
require(providers.gradleProperty("personalApplicationId").orNull.let { it == null || it == personalId }) {
    "The requested package differs from personal.properties. Restore the matching identity or use a clean folder."
}
require(identity.getProperty("signingEstablished") != "true" || localDebugKey.isFile) {
    "Signing key missing: restore .local/debug.keystore instead of generating another key."
}
val providerHslHash = providers.gradleProperty("providerHslSha256")
    .getOrElse("6c67ff15d76b54d808e50da64bb87fc23b8f8f6a86bbdfd92cf31fead9996a18")
require(providerHslHash.matches(Regex("[0-9a-f]{64}"))) { "Invalid provider native hash." }
val createLocalDebugKeystore = tasks.register<Exec>("createLocalDebugKeystore") {
    onlyIf { !localDebugKey.exists() }
    doFirst { localDebugKey.parentFile.mkdirs() }
    val executable = if (System.getProperty("os.name").startsWith("Windows")) "keytool.exe" else "keytool"
    commandLine(File(System.getProperty("java.home"), "bin/$executable").absolutePath,
        "-genkeypair", "-keystore", localDebugKey.absolutePath,
        "-storepass", "android", "-keypass", "android", "-alias", "androiddebugkey",
        "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
        "-dname", "CN=Android Debug,O=Android,C=US")
    doLast {
        identity.setProperty("signingEstablished", "true")
        identityFile.writer(Charsets.UTF_8).use { identity.store(it, null) }
    }
}
tasks.configureEach {
    if (name == "validateSigningDebug") dependsOn(createLocalDebugKeystore)
}

android {
    namespace = "com.yuminaga.motonav"
    compileSdk = 35

    defaultConfig {
        applicationId = personalId
        buildConfigField("String", "PROVIDER_HSL_SHA256", "\"$providerHslHash\"")
        minSdk = 28
        targetSdk = 35
        versionCode = 182
        versionName = "8.3.26-single.32-fresh.1"
        ndk { abiFilters += setOf("arm64-v8a") }
    }

    signingConfigs {
        getByName("debug") { storeFile = rootProject.file(".local/debug.keystore") }
        if (File(signingDir,"keystore.properties").exists()) {
            create("release") {
                storeFile = File(signingDir,ksProps.getProperty("storeFile"))
                storePassword = ksProps.getProperty("storePassword")
                keyAlias = ksProps.getProperty("keyAlias")
                keyPassword = ksProps.getProperty("keyPassword")
            }
        }
    }

    buildFeatures { buildConfig = true }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
        }
    }

    androidResources { additionalParameters += listOf("--package-id", "0x80") }

    packaging {
        jniLibs { useLegacyPackaging = true }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("com.amap.api:navi-3dmap-location-search:10.1.600_3dmap10.1.600_loc6.5.1_sea9.7.4")
}
