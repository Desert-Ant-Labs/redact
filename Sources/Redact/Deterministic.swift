import Foundation

/// High-precision deterministic recognizers (regex + checksums), a direct port
/// of `redact_training.deterministic`. These *own* structured labels where a
/// checksum or distinctive format beats the small neural model.
enum Deterministic {
    static let owned: Set<String> = [
        "EMAIL", "URL", "IP_ADDRESS", "CREDIT_CARD", "SSN",
        "BANK_ACCOUNT", "ROUTING_NUMBER", "TAX_ID", "GOVERNMENT_ID", "PASSPORT",
    ]

    // MARK: patterns
    private static let emailRE = rx(#"(?<![A-Za-z0-9.!#$%&'*+/=?^_`{|}~-])([\p{L}\p{N}.!#$%&'*+/=?^`{|}~-]{1,64}@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63})(?![A-Za-z0-9-])"#)
    private static let urlRE = rx(#"\b((?:https?://|ftp://|www\.)[^\s<>()\[\]{}"']{3,})"#, [.caseInsensitive])
    private static let ipv4RE = rx(#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?!\d)(?!\.\d)"#)
    private static let ipv6RE = rx(#"(?<![\w:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![\w:])"#, [.caseInsensitive])
    private static let macRE = rx(#"(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"#, [.caseInsensitive])
    private static let ccRE = rx(#"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#)
    private static let ibanRE = rx(#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b"#, [.caseInsensitive])
    private static let ssnRE = rx(#"(?<!\d)(\d{3})[- ](\d{2})[- ](\d{4})(?!\d)"#)
    private static let routingRE = rx(#"(?<!\d)\d{9}(?!\d)"#)
    private static let intlPhoneRE = rx(#"(?<!\w)\+\d{1,3}[ .-]?(?:\(?\d{1,5}\)?[ .-]?){1,5}\d{2,5}(?!\w)"#)
    private static let genericPhoneRE = rx(#"(?<!\w)(?:\+?\d{1,3}[ .-]?)?(?:\(?\d{2,5}\)?[ .-]?){2,5}\d{2,5}(?!\w)"#)

    private static let ipContext = rx(#"\b(?:ip|ipv4|ipv6|address|addr|host|server|node|endpoint|cidr)\b|地址"#, [.caseInsensitive])
    private static let routingContext = rx(#"\b(?:routing|aba|bank|wire|ach)\b"#, [.caseInsensitive])
    private static let ssnContext = rx(#"\b(?:ssn|social security|social insurance|social number|sin|seguridad social)\b|社保|社会保障|사회보장"#, [.caseInsensitive])
    private static let creditContext = rx(#"\b(?:credit\s*card|debit\s*card|payment\s*card|bank\s*card|card\s*(?:number|no|num|info|ending|on file)|card\s*(?:charged|debited)|charged?\s*(?:my\s*|the\s*)?card|\bcard\b|visa|mastercard|master\s*card|maestro|amex|american\s*express|discover|diners|tarjeta|carte bancaire|kreditkarte|carta di credito|cartão)\b|信用卡|银行卡|カード|카드"#, [.caseInsensitive])
    private static let phoneContext = rx(#"\b(?:phone|mobile|tel(?:ephone)?|cell|call(?:\s*me)?|fax|whatsapp|sms|contact number|phone number|telefon(?:ní|nummer|szám|o|oon)?|teléfono|téléphone|telepon|mobil(?:e|ni|telefon)?|gsm|tlf|zavolejte|zadzwoń|appelez|appeler|téléphonez|chiamare|chiami|chiama|llame|llamar|llamada|ligue|ligar|bel(?:len)?|hívja|hívjon|sunați|sună|ring|ringa|nazovite|καλέστε|τηλέφωνο|телефон)\b|电话|電話|연락처|전화"#, [.caseInsensitive])

    // MARK: validators
    private static func digitCount(_ s: String) -> Int { s.reduce(0) { $0 + ($1.isNumber ? 1 : 0) } }

    private static func luhnOk(_ s: String) -> Bool {
        let d = s.compactMap { $0.isNumber ? Int(String($0)) : nil }
        guard d.count >= 13, d.count <= 19 else { return false }
        var total = 0
        let parity = d.count % 2
        for (i, v) in d.enumerated() {
            var x = v
            if i % 2 == parity { x *= 2; if x > 9 { x -= 9 } }
            total += x
        }
        return total % 10 == 0
    }

    private static func ibanOk(_ value: String) -> Bool {
        let s = value.replacingOccurrences(of: " ", with: "").uppercased()
        guard rx(#"^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$"#).matches(s) else { return false }
        let r = String(s.dropFirst(4) + s.prefix(4))
        var rem = 0
        for ch in r {
            let n: Int
            if let a = ch.asciiValue, ch.isLetter { n = Int(a) - 55 } else { n = ch.wholeNumberValue ?? 0 }
            for d in String(n) { rem = (rem * 10 + (d.wholeNumberValue ?? 0)) % 97 }
        }
        return rem == 1
    }

    private static func abaRoutingOk(_ v: String) -> Bool {
        guard v.count == 9, v.allSatisfy({ $0.isNumber }) else { return false }
        let d = v.map { Int(String($0))! }
        let cs = 3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])
        return cs % 10 == 0
    }

    private static func validUsSsn(_ v: String) -> Bool {
        guard let m = rx(#"^(\d{3})[- ](\d{2})[- ](\d{4})$"#).firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) else { return false }
        let ns = v as NSString
        let area = ns.substring(with: m.range(at: 1))
        let group = ns.substring(with: m.range(at: 2))
        let serial = ns.substring(with: m.range(at: 3))
        let a = Int(area) ?? 0
        if area == "000" || area == "666" || (a >= 900 && a <= 999) { return false }
        if group == "00" || serial == "0000" { return false }
        return true
    }

    private static func isIp(_ v: String) -> Bool {
        if rx(#"^(\d{1,3}\.){3}\d{1,3}$"#).matches(v) {
            return v.split(separator: ".").allSatisfy { (Int($0) ?? 999) <= 255 }
        }
        if rx(#"^[0-9a-f:]+$"#, [.caseInsensitive]).matches(v), v.contains(":"), v != ":", v != "::" {
            return v.components(separatedBy: "::").count <= 2
        }
        return false
    }

    private static func hasContext(_ re: NSRegularExpression, _ t: UTF16Text, _ start: Int, _ end: Int, _ window: Int = 48) -> Bool {
        let lo = max(0, start - window), hi = min(t.length, end + window)
        return re.matches(t.slice(lo, hi))
    }

    // MARK: detect
    static func detect(_ text: String, enabled: Set<String>? = nil) -> [Span] {
        let t = UTF16Text(text)
        let ns = t.ns
        let en = enabled ?? owned
        var spans: [Span] = []
        func add(_ s: Int, _ e: Int, _ label: String, _ score: Double = 1.0) { if s < e { spans.append(Span(s, e, label, score)) } }
        func r(_ m: NSTextCheckingResult, _ g: Int = 0) -> NSRange { m.range(at: g) }

        for m in emailRE.matches(ns) { let g = r(m, 1); add(g.location, g.location + g.length, "EMAIL") }
        for m in urlRE.matches(ns) {
            let g = r(m, 1)
            if g.location > 0, t.slice(g.location - 1, g.location) == "@" { continue }
            add(g.location, g.location + g.length, "URL")
        }
        for m in ipv4RE.matches(ns) {
            let v = ns.substring(with: r(m)); let a = r(m).location, b = a + r(m).length
            if isIp(v) && hasContext(ipContext, t, a, b, 40) { add(a, b, "IP_ADDRESS") }
        }
        for m in ipv6RE.matches(ns) {
            let v = ns.substring(with: r(m)); let a = r(m).location, b = a + r(m).length
            if isIp(v) && hasContext(ipContext, t, a, b, 40) { add(a, b, "IP_ADDRESS") }
        }
        for m in macRE.matches(ns) { add(r(m).location, r(m).location + r(m).length, "IP_ADDRESS") }
        for m in ccRE.matches(ns) {
            let a = r(m).location, b = a + r(m).length
            let val = ns.substring(with: r(m))
            let dg = val.filter(\.isNumber)
            if Set(dg).count <= 1 { continue }
            let before = t.slice(max(0, a - 56), a)
            if luhnOk(val) && creditContext.matches(before) {
                var end = b
                while end > a, let s = t.scalar(at: end - 1), " -.".unicodeScalars.contains(s) { end -= 1 }
                add(a, end, "CREDIT_CARD")
            }
        }
        for m in ibanRE.matches(ns) {
            let a = r(m).location, b = a + r(m).length
            if ibanOk(ns.substring(with: r(m))) { add(a, b, "BANK_ACCOUNT") }
        }
        for m in ssnRE.matches(ns) {
            let a = r(m).location, b = a + r(m).length
            let v = ns.substring(with: r(m))
            if validUsSsn(v) || hasContext(ssnContext, t, a, b) { add(a, b, "SSN") }
        }
        for m in routingRE.matches(ns) {
            let a = r(m).location, b = a + r(m).length
            let v = ns.substring(with: r(m))
            if abaRoutingOk(v) && hasContext(routingContext, t, a, b) { add(a, b, "ROUTING_NUMBER") }
        }
        for m in intlPhoneRE.matches(ns) {
            let a = r(m).location, b = a + r(m).length
            let n = digitCount(ns.substring(with: r(m)))
            if n >= 8, n <= 15 { add(a, b, "PHONE", 0.92) }
        }
        for m in genericPhoneRE.matches(ns) {
            let a = r(m).location, b = a + r(m).length
            let raw = ns.substring(with: r(m))
            let dg = digitCount(raw)
            let before = t.slice(max(0, a - 56), a)
            let grouped = raw.contains(where: { " .-".contains($0) })
            if phoneContext.matches(before), (dg >= 9 && dg <= 15) || (dg >= 7 && dg <= 8 && grouped) {
                add(a, b, "PHONE", 0.88)
            }
        }

        return merge(spans).filter { en.contains($0.label) }
    }

    /// Overlap resolution for deterministic spans: keep the longer span (or the
    /// higher-scoring one when equal length). Mirrors the JS `merge`.
    private static func merge(_ spans: [Span]) -> [Span] {
        let ordered = spans.sorted {
            $0.start != $1.start ? $0.start < $1.start
                : ($0.end - $0.start) != ($1.end - $1.start) ? ($0.end - $0.start) > ($1.end - $1.start)
                : $0.label < $1.label
        }
        var out: [Span] = []
        for s in ordered {
            if out.isEmpty || s.start >= out[out.count - 1].end {
                out.append(s)
            } else {
                let p = out[out.count - 1]
                let sl = s.end - s.start, pl = p.end - p.start
                if sl > pl || (sl == pl && s.score > p.score) { out[out.count - 1] = s }
            }
        }
        return out
    }
}
