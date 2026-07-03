import Foundation

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
/// ported pipeline needs (character access, slicing, whitespace/word tests).
struct UTF16Text {
    let ns: NSString
    var length: Int { ns.length }

    init(_ string: String) { ns = string as NSString }

    /// The Unicode scalar at UTF-16 index `i` (BMP; surrogate pairs read as their
    /// leading unit — PII text is effectively all BMP).
    func scalar(at i: Int) -> Unicode.Scalar? {
        guard i >= 0, i < ns.length else { return nil }
        return Unicode.Scalar(ns.character(at: i))
    }

    func slice(_ a: Int, _ b: Int) -> String {
        let lo = max(0, min(a, ns.length)), hi = max(0, min(b, ns.length))
        guard hi > lo else { return "" }
        return ns.substring(with: NSRange(location: lo, length: hi - lo))
    }

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

/// Compile an ICU regex; traps on a bad literal pattern (all patterns here are
/// compile-time constants, so failure indicates a source bug).
func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    do { return try NSRegularExpression(pattern: pattern, options: options) }
    catch { fatalError("invalid regex: \(pattern) — \(error)") }
}

extension NSRegularExpression {
    /// All matches over the whole string.
    func matches(_ ns: NSString) -> [NSTextCheckingResult] {
        matches(in: ns as String, range: NSRange(location: 0, length: ns.length))
    }

    /// Whether the pattern occurs anywhere in `slice`.
    func matches(_ slice: String) -> Bool {
        firstMatch(in: slice, range: NSRange(location: 0, length: (slice as NSString).length)) != nil
    }
}
