#if !os(WASI)
import Foundation
#endif

/// Internal span with UTF-16 offsets into the source string (matches the
/// JavaScript/Python reference pipeline's indexing so the ports agree exactly).
struct Span {
    var start: Int
    var end: Int
    var label: String
    var score: Double

    init(_ start: Int, _ end: Int, _ label: String, _ score: Double = 1.0) {
        self.start = start; self.end = end; self.label = label; self.score = score
    }
}

/// UTF-16-indexed view over a string, providing the small set of operations the
/// ported pipeline needs (character access, slicing, whitespace/word tests,
/// literal search). Backed by `NSString` natively and by a plain code-unit
/// array on WebAssembly (no Foundation there).
struct UTF16Text {
    #if os(WASI)
    let string: String
    private let units: [UInt16]
    var length: Int { units.count }

    init(_ string: String) { self.string = string; units = Array(string.utf16) }

    /// The Unicode scalar at UTF-16 index `i` (BMP; surrogate pairs read as their
    /// leading unit - PII text is effectively all BMP).
    func scalar(at i: Int) -> Unicode.Scalar? {
        guard i >= 0, i < units.count else { return nil }
        return Unicode.Scalar(units[i])
    }

    func slice(_ a: Int, _ b: Int) -> String {
        let lo = max(0, min(a, units.count)), hi = max(0, min(b, units.count))
        guard hi > lo else { return "" }
        return String(decoding: units[lo..<hi], as: UTF16.self)
    }

    /// First literal occurrence of `needle` at or after UTF-16 offset `from`.
    func find(_ needle: String, from: Int) -> (start: Int, end: Int)? {
        let n = Array(needle.utf16)
        guard !n.isEmpty, from <= units.count - n.count else { return nil }
        outer: for i in max(0, from)...(units.count - n.count) {
            for j in 0..<n.count where units[i + j] != n[j] { continue outer }
            return (i, i + n.count)
        }
        return nil
    }
    #else
    private let ns: NSString
    var string: String { ns as String }
    var length: Int { ns.length }

    init(_ string: String) { ns = string as NSString }

    /// The Unicode scalar at UTF-16 index `i` (BMP; surrogate pairs read as their
    /// leading unit - PII text is effectively all BMP).
    func scalar(at i: Int) -> Unicode.Scalar? {
        guard i >= 0, i < ns.length else { return nil }
        return Unicode.Scalar(ns.character(at: i))
    }

    func slice(_ a: Int, _ b: Int) -> String {
        let lo = max(0, min(a, ns.length)), hi = max(0, min(b, ns.length))
        guard hi > lo else { return "" }
        return ns.substring(with: NSRange(location: lo, length: hi - lo))
    }

    /// First literal occurrence of `needle` at or after UTF-16 offset `from`.
    func find(_ needle: String, from: Int) -> (start: Int, end: Int)? {
        let start = max(0, min(from, ns.length))
        let r = ns.range(of: needle, options: [], range: NSRange(location: start, length: ns.length - start))
        guard r.location != NSNotFound else { return nil }
        return (r.location, r.location + r.length)
    }
    #endif

    func isWhitespace(at i: Int) -> Bool {
        guard let s = scalar(at: i) else { return false }
        return s.properties.isWhitespace
    }

    func isWordChar(at i: Int) -> Bool {
        guard let s = scalar(at: i) else { return false }
        if s.properties.isAlphabetic || s.properties.numericType != nil { return true }
        switch s.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}
