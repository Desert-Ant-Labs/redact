#if canImport(COnnxRuntime)
import COnnxRuntime
import Foundation

/// ONNX Runtime inference backend (Android / Linux). Runs the same exported
/// classifier as the Kotlin/JS runtimes (`redact.onnx`, dynamic sequence
/// length, int64 `input_ids` + `attention_mask`) through the ORT C API.
final class OrtEngine: InferenceEngine {
    private let api: OrtApi
    private var env: OpaquePointer?
    private var session: OpaquePointer?
    private var memoryInfo: OpaquePointer?

    private static func dup(_ s: String) -> UnsafeMutablePointer<CChar>? {
        s.withCString { strdup($0) }
    }

    private let inputNames: [UnsafeMutablePointer<CChar>?] = [dup("input_ids"), dup("attention_mask")]
    private let outputNames: [UnsafeMutablePointer<CChar>?] = [dup("logits")]

    init(modelPath: String) throws {
        guard let base = OrtGetApiBase(), let apiPtr = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw RedactError.predictionFailed
        }
        api = apiPtr.pointee
        try check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "redact", &env))
        var options: OpaquePointer?
        try check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        try check(api.CreateSession(env, modelPath, options, &session))
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo))
    }

    deinit {
        if let session { api.ReleaseSession(session) }
        if let memoryInfo { api.ReleaseMemoryInfo(memoryInfo) }
        if let env { api.ReleaseEnv(env) }
        for p in inputNames + outputNames { free(p) }
    }

    private func check(_ status: OrtStatusPtr?) throws {
        guard let status else { return }
        api.ReleaseStatus(status)
        throw RedactError.predictionFailed
    }

    func logits(ids: [Int]) throws -> (values: [Float], numLabels: Int) {
        let n = ids.count
        var ids64 = ids.map { Int64($0) }
        var mask64 = [Int64](repeating: 1, count: n)
        let shape: [Int64] = [1, Int64(n)]

        var inputs: [OpaquePointer?] = [nil, nil]
        defer { for v in inputs where v != nil { api.ReleaseValue(v) } }
        try ids64.withUnsafeMutableBytes { idsBuf in
            try mask64.withUnsafeMutableBytes { maskBuf in
                try shape.withUnsafeBufferPointer { shp in
                    try check(api.CreateTensorWithDataAsOrtValue(
                        memoryInfo, idsBuf.baseAddress, idsBuf.count,
                        shp.baseAddress, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[0]))
                    try check(api.CreateTensorWithDataAsOrtValue(
                        memoryInfo, maskBuf.baseAddress, maskBuf.count,
                        shp.baseAddress, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[1]))
                }
            }
        }

        var output: OpaquePointer?
        try inputNames.withUnsafeBufferPointer { inNames in
            try outputNames.withUnsafeBufferPointer { outNames in
                try inputs.withUnsafeBufferPointer { inVals in
                    // The C API takes const char* const*; reuse the strdup'd names.
                    let inN = UnsafeRawPointer(inNames.baseAddress!)
                        .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                    let outN = UnsafeRawPointer(outNames.baseAddress!)
                        .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                    try check(api.Run(session, nil, inN, inVals.baseAddress, 2, outN, 1, &output))
                }
            }
        }
        defer { if output != nil { api.ReleaseValue(output) } }
        guard let out = output else { throw RedactError.predictionFailed }

        var info: OpaquePointer?
        try check(api.GetTensorTypeAndShape(out, &info))
        defer { if info != nil { api.ReleaseTensorTypeAndShapeInfo(info) } }
        var rawCount: size_t = 0
        try check(api.GetTensorShapeElementCount(info, &rawCount))
        let count = Int(rawCount)
        guard count > 0, count % n == 0 else { throw RedactError.predictionFailed }
        let numLabels = count / n

        var dataPtr: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(out, &dataPtr))
        guard let data = dataPtr?.assumingMemoryBound(to: Float.self) else {
            throw RedactError.predictionFailed
        }
        return (Array(UnsafeBufferPointer(start: data, count: count)), numLabels)
    }
}
#endif
