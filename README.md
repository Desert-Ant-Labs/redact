# Redact

On-device multilingual PII redaction for Swift, Android, and JavaScript. Redact finds and masks personal data in text: names, addresses, emails, phone numbers, cards, IBANs, national IDs, VAT numbers, URLs, IP addresses, and more across all 24 official EU languages. Everything runs locally, so your text never leaves the device or browser.

Redaction is reversible. Mask PII before sending text to an LLM or another service, then restore the originals in the response on device. Keep the placeholder mapping and the result is pseudonymized; drop it and the masked copy is anonymized.

```text
Email Anna Kovács at anna@example.hu.
Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1].
```

## Packages

| Platform | Package | Runtime |
| --- | --- | --- |
| Swift, iOS, macOS, tvOS, visionOS | `https://github.com/Desert-Ant-Labs/redact.git` | Core ML on Apple platforms, ONNX Runtime on Linux |
| Android | `ai.desertant:redact` | Cross-compiled Swift core plus ONNX Runtime |
| JavaScript, Node and browsers | `@desert-ant-labs/redact` | Shared Swift core compiled to WebAssembly plus ONNX Runtime |

All three packages use the same redaction pipeline, the same pinned model revision, and the same placeholder format.

## Features

- Runs fully on device or in the local runtime. Text never leaves the machine.
- Detects 20 model categories plus deterministic IMEI: names, addresses, emails, phone numbers, credit cards, IBANs, routing numbers, IP addresses, URLs, government IDs, passports, driving licences, tax IDs, SSNs, and more.
- Supports all 24 official EU languages, including Latin, Greek, and Cyrillic scripts.
- Validates structured fields with dependency-free rules: Luhn cards, ISO-13616 IBANs, BIC, VIN, checksum-validated national IDs for all 24 EU countries, all 27 EU VAT numbers, IMEI, and per-country driving licences.
- Reversible redaction with unique numbered placeholders such as `[EMAIL_1]` and `[BANK_ACCOUNT_1]`.
- Small 4-bit model, downloaded on demand and cached by default, or bundled for offline apps.

## Swift

### Install

Add Redact with Swift Package Manager:

```swift
.package(url: "https://github.com/Desert-Ant-Labs/redact.git", from: "0.3.0")
```

Then add the `Redact` product to your app target.

To bundle the Core ML model for fully offline Apple apps, also add `RedactCoreMLResources` to your target.

### Usage

Create one `Redact` and reuse it. Construction is cheap and non-blocking. The model loads on first use, or earlier if you call `download`.

```swift
import Redact

let redact = Redact()
let result = try await redact.redaction(of: "Email Anna Kovács at anna@example.hu.")

print(result.redactedText)
// Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1].

for item in result.items {
    print(item.label.displayName, item.original, item.confidence)
}

let reply = try await myLLM.rewrite(result.redactedText)
let restored = result.restore(reply)
```

Filter by category:

```swift
let options = Options(labels: [.email, .phone, .creditCard, .bankAccount])
let contactOnly = try await redact.redaction(of: text, options: options)
```

Choose where the model comes from:

```swift
let redact = Redact()                       // managed cache, download on demand
let redact = Redact(directory: myModelDir)  // explicit model directory
let redact = Redact(bundle: myBundle)       // bundled model resources
```

Download ahead of time, for example from an onboarding screen:

```swift
let redact = Redact()
if !redact.isDownloaded() {
    try await redact.download { fraction in
        print("\(Int(fraction * 100))%")
    }
}
```

Bundle the model in an Apple app:

```swift
import Redact
import RedactCoreMLResources

let redact = Redact(bundle: RedactCoreMLResourcesBundle.bundle)
```

### Swift API

```swift
public final class Redact: Sendable {
    public init(directory: String? = nil)
    public init(bundle: Bundle)
    public func redaction(of text: String, options: Options = .init()) async throws -> Redaction
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws
    public func isDownloaded() -> Bool
}

public struct Options: Sendable {
    public var minimumConfidence: Double
    public var labels: Set<Label>?
}

public struct Redaction: Sendable {
    public let redactedText: String
    public let items: [Item]
    public func restore(_ processed: String) -> String
}
```

## Android

### Install

Redact is published to Maven Central.

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

// build.gradle.kts
dependencies {
    implementation("ai.desertant:redact:0.3.0")
}
```

`ai.desertant:redact` downloads the model on demand and caches it under the app cache directory. To ship the ONNX model inside your APK or app bundle instead, add the resources artifact and use `Redact.bundled()`:

```kotlin
dependencies {
    implementation("ai.desertant:redact:0.3.0")
    implementation("ai.desertant:redact-onnx-resources:0.3.0")
}
```

### Usage

```kotlin
import ai.desertant.redact.Options
import ai.desertant.redact.Redact

val redact = Redact(context)                 // download on demand, cached
val result = redact.redaction("Email Anna at anna@example.com.")

println(result.redactedText)
// Email [GIVEN_NAME_1] at [EMAIL_1].

for (item in result.items) {
    println("${item.label} ${item.original} ${item.confidence} ${item.start}..${item.end}")
}

val reply = myLlm.rewrite(result.redactedText)
val restored = result.restore(reply)

redact.close()
```

Use `use` to close the native handle automatically:

```kotlin
Redact(context).use { redact ->
    val result = redact.redaction(text)
}
```

Filter by category:

```kotlin
val result = redact.redaction(
    text,
    Options(labels = setOf("EMAIL", "PHONE", "CREDIT_CARD", "BANK_ACCOUNT"))
)
```

Download before first use:

```kotlin
val redact = Redact(context)
if (!redact.isDownloaded()) {
    redact.download()
}
```

Use an explicit model directory or bundled resources:

```kotlin
val cached = Redact(context)                         // managed cache
val explicit = Redact(context, directory = modelDir) // explicit model directory
val offline = Redact.bundled()                       // needs redact-onnx-resources
```

### Android API

```kotlin
class Redact : AutoCloseable {
    constructor(context: Context, directory: String? = null)
    companion object { fun bundled(): Redact }

