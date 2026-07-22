// How Redact obtains and shapes its model: the file manifest, the
// download/adopt/bundle sources, and the `ModelAssets` the pipeline consumes.
// (Running the model is `Model.swift`.) All platform variation is data here
// (which artifact ships where); building the platform's session is
// desert-ant-core's `inferenceSession` factory.
import Inference
import ModelStore

/// The model's file names and per-platform artifacts, in one place.
enum RedactModel {
    static let tokenizer = "redact_tokenizer.bin"
    static let labels = "labels.json"
    static let tflite = "redact.tflite"    // LiteRT platforms (Linux/Android/Windows) + wasm
    static let coreML = "redact.mlmodelc"  // Apple

    /// The runnable artifact on this platform. Both the Core ML and the LiteRT
    /// exports use the same fixed-256, int32, baked-position-ids window (see
    /// `Model.logits`), so there is no per-artifact tensor shaping to track.
    static var artifact: String { ModelPlatform.current == .apple ? coreML : tflite }
}

/// Loaded model inputs: the sidecar files plus a ready inference session. Also
/// the entry point for the cross-language bindings and custom deployments (not
/// part of the Swift SDK's public API, which loads assets for you).
@_spi(RedactBindings)
public struct ModelAssets: Sendable {
    /// Contents of `redact_tokenizer.bin` (compact SentencePiece vocab).
    public let tokenizer: [UInt8]
    /// Contents of `labels.json` (BIOES id->label map).
    public let labelsJSON: String
    /// The platform's ready-to-run session for the model artifact.
    let session: any InferenceSession

    /// Bindings entry point: in-memory model files (e.g. the Android AAR reads
    /// them from classpath resources). The model bytes must be the LiteRT
    /// (`.tflite`) export.
    public init(tokenizer: [UInt8], labelsJSON: String, modelBytes: [UInt8]) throws {
        self.init(
            tokenizer: tokenizer, labelsJSON: labelsJSON,
            session: try inferenceSession(modelBytes: modelBytes))
    }

    /// Bindings entry point: build from an already-constructed session (e.g. the
    /// wasm host's `JSInferenceSession`) plus the sidecars.
    @_spi(RedactBindings)
    public init(tokenizer: [UInt8], labelsJSON: String, session: any InferenceSession) {
        self.tokenizer = tokenizer
        self.labelsJSON = labelsJSON
        self.session = session
    }

    /// Build from a resolved model directory: read the sidecars and let the
    /// core pick this platform's session for the artifact.
    static func redact(files: StoredModel) async throws -> ModelAssets {
        ModelAssets(
            tokenizer: try files.read(RedactModel.tokenizer),
            labelsJSON: try files.readString(RedactModel.labels),
            session: try await files.inferenceSession(model: RedactModel.artifact, hostGlobal: "__RedactHost"))
    }
}

public extension Redact {
    /// The published model repository.
    static var modelRepo: String { "desert-ant-labs/redact" }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { "v0.3.0" }

    /// Resolve the model for `directory` (adopt your files, or download there),
    /// then build loadable assets. `nil` uses the managed cache.
    internal static func resolvedAssets(
        directory: String?,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelAssets {
        let files = try await distribution().resolve(cacheDirectory: directory, cacheRoot: cacheRoot) { progress($0.fraction) }
        return try await .redact(files: files)
    }

    /// Whether the model is available offline for `directory`.
    internal static func isModelAvailable(directory: String?, cacheRoot: String? = nil) -> Bool {
        distribution().isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot)
    }

    private static func distribution() -> ModelDistribution {
        let sidecars = [RedactModel.tokenizer, RedactModel.labels]
        let tflite = [RedactModel.tflite] + sidecars
        return ModelDistribution(
            repo: modelRepo,
            revision: modelRevision,
            files: [
                .apple: [RedactModel.coreML + "/"] + sidecars,
                .android: tflite,
                .linux: tflite,
                .windows: tflite,
                .web: tflite,
            ]
        )
    }
}

// MARK: opt-in app bundling (Apple / Linux)

// Add a model resources product (RedactCoreMLResources on Apple,
// RedactTFLiteResources on Linux) and pass its bundle. On Android, bundling is
// the optional `:redact-tflite-resources` artifact; wasm always downloads. This is
// the one platform conditional in the model code: `Bundle` is a Foundation
// type, so the initializer only exists where SwiftPM resource bundles do.
#if canImport(CoreML) || os(Linux)
import Foundation
import ModelResources

public extension Redact {
    /// Load a model bundled into your app:
    ///
    /// ```swift
    /// import RedactCoreMLResources
    /// let redact = Redact(bundle: RedactCoreMLResourcesBundle.bundle)
    /// ```
    convenience init(bundle: Bundle) {
        self.init(
            resolve: { _ in try ModelAssets.redact(bundle: bundle) },
            isAvailable: { true }
        )
    }
}

extension ModelAssets {
    /// Build from a resource bundle: the sidecars plus this platform's session
    /// for the bundled artifact.
    static func redact(bundle: Bundle) throws -> ModelAssets {
        let resources = BundledResources(bundle)
        let artifact = RedactModel.artifact
        do {
            return ModelAssets(
                tokenizer: try resources.read(RedactModel.tokenizer),
                labelsJSON: try resources.readString(RedactModel.labels),
                session: try inferenceSession(modelPath: try resources.path(artifact)))
        } catch {
            throw RedactError.resourceMissing
        }
    }
}
#endif
