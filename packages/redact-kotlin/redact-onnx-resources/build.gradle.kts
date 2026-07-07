import com.vanniktech.maven.publish.JavaLibrary
import com.vanniktech.maven.publish.JavadocJar

// Optional bundled model for Redact on Android (the Android counterpart of the
// SwiftPM `RedactONNXResources` product). The model files (redact.onnx,
// redact_tokenizer.bin, labels.json) are staged into src/main/resources by
// `mise run android-natives`; this module packages them as classpath
// resources. An app bundles the model by depending on this artifact:
//
//     implementation("ai.desertant:redact")                 // the SDK (no model)
//     implementation("ai.desertant:redact-onnx-resources")  // opt-in: bundle the model
//
// Without it, `Redact(context)` downloads the model on demand instead.
plugins {
    `java-library`
    id("com.vanniktech.maven.publish") version "0.34.0"
}

group = "ai.desertant"
version = "0.3.0"

// The model files are staged (gitignored) by the root project's Swift build
// task; depend on it so a fresh checkout cannot produce or publish an empty
// model JAR, and fail fast if staging somehow left files missing.
val stageModel = rootProject.tasks.named("buildSwiftNatives")
tasks.processResources {
    dependsOn(stageModel)
}
tasks.withType<Jar>().matching { it.name == "sourcesJar" }.configureEach {
    dependsOn(stageModel)
    // The model binaries are the main jar's content; keep the sources jar
    // (required by Maven Central) minimal instead of duplicating ~14 MB.
    exclude("*.onnx", "*.bin", "labels.json")
}
tasks.jar {
    doFirst {
        val resources = file("src/main/resources")
        val required = listOf("redact.onnx", "redact_tokenizer.bin", "labels.json")
        val missing = required.filterNot { resources.resolve(it).isFile }
        check(missing.isEmpty()) {
            "model files missing from $resources: $missing (run `mise run android-natives`)"
        }
    }
}

mavenPublishing {
    publishToMavenCentral()
    if (providers.gradleProperty("signingInMemoryKey").isPresent) {
        signAllPublications()
    }
    coordinates("ai.desertant", "redact-onnx-resources", version.toString())
    configure(JavaLibrary(javadocJar = JavadocJar.Empty(), sourcesJar = true))
    pom {
        name.set("Redact ONNX resources")
        description.set("Opt-in bundled on-device Redact model files for Android (no network at runtime).")
        url.set("https://github.com/Desert-Ant-Labs/redact")
        licenses {
            license {
                name.set("Desert Ant Labs Source-Available License 1.0")
                url.set("https://license.desertant.ai/1.0")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("desert-ant-labs")
                name.set("Desert Ant Labs")
                email.set("contact@desertant.ai")
                url.set("https://desertant.ai")
            }
        }
        scm {
            url.set("https://github.com/Desert-Ant-Labs/redact")
            connection.set("scm:git:git://github.com/Desert-Ant-Labs/redact.git")
            developerConnection.set("scm:git:ssh://git@github.com/Desert-Ant-Labs/redact.git")
        }
    }
}
