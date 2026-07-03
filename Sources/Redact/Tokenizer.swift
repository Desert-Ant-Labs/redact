import Foundation

/// XLM-R SentencePiece **Unigram** tokenizer, ported to pure Swift and verified
/// to reproduce the training tokenizer's ids exactly (NFKC normalization, no
/// lowercasing, `▁` metaspace, Viterbi over the vocab with a `min_score − 10`
/// unknown penalty). Backed by a compact `redact_tokenizer.bin`.
struct Tokenizer {
    /// One content sub-word: its vocab `id` and its surface `text` (the piece
    /// string, which may begin with the `▁` metaspace marker).
    struct Token {
        let id: Int
        let scalars: [Unicode.Scalar]
    }

    let bosID: Int
    let eosID: Int
    let unkID: Int

    private let scores: [Float]
    private let index: [String: Int]
    private let unkPenalty: Double
    private let maxLen: Int

    private static let metaspace: Unicode.Scalar = "\u{2581}"  // ▁

    init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 21, b[0] == 0x52, b[1] == 0x44, b[2] == 0x54, b[3] == 0x4B else { return nil } // "RDTK"
        var off = 5
        func i32() -> Int {
            let v = Int32(bitPattern:
                UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24)
            off += 4
            return Int(v)
        }
        unkID = i32(); bosID = i32(); eosID = i32()
        let count = i32()
        guard count > 0 else { return nil }

        var sc = [Float](); sc.reserveCapacity(count)
        for _ in 0..<count {
            sc.append(Float(bitPattern:
                UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24))
            off += 4
        }
        var lens = [Int](); lens.reserveCapacity(count)
        for _ in 0..<count {
            lens.append(Int(b[off]) | Int(b[off + 1]) << 8)
            off += 2
        }
        var idx = [String: Int](minimumCapacity: count)
        var maxScalars = 1
        for i in 0..<count {
            let piece = String(decoding: b[off..<(off + lens[i])], as: UTF8.self)
            off += lens[i]
            idx[piece] = i
            let ns = piece.unicodeScalars.count
            if ns > maxScalars { maxScalars = ns }
        }
        scores = sc
        index = idx
        maxLen = min(maxScalars, 32)
        unkPenalty = Double(sc.min() ?? 0) - 10.0
    }

    /// Tokenize `text` into content sub-words (no `<s>` / `</s>`), Viterbi-optimal
    /// over the unigram vocabulary.
    func tokenize(_ text: String) -> [Token] {
        let normalized = "\u{2581}" + text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: " ", with: "\u{2581}")
        let s = Array(normalized.unicodeScalars)
        let n = s.count
        if n == 0 { return [] }

        let neg = -1e18
        var best = [Double](repeating: neg, count: n + 1); best[0] = 0
        var backPos = [Int](repeating: -1, count: n + 1)
        var backID = [Int](repeating: -1, count: n + 1)
        for i in 1...n {
            let lo = max(0, i - maxLen)
            for j in lo..<i {
                if let tid = index[String(String.UnicodeScalarView(s[j..<i]))] {
                    let sc = best[j] + Double(scores[tid])
                    if sc > best[i] { best[i] = sc; backPos[i] = j; backID[i] = tid }
                }
            }
            let cand = best[i - 1] + unkPenalty
            if cand > best[i] { best[i] = cand; backPos[i] = i - 1; backID[i] = unkID }
        }

        var tokens: [Token] = []
        var i = n
        while i > 0 {
            let j = backPos[i]
            tokens.append(Token(id: backID[i], scalars: Array(s[j..<i])))
            i = j
        }
        return tokens.reversed()
    }
}
