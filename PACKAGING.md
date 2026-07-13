# Packaging

Three distributions, one core. Everything is a mise task: `build-*`, `test-*`,
and `publish-*` per platform, with the full logic inlined in `mise.toml` (no
separate shell scripts).

| Distribution | Consumers | Build | Test | Publish |
|---|---|---|---|---|
| Swift package (this repo) | iOS/macOS via SwiftPM | `mise run build-swift` | `mise run test-swift` | `mise run publish-swift` |
| `packages/redact-kotlin` (AAR) | Android via Maven Central | `mise run build-android` | `mise run test-android` | `mise run publish-android` |
| `packages/redact-node` | node + browsers via npm | `mise run build-web` | `mise run test-web` | `mise run publish-web` |

`mise run test` runs all three suites. `mise run android-natives` (internal)
cross-compiles the Swift core into jniLibs; it is what the Gradle AAR build
invokes before packaging.

The release version is single-sourced from `packages/redact-node/package.json`;
the two Gradle module versions must equal it (every publish task verifies).
Release all three from the same main commit: push main, then
`publish-swift` (tags `vX.Y.Z`), `publish-android`, `publish-web`.

All three distributions expose the same redaction-focused API as the iOS/Swift
SDK: create a redactor, call `redaction(...)`, use `restore(...)`. Loading
differs by platform idiom (see each section).

## Swift package (Apple platforms)

Consumers add this repo as a SwiftPM dependency and use the `Redact` product.
The model is downloaded on demand and cached, so the core library ships no
model. To bundle the model in the app instead, add the `RedactCoreMLResources`
product (Apple) or `RedactONNXResources` (Linux/Windows) and pass its bundle to
`Redact(bundle:)`. Everything runs on-device. `swift test` works on macOS
(Core ML) and Linux (ONNX Runtime, see below).

## Kotlin (Android AAR)

