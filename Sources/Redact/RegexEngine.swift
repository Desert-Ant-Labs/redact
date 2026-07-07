#if os(WASI)
import JavaScriptKit
#else
import Foundation
#endif

/// One regex match: UTF-16 ranges and matched text per capture group
/// (index 0 = whole match; `nil` for unmatched optional groups).
struct RgxMatch {
    let ranges: [(start: Int, end: Int)?]
    let groups: [String?]
    var start: Int { ranges[0]!.start }
    var end: Int { ranges[0]!.end }
    func range(at i: Int) -> (start: Int, end: Int)? { i < ranges.count ? ranges[i] ?? nil : nil }
    func group(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
}

/// Portable regex, so the pipeline needs no ICU on the web:
/// - native platforms: `NSRegularExpression` (ICU), as before;
/// - WebAssembly: the host JS engine's `RegExp`, which is exactly what the
///   reference redact-js implementation uses, and costs no binary size.
/// Patterns containing `\p{...}` get the JS `u` flag (mirrors redact-js).
final class Rgx {
    #if os(WASI)
    private let regex: JSObject

    init(_ pattern: String, _ caseInsensitive: Bool) {
        var flags = "gd"
        if caseInsensitive { flags += "i" }
        if pattern.contains("\\p{") { flags += "u" }
        regex = JSObject.global.RegExp.function!.new(pattern, flags)
    }

    private func exec(_ s: String) -> RgxMatch? {
        let m = regex.exec!(s)
        guard let obj = m.object else { return nil }
        let count = Int(obj.length.number ?? 1)
        var ranges: [(Int, Int)?] = []
        var groups: [String?] = []
        let indices = obj.indices
        for i in 0..<count {
            groups.append(obj[i].string)
            if let pair = indices.object?[i].object,
               let a = pair[0].number, let b = pair[1].number {
                ranges.append((Int(a), Int(b)))
            } else {
                ranges.append(nil)
            }
        }
        return RgxMatch(ranges: ranges, groups: groups)
    }

    func allMatches(_ s: String) -> [RgxMatch] {
        regex.lastIndex = 0
        var out: [RgxMatch] = []
        while let m = exec(s) {
            out.append(m)
            if m.start == m.end {  // avoid infinite loops on empty matches
                regex.lastIndex = .number(Double(m.end + 1))
            }
        }
        return out
    }

    func first(_ s: String) -> RgxMatch? {
        regex.lastIndex = 0
        return exec(s)
    }
    #else
    private let regex: NSRegularExpression

    init(_ pattern: String, _ caseInsensitive: Bool) {
        do { regex = try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) }
        catch { fatalError("invalid regex: \(pattern) - \(error)") }
    }

    private func convert(_ m: NSTextCheckingResult, _ ns: NSString) -> RgxMatch {
        var ranges: [(Int, Int)?] = []
        var groups: [String?] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location == NSNotFound {
                ranges.append(nil); groups.append(nil)
            } else {
                ranges.append((r.location, r.location + r.length))
                groups.append(ns.substring(with: r))
            }
        }
        return RgxMatch(ranges: ranges, groups: groups)
    }

    func allMatches(_ s: String) -> [RgxMatch] {
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { convert($0, ns) }
    }

    func first(_ s: String) -> RgxMatch? {
        let ns = s as NSString
        return regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)).map { convert($0, ns) }
    }
    #endif

    func test(_ s: String) -> Bool { first(s) != nil }
}

/// Compile a regex; traps on a bad literal pattern (all patterns here are
/// compile-time constants, so failure indicates a source bug).
func rx(_ pattern: String, ci: Bool = false) -> Rgx { Rgx(pattern, ci) }
