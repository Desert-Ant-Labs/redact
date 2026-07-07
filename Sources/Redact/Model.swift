#if os(WASI)
import WASILibc
#else
import Foundation
import RedactResources
#endif

/// Loads the bundled token classifier + tokenizer and runs the full hybrid
/// detection pipeline: windowing, BIOES decoding, and the deterministic-owner
/// merge. Inference itself is delegated to the platform `InferenceEngine`
/// (Core ML on Apple platforms, ONNX Runtime on Android/Linux).
final class Model: @unchecked Sendable {
    private let engine: InferenceEngine
    private let tokenizer: Tokenizer
    private let id2label: [Int: String]

    private static let seq = 256
    private static let maxContent = seq - 2      // room for <s> … </s>
    private static let lowScore = 0.3
    private static let metaspace: Character = "\u{2581}"

    init() throws {
        #if os(WASI)
        // No filesystem in the browser: the JS host injects the tokenizer and
        // label map (and runs the ONNX model) via globals. See JSEngine.
        guard
            let tokBytes = JSEngine.tokenizerBytes(),
            let tok = Tokenizer(bytes: tokBytes),
            let labels = JSEngine.labelMap()
        else { throw RedactError.resourceMissing }
        tokenizer = tok
        id2label = labels
        engine = try JSEngine()
        #else
        let bundle = RedactResourcesBundle.bundle
        guard
            let tokURL = bundle.url(forResource: "redact_tokenizer", withExtension: "bin"),
            let labURL = bundle.url(forResource: "labels", withExtension: "json"),
            let tok = Tokenizer(bytes: [UInt8](try Data(contentsOf: tokURL)))
        else { throw RedactError.resourceMissing }
        tokenizer = tok
        let labelData = try Data(contentsOf: labURL)

        struct Labels: Decodable { let id2label: [String: String] }
        let labels = try JSONDecoder().decode(Labels.self, from: labelData)
        id2label = Dictionary(uniqueKeysWithValues: labels.id2label.compactMap { k, v in Int(k).map { ($0, v) } })

        #if canImport(CoreML)
        engine = try CoreMLEngine()
        #else
        guard let onnxURL = bundle.url(forResource: "redact", withExtension: "onnx") else {
            throw RedactError.resourceMissing
        }
        engine = try OrtEngine(modelPath: onnxURL.path)
        #endif
        #endif
    }

    // MARK: public entry - full hybrid detection
    func detect(_ text: String, minScore: Double) async throws -> [Span] {
        let det = Deterministic.detect(text, enabled: Deterministic.owned)
        let masked = Pipeline.maskText(text, det)
        let ml = try await mlSpans(masked, minScore: minScore)
        let corr = Deterministic.detect(text, enabled: ["PHONE"]).filter { !Deterministic.owned.contains($0.label) }
        return Pipeline.cleanSpans(text, Pipeline.relabelByContext(text, Pipeline.resolve(det + corr, ml)))
    }

    // MARK: neural spans (windowed)
    private func mlSpans(_ text: String, minScore: Double) async throws -> [Span] {
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
            let (tags, tagOffsets, probs) = try await runWindow(chunk, chunkOffsets)
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

    /// Run one window (<= 256 incl. specials); returns (tags, offsets, probs).
    private func runWindow(_ chunk: [Tokenizer.Token], _ chunkOffsets: [(Int, Int)]) async throws
        -> ([String], [(Int, Int)], [Double]) {
        let ids = [tokenizer.bosID] + chunk.map(\.id) + [tokenizer.eosID]
        let realLen = ids.count
        var offs: [(Int, Int)] = [(0, 0)] + chunkOffsets + [(0, 0)]

        let (logits, numLabels) = try await engine.logits(ids: ids)
        guard logits.count >= realLen * numLabels else { throw RedactError.predictionFailed }

        var tags = [String](repeating: "O", count: realLen)
        var probs = [Double](repeating: 0, count: realLen)
        for k in 0..<realLen {
            var mx = -Double.greatestFiniteMagnitude, top = 0
            for c in 0..<numLabels {
                let v = Double(logits[k * numLabels + c])
                if v > mx { mx = v; top = c }
            }
            var sum = 0.0
            for c in 0..<numLabels { sum += exp(Double(logits[k * numLabels + c]) - mx) }
            tags[k] = id2label[top] ?? "O"
            probs[k] = exp(Double(logits[k * numLabels + top]) - mx) / sum
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
            let core = String(String.UnicodeScalarView(scalars))
            if let r = t.find(core, from: cursor) {
                out.append((r.start, r.end))
                cursor = r.end
            } else {
                out.append((cursor, cursor))
            }
        }
        return out
    }
}