`packages/redact-kotlin` is an Android library (`com.android.library`). Gradle
drives the Swift build: `apply(from = "swift-android.gradle.kts")` runs
`mise run android-natives` before packaging, so a single `./gradlew` command
builds the AAR end-to-end (Gradle's `buildSwiftNatives` task shells out to mise).

The base `redact` AAR ships **no model** (it downloads on demand by default).
Bundling the model in the app is opt-in via a second artifact, `:redact-onnx-resources`
(`packages/redact-kotlin/redact-onnx-resources`), a resources JAR carrying `redact.onnx`
+ tokenizer + labels. A consumer bundles by adding both:

```kotlin
implementation("ai.desertant:redact")         // the SDK (native + Kotlin, no model)
implementation("ai.desertant:redact-onnx-resources")   // opt-in: bundle the model (~13 MB)
```

The Kotlin API mirrors iOS: create a `Redact` and reuse it.

```kotlin
val redact = Redact(context)   // download on demand, cached (or a directory you filled)
// or, with the redact-onnx-resources dependency:
val redact = Redact.bundled()          // bundled model, no network

val r = redact.redaction("Email Anna at anna@example.com.")
redact.isDownloaded(); redact.download(); redact.close()
```

There is no manual setup. On first run `mise run android-natives` installs everything it
needs: the version-matched Android Swift SDK, the Android NDK it depends on
(r27d+, configured via the bundle's `setup-android-sdk.sh`), and the per-ABI
`libonnxruntime.so` from the `onnxruntime-android` AAR (into
`Vendor/onnxruntime/lib/android-{aarch64,x86_64}/`). The native is stripped with
the toolchain's `llvm-objcopy`, so `ANDROID_NDK_HOME` is not needed. Then, from
`packages/redact-kotlin`:

```bash
ANDROID_HOME=<sdk> ./gradlew assembleRelease         # -> build/outputs/aar/redact-release.aar
ANDROID_HOME=<sdk> ./gradlew connectedDebugAndroidTest # instrumented tests on a device/emulator
```

The Gradle-invoked `mise run android-natives` cross-compiles `libRedactAndroid.so`
(the C ABI + Swift JNI over the core) for arm64-v8a and x86_64 with a **static
Swift stdlib** (`-static-stdlib`), so the whole Swift runtime is dead-stripped
into that one `.so` instead of shipping the ~10 MB dynamic runtime closure. Per
ABI it drops `libRedactAndroid.so` + `libc++_shared.so` + `libonnxruntime.so` into
`src/main/jniLibs` (packaged into the base AAR), and stages the model into
`redact-onnx-resources/src/main/resources` (the opt-in artifact, classpath, read via
`getResourceAsStream`).

The script sets `SWIFT_ANDROID_STATIC_BUILD=1`, which drops JavaScriptKit from
the manifest (its swift-syntax macros build for the host and conflict with the
`-resource-dir` static linking needs; the wasm code is all `#if os(WASI)` so it
is absent off-wasm anyway).

The Android build is Foundation-free (`java.util.regex.Pattern` and native JSON
through JNI, Android platform ICU NFKC; see ARCHITECTURE.md), so the per-ABI
native payload is ~26 MB unpacked (16.8 MB ONNX Runtime + 7.1 MB static
`libRedactAndroid.so` + 1.7 MB `libc++_shared.so`). It requires Android API 31+
because it links the NDK/system `libicu.so`. With the ~14 MB model assets, one
ABI totals ~40 MB raw; the Swift-core overhead over a pure-Kotlin build is the
~8.8 MB static Swift runtime + libc++.

The JNI is written directly in Swift (`Sources/RedactAndroid/AndroidJNI.swift`,
`@_cdecl("Java_...")` + `import Android`), so there is no C shim, and it is
Android-only (desktop JVM is not a target). Kotlin loads it with
`System.loadLibrary("RedactAndroid")` from the AAR's jniLibs; the model is read from
classpath resources.

The `src/androidTest` suite (the original redact-kotlin tests) runs on a
device/emulator via `./gradlew connectedDebugAndroidTest`, exercising the real
AAR path: `Redact` loads the model from resources and calls the Swift JNI.

Note: unlike the pure-Kotlin version, this artifact contains prebuilt Swift
binaries, so JitPack (which builds from source) cannot produce it. Publish
the assembled AAR to Maven Central/GitHub Packages or attach it to releases.

## node / browser (npm)

No manual setup: the WebAssembly Swift SDK auto-installs on first `mise run
wasm`, and `wasm-opt` (binaryen) is provisioned by mise. Then:

```bash
mise run build-web            # -> packages/redact-node/dist (wasm ~4.8 MB raw / ~1.7 MB gz)
cd packages/redact-node && npm pack   # inspect the tarball
```

The package mirrors the iOS/Swift SDK with a `Redact` class and an async factory
(loading is async on the web, so `await Redact.load(...)` replaces a constructor):

```js
import { Redact } from "@desert-ant-labs/redact";
const redact = await Redact.load();          // download on demand, cached
const r = await redact.redaction(text);
r.redactedText; r.items; r.restore(reply);
```

`Redact.load()` accepts `{ directory }` (an explicit model home; omit for the
managed `~/.cache/desert-ant-models/...` cache), `{ onProgress }` for download
progress, plus `{ ort }` for bring-your-own ONNX Runtime (e.g. a bundler-managed
onnxruntime-web import).
onnxruntime-node / onnxruntime-web are optional peer dependencies; the facade
picks whichever matches the environment. `npm test` in `packages/redact-node`
runs the redaction suite.

## Publishing

Each platform has a `publish-*` mise task. All three verify the release version
is consistent (package.json is the single source; the Gradle modules must
match). Bump everything at once with:

```bash
mise run set-version 0.4.0   # package.json + lock, both Gradle modules, README
```

then commit, push main, and publish.

### Swift (`mise run publish-swift`)

SwiftPM releases are semver tags on this repo: the task tags `vX.Y.Z` on
`main@origin` and pushes the tag. Consumers then pin
`.package(url: "https://github.com/Desert-Ant-Labs/redact", from: "X.Y.Z")`.
No credentials beyond git push access.

### Android (`mise run publish-android`)

Publishes `ai.desertant:redact` (AAR) and `ai.desertant:redact-onnx-resources`
(JAR) to Maven Central through the Central portal (vanniktech maven-publish
plugin: upload, validation, and in-memory GPG signing). JitPack cannot build
this AAR (it builds from source and lacks the Swift-for-Android toolchain), so
Central it is.

One-time setup:

1. Account at https://central.sonatype.com, claim the `ai.desertant` namespace
   (DNS TXT record on `desertant.ai`), and generate a publishing token.
2. A GPG key for signing: `gpg --gen-key`, then publish it:
   `gpg --keyserver keyserver.ubuntu.com --send-keys <KEY_ID>`.

Signing only engages when the key is present, so local
`./gradlew publishToMavenLocal` needs no setup. The task builds the natives
first (via the Gradle hook) and requires `ANDROID_HOME`.

### Secrets: `mise.local.toml`

All release credentials live in a gitignored **`mise.local.toml`** at the repo
root (mise loads it automatically for every task, so no manual exports). The
durable copies live in 1Password; this file is machine-local plumbing,
`chmod 600`. Shape:

```toml
[env]
ANDROID_HOME = "/path/to/android-sdk"

# Maven Central portal token (central.sonatype.com -> Generate User Token).
ORG_GRADLE_PROJECT_mavenCentralUsername = { value = "...", redact = true }
ORG_GRADLE_PROJECT_mavenCentralPassword = { value = "...", redact = true }

# Artifact signing (armored private key + its passphrase).
ORG_GRADLE_PROJECT_signingInMemoryKeyPassword = { value = "...", redact = true }
ORG_GRADLE_PROJECT_signingInMemoryKey = { value = '''
-----BEGIN PGP PRIVATE KEY BLOCK-----
...
-----END PGP PRIVATE KEY BLOCK-----
''', redact = true }

# npm automation token for @desert-ant-labs (publish-web).
NPM_TOKEN = { value = "npm_...", redact = true }
```

`redact = true` masks the values in mise task output. For encrypted-at-rest
secrets, mise also supports SOPS/age-encrypted env files
(https://mise.jdx.dev/environments/secrets/); not used here since the file is
local-only and 1Password is the source of truth.

### Web (`mise run publish-web`)

Builds `dist/` fresh and runs `npm publish --access public` for
`@desert-ant-labs/redact`. Auth: `NPM_TOKEN` in `mise.local.toml` (an
automation token with publish rights on the `desert-ant-labs` npm org; passed
via a throwaway `--userconfig`, so no checked-in or global npmrc carries
auth), or an interactive `npm login`. The tarball carries
index.js/index.d.ts, `dist/` (wasm + JS glue), README, and LICENSE.

## Dev loop on Linux (this repo)

```bash
mise run test-swift  # swift test with ONNX Runtime linked from Vendor/

# wasm examples (after mise run build-web; npm install in both dirs)
cd Examples/RedactWasmExample && node main.mjs && node browser-test.mjs
```

Vendored ONNX Runtime libraries (not committed) come from the v1.20.0 GitHub
release (linux-x64) and the `com.microsoft.onnxruntime:onnxruntime-android`
AAR (`jni/<abi>/libonnxruntime.so`), placed under `Vendor/onnxruntime/lib/`.
