# Redact: On-device PII Redaction

Redact is a small on-device Swift package that finds and masks personally identifiable information (PII) in text: names, addresses, emails, phone numbers, cards, IBANs, national IDs, and more, across all 24 official EU languages. Everything runs on device and your text never leaves the phone. Scrub PII from customer support records, LLM prompts, and application logs so the raw data never reaches a server, yours or a third party's.

Redaction is reversible: mask PII before sending text to an LLM, then restore the originals in the response. Keep the placeholder mapping and the result is pseudonymized; drop it and the masked copy is anonymized.

```swift
import Redact

let redact = Redact()

let r = try await redact.redaction(of: "Email Anna Kovács at anna@example.hu.")
r.redactedText            // "Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1]."
r.items.first?.original   // "Anna"
```

## Features

- Runs fully on-device using Core ML; text never leaves the device
- Detects 20 categories: names, addresses, emails, phone numbers, credit cards, IBANs, national IDs, and more
- Supports all 24 official EU languages (Latin, Greek, and Cyrillic scripts)
- Validates structured fields with a dependency-free layer: Luhn cards, ISO-13616 IBANs, checksummed national IDs for all 24 EU countries, all 27 EU VAT numbers, IMEI, and per-country driving licences
- Reversible redaction with unique, numbered placeholders for safe LLM round-trips
- Small 4-bit Core ML model (~13 MB), downloaded on demand and cached, or bundled in your app
- One Swift core for every platform: iOS/macOS (SwiftPM), Android (Maven Central), and web (npm)

## Installation

Add this package to your app with Swift Package Manager.

```swift
.package(url: "https://github.com/Desert-Ant-Labs/redact.git", from: "0.3.0")
```

Then add the `Redact` product to your app target.

## Usage

Create one `Redact` and reuse it. Construction is cheap and non-blocking: it kicks off loading the model in the background (downloading it on first use), and the first `redaction(of:)` awaits it off your calling thread. The core API is a single method.

### Redact and inspect

```swift
import Redact

let redact = Redact()
let r = try await redact.redaction(of: text)

// Masked text with unique, numbered placeholders
print(r.redactedText)                 // "Call [PHONE_1] or email [EMAIL_1]"

// Every detection, with its category, original value, confidence, and range
for item in r.items {
    print(item.label.displayName, item.original, item.confidence)
}
```

### Filter by category

Detect and mask only certain categories, for example contact details while leaving IDs untouched:

```swift
let opts = Options(labels: [.email, .phone, .creditCard, .bankAccount])
let contactOnly = try await redact.redaction(of: text, options: opts)
```

Custom placeholders? Build the string yourself from `r.items`, where each carries the `range` and `original` value, so you can substitute anything (`"••••"` or `"⟨\(item.label.displayName)⟩"`).

### Reversible redaction (LLM round-trip)

Mask PII to unique placeholders, hand the placeholdered text to an LLM or any external service, then fill the originals back in on-device. The sensitive values never leave the phone.

```swift
let r = try await redact.redaction(of: userText)
// r.redactedText: "Email [EMAIL_1] and [EMAIL_2] about [BANK_ACCOUNT_1]."

let reply = try await myLLM.rewrite(r.redactedText)   // sees only placeholders

let final = r.restore(reply)                          // originals filled back in
```

Placeholders are numbered per category (`[EMAIL_1]`, `[EMAIL_2]`, …), so two emails never collapse into one and restoration is order-independent. Instruct your LLM to keep the `[LABEL_N]` tokens verbatim.

### Choosing where the model comes from

The model is **downloaded on demand by default** and cached, so your app stays
small. Construction is always cheap and non-blocking; loading (and any download)
happens in the background and the first `redaction(of:)` awaits it.

```swift
let redact = Redact()                       // download to the managed cache
let redact = Redact(directory: myModelDir)  // the model lives here (use or download)
let redact = Redact(bundle: myBundle)       // bundled in your app (offline)
```

The model revision is pinned to the SDK version. `directory:` is where the model
lives: if it already holds the files (you pre-downloaded or shipped them there)
they are used offline; otherwise the model is downloaded there and reused offline
afterward. With no `directory`, a managed cache location is used.

Construction never downloads; the model loads on the first `redaction(of:)`.
To control *when* that happens (e.g. at launch with a progress bar), call
`download` yourself. Concurrent calls and an implicit load share one download:

