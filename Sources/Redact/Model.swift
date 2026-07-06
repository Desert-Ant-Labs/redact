import CoreML
import Foundation

/// Loads the bundled Core ML token classifier + tokenizer and runs the full
/// hybrid detection pipeline. Owns Core ML I/O, windowing, BIOES decoding, and
/// the deterministic-owner merge.
final class Model: @unchecked Sendable {
    private let mlmodel: MLModel
    private let tokenizer: Tokenizer
    private let id2label: [Int: String]

    private static let seq = 256
    private static let maxContent = seq - 2      // room for <s> … </s>
    private static let lowScore = 0.3
    private static let metaspace: Character = "\u{2581}"
    // position_ids baked at Core ML export time: arange(pad+1, pad+1+seq).
    private static let positionIDs: [Int32] = (0..<seq).map { Int32(2 + $0) }

    init() throws {
        guard
            let tokURL = Bundle.module.url(forResource: "redact_tokenizer", withExtension: "bin"),
            let labURL = Bundle.module.url(forResource: "labels", withExtension: "json"),
            let tok = Tokenizer(data: try Data(contentsOf: tokURL))
        else { throw RedactError.resourceMissing }
        tokenizer = tok

        struct Labels: Decodable { let id2label: [String: String] }
        let labels = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: labURL))
        id2label = Dictionary(uniqueKeysWithValues: labels.id2label.compactMap { k, v in Int(k).map { ($0, v) } })

        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        mlmodel = try Model.loadCoreML(config: config)
    }

    private static func loadCoreML(config: MLModelConfiguration) throws -> MLModel {
        // Ships a precompiled Core ML model (redact.mlmodelc).
        guard let url = Bundle.module.url(forResource: "redact", withExtension: "mlmodelc") else {
            throw RedactError.resourceMissing
        }
        return try MLModel(contentsOf: url, configuration: config)
    }

    // MARK: public entry - full hybrid detection
    func detect(_ text: String, minScore: Double) throws -> [Span] {
        let det = Deterministic.detect(text, enabled: Deterministic.owned)
        let masked = Pipeline.maskText(text, det)
        let ml = try mlSpans(masked, minScore: minScore)
        let corr = Deterministic.detect(text, enabled: ["PHONE"]).filter { !Deterministic.owned.contains($0.label) }
        return Pipeline.cleanSpans(text, Pipeline.relabelByContext(text, Pipeline.resolve(det + corr, ml)))
    }

    // MARK: neural spans (windowed)
    private func mlSpans(_ text: String, minScore: Double) throws -> [Span] {
        let t = UTF16Text(text)
        let tokens = tokenizer.tokenize(text)
        let offsets = reconstructOffsets(t, tokens)
        let low = min(Model.lowScore, minScore)

        var scored: [(Span, Double)] = []
        var i = 0
        while i < max(tokens.count, 1) {
            let chunk = Array(tokens[i..<min(i + Model.maxContent, tokens.count)])
            if chunk.isEmpty { break }
            let chunkOffsets = Array(offsets[i..<i + chunk.count])
            let (tags, tagOffsets, probs) = try runWindow(chunk, chunkOffsets)
            // score = max token prob overlapping each BIOES span (within this window)
            let usableTags = zip(tags, probs).map { $0.1 >= low ? $0.0 : "O" }
            for span in Pipeline.bioesToSpans(usableTags, tagOffsets) {
                var mx = 0.0
                for (k, (a, b)) in tagOffsets.enumerated() where b > a && max(a, span.start) < min(b, span.end) {
                    mx = max(mx, probs[k])
                }
                scored.append((span, mx))
            }
            i += chunk.count
        }

        var kept = Pipeline.hysteresis(t, scored, minScore)
        kept = Pipeline.mergePriority(kept)
        kept = Pipeline.attachBuildingNumbers(t, Pipeline.extendParticleNames(t, Pipeline.bridgeNameGaps(t, Pipeline.snapSpans(t, kept))))
        kept = Pipeline.redactSecondaryAddress(t, Pipeline.attachStateCodes(t, Pipeline.redactUsStreet(t, kept)))
        return Pipeline.mergePriority(kept)
    }

    /// Run one 256-wide window; returns (tags, offsets, probs) for its positions.
    private func runWindow(_ chunk: [Tokenizer.Token], _ chunkOffsets: [(Int, Int)]) throws
        -> ([String], [(Int, Int)], [Double]) {
        let ids = [tokenizer.bosID] + chunk.map(\.id) + [tokenizer.eosID]
        let realLen = ids.count
        var offs: [(Int, Int)] = [(0, 0)] + chunkOffsets + [(0, 0)]

        guard
            let inIDs = try? MLMultiArray(shape: [1, NSNumber(value: Model.seq)], dataType: .int32),
            let inMask = try? MLMultiArray(shape: [1, NSNumber(value: Model.seq)], dataType: .int32),
            let inPos = try? MLMultiArray(shape: [1, NSNumber(value: Model.seq)], dataType: .int32),
            let inType = try? MLMultiArray(shape: [1, NSNumber(value: Model.seq)], dataType: .int32)
        else { throw RedactError.predictionFailed }

        let pIDs = inIDs.dataPointer.bindMemory(to: Int32.self, capacity: Model.seq)
        let pMask = inMask.dataPointer.bindMemory(to: Int32.self, capacity: Model.seq)
        let pPos = inPos.dataPointer.bindMemory(to: Int32.self, capacity: Model.seq)
        let pType = inType.dataPointer.bindMemory(to: Int32.self, capacity: Model.seq)
        for k in 0..<Model.seq {
            pIDs[k] = k < realLen ? Int32(ids[k]) : 1        // <pad>
            pMask[k] = k < realLen ? 1 : 0
            pPos[k] = Model.positionIDs[k]
            pType[k] = 0
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inIDs, "attention_mask": inMask,
            "position_ids": inPos, "token_type_ids": inType,
        ])
        let out = try mlmodel.prediction(from: provider)
        guard let logits = out.featureValue(for: "logits")?.multiArrayValue else { throw RedactError.predictionFailed }

        let numLabels = logits.shape[2].intValue
        var tags = [String](repeating: "O", count: realLen)
        var probs = [Double](repeating: 0, count: realLen)
        for k in 0..<realLen {
            var row = [Double](repeating: 0, count: numLabels)
            var mx = -Double.greatestFiniteMagnitude, top = 0
            for c in 0..<numLabels {
                let v = logits[[0, NSNumber(value: k), NSNumber(value: c)] as [NSNumber]].doubleValue
                row[c] = v
                if v > mx { mx = v; top = c }
            }
            var sum = 0.0
            for v in row { sum += exp(v - mx) }
            tags[k] = id2label[top] ?? "O"
            probs[k] = exp(row[top] - mx) / sum
        }
        if offs.count > realLen { offs = Array(offs.prefix(realLen)) }
        return (tags, offs, probs)
    }

    /// Map each content sub-word to its char range in the source string by
    /// scanning its surface (minus the `▁` metaspace) forward from a cursor.
    private func reconstructOffsets(_ t: UTF16Text, _ tokens: [Tokenizer.Token]) -> [(Int, Int)] {
        var cursor = 0
        var out: [(Int, Int)] = []
        out.reserveCapacity(tokens.count)
        for tok in tokens {
            var scalars = tok.scalars
            if scalars.first == "\u{2581}" { scalars.removeFirst() }
            if scalars.isEmpty { out.append((cursor, cursor)); continue }
            let core = String(String.UnicodeScalarView(scalars)) as NSString
            let range = t.ns.range(of: core as String, options: [], range: NSRange(location: cursor, length: t.length - cursor))
            if range.location == NSNotFound {
                out.append((cursor, cursor))
            } else {
                out.append((range.location, range.location + range.length))
                cursor = range.location + range.length
            }
        }
        return out
    }
}
