#if canImport(CoreML)
import CoreML
import Foundation
import RedactResources

/// Core ML inference backend (Apple platforms). Ships a precompiled
/// `redact.mlmodelc` exported with a fixed 256-token window, int32 inputs and
/// baked position ids; this class owns that I/O layout.
final class CoreMLEngine: InferenceEngine {
    private let mlmodel: MLModel

    private static let seq = 256
    // position_ids baked at Core ML export time: arange(pad+1, pad+1+seq).
    private static let positionIDs: [Int32] = (0..<seq).map { Int32(2 + $0) }

    init() throws {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        guard let url = RedactResourcesBundle.bundle.url(forResource: "redact", withExtension: "mlmodelc") else {
            throw RedactError.resourceMissing
        }
        mlmodel = try MLModel(contentsOf: url, configuration: config)
    }

    func logits(ids: [Int]) throws -> (values: [Float], numLabels: Int) {
        let realLen = ids.count
        guard
            let inIDs = try? MLMultiArray(shape: [1, NSNumber(value: Self.seq)], dataType: .int32),
            let inMask = try? MLMultiArray(shape: [1, NSNumber(value: Self.seq)], dataType: .int32),
            let inPos = try? MLMultiArray(shape: [1, NSNumber(value: Self.seq)], dataType: .int32),
            let inType = try? MLMultiArray(shape: [1, NSNumber(value: Self.seq)], dataType: .int32)
        else { throw RedactError.predictionFailed }

        let pIDs = inIDs.dataPointer.bindMemory(to: Int32.self, capacity: Self.seq)
        let pMask = inMask.dataPointer.bindMemory(to: Int32.self, capacity: Self.seq)
        let pPos = inPos.dataPointer.bindMemory(to: Int32.self, capacity: Self.seq)
        let pType = inType.dataPointer.bindMemory(to: Int32.self, capacity: Self.seq)
        for k in 0..<Self.seq {
            pIDs[k] = k < realLen ? Int32(ids[k]) : 1        // <pad>
            pMask[k] = k < realLen ? 1 : 0
            pPos[k] = Self.positionIDs[k]
            pType[k] = 0
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inIDs, "attention_mask": inMask,
            "position_ids": inPos, "token_type_ids": inType,
        ])
        let out = try mlmodel.prediction(from: provider)
        guard let logits = out.featureValue(for: "logits")?.multiArrayValue else { throw RedactError.predictionFailed }

        let numLabels = logits.shape[2].intValue
        var values = [Float](repeating: 0, count: realLen * numLabels)
        for k in 0..<realLen {
            for c in 0..<numLabels {
                values[k * numLabels + c] =
                    logits[[0, NSNumber(value: k), NSNumber(value: c)] as [NSNumber]].floatValue
            }
        }
        return (values, numLabels)
    }
}
#endif
