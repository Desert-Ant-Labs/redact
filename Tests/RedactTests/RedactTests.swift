import XCTest
import Foundation
@testable import Redact
#if canImport(CoreML)
import RedactCoreMLResources
#else
import RedactONNXResources
#endif

/// Thread-safe Double for capturing progress across concurrency domains.
final class LockedDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func set(_ v: Double) { lock.withLock { value = v } }
    func get() -> Double { lock.withLock { value } }
}

final class RedactTests: XCTestCase {
    // MARK: deterministic recognizers (no model needed)

    func testEmailAndURL() {
        let spans = Deterministic.detect("Reach me at anna.k@example.com or https://ex.com/x")
        let labels = Set(spans.map(\.label))
        XCTAssertTrue(labels.contains("EMAIL"))
        XCTAssertTrue(labels.contains("URL"))
    }

    func testCreditCardLuhnGated() {
        // valid Luhn + context means detected
        let ok = Deterministic.detect("charge my card 4539 1488 0343 6467")
        XCTAssertTrue(ok.contains { $0.label == "CREDIT_CARD" })
        // invalid Luhn means not a credit card
        let bad = Deterministic.detect("card 1234 5678 9012 3456")
        XCTAssertFalse(bad.contains { $0.label == "CREDIT_CARD" })
    }

    func testIBANChecksum() {
        let ok = Deterministic.detect("IBAN GB29 NWBK 6016 1331 9268 19")
        XCTAssertTrue(ok.contains { $0.label == "BANK_ACCOUNT" })
    }

    func testUSStreetAndState() {
        let t = UTF16Text("mailed to 123 Any Street, Seattle, WA 98109")
        let spans = Pipeline.attachStateCodes(t, Pipeline.redactUsStreet(t, []))
        let byLabel = Dictionary(grouping: spans) { $0.label }
        XCTAssertEqual(byLabel["BUILDING_NUMBER"]?.count, 1)
        XCTAssertTrue(byLabel["STREET_NAME"]?.contains { t.slice($0.start, $0.end) == "Any Street" } ?? false)
        XCTAssertTrue(byLabel["STATE"]?.contains { t.slice($0.start, $0.end) == "WA" } ?? false)
    }

    func testSecondaryAddress() {
        let t = UTF16Text("123 Main St, Apt 4B")
        let spans = Pipeline.redactSecondaryAddress(t, [])
        XCTAssertTrue(spans.contains { $0.label == "SECONDARY_ADDRESS" && t.slice($0.start, $0.end) == "Apt 4B" })
        // precision: ordinary prose is left alone
        let prose = UTF16Text("unit tests pass")
        XCTAssertTrue(Pipeline.redactSecondaryAddress(prose, []).isEmpty)
    }

    func testTokenizerRejectsTruncatedData() {
        XCTAssertNil(Tokenizer(bytes: [0x52, 0x44, 0x54, 0x4B]))
        var header = [UInt8](repeating: 0, count: 21)
        header.replaceSubrange(0...3, with: [0x52, 0x44, 0x54, 0x4B])
        XCTAssertNil(Tokenizer(bytes: header))
    }

    func testOptionsClampInvalidConfidence() {
        XCTAssertEqual(Options(minimumConfidence: -1).minimumConfidence, 0)
        XCTAssertEqual(Options(minimumConfidence: 2).minimumConfidence, 1)
        XCTAssertEqual(Options(minimumConfidence: .nan).minimumConfidence, 0.6)
    }

