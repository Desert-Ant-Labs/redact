import XCTest
@testable import Redact
import RedactResources

final class RedactTests: XCTestCase {
    // MARK: deterministic recognizers (no model needed)

    func testEmailAndURL() {
        let spans = Deterministic.detect("Reach me at anna.k@example.com or https://ex.com/x")
        let labels = Set(spans.map(\.label))
        XCTAssertTrue(labels.contains("EMAIL"))
        XCTAssertTrue(labels.contains("URL"))
    }

    func testCreditCardLuhnGated() {
        // valid Luhn + context → detected
        let ok = Deterministic.detect("charge my card 4539 1488 0343 6467")
        XCTAssertTrue(ok.contains { $0.label == "CREDIT_CARD" })
        // invalid Luhn → not a credit card
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

    func testTokenizerLoads() throws {
        let url = try XCTUnwrap(RedactResourcesBundle.bundle.url(forResource: "redact_tokenizer", withExtension: "bin"))
        let tok = try XCTUnwrap(Tokenizer(bytes: [UInt8](try Data(contentsOf: url))))
        XCTAssertEqual(tok.bosID, 0)
        XCTAssertEqual(tok.eosID, 2)
        XCTAssertFalse(tok.tokenize("Contact Anna Kovács in Berlin").isEmpty)
    }

    // MARK: end-to-end (requires Core ML — runs on macOS/iOS)

    func testRedactEndToEnd() async throws {
        let redact = Redact()
        let r = try await redact.redaction(of: "Email Anna Kovács at anna@example.hu.")
        XCTAssertTrue(r.redactedText.contains("[EMAIL_1]"))
        XCTAssertFalse(r.redactedText.contains("anna@example.hu"))
        XCTAssertFalse(r.redactedText.contains("Anna"))
    }

    func testLabelFilter() async throws {
        let redact = Redact()
        let text = "Call +34 600 100 200 or email me@x.com"
        let phonesOnly = try await redact.redaction(of: text, options: .init(labels: [.phone]))
        XCTAssertTrue(phonesOnly.items.allSatisfy { $0.label == .phone })
        XCTAssertTrue(phonesOnly.items.contains { $0.original.contains("600") })
        XCTAssertTrue(phonesOnly.redactedText.contains("[PHONE_1]"))     // phone redacted
        XCTAssertTrue(phonesOnly.redactedText.contains("me@x.com"))      // email kept (filtered out)
    }

    func testReversibleRoundTrip() async throws {
        let redact = Redact()
        let text = "Email anna@example.hu and bob@example.hu about the invoice."
        let r = try await redact.redaction(of: text)
        XCTAssertEqual(r.items.filter { $0.label == .email }.count, 2)
        XCTAssertTrue(r.redactedText.contains("[EMAIL_1]"))
        XCTAssertTrue(r.redactedText.contains("[EMAIL_2]"))
        XCTAssertFalse(r.redactedText.contains("example.hu"))
        // an LLM rewrites the text but keeps the placeholders
        let rewritten = "Please contact [EMAIL_1] (cc [EMAIL_2]) regarding the invoice."
        let restored = r.restore(rewritten)
        XCTAssertTrue(restored.contains("anna@example.hu"))
        XCTAssertTrue(restored.contains("bob@example.hu"))
        XCTAssertFalse(restored.contains("[EMAIL_"))
    }
}
