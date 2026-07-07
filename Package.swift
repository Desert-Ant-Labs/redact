// swift-tools-version: 5.9
import PackageDescription

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
        .executable(name: "RedactWasm", targets: ["RedactWasm"]),
    ],
    dependencies: [
        // JS interop for the WebAssembly build (browser / node).
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", from: "0.56.1"),
    ],
    targets: [
        // ONNX Runtime C API, used on platforms without Core ML (Android, Linux).
        // Vendored headers; link against libonnxruntime.so from
        // Vendor/onnxruntime/lib/<platform>/ (see README-android experiment).
        .systemLibrary(name: "COnnxRuntime"),
        // Model resources + Bundle accessor. Not used on WASI (the JS host
        // injects resources), keeping Foundation/ICU out of the wasm binary.
        .target(
            name: "RedactResources",
            resources: [
                .copy("Resources/redact.mlmodelc"),
                .copy("Resources/redact.onnx"),
                .copy("Resources/redact_tokenizer.bin"),
                .copy("Resources/labels.json"),
                .copy("Resources/redact_meta.json"),
            ]
        ),
        .target(
            name: "Redact",
            dependencies: [
                .target(name: "COnnxRuntime", condition: .when(platforms: [.linux, .android])),
                .target(name: "RedactResources", condition: .when(platforms: [
                    .macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS, .linux, .android, .windows,
                ])),
                .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
            ]
        ),
        .executableTarget(
            name: "redact-cli",
            dependencies: ["Redact"],
            path: "Sources/RedactCLI"
        ),
        // WebAssembly entry point: exposes the redactor to JS (browser / node).
        .executableTarget(
            name: "RedactWasm",
            dependencies: [
                "Redact",
                .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
            ]
        ),
        .testTarget(
            name: "RedactTests",
            dependencies: ["Redact", "RedactResources"]
        ),
    ]
)
