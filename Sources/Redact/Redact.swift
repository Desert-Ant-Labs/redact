#if !os(WASI)
import Foundation
#endif

/// A redaction: text with unique placeholders, plus the mapping needed to
/// inspect the detections and restore the originals after out-of-band
/// processing (e.g. an LLM).
///
/// ```swift
/// let r = try await redact.redaction(of: userText)
/// let reply = try await llm.rewrite(r.redactedText)   // sees only [EMAIL_1], [GIVEN_NAME_1], …
/// let final = r.restore(reply)                          // originals filled back in
/// ```
public struct Redaction: Sendable {
    /// A single detected entity and the placeholder that stands in for it.
    public struct Item: Sendable, Identifiable, Equatable {
        public var id: String { placeholder }
        /// The category of personal data.
        public let label: Label
        /// The original (sensitive) text that was matched.
        public let original: String
        /// The unique, restorable placeholder, e.g. `"[EMAIL_1]"`.
        public let placeholder: String
        /// The model's confidence, `0...1` (deterministic recognizers report `1.0`).
        public let confidence: Double
        /// The entity's range in the *original* text.
        public let range: Range<String.Index>
    }

    /// The text with each entity replaced by its unique placeholder.
    public let redactedText: String
    /// Every detected entity, in document order.
    public let items: [Item]

    /// Fill the originals back into `processed` (typically an LLM's output) by
    /// substituting each placeholder. Placeholders are bracket-delimited and
    /// numbered (`[EMAIL_1]`, `[EMAIL_2]`, …) so they are unique and never a
    /// prefix of one another — restoration is order-independent and safe.
    public func restore(_ processed: String) -> String {
        var out = processed
        for item in items { out = out.replacing(item.placeholder, with: item.original) }
        return out
    }
}

/// Options controlling detection and redaction.
public struct Options: Sendable {
    /// Minimum confidence for neural detections. Structured recognizers
    /// (email, cards, IBANs, …) always apply. Default `0.6`.
    public var minimumConfidence: Double
    /// If set, only these categories are detected/redacted; otherwise all are.
    public var labels: Set<Label>?

    public init(minimumConfidence: Double = 0.6, labels: Set<Label>? = nil) {
        self.minimumConfidence = minimumConfidence
        self.labels = labels
    }
}

/// Errors thrown while loading or running the bundled model.
/// (`LocalizedError` is Foundation-only, so it is skipped on WASI.)
#if os(WASI)
public enum RedactError: Error, Sendable {
    case resourceMissing
    case predictionFailed
}
#else
public enum RedactError: Error, LocalizedError, Sendable {
    case resourceMissing
    case predictionFailed

    public var errorDescription: String? {
        switch self {
        case .resourceMissing: "A Redact model resource was not found in the package bundle."
        case .predictionFailed: "On-device PII detection failed."
        }
    }
}
#endif

/// On-device, multilingual PII redaction.
///
/// `Redact` finds names, addresses, emails, phone numbers, cards, IBANs,
/// national IDs and more across the 24 official EU languages, fully on device.
/// Create one once and reuse it.
///
/// ```swift
/// let redact = Redact()
/// let r = try await redact.redaction(of: "Email Anna at anna@example.com.")
/// r.redactedText            // "Email [GIVEN_NAME_1] at [EMAIL_1]."
/// r.items.first?.original   // "Anna"
/// ```
public final class Redact: @unchecked Sendable {
    private let modelTask: Task<Model, Error>

    /// Creates a redactor and begins loading the small bundled model in the
    /// background. Returns immediately; the first ``redaction(of:options:)``
    /// call awaits the load, so nothing ever blocks your UI thread.
    public init() {
        modelTask = Task.detached(priority: .userInitiated) { try Model() }
    }

    /// Detect and redact the PII in `text`.
    ///
    /// The result's ``Redaction/redactedText`` has each entity replaced by a
    /// unique placeholder (`[EMAIL_1]`, `[GIVEN_NAME_1]`, …); ``Redaction/items``
    /// lists every detection (label, original text, placeholder, confidence,
    /// range); and ``Redaction/restore(_:)`` fills the originals back in.
    public func redaction(of text: String, options: Options = .init()) async throws -> Redaction {
        let model = try await modelTask.value
        let spans = try await model.detect(text, minScore: options.minimumConfidence)
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        let units = Array(text.utf16)
        var counts: [Label: Int] = [:]
        var items: [Redaction.Item] = []
        var out: [UInt16] = []
        var last = 0
        for span in spans {
            guard let label = Label(rawValue: span.label) else { continue }
            if let allowed = options.labels, !allowed.contains(label) { continue }
            let s = span.start, e = span.end
            guard s >= last, s < e, e <= units.count else { continue }   // in order, non-overlapping
            let n = (counts[label] ?? 0) + 1
            counts[label] = n
            let placeholder = "[\(label.rawValue)_\(n)]"
            let original = String(decoding: units[s..<e], as: UTF16.self)
            let range = String.Index(utf16Offset: s, in: text)..<String.Index(utf16Offset: e, in: text)
            items.append(.init(label: label, original: original, placeholder: placeholder,
                               confidence: span.score, range: range))
            out.append(contentsOf: units[last..<s])
            out.append(contentsOf: Array(placeholder.utf16))
            last = e
        }
        out.append(contentsOf: units[last...])
        return Redaction(redactedText: String(decoding: out, as: UTF16.self), items: items)
    }
}
