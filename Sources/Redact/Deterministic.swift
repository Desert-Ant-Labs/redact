import Foundation

/// High-precision deterministic recognizers (regex + checksums), a direct port
/// of `redact_training.deterministic` (v1.4). These *own* structured labels where
/// a checksum or distinctive format beats the small neural model. Kept in parity
/// with the JS/Python reference via the shared span corpus (see parity_gen.py).
enum Deterministic {
    static let owned: Set<String> = [
        "EMAIL", "URL", "IP_ADDRESS", "CREDIT_CARD", "SSN",
        "BANK_ACCOUNT", "ROUTING_NUMBER", "TAX_ID", "GOVERNMENT_ID", "PASSPORT",
        "DRIVERS_LICENSE", "IMEI",
    ]

    // MARK: patterns
    private static let emailRE = rx(#"(?<![A-Za-z0-9.!#$%&'*+/=?^_`{|}~-])([\p{L}\p{N}.!#$%&'*+/=?^`{|}~-]{1,64}@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63})(?![A-Za-z0-9-])"#)
    private static let urlRE = rx(#"\b((?:https?://|ftp://|www\.)[^\s<>()\[\]{}"']{3,})"#, [.caseInsensitive])
    private static let ipv4RE = rx(#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?!\d)(?!\.\d)"#)
    private static let ipv6RE = rx(#"(?<![\w:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![\w:])"#, [.caseInsensitive])
    private static let macRE = rx(#"(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"#, [.caseInsensitive])
    private static let ccRE = rx(#"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#)
    private static let ibanRE = rx(#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b"#, [.caseInsensitive])
    private static let bicRE = rx(#"\b[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}(?:[A-Z0-9]{3})?\b"#)
    private static let ssnRE = rx(#"(?<!\d)(\d{3})[- ](\d{2})[- ](\d{4})(?!\d)"#)
    private static let routingRE = rx(#"(?<!\d)\d{9}(?!\d)"#)
    private static let esDniRE = rx(#"(?<![A-Z0-9])(?:\d{8}|[XYZ]\d{7})[A-Z](?![A-Z0-9])"#, [.caseInsensitive])
    private static let natIdRE = rx(#"(?<![A-Za-z0-9])\d[\d .\-]{7,17}\d(?![A-Za-z0-9])"#)
    private static let itCfRE = rx(#"(?<![A-Za-z0-9])[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z](?![A-Za-z0-9])"#, [.caseInsensitive])
    private static let fiHetuRE = rx(#"(?<![A-Za-z0-9])\d{6}[-+A-F]\d{3}[0-9A-Y](?![A-Za-z0-9])"#)
    private static let dkCprRE = rx(#"(?<!\d)\d{6}[- ]?\d{4}(?!\d)"#)
    private static let vatRE = rx(#"(?<![A-Za-z0-9])(AT|BE|BG|CY|CZ|DE|DK|EE|EL|GR|ES|FI|FR|HR|HU|IE|IT|LT|LU|LV|MT|NL|PL|PT|RO|SE|SI|SK)\s?([0-9A-Za-z]{5,14})(?![A-Za-z0-9])"#)
    private static let imeiRE = rx(#"(?<!\d)\d{15}(?!\d)"#)
    private static let sePnRE = rx(#"(?<!\d)((?:\d{2})?\d{6})[-+](\d{4})(?!\d)"#)
    private static let passportValRE = rx(#"(?<![A-Za-z0-9])[A-Z0-9]{6,9}(?![A-Za-z0-9])"#)
    private static let ppsRE = rx(#"(?<![A-Za-z0-9])\d{7}[A-Za-z]{1,2}(?![A-Za-z0-9])"#)
    private static let plDlRE = rx(#"(?<![0-9/])\d{5}/\d{2}/\d{4,7}(?![0-9/])"#)
    private static let contextDigitRE = rx(#"(?<![A-Za-z0-9])\d{7,12}(?![A-Za-z0-9])"#)
    private static let intlPhoneRE = rx(#"(?<!\w)\+\d{1,3}[ .-]?(?:\(?\d{1,5}\)?[ .-]?){1,5}\d{2,5}(?!\w)"#)
    private static let genericPhoneRE = rx(#"(?<!\w)(?:\+?\d{1,3}[ .-]?)?(?:\(?\d{2,5}\)?[ .-]?){2,5}\d{2,5}(?!\w)"#)
    // keyword recognizers: ICU honours inline (?i)/(?-i:) so these match Python.
    private static let dlKwRE = rx(#"(?i)\b(driving licen[cs]e|driver'?s? licen[cs]e|licence number|permis de conduire|permis de conduite|f[uü]hrerschein|fahrerlaubnis(?:nummer)?|patente(?: di guida)?|numero patente|prawo jazdy|rijbewijs(?:nummer)?|(?:carn[eé]|permiso) de conducir|carta de condu[cç][aã]o|k[oö]rkort(?:snummer)?|k[oø]rekort|ajokortti|vezet[oő]i enged[eé]ly|[rř]idi[cč]sk\w* pr[uů]kaz\w*|vodi[cč]sk\w* preukaz\w*|permis de conducere|voza[cč]k[au] dozvol[ae]|vozni[sš]ko dovoljenje|vairuotojo pa[zž]ym[eė]jimas|vad[iī]t[aā]ja apliec[iī]ba|juhiluba|licenzja tas-sewqan)(?i:[\s.:\-]*(?:nr|no|nummer|number|num[eé]ro|n[°º])\.?)?(?-i:[^A-Z0-9\n]{0,14}?([A-Z0-9](?:[A-Z0-9]|[ .\-/](?=[A-Z0-9])){4,24}))"#)
    private static let docIdKwRE = rx(#"(?i)\b(passport|passeport|reisepass|pasaporte|passaporto|paspoort|national id|identity card|id card|identity number|identification number|id number|id no|personalausweis|ausweisnummer|ausweis|carte d.identit[eé]|documento de identidad|documento di identit[aà]|carta d.identit[aà]|identiteitskaart|n[uú]mero de identificaci[oó]n|de identifica[cç][aã]o|c[eé]dula)(?-i:[^A-Z0-9\n]{0,18}?([A-Z0-9](?:[A-Z0-9]|[ .\-/](?=[A-Z0-9])){4,44}))"#)
    private static let passportKwRE = rx(#"^(passport|passeport|reisepass|pasaporte|passaporto|paspoort)"#, [.caseInsensitive])

    // MARK: context patterns
    private static let ipContext = rx(#"\b(?:ip|ipv4|ipv6|address|addr|host|server|node|endpoint|cidr)\b|地址"#, [.caseInsensitive])
    private static let routingContext = rx(#"\b(?:routing|aba|bank|wire|ach)\b"#, [.caseInsensitive])
    private static let ssnContext = rx(#"\b(?:ssn|social security|social insurance|social number|sin|seguridad social)\b|社保|社会保障|사회보장"#, [.caseInsensitive])
    private static let taxContext = rx(#"\b(?:tax|taxnum|tax number|tax identification|tin|vat|npwp)\b|税号|税|세금"#, [.caseInsensitive])
    private static let govContext = rx(#"\b(?:national id|identity card|id card|government id|nric|fin|dni|nie|cpf|cnpj|passport)\b|身份证|주민등록"#, [.caseInsensitive])
    private static let natIdContext = rx(#"\b(id|ident\w*|national|personal (?:id|number|code)|pesel|bsn|burgerservice\w*|egn|ЕГН|cnp|oib|amka|ΑΜΚΑ|isikukood|henkilötunnus|hetu|codice fiscale|rodné|personnummer|personas kods|asmens kodas|emšo|emso|matricule|rijksregister\w*|steuer\w*|dni|nie|nif|nir|insee|sécu\w*|sécurité sociale|rodné|rodné číslo|adóazonosító|adószám|cpr|nip|partita iva|p\.?\s?iva|\biva\b|vat|svnr|sozialversicherung\w*|pps\w*|tax|fiscal\w*|social|seguridad)\b"#, [.caseInsensitive])
    private static let vatContext = rx(#"\b(vat|ust[- ]?id\w*|umsatzsteuer|tva|iva|partita iva|btw|moms|alv|dph|di[cč]|pvn|pvm|dds|nip|nif|cif|[aá]fa|arvonlis\w*|fiscal\w*|tax)\b|ΑΦΜ|ФДС"#, [.caseInsensitive])
    private static let imeiContext = rx(#"\bimei\b"#, [.caseInsensitive])
    private static let sePnContext = rx(#"\b(?:personnummer|person\s*number|födelsenummer|personnr)\b"#, [.caseInsensitive])
    private static let passportContext = rx(#"\b(?:passport|passeport|reisepass|pasaporte|passaporto|paspoort)\b"#, [.caseInsensitive])
    private static let ppsContext = rx(#"\b(?:pps|ppsn|personal\s*public\s*service)\b"#, [.caseInsensitive])
    private static let dkCprContext = rx(#"\bcpr\b"#, [.caseInsensitive])
    private static let bicBefore = rx(#"(?:swift\s*[-/]?\s*bic|swift\s+code|bic(?:\s+code)?)\s*[:#=(\[]?\s*$"#, [.caseInsensitive])
    private static let creditContext = rx(#"\b(?:credit\s*card|debit\s*card|payment\s*card|bank\s*card|card\s*(?:number|no|num|info|ending|on file)|card\s*(?:charged|debited)|charged?\s*(?:my\s*|the\s*)?card|\bcard\b|visa|mastercard|master\s*card|maestro|amex|american\s*express|discover|diners|tarjeta|carte bancaire|kreditkarte|carta di credito|cartão)\b|信用卡|银行卡|カード|카드"#, [.caseInsensitive])
    private static let phoneContext = rx(#"\b(?:phone|mobile|tel(?:ephone)?|cell|call(?:\s*me)?|fax|whatsapp|sms|contact number|phone number|telefon(?:ní|nummer|szám|o|oon)?|teléfono|téléphone|telepon|mobil(?:e|ni|telefon)?|gsm|tlf|zavolejte|zadzwoń|appelez|appeler|téléphonez|chiamare|chiami|chiama|llame|llamar|llamada|ligue|ligar|bel(?:len)?|hívja|hívjon|sunați|sună|ring|ringa|nazovite|καλέστε|τηλέφωνο|телефон)\b|电话|電話|연락처|전화"#, [.caseInsensitive])

    // MARK: numeric helpers
    private static func dl(_ s: String) -> [Int] { s.compactMap { $0 >= "0" && $0 <= "9" ? Int(String($0)) : nil } }
    private static func digitCount(_ s: String) -> Int { s.reduce(0) { $0 + (($1 >= "0" && $1 <= "9") ? 1 : 0) } }
    private static func wsum(_ d: [Int], _ w: [Int]) -> Int { zip(d, w).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func luhnLen(_ d: [Int]) -> Bool {
        var total = 0; let parity = d.count % 2
        for (i, v) in d.enumerated() { var x = v; if i % 2 == parity { x *= 2; if x > 9 { x -= 9 } }; total += x }
        return total % 10 == 0
    }
    private static func joinInt(_ d: ArraySlice<Int>) -> Int { Int(d.map(String.init).joined()) ?? 0 }

    // MARK: checksums
    private static func luhnOk(_ s: String) -> Bool { let d = dl(s); return d.count >= 13 && d.count <= 19 && luhnLen(d) }
    private static func imeiOk(_ s: String) -> Bool { let d = dl(s); return d.count == 15 && luhnLen(d) }
    private static func validSePn(_ s: String) -> Bool { var d = dl(s); if d.count == 12 { d = Array(d.dropFirst(2)) }; return d.count == 10 && luhnLen(d) }

    private static let ibanLen: [String: Int] = [
        "AD":24,"AE":23,"AL":28,"AT":20,"AZ":28,"BA":20,"BE":16,"BG":22,"BH":22,"BR":29,"BY":28,"CH":21,"CR":22,"CY":28,"CZ":24,"DE":22,"DK":18,"DO":28,"EE":20,"EG":29,"ES":24,"FI":18,"FO":18,"FR":27,"GB":22,"GE":22,"GI":23,"GL":18,"GR":27,"GT":28,"HR":21,"HU":28,"IE":22,"IL":23,"IS":26,"IT":27,"JO":30,"KW":30,"KZ":20,"LB":28,"LC":32,"LI":21,"LT":20,"LU":20,"LV":21,"MC":27,"MD":24,"ME":22,"MK":19,"MR":27,"MT":31,"MU":30,"NL":18,"NO":15,"PK":24,"PL":28,"PS":29,"PT":25,"QA":29,"RO":24,"RS":22,"SA":24,"SC":31,"SE":24,"SI":19,"SK":24,"SM":27,"TN":24,"TR":26,"UA":29,"VG":24,"XK":20]

    private static func ibanOk(_ value: String) -> Bool {
        let s = value.replacingOccurrences(of: " ", with: "").uppercased()
        guard rx(#"^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$"#).matches(s) else { return false }
        guard s.count == ibanLen[String(s.prefix(2))] else { return false }
        let r = String(s.dropFirst(4) + s.prefix(4))
        var rem = 0
        for ch in r {
            let n: Int
            if ch.isLetter, let a = ch.asciiValue { n = Int(a) - 55 } else { n = ch.wholeNumberValue ?? 0 }
            for d in String(n) { rem = (rem * 10 + (d.wholeNumberValue ?? 0)) % 97 }
        }
        return rem == 1
    }
    private static func abaRoutingOk(_ v: String) -> Bool {
        guard v.count == 9, v.allSatisfy({ $0.isNumber }) else { return false }
        let d = dl(v)
        return (3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])) % 10 == 0
    }
    private static func validUsSsn(_ v: String) -> Bool {
        guard let m = rx(#"^(\d{3})[- ](\d{2})[- ](\d{4})$"#).firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) else { return false }
        let ns = v as NSString
        let area = ns.substring(with: m.range(at: 1)), group = ns.substring(with: m.range(at: 2)), serial = ns.substring(with: m.range(at: 3))
        let a = Int(area) ?? 0
        if area == "000" || area == "666" || (a >= 900 && a <= 999) { return false }
        return group != "00" && serial != "0000"
    }
    private static func bicOk(_ v: String) -> Bool {
        guard v == v.uppercased(), rx(#"^[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?$"#).matches(v) else { return false }
        let c = String(Array(v)[4...5]); return c != "AA" && c != "ZZ"
    }
    private static func esDniOk(_ v: String) -> Bool {
        let s = v.uppercased()
        guard rx(#"^(?:\d{8}|[XYZ]\d{7})[A-Z]$"#).matches(s) else { return false }
        let first = s.first!
        let num: Int
        if let p = ["X": "0", "Y": "1", "Z": "2"][String(first)] { num = Int(p + String(s.dropFirst().prefix(7)))! }
        else { num = Int(s.prefix(8))! }
        return s.last! == Array("TRWAGMYFPDXBNJZSQVHLCKE")[num % 23]
    }

    // national IDs (dispatched by digit count)
    private static func plPeselOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 11 else { return false }; if (10 - wsum(Array(d.prefix(10)), [1,3,7,9,1,3,7,9,1,3]) % 10) % 10 != d[10] { return false }; let mm = (d[2]*10+d[3]) % 20; return mm >= 1 && mm <= 12 && (d[4]*10+d[5]) >= 1 && (d[4]*10+d[5]) <= 31 }
    private static func nlBsnOk(_ v: String) -> Bool { let d = dl(v); return d.count == 9 && d.contains(where: { $0 != 0 }) && (wsum(Array(d.prefix(8)), [9,8,7,6,5,4,3,2]) - d[8]) % 11 == 0 }
    private static func bgEgnOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 10 else { return false }; var c = wsum(Array(d.prefix(9)), [2,4,8,5,10,9,7,3,6]) % 11; if c == 10 { c = 0 }; guard c == d[9] else { return false }; var mm = d[2]*10+d[3]; mm = (mm >= 21 && mm <= 32) ? mm-20 : (mm >= 41 && mm <= 52) ? mm-40 : mm; return mm >= 1 && mm <= 12 && (d[4]*10+d[5]) >= 1 && (d[4]*10+d[5]) <= 31 }
    private static func roCnpOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 13 else { return false }; var c = wsum(Array(d.prefix(12)), [2,7,9,1,4,6,3,5,8,2,7,9]) % 11; if c == 10 { c = 1 }; return c == d[12] && d[0] >= 1 && d[0] <= 9 && (d[3]*10+d[4]) >= 1 && (d[3]*10+d[4]) <= 12 && (d[5]*10+d[6]) >= 1 && (d[5]*10+d[6]) <= 31 }
    private static func hrOibOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 11 else { return false }; var r = 10; for i in 0..<10 { r = (r + d[i]) % 10; if r == 0 { r = 10 }; r = (r * 2) % 11 }; return (11 - r) % 10 == d[10] }
    private static func eeIsikukoodOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 11 else { return false }; var c = wsum(Array(d.prefix(10)), [1,2,3,4,5,6,7,8,9,1]) % 11; if c == 10 { c = wsum(Array(d.prefix(10)), [3,4,5,6,7,8,9,1,2,3]) % 11; if c == 10 { c = 0 } }; return c == d[10] }
    private static func grAmkaOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 11, (d[2]*10+d[3]) >= 1, (d[2]*10+d[3]) <= 12 else { return false }; return luhnLen(d) }
    private static func ptNifOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 9, [1,2,3,5,6,8,9].contains(d[0]) else { return false }; var c = 11 - wsum(Array(d.prefix(8)), [9,8,7,6,5,4,3,2]) % 11; if c >= 10 { c = 0 }; return c == d[8] }
    private static func frNirOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 15, d[0] == 1 || d[0] == 2 else { return false }; let k = 97 - joinInt(d[0..<13]) % 97; return d[13]*10+d[14] == (k == 0 ? 97 : k) }
    private static func beRrnOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 11 else { return false }; let base = joinInt(d[0..<9]), chk = d[9]*10+d[10]; return (97 - base % 97) % 97 == chk || (97 - (2_000_000_000 + base) % 97) % 97 == chk }
    private static func czRcOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 10 else { return false }; let mm = d[2]*10+d[3]; guard [0,20,50,70].contains(where: { mm-$0 >= 1 && mm-$0 <= 12 }) else { return false }; return joinInt(d[0..<10]) % 11 == 0 }
    private static func siEmsoOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 13, (d[2]*10+d[3]) >= 1, (d[2]*10+d[3]) <= 12 else { return false }; let m = wsum(Array(d.prefix(12)), [7,6,5,4,3,2,7,6,5,4,3,2]) % 11; let chk = m == 0 ? 0 : 11 - m; return chk != 10 && chk == d[12] }
    private static func huAdoazOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 10, d[0] == 8 else { return false }; var c = 0; for i in 0..<9 { c += d[i] * (i + 1) }; c %= 11; return c != 10 && c == d[9] }
    private static func lvPkOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 11, d[0] != 3, (d[2]*10+d[3]) >= 1, (d[2]*10+d[3]) <= 12 else { return false }; return ((1 - wsum(Array(d.prefix(10)), [1,6,3,7,9,10,5,8,4,2])) % 11 + 11) % 11 % 10 == d[10] }
    private static func plNipOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 10 else { return false }; let c = wsum(Array(d.prefix(9)), [6,5,7,2,3,4,5,6,7]) % 11; return c != 10 && c == d[9] }
    private static func itPivaOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 11 else { return false }; var x = 0, y = 0; for i in stride(from: 0, to: 10, by: 2) { x += d[i] }; for i in stride(from: 1, to: 10, by: 2) { let t = d[i]*2; y += t > 9 ? t-9 : t }; return (10 - (x+y) % 10) % 10 == d[10] }
    private static func atSvnrOk(_ v: String) -> Bool { let d = dl(v); guard d.count == 10 else { return false }; let w = [3,7,9,0,5,8,4,2,1,6]; var c = 0; for i in 0..<10 where i != 3 { c += d[i]*w[i] }; c %= 11; return c != 10 && c == d[3] }
    private static func iePpsOk(_ v: String) -> Bool { guard let m = rx(#"^(\d{7})([A-W])([A-W]?)$"#).firstMatch(in: v.uppercased(), range: NSRange(location: 0, length: v.count)) else { return false }; let ns = v.uppercased() as NSString; let d = ns.substring(with: m.range(at: 1)), c1 = ns.substring(with: m.range(at: 2)), c2 = ns.substring(with: m.range(at: 3)); var s = 0; let da = Array(d); for i in 0..<7 { s += Int(String(da[i]))! * (8 - i) }; if let f = c2.unicodeScalars.first, !c2.isEmpty { s += (Int(f.value) - 64) * 9 }; return String(Array("WABCDEFGHIJKLMNOPQRSTUV")[s % 23]) == c1 }
    private static func itCfOk(_ v: String) -> Bool {
        let s = v.uppercased(); guard rx(#"^[A-Z0-9]{16}$"#).matches(s) else { return false }
        let odd: [Character: Int] = ["0":1,"1":0,"2":5,"3":7,"4":9,"5":13,"6":15,"7":17,"8":19,"9":21,"A":1,"B":0,"C":5,"D":7,"E":9,"F":13,"G":15,"H":17,"I":19,"J":21,"K":2,"L":4,"M":18,"N":20,"O":11,"P":3,"Q":6,"R":8,"S":12,"T":14,"U":16,"V":10,"W":22,"X":25,"Y":24,"Z":23]
        let chars = Array(s); var tot = 0
        for i in 0..<15 { if i % 2 == 0 { tot += odd[chars[i]]! } else { tot += (chars[i].isNumber ? Int(String(chars[i]))! : Int(chars[i].asciiValue!) - 65) } }
        return Character(UnicodeScalar(65 + tot % 26)!) == chars[15]
    }
    private static func fiHetuOk(_ v: String) -> Bool { let s = v.replacingOccurrences(of: " ", with: "").uppercased(); guard let m = rx(#"^(\d{6})[-+A-F](\d{3})([0-9A-Y])$"#).firstMatch(in: s, range: NSRange(location: 0, length: s.count)) else { return false }; let ns = s as NSString; let n = Int(ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)))!; return String(Array("0123456789ABCDEFHJKLMNPRSTUVWXY")[n % 31]) == ns.substring(with: m.range(at: 3)) }

    private static let natValidators: [Int: [(String) -> Bool]] = [
        9: [nlBsnOk, ptNifOk],
        10: [bgEgnOk, czRcOk, huAdoazOk, plNipOk, atSvnrOk],
        11: [plPeselOk, hrOibOk, grAmkaOk, eeIsikukoodOk, lvPkOk, beRrnOk, itPivaOk],
        13: [roCnpOk, siEmsoOk],
        15: [frNirOk],
    ]

    // VAT: per-country checksum
    private static let vatFmtOnly: Set<String> = ["ES", "LV", "NL"]
    private static let vat: [String: (String) -> Bool] = {
        func re(_ p: String) -> NSRegularExpression { rx("^" + p + "$") }
        var m: [String: (String) -> Bool] = [
            "AT": { n in guard re(#"U\d{8}"#).matches(n) else { return false }; let d = dl(n); var s = 4; for i in 0..<7 { var x = d[i] * (i % 2 == 1 ? 2 : 1); if x > 9 { x -= 9 }; s += x }; return (10 - s % 10) % 10 == d[7] },
            "BE": { n in re(#"0\d{9}"#).matches(n) && (97 - Int(n.prefix(8))! % 97) == Int(n.suffix(2))! },
            "BG": { n in if re(#"\d{9}"#).matches(n) { let d = dl(n); var s = 0; for i in 0..<8 { s += d[i]*(i+1) }; s %= 11; if s == 10 { s = 0; for i in 0..<8 { s += d[i]*(i+3) }; s %= 11; if s == 10 { s = 0 } }; return s == d[8] }; return re(#"\d{10}"#).matches(n) && bgEgnOk(n) },
            "CY": { n in guard re(#"\d{8}[A-Z]"#).matches(n) else { return false }; let tr = [1,0,5,7,9,13,15,17,19,21]; let d = dl(n); var s = 0; for i in 0..<8 { s += (i % 2 == 0 ? tr[d[i]] : d[i]) }; return Character(UnicodeScalar(65 + s % 26)!) == Array(n)[8] },
            "CZ": { n in if re(#"\d{8}"#).matches(n) { let d = dl(n); var s = 0; for i in 0..<7 { s += d[i]*(8-i) }; s %= 11; return (11 - s) % 10 == d[7] }; return re(#"\d{10}"#).matches(n) && czRcOk(n) },
            "DE": { n in guard re(#"\d{9}"#).matches(n) else { return false }; let d = dl(n); var p = 10; for i in 0..<8 { var s = (d[i] + p) % 10; if s == 0 { s = 10 }; p = (s*2) % 11 }; return (11 - p) % 10 == d[8] },
            "DK": { n in re(#"\d{8}"#).matches(n) && wsum(dl(n), [2,7,6,5,4,3,2,1]) % 11 == 0 },
            "EE": { n in re(#"\d{9}"#).matches(n) && (10 - wsum(Array(dl(n).prefix(8)), [3,7,1,3,7,1,3,7]) % 10) % 10 == dl(n)[8] },
            "EL": { n in guard re(#"\d{9}"#).matches(n) else { return false }; let d = dl(n); var s = 0; for i in 0..<8 { s += d[i] * (1 << (8-i)) }; s %= 11; return (s < 10 ? s : 0) == d[8] },
            "ES": { n in re(#"[A-Z0-9]\d{7}[A-Z0-9]"#).matches(n) },
            "FI": { n in guard re(#"\d{8}"#).matches(n) else { return false }; let d = dl(n); let s = wsum(Array(d.prefix(7)), [7,9,10,5,8,4,2]) % 11; return s != 1 && (s == 0 ? 0 : 11-s) == d[7] },
            "FR": { n in guard re(#"\d{11}"#).matches(n) else { return false }; let siren = String(n.dropFirst(2)); let d = dl(siren); var ls = 0; for i in 0..<d.count { var x = d[d.count-1-i] * (i % 2 == 1 ? 2 : 1); if x > 9 { x -= 9 }; ls += x }; return ls % 10 == 0 && Int(n.prefix(2))! == (12 + 3 * (Int(siren)! % 97)) % 97 },
            "HR": hrOibOk,
            "HU": { n in re(#"\d{8}"#).matches(n) && (10 - wsum(Array(dl(n).prefix(7)), [9,7,3,1,9,7,3]) % 10) % 10 == dl(n)[7] },
            "IE": { n in guard let mm = rx(#"^(\d{7})([A-W])([A-W]?)$"#).firstMatch(in: n, range: NSRange(location: 0, length: n.count)) else { return false }; let ns = n as NSString; let d = Array(ns.substring(with: mm.range(at: 1))); var s = 0; for i in 0..<7 { s += Int(String(d[i]))!*(8-i) }; let c2 = ns.substring(with: mm.range(at: 3)); if let f = c2.unicodeScalars.first, !c2.isEmpty { s += (Int(f.value)-64)*9 }; return String(Array("WABCDEFGHIJKLMNOPQRSTUV")[s % 23]) == ns.substring(with: mm.range(at: 2)) },
            "IT": itPivaOk,
            "LT": { n in guard re(#"\d{9}|\d{12}"#).matches(n) else { return false }; let d = dl(n); let k = d.count; var s = 0; for i in 0..<(k-1) { s += d[i] * ((i % 9)+1) }; s %= 11; if s == 10 { s = 0; for i in 0..<(k-1) { s += d[i] * ((i % 9)+3) }; s %= 11; if s == 10 { s = 0 } }; return s == d[k-1] },
            "LU": { n in re(#"\d{8}"#).matches(n) && Int(n.prefix(6))! % 89 == Int(n.suffix(2))! },
            "LV": { n in re(#"\d{11}"#).matches(n) },
            "MT": { n in re(#"\d{8}"#).matches(n) && (37 - wsum(Array(dl(n).prefix(6)), [3,4,6,7,8,9]) % 37) % 37 == Int(n.suffix(2))! },
            "NL": { n in re(#"\d{9}B\d{2}"#).matches(n) },
            "PL": plNipOk, "PT": ptNifOk,
            "RO": { n in guard re(#"\d{2,10}"#).matches(n) else { return false }; let b = Array(n.dropLast()); let full = [7,5,3,2,1,7,5,3,2]; let w = Array(full.suffix(b.count)); var s = 0; for i in 0..<b.count { s += Int(String(b[i]))!*w[i] }; s = (s*10) % 11; return (s == 10 ? 0 : s) == Int(String(n.last!))! },
            "SE": { n in guard re(#"\d{10}01"#).matches(n) else { return false }; let d = Array(dl(n).prefix(10)); var ls = 0; for i in 0..<10 { var x = d[i] * (i % 2 == 0 ? 2 : 1); if x > 9 { x -= 9 }; ls += x }; return ls % 10 == 0 },
            "SI": { n in guard re(#"\d{8}"#).matches(n) else { return false }; let s = wsum(Array(dl(n).prefix(7)), [8,7,6,5,4,3,2]) % 11; let c = 11 - s; return c != 10 && (c == 11 ? 0 : c) == dl(n)[7] },
            "SK": { n in re(#"\d{10}"#).matches(n) && Int(n)! % 11 == 0 },
        ]
        m["GR"] = m["EL"]
        return m
    }()

    // MARK: helpers
    private static func hasContext(_ re: NSRegularExpression, _ t: UTF16Text, _ start: Int, _ end: Int, _ window: Int = 48) -> Bool {
        re.matches(t.slice(max(0, start - window), min(t.length, end + window)))
    }
    private static func before(_ re: NSRegularExpression, _ t: UTF16Text, _ start: Int, _ window: Int = 64) -> Bool {
        re.matches(t.slice(max(0, start - window), start))
    }
    private static func isIp(_ v: String) -> Bool {
        if rx(#"^(\d{1,3}\.){3}\d{1,3}$"#).matches(v) { return v.split(separator: ".").allSatisfy { (Int($0) ?? 999) <= 255 } }
        if rx(#"^[0-9a-f:]+$"#, [.caseInsensitive]).matches(v), v.contains(":"), v != ":", v != "::" { return v.components(separatedBy: "::").count <= 2 }
        return false
    }
    // trim a document-keyword value that swallowed a following lowercase word
    private static func trimWord(_ t: UTF16Text, _ val0: String, _ end0: Int) -> (String, Int) {
        var chars = Array(val0), end = end0
        while chars.count >= 2, chars[chars.count-1].isLetter, chars[chars.count-2] == " ",
              let sc = t.scalar(at: end), sc.value >= 97, sc.value <= 122 {
            chars.removeLast(2); end -= 2
        }
        return (String(chars), end)
    }

    // MARK: detect
    static func detect(_ text: String, enabled: Set<String>? = nil) -> [Span] {
        let t = UTF16Text(text); let ns = t.ns; let en = enabled ?? owned
        var spans: [Span] = []
        func add(_ s: Int, _ e: Int, _ label: String, _ score: Double = 1.0) { if s < e { spans.append(Span(s, e, label, score)) } }
        func r(_ m: NSTextCheckingResult, _ g: Int = 0) -> NSRange { m.range(at: g) }

        for m in emailRE.matches(ns) { let g = r(m, 1); add(g.location, g.location + g.length, "EMAIL") }
        for m in urlRE.matches(ns) { let g = r(m, 1); if g.location > 0, t.slice(g.location - 1, g.location) == "@" { continue }; add(g.location, g.location + g.length, "URL") }
        for m in ipv4RE.matches(ns) { let a = r(m).location, b = a + r(m).length; if isIp(ns.substring(with: r(m))) && hasContext(ipContext, t, a, b, 40) { add(a, b, "IP_ADDRESS") } }
        for m in ipv6RE.matches(ns) { let v = ns.substring(with: r(m)); if v == ":" || v == "::" { continue }; let a = r(m).location, b = a + r(m).length; if isIp(v) && hasContext(ipContext, t, a, b, 40) { add(a, b, "IP_ADDRESS") } }
        for m in macRE.matches(ns) { add(r(m).location, r(m).location + r(m).length, "IP_ADDRESS") }
        for m in ccRE.matches(ns) {
            let a = r(m).location, b = a + r(m).length; let val = ns.substring(with: r(m))
            let dg = val.filter { $0 >= "0" && $0 <= "9" }; if Set(dg).count <= 1 { continue }
            if luhnOk(val) && creditContext.matches(t.slice(max(0, a - 56), a)) {
                var end = b; while end > a, let s = t.scalar(at: end - 1), " -.".unicodeScalars.contains(s) { end -= 1 }
                add(a, end, "CREDIT_CARD")
            }
        }
        for m in ibanRE.matches(ns) { let a = r(m).location, b = a + r(m).length; if ibanOk(ns.substring(with: r(m))) { add(a, b, "BANK_ACCOUNT") } }
        for m in bicRE.matches(ns) { let a = r(m).location, b = a + r(m).length; if bicOk(ns.substring(with: r(m))) && before(bicBefore, t, a, 64) { add(a, b, "BANK_ACCOUNT") } }
        for m in esDniRE.matches(ns) { let a = r(m).location, b = a + r(m).length; if esDniOk(ns.substring(with: r(m))) && hasContext(govContext, t, a, b, 56) { add(a, b, "GOVERNMENT_ID") } }
        for m in natIdRE.matches(ns) { let a = r(m).location, b = a + r(m).length; let d = ns.substring(with: r(m)); if let vals = natValidators[dl(d).count], vals.contains(where: { $0(d) }), hasContext(natIdContext, t, a, b, 64) { add(a, b, "GOVERNMENT_ID", 0.92) } }
        for m in itCfRE.matches(ns) { let a = r(m).location, b = a + r(m).length; if itCfOk(ns.substring(with: r(m))) { add(a, b, "GOVERNMENT_ID", 0.95) } }
        for m in fiHetuRE.matches(ns) { let a = r(m).location, b = a + r(m).length; if fiHetuOk(ns.substring(with: r(m))) { add(a, b, "GOVERNMENT_ID", 0.95) } }
        for m in dkCprRE.matches(ns) { let a = r(m).location, b = a + r(m).length; let d = dl(ns.substring(with: r(m))); if (d[0]*10+d[1]) >= 1 && (d[0]*10+d[1]) <= 31 && (d[2]*10+d[3]) >= 1 && (d[2]*10+d[3]) <= 12 && before(dkCprContext, t, a, 40) { add(a, b, "GOVERNMENT_ID", 0.85) } }
        for m in vatRE.matches(ns) { let a = r(m).location, b = a + r(m).length; let cc = ns.substring(with: r(m, 1)); let num = ns.substring(with: r(m, 2)).replacingOccurrences(of: " ", with: "").uppercased(); if let fn = vat[cc], fn(num), (!vatFmtOnly.contains(cc) || hasContext(vatContext, t, a, b, 40)) { add(a, b, "TAX_ID", 0.95) } }
        for m in imeiRE.matches(ns) { let a = r(m).location, b = a + r(m).length; if imeiOk(ns.substring(with: r(m))) && hasContext(imeiContext, t, a, b, 32) { add(a, b, "IMEI", 0.9) } }
        for m in ssnRE.matches(ns) { let a = r(m).location, b = a + r(m).length; if validUsSsn(ns.substring(with: r(m))) || hasContext(ssnContext, t, a, b) { add(a, b, "SSN") } }
        for m in sePnRE.matches(ns) { let a = r(m).location, b = a + r(m).length; if validSePn(ns.substring(with: r(m))) || before(sePnContext, t, a, 40) { add(a, b, "GOVERNMENT_ID") } }
        for m in passportValRE.matches(ns) { let a = r(m).location, b = a + r(m).length; let v = ns.substring(with: r(m)); if v.contains(where: { $0 >= "0" && $0 <= "9" }) && before(passportContext, t, a, 32) { add(a, b, "PASSPORT") } }
        for m in dlKwRE.matches(ns) {
            let g2 = r(m, 2); guard g2.location != NSNotFound else { continue }
            let (val, end) = trimWord(t, ns.substring(with: g2), g2.location + g2.length)
            if val.filter({ $0.isLetter || $0.isNumber }).count >= 5 { add(g2.location, end, "DRIVERS_LICENSE", 0.9) }
        }
        for m in plDlRE.matches(ns) { add(r(m).location, r(m).location + r(m).length, "DRIVERS_LICENSE", 0.9) }
        for m in docIdKwRE.matches(ns) {
            let g2 = r(m, 2); guard g2.location != NSNotFound else { continue }
            let (val, end) = trimWord(t, ns.substring(with: g2), g2.location + g2.length)
            if val.contains(where: { $0 >= "0" && $0 <= "9" }) && val.filter({ $0.isLetter || $0.isNumber }).count >= 6 {
                let lab = passportKwRE.matches(ns.substring(with: r(m, 1))) ? "PASSPORT" : "GOVERNMENT_ID"
                add(g2.location, end, lab, 0.9)
            }
        }
        for m in ppsRE.matches(ns) { let a = r(m).location, b = a + r(m).length; if iePpsOk(ns.substring(with: r(m))) || hasContext(ppsContext, t, a, b, 32) { add(a, b, "GOVERNMENT_ID") } }
        for m in contextDigitRE.matches(ns) { let a = r(m).location, b = a + r(m).length; let d = digitCount(ns.substring(with: r(m))); let bef = t.slice(max(0, a - 56), a); if d >= 7 && d <= 12 && ssnContext.matches(bef) && !taxContext.matches(bef) { add(a, b, "SSN", 0.9) } }
        for m in routingRE.matches(ns) { let a = r(m).location, b = a + r(m).length; if abaRoutingOk(ns.substring(with: r(m))) && hasContext(routingContext, t, a, b) { add(a, b, "ROUTING_NUMBER") } }
        for m in intlPhoneRE.matches(ns) { let a = r(m).location, b = a + r(m).length; let n = digitCount(ns.substring(with: r(m))); if n >= 8, n <= 15 { add(a, b, "PHONE", 0.92) } }
        for m in genericPhoneRE.matches(ns) { let a = r(m).location, b = a + r(m).length; let raw = ns.substring(with: r(m)); let dg = digitCount(raw); let bef = t.slice(max(0, a - 56), a); let grouped = raw.contains(where: { " .-".contains($0) }); if phoneContext.matches(bef), (dg >= 9 && dg <= 15) || (dg >= 7 && dg <= 8 && grouped) { add(a, b, "PHONE", 0.88) } }

        return merge(spans).filter { en.contains($0.label) }
    }

    private static func merge(_ spans: [Span]) -> [Span] {
        let ordered = spans.sorted {
            $0.start != $1.start ? $0.start < $1.start
                : ($0.end - $0.start) != ($1.end - $1.start) ? ($0.end - $0.start) > ($1.end - $1.start)
                : $0.label < $1.label
        }
        var out: [Span] = []
        for s in ordered {
            if out.isEmpty || s.start >= out[out.count - 1].end { out.append(s) }
            else { let p = out[out.count - 1]; let sl = s.end - s.start, pl = p.end - p.start; if sl > pl || (sl == pl && s.score > p.score) { out[out.count - 1] = s } }
        }
        return out
    }
}
