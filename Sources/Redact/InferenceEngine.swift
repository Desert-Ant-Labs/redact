#if !os(WASI)
import Foundation
#endif

/// Abstraction over the platform inference runtime. Everything else in the
/// pipeline (tokenization, windowing, BIOES decoding, deterministic merge,
/// post-processing) is shared Swift; only this one call is platform-specific.
///
/// - Apple platforms: Core ML (`CoreMLEngine`, bundled `redact.mlmodelc`).
/// - Android / Linux: ONNX Runtime C API (`OrtEngine`, bundled `redact.onnx`).
/// - WebAssembly: a JS-provided runner (`JSEngine`, onnxruntime-web/-node).
protocol InferenceEngine {
    /// Run the token classifier over one window.
    /// `ids` is the full window including `<s>`/`</s>` (length <= 256).
    /// Returns row-major logits, `ids.count * numLabels` values.
    /// Async because the web backend awaits a JS Promise; native backends
    /// satisfy it synchronously.
    func logits(ids: [Int]) async throws -> (values: [Float], numLabels: Int)
}