    func testTokenizerLoads() throws {
        #if canImport(CoreML)
        let bundle = RedactCoreMLResourcesBundle.bundle
        #else
        let bundle = RedactONNXResourcesBundle.bundle
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: "redact_tokenizer", withExtension: "bin"))
        let tok = try XCTUnwrap(Tokenizer(bytes: [UInt8](try Data(contentsOf: url))))
        XCTAssertEqual(tok.bosID, 0)
        XCTAssertEqual(tok.eosID, 2)
        XCTAssertFalse(tok.tokenize("Contact Anna Kovács in Berlin").isEmpty)
    }

    // MARK: deterministic parity vs the Python reference (1354 cases)

    func testDeterministicCorpusParity() throws {
        struct Row: Decodable {
            let text: String
            let py: [Expected]
        }
        struct Expected: Decodable {
            let start: Int, end: Int, label: String
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                start = try c.decode(Int.self)
                end = try c.decode(Int.self)
                label = try c.decode(String.self)
            }
        }
        let enabled: Set<String> = [
            "EMAIL", "URL", "IP_ADDRESS", "CREDIT_CARD", "BANK_ACCOUNT", "GOVERNMENT_ID",
            "TAX_ID", "PASSPORT", "DRIVERS_LICENSE", "IMEI", "SSN", "ROUTING_NUMBER", "PHONE",
        ]
        let url = try XCTUnwrap(Bundle.module.url(forResource: "deterministic_corpus", withExtension: "json"))
        let rows = try JSONDecoder().decode([Row].self, from: try Data(contentsOf: url))
        XCTAssertGreaterThan(rows.count, 1000)
        var failures: [String] = []
        for row in rows {
            let got = Set(Deterministic.detect(row.text, enabled: enabled).map { "\($0.start),\($0.end),\($0.label)" })
            let want = Set(row.py.map { "\($0.start),\($0.end),\($0.label)" })
            if got != want { failures.append("\(row.text): want \(want.sorted()) got \(got.sorted())") }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) mismatches\n" + failures.prefix(5).joined(separator: "\n"))
    }

    // MARK: end-to-end (requires the platform model backend)

    /// A redactor from the bundled resources (offline, no download).
    private func bundledRedact() -> Redact {
        #if canImport(CoreML)
        Redact(bundle: RedactCoreMLResourcesBundle.bundle)
        #else
        Redact(bundle: RedactONNXResourcesBundle.bundle)
        #endif
    }

    func testLocalModelDirectory() async throws {
        #if canImport(CoreML)
        let bundle = RedactCoreMLResourcesBundle.bundle
        let modelName = "redact.mlmodelc"
        let modelURL = try XCTUnwrap(bundle.url(forResource: "redact", withExtension: "mlmodelc"))
        #else
        let bundle = RedactONNXResourcesBundle.bundle
        let modelName = "redact.onnx"
        let modelURL = try XCTUnwrap(bundle.url(forResource: "redact", withExtension: "onnx"))
        #endif
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("redact-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: modelURL, to: directory.appendingPathComponent(modelName))
        for (name, ext) in [("redact_tokenizer", "bin"), ("labels", "json")] {
            let source = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext))
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("\(name).\(ext)"))
        }

        let redact = Redact(directory: directory.path)
        XCTAssertTrue(redact.isDownloaded())
        XCTAssertFalse(Redact(directory: directory.path + "-missing").isDownloaded())

        // A directory holding an interrupted download (a `.dal-meta` marker but
        // no verified manifest) is not adopted as a complete model.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".dal-meta"), withIntermediateDirectories: true)
        XCTAssertFalse(Redact(directory: directory.path).isDownloaded())
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".dal-meta"))

        // download drives the load to completion and reports final progress.
        let progress = LockedDouble()
        try await redact.download { progress.set($0) }
        XCTAssertEqual(progress.get(), 1.0, accuracy: 0.0001)

        // Concurrent redactions share the single load (no crash, both succeed).
        async let a = redact.redaction(of: "Email anna@example.com")
        async let b = redact.redaction(of: "Email bob@example.com")
        let (ra, rb) = try await (a, b)
        XCTAssertTrue(ra.redactedText.contains("[EMAIL_1]"))
        XCTAssertTrue(rb.redactedText.contains("[EMAIL_1]"))
    }

    func testRedactEndToEnd() async throws {
        let redact = bundledRedact()
        let r = try await redact.redaction(of: "Email Anna Kovács at anna@example.hu.")
        XCTAssertTrue(r.redactedText.contains("[EMAIL_1]"))
        XCTAssertFalse(r.redactedText.contains("anna@example.hu"))
        XCTAssertFalse(r.redactedText.contains("Anna"))
    }

    func testLabelFilter() async throws {
        let redact = bundledRedact()
        let text = "Call +34 600 100 200 or email me@x.com"
        let phonesOnly = try await redact.redaction(of: text, options: .init(labels: [.phone]))
        XCTAssertTrue(phonesOnly.items.allSatisfy { $0.label == .phone })
        XCTAssertTrue(phonesOnly.items.contains { $0.original.contains("600") })
        XCTAssertTrue(phonesOnly.redactedText.contains("[PHONE_1]"))     // phone redacted
        XCTAssertTrue(phonesOnly.redactedText.contains("me@x.com"))      // email kept (filtered out)
    }

    func testReversibleRoundTrip() async throws {
        let redact = bundledRedact()
        let text = "Email anna@example.hu and bob@example.hu about the invoice."
        let r = try await redact.redaction(of: text)
        XCTAssertEqual(r.items.filter { $0.label == .email }.count, 2)
        XCTAssertTrue(r.redactedText.contains("[EMAIL_1]"))
        XCTAssertTrue(r.redactedText.contains("[EMAIL_2]"))
        XCTAssertFalse(r.redactedText.contains("example.hu"))
        // An LLM rewrites the text but keeps the placeholders.
        let rewritten = "Please contact [EMAIL_1] (cc [EMAIL_2]) regarding the invoice."
        let restored = r.restore(rewritten)
        XCTAssertTrue(restored.contains("anna@example.hu"))
        XCTAssertTrue(restored.contains("bob@example.hu"))
        XCTAssertFalse(restored.contains("[EMAIL_"))
    }
}
