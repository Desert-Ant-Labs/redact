#if os(WASI)
import JavaScriptEventLoop
import JavaScriptKit

/// WebAssembly inference backend. The JS host (browser or node) owns the ONNX
/// session (onnxruntime-web / onnxruntime-node / transformers.js) and exposes:
///
/// ```js
/// globalThis.__redactResources = { tokenizer: Uint8Array, labels: string|Uint8Array }
/// globalThis.__redactRunModel = async (idsInt32Array) =>
///     ({ logits: Float32Array, numLabels: number })
/// ```
///
/// Everything else (tokenization, windowing, decoding, post-processing) runs
/// inside the wasm module, shared with the Apple/Android builds.
final class JSEngine: InferenceEngine {
    private let runModel: JSObject

    init() throws {
        guard let fn = JSObject.global.__redactRunModel.object else { throw RedactError.resourceMissing }
        runModel = fn
    }

    /// NFKC normalization via the host JS engine (`String.prototype.normalize`);
    /// keeps ICU out of the wasm binary.
    private static let normalizeFn: JSObject =
        JSObject.global.Function.function!.new("s", "return s.normalize('NFKC')")
    static func nfkc(_ s: String) -> String {
        normalizeFn(s).string ?? s
    }

    /// Injected tokenizer bytes from the JS host.
    static func tokenizerBytes() -> [UInt8]? {
        guard let resources = JSObject.global.__redactResources.object,
              let bytes = JSTypedArray<UInt8>(from: resources.tokenizer)
        else { return nil }
        return bytes.withUnsafeBytes { Array($0) }
    }

    /// Injected label map, parsed by the host's `JSON.parse` (keeps
    /// FoundationEssentials' JSONDecoder out of the wasm binary).
    static func labelMap() -> [Int: String]? {
        guard let resources = JSObject.global.__redactResources.object,
              let labelsJSON = resources.labels.string
        else { return nil }
        let parsed = JSObject.global.JSON.object!.parse!(labelsJSON)
        guard let obj = parsed.id2label.object ?? parsed.object else { return nil }
        let keys = JSObject.global.Object.function!.keys!(obj)
        var out: [Int: String] = [:]
        for i in 0..<Int(keys.length.number ?? 0) {
            if let k = keys[i].string, let id = Int(k), let v = obj[k].string { out[id] = v }
        }
        return out.isEmpty ? nil : out
    }

    func logits(ids: [Int]) async throws -> (values: [Float], numLabels: Int) {
        let jsIDs = JSTypedArray<Int32>(ids.map(Int32.init))
        guard let promise = runModel(jsIDs.jsValue).object.flatMap(JSPromise.init) else {
            throw RedactError.predictionFailed
        }
        // swift-format-ignore: promise.value is the async accessor from JavaScriptEventLoop
        let result = try await promise.value
        guard
            let logits = JSTypedArray<Float32>(from: result.logits),
            let numLabels = result.numLabels.number, numLabels > 0
        else { throw RedactError.predictionFailed }
        return (logits.withUnsafeBytes { Array($0) }, Int(numLabels))
    }
}
#endif
