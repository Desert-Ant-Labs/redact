import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Android library (AAR) with prebuilt native libraries. Gradle drives the
// native build: `apply(from = "swift-android.gradle.kts")` runs `mise run
// android-natives` (static-stdlib Swift JNI + LiteRT) before packaging,
// dropping the per-ABI libRedactAndroid.so into src/main/jniLibs. Redact bundles
// the LiteRT resources by default so normal installs work offline. Consumers who
// want download-on-demand can exclude the transitive resources artifact.
//
// Publishing: the AAR contains a prebuilt Swift native, so JitPack (which
// builds from source) cannot produce it. `mise run publish-android` publishes
// ai.desertant:redact to Maven Central via the Central portal (the vanniktech
// plugin handles upload, validation, and in-memory GPG signing; credentials
// come from the environment, usually via mise.local.toml.
plugins {
    id("com.android.library") version "8.7.3"
    id("org.jetbrains.kotlin.android") version "2.1.21"
    id("org.jetbrains.kotlin.plugin.serialization") version "2.1.21"
    id("com.vanniktech.maven.publish") version "0.34.0"
}

apply(from = "swift-android.gradle.kts")

group = "ai.desertant"
version = "0.7.0"

android {
    namespace = "ai.desertant.redact"
    compileSdk = 35

    defaultConfig {
        minSdk = 24 // NFKC now runs via the host java.text.Normalizer (API 1+), no platform libicu
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    buildTypes {
        release { isMinifyEnabled = false }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    // Reusable Android host bridge (ai.desertant.core.HostBridge + FfiReader),
    // shared across the Desert Ant model SDKs. Brings kotlinx-serialization-json
    // transitively (HostBridge parses the Hub tree JSON with it).
    implementation("ai.desertant:core:0.3.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    // Redact bundles the LiteRT resources by default so normal installs work
    // offline, matching Emo and Shapes. Consumers who want download-on-demand
    // exclude this transitive artifact.
    implementation(project(":redact-tflite-resources"))

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

mavenPublishing {
    publishToMavenCentral()
    // Sign only when a key is provided (CI/release); local publishToMavenLocal
    // stays keyless. ORG_GRADLE_PROJECT_signingInMemoryKey maps to this property.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) {
        signAllPublications()
    }
    coordinates("ai.desertant", "redact", version.toString())
    configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = true, publishJavadocJar = true))
    pom {
        name.set("Redact")
        description.set(
            "On-device multilingual PII redaction for Android: names, addresses, emails, cards, " +
                "IBANs, national IDs, VAT numbers and more across 24 EU languages.")
        url.set("https://github.com/Desert-Ant-Labs/redact")
        licenses {
            license {
                name.set("Desert Ant Labs Source-Available License 1.0")
                url.set("https://license.desertant.com/1.0")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("desert-ant-labs")
                name.set("Desert Ant Labs")
                email.set("contact@desertant.com")
                url.set("https://desertant.com")
            }
        }
        scm {
            url.set("https://github.com/Desert-Ant-Labs/redact")
            connection.set("scm:git:git://github.com/Desert-Ant-Labs/redact.git")
            developerConnection.set("scm:git:ssh://git@github.com/Desert-Ant-Labs/redact.git")
        }
    }
}