```swift
let redact = Redact()
if !redact.isDownloaded() {
    try await redact.download { fraction in print("\(Int(fraction * 100))%") }
}
// … first redaction is now instant
```

To ship the model **inside your app** instead of downloading, add a model
resources product and pass its bundle:

```swift
// Package.swift: add `.product(name: "RedactCoreMLResources", package: "redact")`
import RedactCoreMLResources
let redact = Redact(bundle: RedactCoreMLResourcesBundle.bundle)
```

## API

```swift
public final class Redact: Sendable {
    public init(directory: String? = nil)   // the model dir; download if absent (default managed cache)
    public init(bundle: Bundle)             // bundled in your app (offline)
    public func redaction(of text: String, options: Options = .init()) async throws -> Redaction

    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws
    public func isDownloaded() -> Bool
}

public struct Options: Sendable {
    public var minimumConfidence: Double   // neural threshold, default 0.6
    public var labels: Set<Label>?         // nil = detect every category
}

public struct Redaction: Sendable {
    public let redactedText: String        // originals replaced by [LABEL_N] placeholders
    public let items: [Item]               // every detection, in document order
    public func restore(_ processed: String) -> String

    public struct Item: Identifiable, Sendable, Equatable {
        public let label: Label
        public let original: String        // the matched sensitive text
        public let placeholder: String     // e.g. "[EMAIL_1]"
        public let confidence: Double      // 0...1 (deterministic recognizers report 1.0)
        public let range: Range<String.Index>
    }
}

public enum Label: String, CaseIterable, Sendable {
    case givenName, surname, streetName, buildingNumber, secondaryAddress,
         city, state, zipCode, email, phone, creditCard, bankAccount,
         routingNumber, ipAddress, url, governmentID, passport,
         driversLicense, taxID, ssn
    public var displayName: String { get }
}
```

## Example App

A SwiftUI example is included in `Examples/RedactExample`. Pick a sample or type your own text and watch PII get highlighted or masked live, entirely on device (the same interaction as the web demo). Open `Examples/RedactExample/RedactExample.xcodeproj` in Xcode and run.

## How it works

A tiny 6-layer multilingual token classifier (Core ML, 4-bit) handles contextual PII (names, streets, messy natural-language data) while a dependency-free deterministic layer owns the structured fields with real validation: Luhn cards, ISO-13616 IBANs, BIC/VIN, checksum-validated national IDs for all 24 EU countries, all 27 EU VAT numbers, IMEI, and per-country driving-licence numbers, plus portable recognizers for street addresses, `City, ST ZIP` state codes, and apartment/unit designators. The two are reconciled so the checksummed rules win where they fire and the model owns everything else. It mirrors the Python training pipeline exactly (span-for-span parity).

## Requirements

iOS 16+ / macOS 13+ / tvOS 16+ / visionOS 1+, Swift 5.9+.

## One core, every platform

This package is also the single source of truth for the Android/Kotlin and
node/browser distributions: the same Swift pipeline cross-compiles to Android
(via the Swift SDK for Android + ONNX Runtime) and WebAssembly (inference via
onnxruntime-web/-node on the JS side). See [ARCHITECTURE.md](ARCHITECTURE.md)
for how the platform seams are organized and [PACKAGING.md](PACKAGING.md) for
building the Kotlin and npm artifacts in `packages/`.

## Model

The bundled model is published at [`desert-ant-labs/redact`](https://huggingface.co/desert-ant-labs/redact) on Hugging Face: full weights, the compiled Core ML build, and the model card.

## Other platforms

Same model, same Swift core, shipped from this repository (see
[PACKAGING.md](PACKAGING.md)):

- Android: `ai.desertant:redact` on Maven Central (Kotlin over the
  cross-compiled Swift core; optional `ai.desertant:redact-onnx-resources` to
  bundle the model).
- Web: [`@desert-ant-labs/redact`](https://www.npmjs.com/package/@desert-ant-labs/redact)
  on npm (node + browsers; the core compiled to WebAssembly).
- Model weights and card: [`desert-ant-labs/redact`](https://huggingface.co/desert-ant-labs/redact) on Hugging Face.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.ai/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.ai>.

Third-party data and model attributions are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