    fun isDownloaded(): Boolean
    suspend fun download()
    suspend fun redaction(text: String, options: Options = Options()): Redaction
    override fun close()
}

data class Options(
    val minimumConfidence: Double = 0.6,
    val labels: Set<String>? = null,
)

data class Redaction(
    val redactedText: String,
    val items: List<RedactionItem>,
) {
    fun restore(processed: String): String
}
```

## JavaScript and TypeScript

### Install

Node:

```bash
npm install @desert-ant-labs/redact onnxruntime-node
```

Browsers and bundlers:

```bash
npm install @desert-ant-labs/redact onnxruntime-web
```

The ONNX Runtime package is a peer dependency so apps can choose the runtime that matches their environment.

### Usage

```js
import { Redact } from "@desert-ant-labs/redact";

const redact = await Redact.load();
const result = await redact.redaction("Email Anna at anna@example.com.");

console.log(result.redactedText);
// Email [GIVEN_NAME_1] at [EMAIL_1].

for (const item of result.items) {
  console.log(item.label, item.original, item.confidence, item.start, item.end);
}

const reply = await llm(result.redactedText);
const restored = result.restore(reply);
```

Filter by category:

```js
const result = await redact.redaction(text, {
  labels: ["EMAIL", "PHONE", "CREDIT_CARD", "BANK_ACCOUNT"],
});
```

Control loading:

```js
const redact = await Redact.load({
  directory: "/var/cache/redact",       // Node only, optional
  onProgress: (fraction) => console.log(fraction),
});
```

Bring your own ONNX Runtime module, useful for browser bundlers and React Native:

```js
import * as ort from "onnxruntime-web";
import { Redact } from "@desert-ant-labs/redact";

const redact = await Redact.load({ ort });
```

### TypeScript API

```ts
class Redact {
  static load(options?: LoadOptions): Promise<Redact>;
  redaction(text: string, options?: Options): Promise<Redaction>;
}

interface LoadOptions {
  directory?: string;
  onProgress?: (fraction: number) => void;
  ort?: unknown;
}

interface Options {
  minimumConfidence?: number;
  labels?: Iterable<string>;
}

interface Redaction {
  redactedText: string;
  items: RedactionItem[];
  restore(processed: string): string;
}
```

## Reversible redaction for LLMs

All platforms return the same redaction shape: masked text, ordered items, and a `restore` helper.

```text
Input:  Email anna@example.com and bob@example.com about IBAN DE89370400440532013000.
Masked: Email [EMAIL_1] and [EMAIL_2] about IBAN [BANK_ACCOUNT_1].
```

Placeholders are numbered per category, so two emails never collapse into one and restoration is order-independent. Tell your LLM to preserve `[LABEL_N]` tokens verbatim.

## Categories

`GIVEN_NAME`, `SURNAME`, `STREET_NAME`, `BUILDING_NUMBER`, `SECONDARY_ADDRESS`, `CITY`, `STATE`, `ZIP_CODE`, `EMAIL`, `PHONE`, `CREDIT_CARD`, `BANK_ACCOUNT`, `ROUTING_NUMBER`, `IP_ADDRESS`, `URL`, `GOVERNMENT_ID`, `PASSPORT`, `DRIVERS_LICENSE`, `TAX_ID`, `SSN`, and `IMEI`.

`IMEI` is deterministic-only. Structured recognizers report confidence `1.0`; neural detections use `minimumConfidence`, default `0.6`.

## Model and caching

The model artifacts are published at [`desert-ant-labs/redact`](https://huggingface.co/desert-ant-labs/redact) on Hugging Face. Each SDK pins the model revision to its own package version.

Default behavior:

- Swift: downloads the Core ML model on demand to a managed cache, or uses bundled `RedactCoreMLResources`.
- Android: downloads the ONNX model on demand to app cache, or uses bundled `ai.desertant:redact-onnx-resources`.
- JavaScript: downloads the ONNX model on `Redact.load()` to the managed cache in Node or browser cache storage when available.

Passing an explicit `directory` makes that directory the model home. Existing valid files are adopted for offline use; otherwise Redact downloads into that directory and reuses it later.

## Examples

A SwiftUI example app is included in `Examples/RedactExample`. Open `Examples/RedactExample/RedactExample.xcodeproj` in Xcode and run.

The JavaScript package README in `packages/redact-node` contains the npm-specific quick start that is published to npm.

## Development

This repository builds all three distributions from one Swift core.

```bash
mise run build-swift
mise run build-android
mise run build-web

mise run test-swift
mise run test-android
mise run test-web
mise run test
```

Release tasks:

```bash
mise run set-version 0.3.1
mise run publish-swift
mise run publish-android
mise run publish-web
```

`mise.local.toml` is gitignored and is the place for machine-local release credentials such as `ANDROID_HOME`, Maven Central portal credentials, signing keys, and `NPM_TOKEN`. Mark secrets with `redact = true` so mise masks them in task output.

## Requirements

- Swift: iOS 16+, macOS 13+, tvOS 16+, visionOS 1+, Swift 5.9+.
- Android: Android API 24+. The AAR contains prebuilt arm64-v8a and x86_64 native libraries.
- JavaScript: modern Node or browser runtime with `onnxruntime-node` or `onnxruntime-web`.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.ai/1.0). Free for most apps; a commercial license is required at scale. Full terms are at the link. Licensing: <licensing@desertant.ai>.

Third-party data and model attributions are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
