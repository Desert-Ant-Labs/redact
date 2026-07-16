// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Redact: on-device PII redaction for every platform.
//
//   desert-ant-core           reusable primitives (Regex, JSON, ModelStore,
//                             Inference sessions + platform session factory)
//   Sources/Redact            shared pipeline (pure Swift; platform variation
//                             is data: which artifact ships where)
//   Sources/RedactCoreMLResources  Apple/Core ML model files (not LiteRT)
//   Sources/RedactTFLiteResources  LiteRT (.tflite) model files for Linux/Android/Windows
//   Sources/RedactAndroid    C ABI + Swift JNI -> packages/redact-kotlin (Android)
//   Sources/RedactWeb         wasm entry point -> packages/redact-node
//
// Platforms that load resources from a SwiftPM bundle (Apple + Linux; Android
// receives assets through the FFI and wasm through the JS host). Apple
// platforms get only Core ML resources; Linux gets only LiteRT resources.
let appleResourcePlatforms: [Platform] = [.macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS]

// The Android static-stdlib link needs no macros in the build graph, so this
// flag (set by `mise run android-natives`) drops JavaScriptKit and the wasm entry
// point. The wasm/JS code is all `#if os(WASI)`, so it is absent off-wasm anyway.
let noJavaScriptKit = ProcessInfo.processInfo.environment["SWIFT_ANDROID_STATIC_BUILD"] != nil

let jsDependencies: [Package.Dependency] = noJavaScriptKit ? [] : [
    .package(url: "https://github.com/swiftwasm/JavaScriptKit", from: "0.56.1"),
]
let wasmProducts: [Product] = noJavaScriptKit ? [] : [
    .executable(name: "RedactWeb", targets: ["RedactWeb"]),
]
let wasmTargets: [Target] = noJavaScriptKit ? [] : [
    .executableTarget(name: "RedactWeb", dependencies: ["Redact"] + [
        .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
        .product(name: "JavaScriptEventLoop", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
    ]),
]

let package = Package(
    name: "Redact",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Redact", targets: ["Redact"]),
        // Opt-in app bundling: add one of these and pass its bundle to
        // `Redact(bundle:)` to ship the model in your app instead of downloading.
        .library(name: "RedactCoreMLResources", targets: ["RedactCoreMLResources"]),
        .library(name: "RedactTFLiteResources", targets: ["RedactTFLiteResources"]),
        // Android JNI library (built by `mise run android-natives`).
        .library(name: "RedactAndroid", type: .dynamic, targets: ["RedactAndroid"]),
        // Native library for the Node.js server-side backend (built by
        // `mise run node-natives`). Shares the RedactAndroid target: on a host
        // (Linux/macOS) triple only the C ABI in `CABI.swift` compiles, since
        // `AndroidJNI.swift` is `#if os(Android)`, so koffi in packages/redact-node
        // binds the `redact_*` C ABI over the resulting libRedactNode.
        .library(name: "RedactNode", type: .dynamic, targets: ["RedactAndroid"]),
    ] + wasmProducts,
    dependencies: [
        // Reusable cross-platform primitives (Regex, JSON, TextNormalization,
        // ModelStore, FFIBuffer, HostBridge, CHostBridge).
        .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "0.3.0"),
        // Portable `Double.exp` for the softmax (stdlib has no transcendentals;
        // this avoids a per-platform libm import and Foundation on Android/wasm).
        .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0"),
    ] + jsDependencies,
    targets: [
        // MARK: core
        .target(
            name: "Redact",
            dependencies: [
                // Reusable, platform-abstracting primitives: the core just uses
                // `Pattern`/`rx` and `JSONDecoder` with no platform code.
                .product(name: "Regex", package: "desert-ant-core"),
                .product(name: "JSON", package: "desert-ant-core"),
                .product(name: "TextNormalization", package: "desert-ant-core"),
                .product(name: "ModelStore", package: "desert-ant-core"),
                .product(name: "PlatformSupport", package: "desert-ant-core"),
                .product(name: "ModelResources", package: "desert-ant-core"),
                .product(name: "RealModule", package: "swift-numerics"),
                // Named-tensor inference sessions (Core ML | LiteRT | JS
                // host); the engines in Engines/ are thin adapters over these.
                // The model is downloaded on demand by default; the resource
                // targets above are opt-in and passed via `Redact(bundle:)`, so
                // the core library does not depend on (or ship) the model.
                .product(name: "Inference", package: "desert-ant-core"),
            ]
        ),

        // MARK: resources (split so Apple apps do not ship the unused LiteRT model)
        .target(
            name: "RedactCoreMLResources",
            resources: [
                .copy("Resources/redact.mlmodelc"),
                .copy("Resources/redact_tokenizer.bin"),
                .copy("Resources/labels.json"),
                .copy("Resources/redact_meta.json"),
            ]
        ),
        .target(
            name: "RedactTFLiteResources",
            resources: [
                .copy("Resources/redact.tflite"),
                .copy("Resources/redact_tokenizer.bin"),
                .copy("Resources/labels.json"),
                .copy("Resources/redact_meta.json"),
            ]
        ),

        // MARK: Android JNI bindings (CABI.swift = redact_* C ABI + typed buffer,
        // AndroidJNI.swift = @_cdecl("Java_...") entry points; no C shim).
        .target(name: "RedactAndroid", dependencies: [
            "Redact",
            .product(name: "FFIBuffer", package: "desert-ant-core"),
            .product(name: "HostBridge", package: "desert-ant-core", condition: .when(platforms: [.android])),
            .product(name: "ModelStore", package: "desert-ant-core", condition: .when(platforms: [.android])),
            .product(name: "PlatformSupport", package: "desert-ant-core"),
        ]),

        // MARK: tests
        .testTarget(
            name: "RedactTests",
            dependencies: [
                "Redact",
                .target(name: "RedactCoreMLResources", condition: .when(platforms: appleResourcePlatforms)),
                .target(name: "RedactTFLiteResources", condition: .when(platforms: [.linux, .windows])),
            ],
            resources: [.copy("Resources/deterministic_corpus.json")]
        ),
    ] + wasmTargets
)
