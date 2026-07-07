# Experiment: one Swift codebase, Android (and Linux) via ONNX Runtime

Goal: write the redact logic once in Swift and run it everywhere, instead of
maintaining parallel ports in Kotlin/JS. All shared logic (tokenizer, windowing,
BIOES decoding, deterministic recognizers, span post-processing, placeholder
assembly) is the existing Swift code, unchanged. Only the inference call is
platform-specific:

- Apple platforms: Core ML (`CoreMLEngine`, bundled `redact.mlmodelc`), as before.
- Android / Linux: ONNX Runtime C API (`OrtEngine`, bundled `redact.onnx`, the
  same model file the Kotlin runtime ships).

The seam is the `InferenceEngine` protocol (`Sources/Redact/InferenceEngine.swift`):
one method, `logits(ids:)`, taking a <=256 token window and returning per-token
logits. `Model.swift` no longer imports CoreML; it picks the backend with
`#if canImport(CoreML)`. (The method is `async` so the WebAssembly backend can
await a JS Promise, see WEB.md; native backends satisfy it synchronously.)

Status: works. `swift test` passes on Linux, and `redact-cli` produces
bit-identical redactions on x86_64 Linux and an Android 11 emulator
(x86_64, API 30), including multilingual text. An aarch64 Android build links
fine too (untested on hardware). ~180-440 ms per short text on emulator (debug
build, CPU).

## Layout

- `Sources/COnnxRuntime/` - system library target for the ORT C API
  (vendored `onnxruntime_c_api.h` from ORT 1.20.0, `link "onnxruntime"`).
- `Sources/Redact/OrtEngine.swift` - ORT backend (~100 lines, the only new
  runtime code).
- `Sources/Redact/CoreMLEngine.swift` - Core ML I/O moved out of `Model.swift`.
- `Sources/Redact/Resources/redact.onnx` - same artifact as redact-kotlin.
- `Sources/RedactCLI/` - smoke-test executable.
- `Vendor/onnxruntime/lib/<platform>/` - untracked; `libonnxruntime.so` per
  platform. Linux x64 from the GitHub release tgz, Android libs from the
  `com.microsoft.onnxruntime:onnxruntime-android:1.20.0` AAR (`jni/<abi>/`).

## Build and run (Linux host)

```bash
swift build -Xlinker -LVendor/onnxruntime/lib/linux-x64
LD_LIBRARY_PATH=$PWD/Vendor/onnxruntime/lib/linux-x64 ./.build/debug/redact-cli "some text"
LD_LIBRARY_PATH=$PWD/Vendor/onnxruntime/lib/linux-x64 swift test -Xlinker -LVendor/onnxruntime/lib/linux-x64
```

## Build for Android

One-time setup (Swift 6.3.2 toolchain + official Swift SDK for Android + NDK r27+):

```bash
swift sdk install https://download.swift.org/swift-6.3.2-release/android-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_android.artifactbundle.tar.gz
ANDROID_NDK_HOME=~/android-ndk/android-ndk-r27c \
  bash ~/.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh
```

Then:

```bash
swift build --swift-sdk aarch64-unknown-linux-android28 -Xlinker -LVendor/onnxruntime/lib/android-arm64
# or x86_64-unknown-linux-android28 with lib/android-x86_64 for the emulator
```

Run on a device/emulator by pushing the binary, the `Redact_Redact.resources`
bundle from the build dir, `libonnxruntime.so`, the Swift runtime `.so`s from
the SDK bundle (`swift-android/swift-resources/usr/lib/swift-<arch>/android/`),
and the NDK's `libc++_shared.so`, then:

```bash
adb shell 'cd /data/local/tmp/redact && LD_LIBRARY_PATH=$PWD ./redact-cli'
```

## Caveats / next steps for a real Android runtime

- Packaging: a real `redact-android` would ship the Swift library + deps as an
  AAR with a thin JNI or `swift-java` surface, not a pushed CLI. The .so
  payload is ~90 MB unstripped debug here; release + stripped + only-needed
  runtime libs will be much smaller.
- Resource loading: `Bundle.module` works for an exe next to its `.resources`
  dir; inside an APK the model/tokenizer would be loaded from assets paths
  passed in from Kotlin instead.
- Both `redact.mlmodelc` and `redact.onnx` are currently bundled resources, so
  Apple bundles gain ~14 MB dead weight. Per-platform resource selection (or
  fetching, like redact-js) is needed before shipping.
- `swift test` cross-compiled for Android is not wired up (would need an
  on-device XCTest runner); host Linux tests cover the shared logic + ORT path.
- ORT session uses default CPU options; NNAPI/XNNPACK execution providers are
  available in the same AAR if we want speed later.
