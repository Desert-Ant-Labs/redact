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
    ],
    targets: [
        .target(
            name: "Redact",
            resources: [
                .copy("Resources/redact.mlmodelc"),
                .copy("Resources/redact_tokenizer.bin"),
                .copy("Resources/labels.json"),
                .copy("Resources/redact_meta.json"),
            ]
        ),
        .testTarget(
            name: "RedactTests",
            dependencies: ["Redact"]
        ),
    ]
)
